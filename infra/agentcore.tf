# Amazon Bedrock AgentCore: the Gateway (tools over MCP) and the Runtime (the agent).

data "aws_iam_policy_document" "agentcore_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock-agentcore:${var.region}:${local.account_id}:*"]
    }
  }
}

# --- Gateway -------------------------------------------------------------------

resource "aws_iam_role" "gateway" {
  name               = "${local.name}-gateway"
  assume_role_policy = data.aws_iam_policy_document.agentcore_assume.json
}

data "aws_iam_policy_document" "gateway" {
  statement {
    sid     = "InvokeInterceptorAndTools"
    actions = ["lambda:InvokeFunction"]
    resources = [
      aws_lambda_function.interceptor.arn,
      aws_lambda_function.tools.arn,
    ]
  }
}

resource "aws_iam_role_policy" "gateway" {
  name   = "invoke-lambdas"
  role   = aws_iam_role.gateway.id
  policy = data.aws_iam_policy_document.gateway.json
}

resource "aws_bedrockagentcore_gateway" "this" {
  name            = "${local.name}-gateway"
  description     = "Claims assistant tools. Accepts only Cognito access tokens from the assistant app client."
  role_arn        = aws_iam_role.gateway.arn
  protocol_type   = "MCP"
  authorizer_type = "CUSTOM_JWT"

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url = local.cognito_discovery_url
      # Cognito access tokens carry the app client in client_id and have no aud claim,
      # so validate allowed_clients rather than allowed_audience.
      allowed_clients = [aws_cognito_user_pool_client.assistant.id]
      allowed_scopes  = [local.api_scope]
    }
  }

  interceptor_configuration {
    interception_points = ["REQUEST"]

    interceptor {
      lambda {
        arn = aws_lambda_function.interceptor.arn
      }
    }

    input_configuration {
      pass_request_headers = true # without this the interceptor never sees the bearer token
    }
  }

  depends_on = [aws_iam_role_policy.gateway]
  tags       = { Component = "agentcore-gateway" }
}

resource "aws_bedrockagentcore_gateway_target" "claims" {
  name               = local.gateway_target_name
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  description        = "Claims and policy lookups, authorized per user with Verified Permissions"

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.tools.arn

        tool_schema {
          # The reserved _caller_token argument is deliberately NOT declared:
          # the model never sees it, and the interceptor overwrites any value.
          inline_payload {
            name        = "get_claim"
            description = "Get the details of one insurance claim by its claim ID (for example CLM-1001)."

            input_schema {
              type = "object"
              property {
                name        = "claim_id"
                type        = "string"
                description = "Claim ID, for example CLM-1001."
                required    = true
              }
            }
          }

          inline_payload {
            name        = "search_claims"
            description = "List claims the user may see, optionally filtered by policy ID and status (OPEN, UNDER_REVIEW, SETTLED)."

            input_schema {
              type = "object"
              property {
                name        = "policy_id"
                type        = "string"
                description = "Policy ID, for example POL-2001."
              }
              property {
                name        = "status"
                type        = "string"
                description = "Claim status: OPEN, UNDER_REVIEW or SETTLED."
              }
            }
          }

          inline_payload {
            name        = "get_policy"
            description = "Get the cover and key conditions of one insurance policy by its policy ID (for example POL-2001)."

            input_schema {
              type = "object"
              property {
                name        = "policy_id"
                type        = "string"
                description = "Policy ID, for example POL-2001."
                required    = true
              }
            }
          }
        }
      }
    }
  }
}

# --- Runtime -----------------------------------------------------------------

resource "aws_iam_role" "runtime" {
  name               = "${local.name}-runtime"
  assume_role_policy = data.aws_iam_policy_document.agentcore_assume.json
}

data "aws_iam_policy_document" "runtime" {
  statement {
    sid       = "EcrToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "EcrPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.this["agent"].arn]
  }

  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "logs:DescribeLogGroups",
    ]
    resources = [
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*",
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*",
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:*",
    ]
  }

  statement {
    sid = "Tracing"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["bedrock-agentcore"]
    }
  }

  statement {
    sid = "WorkloadIdentity"
    actions = [
      "bedrock-agentcore:GetWorkloadAccessToken",
      "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
      "bedrock-agentcore:GetWorkloadAccessTokenForUserId",
    ]
    resources = [
      "arn:${local.partition}:bedrock-agentcore:${var.region}:${local.account_id}:workload-identity-directory/default",
      "arn:${local.partition}:bedrock-agentcore:${var.region}:${local.account_id}:workload-identity-directory/default/workload-identity/*",
    ]
  }

  statement {
    sid     = "InvokeModel"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    # Cross-Region inference profiles (eu.*, us.*) route to foundation models in several Regions.
    resources = [
      "arn:${local.partition}:bedrock:*::foundation-model/*",
      "arn:${local.partition}:bedrock:${var.region}:${local.account_id}:inference-profile/*",
    ]
  }
}

resource "aws_iam_role_policy" "runtime" {
  name   = "agent-runtime"
  role   = aws_iam_role.runtime.id
  policy = data.aws_iam_policy_document.runtime.json
}

resource "aws_bedrockagentcore_agent_runtime" "this" {
  agent_runtime_name = replace("${local.name}_agent", "-", "_")
  description        = "Claims assistant agent. Calls tools with the end user's own token."
  role_arn           = aws_iam_role.runtime.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${aws_ecr_repository.this["agent"].repository_url}:${var.image_tag}"
    }
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  protocol_configuration {
    server_protocol = "HTTP"
  }

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = local.cognito_discovery_url
      allowed_clients = [aws_cognito_user_pool_client.assistant.id]
    }
  }

  # Forward the validated bearer token to the agent code so it can call the
  # gateway as the user. Without this the agent never sees the token.
  request_header_configuration {
    request_header_allowlist = ["Authorization"]
  }

  environment_variables = {
    GATEWAY_URL = aws_bedrockagentcore_gateway.this.gateway_url
    MODEL_ID    = var.model_id
  }

  depends_on = [aws_iam_role_policy.runtime]
  tags       = { Component = "agentcore-runtime" }
}
