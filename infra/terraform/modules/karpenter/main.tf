###############################################################################
# Karpenter: the capacity layer for all application + GPU workloads.
# Provides the controller IAM role (IRSA), the node IAM role reuse, the spot
# interruption SQS queue, and the Helm release. NodePools/EC2NodeClasses are
# delivered through GitOps (deploy/argocd/platform/karpenter-nodepools) so that
# capacity policy is reviewed like any other change.
###############################################################################
locals { tags = merge(var.tags, { Module = "karpenter" }) }

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

########################  Spot interruption queue  ############################
resource "aws_sqs_queue" "interruption" {
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags                      = local.tags
}

data "aws_iam_policy_document" "queue" {
  statement {
    sid       = "EC2InterruptionPolicy"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.interruption.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }
}

resource "aws_sqs_queue_policy" "interruption" {
  queue_url = aws_sqs_queue.interruption.url
  policy    = data.aws_iam_policy_document.queue.json
}

resource "aws_cloudwatch_event_rule" "this" {
  for_each = {
    spot_interruption = { source = ["aws.ec2"], detail_type = ["EC2 Spot Instance Interruption Warning"] }
    rebalance         = { source = ["aws.ec2"], detail_type = ["EC2 Instance Rebalance Recommendation"] }
    instance_state    = { source = ["aws.ec2"], detail_type = ["EC2 Instance State-change Notification"] }
    scheduled_change  = { source = ["aws.health"], detail_type = ["AWS Health Event"] }
  }

  name          = "${var.cluster_name}-karpenter-${each.key}"
  event_pattern = jsonencode({ "source" = each.value.source, "detail-type" = each.value.detail_type })
  tags          = local.tags
}

resource "aws_cloudwatch_event_target" "this" {
  for_each  = aws_cloudwatch_event_rule.this
  rule      = each.value.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.interruption.arn
}

#########################  Controller IAM (IRSA)  #############################
data "aws_iam_policy_document" "controller_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:karpenter"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "controller" {
  name               = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.controller_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "controller" {
  statement {
    sid       = "AllowScopedEC2InstanceActions"
    actions   = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
  }

  statement {
    sid = "AllowRegionalReadActions"
    actions = [
      "ec2:DescribeImages", "ec2:DescribeInstances", "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes", "ec2:DescribeLaunchTemplates", "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory", "ec2:DescribeSubnets", "ec2:DescribeAvailabilityZones",
      "pricing:GetProducts",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [data.aws_region.current.name]
    }
  }

  statement {
    sid       = "AllowScopedTerminationAndTagging"
    actions   = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate", "ec2:CreateTags"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
  }

  statement {
    sid       = "AllowPassingNodeRole"
    actions   = ["iam:PassRole"]
    resources = [var.node_role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  statement {
    sid = "AllowInstanceProfileManagement"
    actions = [
      "iam:CreateInstanceProfile", "iam:AddRoleToInstanceProfile", "iam:GetInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile", "iam:TagInstanceProfile",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"]
  }

  statement {
    sid       = "AllowInterruptionQueueActions"
    actions   = ["sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
    resources = [aws_sqs_queue.interruption.arn]
  }

  statement {
    sid       = "AllowClusterEndpointLookup"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${data.aws_partition.current.partition}:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"]
  }

  statement {
    sid       = "AllowSSMReadAmis"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:*::parameter/aws/service/*"]
  }
}

resource "aws_iam_role_policy" "controller" {
  name   = "karpenter-controller"
  role   = aws_iam_role.controller.id
  policy = data.aws_iam_policy_document.controller.json
}

##############################  Helm release  #################################
resource "helm_release" "karpenter" {
  count = var.install_via_helm ? 1 : 0

  name             = "karpenter"
  namespace        = var.namespace
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.chart_version
  wait             = true

  values = [yamlencode({
    serviceAccount = {
      annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.controller.arn }
    }
    settings = {
      clusterName       = var.cluster_name
      clusterEndpoint   = var.cluster_endpoint
      interruptionQueue = aws_sqs_queue.interruption.name
      featureGates      = { spotToTimeout = true }
    }
    controller = {
      resources = {
        requests = { cpu = "1", memory = "1Gi" }
        limits   = { memory = "1Gi" }
      }
    }
    replicas            = 2
    tolerations         = [{ key = "CriticalAddonsOnly", operator = "Exists", effect = "NoSchedule" }]
    nodeSelector        = { "workload-class" = "system" }
    podDisruptionBudget = { name = "karpenter", maxUnavailable = 1 }
    serviceMonitor      = { enabled = true }
  })]
}
