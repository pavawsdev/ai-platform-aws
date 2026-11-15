terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws  = { source = "hashicorp/aws", version = ">= 5.60" }
    helm = { source = "hashicorp/helm", version = "~> 3.0" }
    tls  = { source = "hashicorp/tls", version = ">= 4.0" }
  }
}
