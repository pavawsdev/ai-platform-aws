###############################################################################
# EKS control plane + system node group.
# Design notes:
#  - API endpoint is private by default; public access is CIDR-restricted and
#    only enabled in dev. Prod access is via SSM session manager / VPN bastion.
#  - Envelope encryption of Kubernetes secrets with a dedicated CMK.
#  - All control-plane log types shipped to CloudWatch (audit trail requirement).
#  - authentication_mode = API_AND_CONFIG_MAP with EKS access entries, so
#    cluster access is IAM-managed and auditable instead of aws-auth ConfigMap
#    edits.
#  - Only a small managed node group for system/platform addons. Every
#    application pod is scheduled onto Karpenter-provisioned capacity.
###############################################################################
locals {
  tags = merge(var.tags, { Module = "eks" })
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

###############################  Cluster IAM  #################################
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSVPCResourceController",
  ])
  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

############################  Cluster security group  #########################
#checkov:skip=CKV_AWS_382:the EKS-managed control-plane ENIs need broad HTTPS/DNS/etc
#  egress to reach AWS APIs (STS, ECR, CloudWatch, ...) and to run add-ons; scoping
#  this to specific AWS service CIDRs would need to track AWS's published IP ranges
#  and still not cover every endpoint the control plane calls.
resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster"
  description = "EKS control plane"
  vpc_id      = var.vpc_id

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name                     = "${var.cluster_name}-cluster"
    "karpenter.sh/discovery" = var.cluster_name
  })
}

################################  Cluster  ####################################
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = local.tags
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.public_access_cidrs
  }

  kubernetes_network_config {
    ip_family         = "ipv4"
    service_ipv4_cidr = var.service_ipv4_cidr
  }

  encryption_config {
    provider { key_arn = var.eks_kms_key_arn }
    resources = ["secrets"]
  }

  upgrade_policy { support_type = "STANDARD" }

  tags       = local.tags
  depends_on = [aws_iam_role_policy_attachment.cluster, aws_cloudwatch_log_group.cluster]
}

##############################  OIDC / IRSA  ##################################
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  tags            = local.tags
}

###########################  Access entries (RBAC)  ###########################
resource "aws_eks_access_entry" "this" {
  for_each = var.access_entries

  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = each.value.principal_arn
  kubernetes_groups = try(each.value.kubernetes_groups, null)
  type              = try(each.value.type, "STANDARD")
  tags              = local.tags
}

resource "aws_eks_access_policy_association" "this" {
  for_each = {
    for item in flatten([
      for k, v in var.access_entries : [
        for policy in try(v.policy_associations, []) : {
          key           = "${k}-${replace(policy.policy_arn, "/[^a-zA-Z0-9]/", "")}"
          principal_arn = v.principal_arn
          policy_arn    = policy.policy_arn
          access_scope  = policy.access_scope
        }
      ]
    ]) : item.key => item
  }

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type       = each.value.access_scope.type
    namespaces = try(each.value.access_scope.namespaces, null)
  }

  depends_on = [aws_eks_access_entry.this]
}

##############################  Node IAM role  ################################
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(local.tags, { "karpenter.sh/discovery" = var.cluster_name })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_eks_access_entry" "node" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"
}

##########################  System managed node group  ########################
resource "aws_launch_template" "system" {
  name_prefix = "${var.cluster_name}-system-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # pods cannot reach IMDS
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 80
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.data_kms_key_arn
      delete_on_termination = true
    }
  }

  monitoring { enabled = true }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${var.cluster_name}-system" })
  }

  tags = local.tags

  lifecycle { create_before_destroy = true }
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  capacity_type   = "ON_DEMAND"
  instance_types  = var.system_instance_types

  scaling_config {
    desired_size = var.system_desired_size
    min_size     = var.system_min_size
    max_size     = var.system_max_size
  }

  update_config { max_unavailable_percentage = 33 }

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }

  labels = {
    "workload-class"          = "system"
    "node.kubernetes.io/role" = "system"
  }

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = local.tags

  lifecycle { ignore_changes = [scaling_config[0].desired_size] }

  depends_on = [aws_iam_role_policy_attachment.node]
}

################################  Addons  #####################################
data "aws_eks_addon_version" "this" {
  for_each           = var.addons
  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "this" {
  for_each = var.addons

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  service_account_role_arn    = try(each.value.service_account_role_arn, null)
  configuration_values        = try(each.value.configuration_values, null)
  tags                        = local.tags

  depends_on = [aws_eks_node_group.system]
}
