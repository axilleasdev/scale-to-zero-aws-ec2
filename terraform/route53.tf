##################################################################################
# Route53 hosted zone + dns-updater Lambda
#
# TWO MODES:
#   1. Custom domain (public_domain set): Creates a public Route53 zone +
#      A record. dns-updater Lambda updates the A record on EC2 start.
#      CloudFront resolves the hostname publicly.
#
#   2. No custom domain: Skips Route53 entirely. dns-updater Lambda updates
#      the CloudFront origin directly with the EC2's public IP.
##################################################################################

##################################################################################
# Route53 zone + record — only when using a custom domain
##################################################################################

resource "aws_route53_zone" "origin" {
  count   = local.use_custom_domain ? 1 : 0
  name    = local.origin_zone_name
  comment = "Delegated zone holding the dynamic origin A record."

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-origin-zone" })
}

resource "aws_route53_record" "origin" {
  count   = local.use_custom_domain ? 1 : 0
  zone_id = aws_route53_zone.origin[0].zone_id
  name    = local.origin_subdomain
  type    = "A"
  ttl     = 60

  records = [
    aws_instance.app.public_ip != "" ? aws_instance.app.public_ip : "127.0.0.1"
  ]

  lifecycle {
    ignore_changes = [records]
  }
}

##################################################################################
# dns-updater Lambda
##################################################################################

data "archive_file" "dns_updater" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/dns-updater"
  output_path = "${path.module}/../lambda/dns-updater.zip"
}

resource "aws_iam_role" "dns_updater" {
  name = "${var.name_prefix}-dns-updater"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-dns-updater" })
}

resource "aws_iam_role_policy_attachment" "dns_updater_logs" {
  role       = aws_iam_role.dns_updater.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "dns_updater" {
  name = "perms"
  role = aws_iam_role.dns_updater.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "DescribeOurInstance"
          Effect   = "Allow"
          Action   = ["ec2:DescribeInstances"]
          Resource = "*"
        },
      ],
      # With custom domain: allow Route53 changes
      local.use_custom_domain ? [
        {
          Sid      = "ChangeOurZone"
          Effect   = "Allow"
          Action   = ["route53:ChangeResourceRecordSets", "route53:GetChange"]
          Resource = "arn:aws:route53:::hostedzone/${aws_route53_zone.origin[0].zone_id}"
        },
        {
          Sid      = "GetChangeStatus"
          Effect   = "Allow"
          Action   = ["route53:GetChange"]
          Resource = "arn:aws:route53:::change/*"
        },
      ] : [],
      # Without custom domain: allow CloudFront origin update
      local.use_custom_domain ? [] : [
        {
          Sid      = "UpdateCloudFrontOrigin"
          Effect   = "Allow"
          Action   = ["cloudfront:GetDistribution", "cloudfront:GetDistributionConfig", "cloudfront:UpdateDistribution"]
          Resource = aws_cloudfront_distribution.main.arn
        },
      ],
    )
  })
}

resource "aws_lambda_function" "dns_updater" {
  function_name    = "${var.name_prefix}-dns-updater"
  description      = local.use_custom_domain ? "Updates the Route53 A record with the EC2's current public IP." : "Updates CloudFront origin with the EC2's current public IP."
  filename         = data.archive_file.dns_updater.output_path
  source_code_hash = data.archive_file.dns_updater.output_base64sha256

  role    = aws_iam_role.dns_updater.arn
  runtime = "python3.13"
  handler = "handler.lambda_handler"

  timeout     = 30
  memory_size = 128

  environment {
    variables = merge(
      { INSTANCE_ID = aws_instance.app.id },
      local.use_custom_domain ? {
        MODE           = "route53"
        HOSTED_ZONE_ID = aws_route53_zone.origin[0].zone_id
        RECORD_NAME    = aws_route53_record.origin[0].name
        } : {
        MODE            = "cloudfront"
        DISTRIBUTION_ID = aws_cloudfront_distribution.main.id
        ORIGIN_ID       = "origin-ec2"
      },
    )
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-dns-updater" })
}

resource "aws_cloudwatch_log_group" "dns_updater" {
  name              = "/aws/lambda/${aws_lambda_function.dns_updater.function_name}"
  retention_in_days = var.log_retention_days

  depends_on = [aws_cloudwatch_event_rule.ec2_running]

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-dns-updater-logs" })
}

##################################################################################
# EventBridge: trigger the dns-updater on EC2 → running
##################################################################################

resource "aws_cloudwatch_event_rule" "ec2_running" {
  name        = "${var.name_prefix}-ec2-running"
  description = "Fires when the app EC2 transitions to running."

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      instance-id = [aws_instance.app.id]
      state       = ["running"]
    }
  })

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-ec2-running" })
}

resource "aws_cloudwatch_event_target" "dns_updater" {
  rule      = aws_cloudwatch_event_rule.ec2_running.name
  target_id = "dns-updater"
  arn       = aws_lambda_function.dns_updater.arn
}

resource "aws_lambda_permission" "dns_updater_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dns_updater.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ec2_running.arn
}
