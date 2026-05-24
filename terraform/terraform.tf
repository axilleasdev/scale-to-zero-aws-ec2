terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # Optional: enable a remote backend for shared state.
  # backend "s3" {
  #   bucket = "your-tfstate-bucket"
  #   key    = "scale-to-zero-aws-ec2/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

# Primary provider — all workload resources live here.
provider "aws" {
  region = var.aws_region
}

# CloudFront ACM certs MUST live in us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
