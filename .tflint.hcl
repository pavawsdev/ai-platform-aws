plugin "aws" {
  enabled = true
  version = "0.35.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
  deep_check = false
}

config {
  call_module_type = "all"
}

rule "terraform_required_version" { enabled = true }
rule "terraform_required_providers" { enabled = true }
rule "terraform_unused_declarations" { enabled = true }
rule "terraform_deprecated_interpolation" { enabled = true }
rule "terraform_documented_variables" { enabled = false }
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}
rule "terraform_module_pinned_source" { enabled = true }

# Instance types are chosen by Karpenter from a requirements list, not pinned
# here, so this rule would only produce noise.
rule "aws_instance_previous_type" { enabled = false }
