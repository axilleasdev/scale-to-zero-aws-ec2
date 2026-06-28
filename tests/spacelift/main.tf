terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# Test 1: demo mode (cats-vs-dogs)
module "demo" {
  source = "../.."

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix = "ci-demo"
  deploy_mode = "demo"

  apps = {
    voting = { port = 8080 }
  }
}

# Test 2: custom mode (nginx)
module "custom" {
  source = "../.."

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix = "ci-cust"
  deploy_mode = "custom"

  docker_compose_content = <<-YAML
    services:
      web:
        image: nginx:alpine
        ports:
          - "8080:80"
  YAML

  apps = {
    nginx = { port = 8080 }
  }
}

output "demo_url" {
  value = module.demo.public_url["voting"]
}

output "custom_url" {
  value = module.custom.public_url["nginx"]
}
