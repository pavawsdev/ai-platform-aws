###############################################################################
# Generic IRSA role factory.
# One role per Kubernetes ServiceAccount. The trust policy is pinned to the
# exact namespace/serviceaccount pair, so a pod in another namespace cannot
# assume it even if it guesses the role ARN.
###############################################################################
data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = var.max_session_duration
  # A permissions boundary means even a mis-scoped inline policy cannot escalate
  permissions_boundary = var.permissions_boundary_arn
  tags = merge(var.tags, {
    Module         = "iam-irsa"
    ServiceAccount = "${var.namespace}/${var.service_account}"
  })
}

resource "aws_iam_role_policy" "inline" {
  count  = var.policy_json == null ? 0 : 1
  name   = "${var.role_name}-inline"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(var.managed_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}
