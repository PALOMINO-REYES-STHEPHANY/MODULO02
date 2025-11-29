terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "kreuzwerker/archive", version = "~> 2.2" }
  }
}

provider "aws" {
  region = var.region
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/../output/stats.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name = "${var.lambda_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_dynamodb_table" "visits" {
  name         = var.visits_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "code"
  range_key    = "date"

  attribute { name = "code" type = "S" }
  attribute { name = "date" type = "S" }

  tags = { ManagedBy = "modulo03" }
}

resource "aws_dynamodb_table" "users" {
  name         = var.users_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute { name = "id" type = "S" }
  attribute { name = "email" type = "S" }

  global_secondary_index {
    name            = "email-index"
    hash_key        = "email"
    projection_type = "ALL"
  }
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.lambda_name}-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["dynamodb:Query","dynamodb:GetItem"],
        Resource = [
          aws_dynamodb_table.visits.arn,
          "${aws_dynamodb_table.visits.arn}/*"
        ]
      },
      {
        Effect = "Allow",
        Action = ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "stats" {
  function_name = var.lambda_name
  role          = aws_iam_role.lambda_exec.arn
  handler       = var.lambda_handler
  runtime       = "nodejs18.x"
  filename      = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      VISITS_TABLE = aws_dynamodb_table.visits.name
      AWS_REGION   = var.region
    }
  }

  timeout     = 10
  memory_size = 256
}

resource "aws_api_gateway_rest_api" "api" {
  name = "${var.lambda_name}-api"
}

resource "aws_api_gateway_resource" "stats_root" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "stats"
}

resource "aws_api_gateway_resource" "stats_code" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.stats_root.id
  path_part   = "{codigo}"
}

resource "aws_api_gateway_method" "get_stats" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.stats_code.id
  http_method   = "GET"
  authorization = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "lambda_int" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.stats_code.id
  http_method = aws_api_gateway_method.get_stats.http_method
  integration_http_method = "POST"
  type = "AWS_PROXY"
  uri  = aws_lambda_function.stats.invoke_arn
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stats.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "deployment" {
  depends_on = [aws_api_gateway_integration.lambda_int]
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = var.stage
}

resource "aws_api_gateway_api_key" "stats_key" {
  name    = "${var.lambda_name}-apikey"
  enabled = true
}

resource "aws_api_gateway_usage_plan" "usage_plan" {
  name = "${var.lambda_name}-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.api.id
    stage  = aws_api_gateway_deployment.deployment.stage_name
  }
}

resource "aws_api_gateway_usage_plan_key" "usage_key" {
  key_id        = aws_api_gateway_api_key.stats_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.usage_plan.id
}

output "api_url" {
  value = "${aws_api_gateway_deployment.deployment.invoke_url}/stats/{codigo}"
}

output "api_key_value" {
  value       = aws_api_gateway_api_key.stats_key.value
  description = "API Key value to use as header x-api-key"
  sensitive   = true
}

output "visits_table_name" {
  value = aws_dynamodb_table.visits.name
}

output "lambda_name" {
  value = aws_lambda_function.stats.function_name
}