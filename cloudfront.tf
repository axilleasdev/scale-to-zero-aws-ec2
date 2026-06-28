##################################################################################
# CloudFront distributions — one per app in local.effective_apps.
#
# Each app gets its own CloudFront + optional ACM cert. They share the
# same EC2 origin (different port) and API Gateway (Lambda reads port
# from X-App-Port header).
##################################################################################

##################################################################################
# ACM certs (us-east-1) — only for apps with a custom domain
##################################################################################

resource "aws_acm_certificate" "app" {
  for_each          = { for k, v in local.effective_apps : k => v if v.domain != "" }
  provider          = aws.us_east_1
  domain_name       = each.value.domain
  validation_method = "DNS"

  lifecycle { create_before_destroy = true }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${each.key}-cert" })
}

resource "aws_acm_certificate_validation" "app" {
  for_each        = aws_acm_certificate.app
  provider        = aws.us_east_1
  certificate_arn = each.value.arn
}

##################################################################################
# Cache + origin request policies (shared across all apps)
##################################################################################

resource "aws_cloudfront_cache_policy" "static" {
  name        = "${var.name_prefix}-static"
  comment     = "Aggressive caching for static assets (1 day default)."
  default_ttl = 86400
  max_ttl     = 31536000
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
  }
}

resource "aws_cloudfront_cache_policy" "dynamic" {
  name        = "${var.name_prefix}-dynamic"
  comment     = "Effectively no caching: pass cookies/queries through."
  default_ttl = 1
  max_ttl     = 1
  min_ttl     = 1

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
    cookies_config { cookie_behavior = "all" }
    headers_config {
      header_behavior = "whitelist"
      headers { items = ["Authorization", "Origin", "Referer"] }
    }
    query_strings_config { query_string_behavior = "all" }
  }
}

resource "aws_cloudfront_origin_request_policy" "default" {
  name    = "${var.name_prefix}-origin-request"
  comment = "Forward most viewer headers/cookies/queries (not Host)."

  cookies_config { cookie_behavior = "all" }
  headers_config {
    header_behavior = "whitelist"
    headers {
      items = [
        "User-Agent", "Referer", "Accept", "Accept-Language",
        "X-Forwarded-For", "CloudFront-Viewer-Country",
      ]
    }
  }
  query_strings_config { query_string_behavior = "all" }
}

##################################################################################
# CloudFront distributions — one per app
##################################################################################

locals {
  apigw_host = replace(replace(aws_apigatewayv2_api.main.api_endpoint, "https://", ""), "/", "")

  # Origin domain: Route53 hostname if custom domain exists, else sslip.io
  origin_domain = length(aws_route53_record.origin) > 0 ? aws_route53_record.origin[0].name : "${replace(aws_instance.app.public_ip, ".", "-")}.sslip.io"
}

resource "aws_cloudfront_distribution" "app" {
  for_each = local.effective_apps

  enabled             = true
  comment             = "${var.name_prefix}-${each.key} — EC2:${each.value.port} primary, API GW failover"
  price_class         = "PriceClass_100"
  http_version        = "http2"
  is_ipv6_enabled     = true
  aliases             = each.value.domain != "" ? [each.value.domain] : []
  wait_for_deployment = false

  origin_group {
    origin_id = "origin-group"
    failover_criteria { status_codes = [500, 502, 503, 504, 403, 404] }
    member { origin_id = "origin-ec2" }
    member { origin_id = "origin-apigw" }
  }

  origin {
    origin_id   = "origin-ec2"
    domain_name = local.origin_domain

    custom_origin_config {
      http_port              = each.value.port
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    connection_attempts = 1
    connection_timeout  = 3
  }

  origin {
    origin_id   = "origin-apigw"
    domain_name = local.apigw_host

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Tell the Lambda which app this request is for
    custom_header {
      name  = "X-App-Port"
      value = tostring(each.value.port)
    }
    custom_header {
      name  = "X-App-Name"
      value = each.key
    }
  }

  default_cache_behavior {
    target_origin_id         = "origin-group"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = aws_cloudfront_cache_policy.dynamic.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.default.id
  }

  ordered_cache_behavior {
    path_pattern             = "*.php"
    target_origin_id         = "origin-apigw"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = aws_cloudfront_cache_policy.dynamic.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.default.id
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "origin-apigw"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = aws_cloudfront_cache_policy.dynamic.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.default.id
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = each.value.domain != "" ? false : true
    acm_certificate_arn            = each.value.domain != "" ? aws_acm_certificate_validation.app[each.key].certificate_arn : null
    ssl_support_method             = each.value.domain != "" ? "sni-only" : null
    minimum_protocol_version       = each.value.domain != "" ? "TLSv1.2_2021" : "TLSv1"
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${each.key}-cf" })

  lifecycle { ignore_changes = [origin] }
}
