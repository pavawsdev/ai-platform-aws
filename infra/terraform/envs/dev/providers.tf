provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_eks_cluster_auth" "this" {
  name = module.platform.cluster_name
}

provider "helm" {
  kubernetes = {
    host                   = module.platform.cluster_endpoint
    cluster_ca_certificate = base64decode(module.platform.cluster_ca)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
