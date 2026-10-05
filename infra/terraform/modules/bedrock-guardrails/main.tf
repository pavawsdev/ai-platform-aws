###############################################################################
# Bedrock Guardrails + model access policy.
#
# The platform runs guardrails at two layers:
#   L1 (this module) - managed Bedrock Guardrails: content filters, denied
#                      topics, PII redaction, word policy, contextual grounding.
#   L2 (application) - services/ai-gateway/app/guardrails.py: prompt-injection
#                      classifier, schema/tool allow-list, output validation,
#                      token/cost ceilings.
# L1 alone is not enough (it does not know our tool surface); L2 alone is not
# enough (it cannot be attested to an auditor as a managed control). See
# docs/adr/0006-guardrail-layering.md.
###############################################################################
locals { tags = merge(var.tags, { Module = "bedrock-guardrails" }) }

resource "aws_bedrock_guardrail" "this" {
  name                      = "${var.name}-guardrail"
  description               = "Platform-wide content, topic and PII guardrail"
  blocked_input_messaging   = var.blocked_input_messaging
  blocked_outputs_messaging = var.blocked_output_messaging
  kms_key_arn               = var.kms_key_arn

  content_policy_config {
    dynamic "filters_config" {
      for_each = var.content_filters
      content {
        type            = filters_config.value.type
        input_strength  = filters_config.value.input_strength
        output_strength = filters_config.value.output_strength
      }
    }
  }

  sensitive_information_policy_config {
    dynamic "pii_entities_config" {
      for_each = var.pii_entities
      content {
        type   = pii_entities_config.value.type
        action = pii_entities_config.value.action
      }
    }

    dynamic "regexes_config" {
      for_each = var.custom_pii_regexes
      content {
        name        = regexes_config.value.name
        description = regexes_config.value.description
        pattern     = regexes_config.value.pattern
        action      = regexes_config.value.action
      }
    }
  }

  dynamic "topic_policy_config" {
    for_each = length(var.denied_topics) > 0 ? [1] : []
    content {
      dynamic "topics_config" {
        for_each = var.denied_topics
        content {
          name       = topics_config.value.name
          type       = "DENY"
          definition = topics_config.value.definition
          examples   = topics_config.value.examples
        }
      }
    }
  }

  word_policy_config {
    dynamic "managed_word_lists_config" {
      for_each = var.block_profanity ? [1] : []
      content { type = "PROFANITY" }
    }
  }

  # Contextual grounding: the RAG answer must be supported by the retrieved
  # context and relevant to the question. This is the hallucination control.
  contextual_grounding_policy_config {
    filters_config {
      type      = "GROUNDING"
      threshold = var.grounding_threshold
    }
    filters_config {
      type      = "RELEVANCE"
      threshold = var.relevance_threshold
    }
  }

  tags = local.tags
}

resource "aws_bedrock_guardrail_version" "this" {
  guardrail_arn = aws_bedrock_guardrail.this.guardrail_arn
  description   = "Managed by Terraform"

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Model invocation logging - every Bedrock call is recorded (governance)
###############################################################################
resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  count = var.manage_invocation_logging ? 1 : 0

  logging_config {
    embedding_data_delivery_enabled = true
    image_data_delivery_enabled     = false
    text_data_delivery_enabled      = true

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.invocations.name
      role_arn       = aws_iam_role.invocation_logging.arn

      large_data_delivery_s3_config {
        bucket_name = var.audit_bucket_name
        key_prefix  = "bedrock/large"
      }
    }

    s3_config {
      bucket_name = var.audit_bucket_name
      key_prefix  = "bedrock/invocations" # gitleaks:allow - S3 prefix, not a secret
    }
  }
}

resource "aws_cloudwatch_log_group" "invocations" {
  name              = "/aws/bedrock/${var.name}/invocations"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = local.tags
}

resource "aws_iam_role" "invocation_logging" {
  name = "${var.name}-bedrock-invocation-logging"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "invocation_logging" {
  role = aws_iam_role.invocation_logging.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.invocations.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${var.audit_bucket_name}/bedrock/*"
      }
    ]
  })
}
