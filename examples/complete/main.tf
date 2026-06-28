terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Optional: remote backend for shared state.
  # backend "s3" {
  #   bucket = "your-tfstate-bucket"
  #   key    = "scale-to-zero/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = "eu-central-1"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

module "scale_to_zero" {
  source = "../.."

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix = "demo"
  deploy_mode = "demo"
  app_port    = 8080

  # Optional: custom domain
  # public_domain    = "app.example.com"
  # origin_subdomain = "origin.app-aws.example.com"
  # origin_zone_name = "app-aws.example.com"
}

output "public_url" {
  value = module.scale_to_zero.public_url
}

output "cloudfront_domain" {
  value = module.scale_to_zero.cloudfront_domain
}

output "ec2_instance_id" {
  value = module.scale_to_zero.ec2_instance_id
}

output "ssm_connect_command" {
  value = module.scale_to_zero.ssm_connect_command
}
