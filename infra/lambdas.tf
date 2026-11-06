# Lambda packages are built into ../build/lambdas by scripts/build_lambdas.sh.

locals {
  lambda_build_dir = "${path.module}/../build/lambdas"
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

# --- Pre token generation trigger -------------------------------------------

data "archive_file" "pre_token" {
  type        = "zip"
  source_dir  = "${local.lambda_build_dir}/pre_token"
  output_path = "${local.lambda_build_dir}/pre_token.zip"
}

resource "aws_iam_role" "pre_token" {
  name               = "${local.name}-pre-token"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "pre_token_logs" {
  role       = aws_iam_role.pre_token.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "pre_token" {
  name              = "/aws/lambda/${local.name}-pre-token"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "pre_token" {
  function_name    = "${local.name}-pre-token"
  role             = aws_iam_role.pre_token.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.pre_token.output_path
  source_code_hash = data.archive_file.pre_token.output_base64sha256
  timeout          = 5
  memory_size      = 128

  environment {
    variables = {
      WORKFORCE_PROVIDER_NAME = local.workforce_idp_name
      BROKER_PROVIDER_NAME    = local.broker_idp_name
      ALLOW_TEST_USERS        = tostring(var.enable_test_users)
      API_SCOPE               = local.api_scope
    }
  }

  depends_on = [aws_cloudwatch_log_group.pre_token, aws_iam_role_policy_attachment.pre_token_logs]
  tags       = { Component = "identity" }
}

resource "aws_lambda_permission" "cognito_pre_token" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pre_token.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.this.arn
}

# --- Gateway request interceptor --------------------------------------------

data "archive_file" "interceptor" {
  type        = "zip"
  source_dir  = "${local.lambda_build_dir}/interceptor"
  output_path = "${local.lambda_build_dir}/interceptor.zip"
}

resource "aws_iam_role" "interceptor" {
  name               = "${local.name}-interceptor"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "interceptor_logs" {
  role       = aws_iam_role.interceptor.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "interceptor" {
  name              = "/aws/lambda/${local.name}-interceptor"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "interceptor" {
  function_name    = "${local.name}-interceptor"
  role             = aws_iam_role.interceptor.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.interceptor.output_path
  source_code_hash = data.archive_file.interceptor.output_base64sha256
  timeout          = 10
  memory_size      = 256

  environment {
    variables = {
      COGNITO_ISSUER = local.cognito_issuer
      APP_CLIENT_ID  = aws_cognito_user_pool_client.assistant.id
      RESERVED_ARG   = local.reserved_tool_arg
    }
  }

  depends_on = [aws_cloudwatch_log_group.interceptor, aws_iam_role_policy_attachment.interceptor_logs]
  tags       = { Component = "gateway-interceptor" }
}

# --- Tool adapters ------------------------------------------------------------

data "archive_file" "tools" {
  type        = "zip"
  source_dir  = "${local.lambda_build_dir}/tools"
  output_path = "${local.lambda_build_dir}/tools.zip"
}

resource "aws_iam_role" "tools" {
  name               = "${local.name}-tools"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "tools_vpc" {
  role       = aws_iam_role.tools.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "tools" {
  statement {
    sid = "AuthorizeAgainstThisPolicyStoreOnly"
    actions = [
      "verifiedpermissions:IsAuthorizedWithToken",
      "verifiedpermissions:BatchIsAuthorizedWithToken",
    ]
    resources = [aws_verifiedpermissions_policy_store.this.arn]
  }
}

resource "aws_iam_role_policy" "tools" {
  name   = "verified-permissions"
  role   = aws_iam_role.tools.id
  policy = data.aws_iam_policy_document.tools.json
}

resource "aws_cloudwatch_log_group" "tools" {
  name              = "/aws/lambda/${local.name}-tools"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "tools" {
  function_name    = "${local.name}-tools"
  role             = aws_iam_role.tools.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.tools.output_path
  source_code_hash = data.archive_file.tools.output_base64sha256
  timeout          = 20
  memory_size      = 256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.tools_lambda.id]
  }

  environment {
    variables = {
      POLICY_STORE_ID = aws_verifiedpermissions_policy_store.this.id
      API_BASE_URL    = "http://${aws_lb.api.dns_name}"
      RESERVED_ARG    = local.reserved_tool_arg
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.tools,
    aws_iam_role_policy_attachment.tools_vpc,
    aws_route_table_association.private,
  ]
  tags = { Component = "tool-adapters" }
}
