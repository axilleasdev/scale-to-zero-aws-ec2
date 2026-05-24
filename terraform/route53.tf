##################################################################################
# Route53 hosted zone + dns-updater Lambda
#
# We don't pay for an Elastic IP, so the EC2's public IP changes on every
# start. CloudFront's primary origin is `var.origin_subdomain` (an A
# record in this hosted zone). The dns-updater Lambda refreshes that A
# record whenever the EC2 transitions to "running".
##################################################################################

resource "aws_route53_zone" "origin" {
  name    = var.origin_zone_name
  comment = "Delegated zone holding the dynamic origin A record."

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-origin-zone" })
}

# Initial A record. The Lambda will overwrite it on every EC2 start.
# `lifecycle.ignore_changes` keeps Terraform from fighting that.
resource "aws_route53_record" "origin" {
  zone_id = aws_route53_zone.origin.zone_id
  name    = var.origin_subdomain
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
    Statement = [
      {
        Sid      = "DescribeOurInstance"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Sid      = "ChangeOurZone"
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:GetChange"]
        Resource = "arn:aws:route53:::hostedzone/${aws_route53_zone.origin.zone_id}"
      },
      {
        Sid      = "GetChangeStatus"
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = "arn:aws:route53:::change/*"
      },
    ]
  })
}

resource "aws_lambda_function" "dns_updater" {
  function_name    = "${var.name_prefix}-dns-updater"
  description      = "Updates the Route53 A record with the EC2's current public IP."
  filename         = data.archive_file.dns_updater.output_path
  source_code_hash = data.archive_file.dns_updater.output_base64sha256

  role    = aws_iam_role.dns_updater.arn
  runtime = "python3.13"
  handler = "handler.lambda_handler"

  timeout     = 15
  memory_size = 128

  environment {
    variables = {
      INSTANCE_ID    = aws_instance.app.id
      HOSTED_ZONE_ID = aws_route53_zone.origin.zone_id
      RECORD_NAME    = aws_route53_record.origin.name
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-dns-updater" })
}

resource "aws_cloudwatch_log_group" "dns_updater" {
  name              = "/aws/lambda/${aws_lambda_function.dns_updater.function_name}"
  retention_in_days = var.log_retention_days

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
