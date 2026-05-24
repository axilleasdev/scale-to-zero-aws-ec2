# Setup Guide

> Step-by-step instructions for deploying the stack on your own AWS account.

## Prerequisites

- AWS account with admin access (or scoped IAM user)
- Terraform >= 1.5 installed
- A domain managed by a DNS provider (Cloudflare, Route53, etc.)
- `aws-vault` or equivalent for credential management (recommended)

## Steps

### 1. Clone and configure

```bash
git clone https://github.com/axilleasdev/scale-to-zero-aws-ec2.git
cd scale-to-zero-aws-ec2/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values.

### 2. First apply (creates cert, fails on validation)

```bash
terraform init
terraform apply
```

This will **fail** at `aws_acm_certificate_validation` — that's expected.
Look at the output `acm_validation_record` and add that CNAME to your DNS provider.

### 3. Delegate the origin subdomain

Add the NS records from `route53_nameservers` output to your DNS provider.

### 4. Second apply (completes everything)

```bash
terraform apply
```

### 5. Point your public domain at CloudFront

Add a CNAME record:
```
CNAME  <your-subdomain>  →  <cloudfront_domain output>
```

### 6. Deploy your app on the EC2

```bash
aws ssm start-session --target <ec2_instance_id output>
# ... install your app, docker compose up, etc.
```

### 7. Test

Visit `https://<your-public-domain>` — you should see the loading page,
then your app after 30-60 seconds.

## Teardown

```bash
terraform destroy
```

Note: the EBS data volume has `prevent_destroy = true`. Remove that
lifecycle rule first if you want a full teardown.
