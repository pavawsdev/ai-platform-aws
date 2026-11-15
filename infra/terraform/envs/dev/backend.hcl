bucket         = "aiplat-tfstate-111122223333"
key            = "dev/platform/terraform.tfstate"
region         = "ap-south-1"
dynamodb_table = "aiplat-tflock"
encrypt        = true
kms_key_id     = "alias/aiplat-tfstate"
