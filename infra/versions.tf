terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.38.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }

  # Uncomment and fill in to keep state in S3.
  # backend "s3" {
  #   bucket       = "my-terraform-state-bucket"
  #   key          = "claims-assist-agentcore/terraform.tfstate"
  #   region       = "eu-west-1"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Repo      = "claims-assist-agentcore"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
