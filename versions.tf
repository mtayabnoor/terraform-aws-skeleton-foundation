terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.9"
    }
    # Only used when enable_eks and enable_argocd are true. The provider
    # itself is configured by the calling root module (see README).
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0"
    }
  }
}
