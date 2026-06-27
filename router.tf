##################################################################################
# Router Lambda — wakes the EC2 and (when needed) proxies HTTP to it.
#
# Sits behind API Gateway. CloudFront sends here for:
#   - failover GETs when the EC2 origin is unreachable
#   - mutating requests (POST/PUT/DELETE) on configured paths
##################################################################################

data "archive_file" "router" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/router"
  output_path = "${path.module}/lambda/router.zip"
}

resource "aws_iam_role" "router" {
  name = "${var.name_prefix}-router"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-router" })
}

resource "aws_iam_role_policy_attachment" "router_logs" {
  role       = aws_iam_role.router.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "router_ec2" {
  name = "ec2-control"
  role = aws_iam_role.router.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DescribeAllInstances"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"]
        Resource = "*"
      },
      {
        Sid    = "StartOnlyOurInstance"
        Effect = "Allow"
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances",
        ]
        Resource = "arn:aws:ec2:${var.aws_region}:*:instance/${aws_instance.app.id}"
      },
    ]
  })
}

resource "aws_lambda_function" "router" {
  function_name    = "${var.name_prefix}-router"
  description      = "Routes traffic to the app EC2; wakes it on demand."
  filename         = data.archive_file.router.output_path
  source_code_hash = data.archive_file.router.output_base64sha256

  role    = aws_iam_role.router.arn
  runtime = "python3.13"
  handler = "handler.lambda_handler"

  # Need enough headroom to proxy responses; API GW caps integrations at 29 s.
  timeout     = 28
  memory_size = 256

  environment {
    variables = {
      INSTANCE_ID    = aws_instance.app.id
      APP_PORT       = tostring(var.app_port)
      APP_NAME       = var.name_prefix
      HEALTH_PATH    = "/"
      HEALTH_TIMEOUT = "2"
      PROXY_TIMEOUT  = "25"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-router" })
}

resource "aws_cloudwatch_log_group" "router" {
  name              = "/aws/lambda/${aws_lambda_function.router.function_name}"
  retention_in_days = var.log_retention_days

  depends_on = [aws_apigatewayv2_stage.default]

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-router-logs" })
}

##################################################################################
# API Gateway HTTP API → router Lambda
##################################################################################

resource "aws_apigatewayv2_api" "main" {
  name          = "${var.name_prefix}-api"
  description   = "Public entrypoint for the router Lambda (used by CloudFront)."
  protocol_type = "HTTP"

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-api" })
}

resource "aws_apigatewayv2_integration" "router" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.router.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.router.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-api-stage" })
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigw/${var.name_prefix}"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-api-logs" })
}

resource "aws_lambda_permission" "apigw_router" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.router.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
