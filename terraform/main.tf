# ============================================================
# terraform/main.tf
#
# Provider configuration, backend, and shared locals.
# Every resource file reads `local.name_prefix` and `local.tags`
# so naming and tagging are consistent across the project.
# ============================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # ------------------------------------------------------------
  # Remote state — S3 backend with DynamoDB state locking.
  #
  # Before first `terraform init`, create the resources manually:
  #   aws s3 mb s3://cloudpulse-tfstate-<your-account-id> --region us-east-1
  #   aws s3api put-bucket-versioning --bucket cloudpulse-tfstate-<your-account-id> \
  #     --versioning-configuration Status=Enabled
  #   aws dynamodb create-table --table-name cloudpulse-tfstate-lock \
  #     --attribute-definitions AttributeName=LockID,AttributeType=S \
  #     --key-schema AttributeName=LockID,KeyType=HASH \
  #     --billing-mode PAY_PER_REQUEST --region us-east-1
  #
  # Then uncomment this block and fill in your bucket name.
  # Keeping it commented lets the repo work with local state
  # out of the box for first-time reviewers.
  # ------------------------------------------------------------
  # backend "s3" {
  #   bucket         = "cloudpulse-tfstate-<your-account-id>"
  #   key            = "cloudpulse/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "cloudpulse-tfstate-lock"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

# ------------------------------------------------------------
# Current AWS account info (used for bucket names, ARNs)
# ------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ------------------------------------------------------------
# Shared locals — every .tf file references these
# ------------------------------------------------------------

locals {
  # Short prefix: "cloudpulse-dev"
  name_prefix = "${var.project}-${var.environment}"

  # Account ID used to make S3 bucket names globally unique
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name

  # Merged tags applied to every resource via provider default_tags
  tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "https://github.com/UTKARSH698/Cloud_Pulse"
    },
    var.tags,
  )
}
