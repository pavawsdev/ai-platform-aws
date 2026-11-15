terraform {
  backend "s3" {
    # Values supplied by -backend-config in the pipeline:
    #   bucket, key, region, dynamodb_table, kms_key_id, role_arn
    # See infra/terraform/bootstrap and .github/workflows/terraform.yml
    encrypt = true
  }
}
