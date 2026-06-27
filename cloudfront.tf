##################################################################################
# CloudFront distribution with origin failover + ACM cert.
#
# The cert is for `var.public_domain`. ACM lives in us-east-1 because
# CloudFront only consumes certs from there. DNS validation is left to
# YOU because your `public_domain` likely lives in a DNS provider
# (Cloudflare, registrar, etc.) that we don't manage.
#
# Workflow:
#   1. terraform apply  → fails on aws_acm_certificate_validation,
#      but emits the validation CNAME in `acm_validation_record`.
#   2. Add that CNAME at your DNS provider.
#   3. terraform apply  → cert is validated, distribution finishes.
##################################################################################

##################################################################################
# ACM cert (us-east-1) — only when using a custom domain
##################################################################################

resource "aws_acm_certificate" "public" {
  count             = local.use_custom_domain ? 1 : 0
  provider          = aws.us_east_1
  domain_name       = var.public_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-cert" })
}

resource "aws_acm_certificate_validation" "public" {
  count           = local.use_custom_domain ? 1 : 0
  provider        = aws.us_east_1
  certificate_arn = aws_acm_certificate.public[0].arn
}

##################################################################################
# Cache + origin request policies
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
  name    = "${var.name_prefix}-dynamic"
  comment = "Effectively no caching: pass cookies/queries through."
  # AWS rejects min_ttl=0 with header/cookie customization, so use 1.
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

# We DO NOT forward the visitor's Host header. API Gateway expects its
# own *.execute-api hostname; forwarding the public domain breaks the
# failover origin.
resource "aws_cloudfront_origin_request_policy" "default" {
  name    = "${var.name_prefix}-origin-request"
  comment = "Forward most viewer headers/cookies/queries (not Host)."

  cookies_config { cookie_behavior = "all" }
  headers_config {
    header_behavior = "whitelist"
    headers {
      items = [
        "User-Agent",
        "Referer",
        "Accept",
        "Accept-Language",
        "X-Forwarded-For",
        "CloudFront-Viewer-Country",
      ]
    }
  }
  query_strings_config { query_string_behavior = "all" }
}

##################################################################################
# CloudFront distribution
##################################################################################

locals {
  apigw_host = replace(
    replace(aws_apigatewayv2_api.main.api_endpoint, "https://", ""),
    "/", ""
  )
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  comment             = "${var.name_prefix} — EC2 primary, API GW failover"
  price_class         = "PriceClass_100"
  http_version        = "http2"
  is_ipv6_enabled     = true
  aliases             = local.use_custom_domain ? [var.public_domain] : []
  wait_for_deployment = false

  # GETs go through the origin group (with failover). POSTs cannot — see
  # below for the per-path behavior that targets the API GW directly.
  origin_group {
    origin_id = "origin-group"

    failover_criteria {
      status_codes = [500, 502, 503, 504, 403, 404]
    }

    member { origin_id = "origin-ec2" }
    member { origin_id = "origin-apigw" }
  }

  origin {
    origin_id = "origin-ec2"
    # With custom domain: Route53 hostname (publicly resolvable).
    # Without: <ip>.sslip.io (free wildcard DNS that resolves to the IP).
    # The dns-updater Lambda updates this via UpdateDistribution on EC2 start.
    domain_name = local.use_custom_domain ? aws_route53_record.origin[0].name : "${replace(aws_instance.app.public_ip, ".", "-")}.sslip.io"

    custom_origin_config {
      http_port              = var.app_port
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Snappy failover: try once, fail in ≈3 s, jump to API GW.
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
  }

  # Default behavior: all methods through the origin group.
  # When EC2 is up, traffic goes direct. When down, failover to API GW.
  default_cache_behavior {
    target_origin_id       = "origin-group"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id          = aws_cloudfront_cache_policy.dynamic.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.default.id
  }

  # POST/PUT/DELETE go directly to EC2 (origin groups don't support mutating methods).
  # If EC2 is down, these will fail — but the GET loading page will wake it up.
  ordered_cache_behavior {
    path_pattern             = "/vote"
    target_origin_id         = "origin-ec2"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = aws_cloudfront_cache_policy.dynamic.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.default.id
  }

  # POST + dynamic paths go straight to API Gateway. These cannot use an
  # origin group (CloudFront constraint), so the wake-up flow handles
  # the "EC2 down" case via the loading page.
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

  # Static assets: cached aggressively at the edge.
  ordered_cache_behavior {
    path_pattern           = "/css/*"
    target_origin_id       = "origin-group"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = aws_cloudfront_cache_policy.static.id
  }

  ordered_cache_behavior {
    path_pattern           = "/js/*"
    target_origin_id       = "origin-group"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = aws_cloudfront_cache_policy.static.id
  }

  ordered_cache_behavior {
    path_pattern           = "/uploads/*"
    target_origin_id       = "origin-group"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = aws_cloudfront_cache_policy.static.id
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.use_custom_domain ? false : true
    acm_certificate_arn            = local.use_custom_domain ? aws_acm_certificate_validation.public[0].certificate_arn : null
    ssl_support_method             = local.use_custom_domain ? "sni-only" : null
    minimum_protocol_version       = local.use_custom_domain ? "TLSv1.2_2021" : "TLSv1"
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-cf" })

  # The dns-updater Lambda changes origin-ec2's domain_name when the EC2
  # gets a new IP. Don't fight that drift.
  lifecycle {
    ignore_changes = [origin]
  }
}
