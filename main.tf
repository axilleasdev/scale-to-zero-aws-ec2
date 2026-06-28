locals {
  # Route53 zone is used when origin_zone_name is explicitly provided OR public_domain is set
  use_custom_domain = var.origin_zone_name != "" || var.public_domain != ""

  # Multi-app: use var.apps if provided, otherwise single-app from var.app_port
  effective_apps = length(var.apps) > 0 ? var.apps : {
    default = { port = var.app_port, domain = var.public_domain }
  }

  # With custom domain: use a public delegated Route53 zone (like make-iac-great).
  # Without: skip Route53, use EC2 public IP directly as CloudFront origin.
  origin_zone_name = var.origin_zone_name != "" ? var.origin_zone_name : "${var.name_prefix}-origin.internal"
  origin_subdomain = var.origin_subdomain != "" ? var.origin_subdomain : "ec2.${local.origin_zone_name}"

  common_tags = merge(
    {
      Project   = var.name_prefix
      ManagedBy = "terraform"
      Repo      = "scale-to-zero-aws-ec2"
    },
    var.tags,
  )
}

# Default VPC + a default subnet in the first AZ. We don't manage VPC
# resources here — bring-your-own VPC would be a separate module.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "default_a" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = "${var.aws_region}a"
  default_for_az    = true
}

# Latest Ubuntu 24.04 LTS ARM64 from Canonical.
data "aws_ami" "ubuntu_arm" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
