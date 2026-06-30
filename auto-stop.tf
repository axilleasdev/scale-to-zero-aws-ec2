##################################################################################
# Auto-stop Lambda + EventBridge schedule
#
# Every 5 minutes, looks at NetworkPacketsOut over the last
# `auto_stop_idle_window_min` minutes. If average packets/second is
# below `auto_stop_threshold_pps`, stops the EC2.
##################################################################################

data "archive_file" "auto_stop" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/auto-stop"
  output_path = "${path.module}/lambda/auto-stop.zip"
}

resource "aws_iam_role" "auto_stop" {
  name = "${var.name_prefix}-auto-stop"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-auto-stop" })
}

resource "aws_iam_role_policy_attachment" "auto_stop_logs" {
  role       = aws_iam_role.auto_stop.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "auto_stop" {
  name = "perms"
  role = aws_iam_role.auto_stop.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DescribeAllInstances"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Sid      = "StopOnlyOurInstance"
        Effect   = "Allow"
        Action   = ["ec2:StopInstances"]
        Resource = "arn:aws:ec2:${var.aws_region}:*:instance/${aws_instance.app.id}"
      },
      {
        Sid      = "ReadMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricStatistics"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "auto_stop" {
  function_name    = "${var.name_prefix}-auto-stop"
  description      = "Stops the app EC2 when network traffic has been near zero."
  filename         = data.archive_file.auto_stop.output_path
  source_code_hash = data.archive_file.auto_stop.output_base64sha256

  role    = aws_iam_role.auto_stop.arn
  runtime = "python3.13"
  handler = "handler.lambda_handler"

  timeout     = 15
  memory_size = 128

  environment {
    variables = {
      INSTANCE_ID        = aws_instance.app.id
      IDLE_WINDOW_MIN    = tostring(var.auto_stop_idle_window_min)
      IDLE_THRESHOLD_PPS = tostring(var.auto_stop_threshold_pps)
      MIN_UPTIME_MIN     = tostring(var.auto_stop_min_uptime_min)
      HIBERNATE          = tostring(var.hibernate_enabled)
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-auto-stop" })
}

resource "aws_cloudwatch_log_group" "auto_stop" {
  name              = "/aws/lambda/${aws_lambda_function.auto_stop.function_name}"
  retention_in_days = var.log_retention_days

  # Ensure EventBridge rules are destroyed BEFORE this log group,
  # preventing the Lambda from being triggered and auto-recreating it.
  depends_on = [aws_cloudwatch_event_rule.auto_stop_tick]

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-auto-stop-logs" })
}

resource "aws_cloudwatch_event_rule" "auto_stop_tick" {
  name                = "${var.name_prefix}-auto-stop-tick"
  description         = "Periodic check to stop the EC2 if idle."
  schedule_expression = "rate(5 minutes)"

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-auto-stop-tick" })
}

resource "aws_cloudwatch_event_target" "auto_stop" {
  rule      = aws_cloudwatch_event_rule.auto_stop_tick.name
  target_id = "auto-stop"
  arn       = aws_lambda_function.auto_stop.arn
}

resource "aws_lambda_permission" "auto_stop_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auto_stop.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.auto_stop_tick.arn
}
