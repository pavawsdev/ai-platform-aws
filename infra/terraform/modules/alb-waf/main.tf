###############################################################################
# Edge: ACM cert + WAFv2 web ACL consumed by the AWS Load Balancer Controller.
# The ALB itself is created by the controller from the Kubernetes Ingress
# (see deploy/helm/ai-gateway/templates/ingress.yaml); Terraform owns the
# security primitives the ingress references by ARN.
#
# WAF rule set is deliberately AI-aware: on top of the AWS managed baseline we
# add a prompt-injection heuristic rule group and a per-principal rate limit
# so a single leaked API key cannot burn the monthly token budget.
###############################################################################
locals { tags = merge(var.tags, { Module = "alb-waf" }) }

resource "aws_acm_certificate" "this" {
  count = var.create_certificate ? 1 : 0

  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"
  tags                      = local.tags

  lifecycle { create_before_destroy = true }
}

resource "aws_wafv2_ip_set" "blocklist" {
  name               = "${var.name}-blocklist"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.blocked_cidrs
  tags               = local.tags
}

resource "aws_wafv2_regex_pattern_set" "prompt_injection" {
  name  = "${var.name}-prompt-injection"
  scope = "REGIONAL"
  tags  = local.tags

  dynamic "regular_expression" {
    for_each = var.prompt_injection_patterns
    content { regex_string = regular_expression.value }
  }
}

resource "aws_wafv2_web_acl" "this" {
  name        = "${var.name}-web-acl"
  description = "Edge protection for the AI platform API"
  scope       = "REGIONAL"

  default_action { allow {} }

  # 1. Deny-listed source IPs
  rule {
    name     = "ip-blocklist"
    priority = 0
    action { block {} }
    statement {
      ip_set_reference_statement { arn = aws_wafv2_ip_set.blocklist.arn }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ip-blocklist"
      sampled_requests_enabled   = true
    }
  }

  # 2. AWS managed baselines
  dynamic "rule" {
    for_each = { for i, r in var.managed_rule_groups : r.name => merge(r, { priority = i + 1 }) }
    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        dynamic "none" {
          for_each = rule.value.count_only ? [] : [1]
          content {}
        }
        dynamic "count" {
          for_each = rule.value.count_only ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  # 3. Global rate limit per source IP
  rule {
    name     = "rate-limit-ip"
    priority = 50
    action { block {} }
    statement {
      rate_based_statement {
        limit              = var.rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-ip"
      sampled_requests_enabled   = true
    }
  }

  # 4. Per-API-key rate limit: the real cost control at the edge
  rule {
    name     = "rate-limit-api-key"
    priority = 51
    action { block {} }
    statement {
      rate_based_statement {
        limit              = var.rate_limit_per_key_5min
        aggregate_key_type = "CUSTOM_KEY"
        custom_key {
          header {
            name = "x-api-key"
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-api-key"
      sampled_requests_enabled   = true
    }
  }

  # 5. Coarse prompt-injection screen at the edge. The authoritative check is
  #    in the guardrail pipeline; this only sheds the obvious volumetric abuse.
  rule {
    name     = "prompt-injection-screen"
    priority = 60
    action {
      dynamic "block" {
        for_each = var.prompt_injection_block ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.prompt_injection_block ? [] : [1]
        content {}
      }
    }
    statement {
      regex_pattern_set_reference_statement {
        arn = aws_wafv2_regex_pattern_set.prompt_injection.arn
        field_to_match { body { oversize_handling = "CONTINUE" } }
        text_transformation {
          priority = 0
          type     = "LOWERCASE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "prompt-injection-screen"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-web-acl"
    sampled_requests_enabled   = true
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = local.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # Never log the prompt body or auth material
  redacted_fields {
    single_header { name = "authorization" }
  }
  redacted_fields {
    single_header { name = "x-api-key" }
  }
}
