##################################################################################
# OUTPUTS
#
# After `terraform apply`, these tell you everything you need to:
#   - point your DNS provider at CloudFront
#   - delegate the origin subdomain to Route53
#   - validate the ACM cert
#   - SSH/SSM into the EC2
##################################################################################

output "ec2_instance_id" {
  description = "EC2 instance ID (use for SSM Session Manager: aws ssm start-session --target ...)."
  value       = aws_instance.app.id
}

output "ec2_public_ip" {
  description = "Current public IP of the EC2 (changes on every start). Empty when stopped."
  value       = aws_instance.app.public_ip
}

output "data_volume_id" {
  description = "Persistent EBS data volume — survives instance stop/start/terminate."
  value       = aws_ebs_volume.data.id
}

output "api_gateway_endpoint" {
  description = "API Gateway endpoint (used by CloudFront as the failover origin)."
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "cloudfront_domain" {
  description = "CloudFront distribution domain. Point your public_domain CNAME here."
  value       = aws_cloudfront_distribution.main.domain_name
}

output "public_url" {
  description = "Final public URL. If using a custom domain, point its CNAME to cloudfront_domain."
  value       = local.use_custom_domain ? "https://${var.public_domain}" : "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "route53_nameservers" {
  description = "ADD THESE as NS records in your DNS provider so origin_zone_name is delegated to Route53."
  value       = aws_route53_zone.origin.name_servers
}

output "origin_record_name" {
  description = "Hostname CloudFront uses as the primary origin (auto-updated by dns-updater Lambda)."
  value       = aws_route53_record.origin.name
}

output "acm_validation_record" {
  description = "ADD THIS in your DNS provider so ACM can validate the certificate. Only needed with a custom domain."
  value = local.use_custom_domain ? {
    for dvo in aws_acm_certificate.public[0].domain_validation_options :
    dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  } : {}
}

output "router_function_name" {
  description = "Lambda router function (manual invoke for debugging)."
  value       = aws_lambda_function.router.function_name
}

output "dns_updater_function_name" {
  description = "Lambda dns-updater function (auto-triggered by EventBridge)."
  value       = aws_lambda_function.dns_updater.function_name
}

output "auto_stop_function_name" {
  description = "Lambda auto-stop function (runs every 5 minutes)."
  value       = aws_lambda_function.auto_stop.function_name
}

output "ssm_connect_command" {
  description = "Quick SSM Session Manager connect command."
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.aws_region}"
}
