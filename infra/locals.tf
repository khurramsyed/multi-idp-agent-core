locals {
  name       = var.project
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # ECR repositories, built and pushed by scripts/build_and_push.sh.
  repositories = ["claims-api", "policy-api", "agent"]

  # Mock systems of record behind the internal ALB.
  api_services = {
    claims-api = {
      paths    = ["/claims", "/claims/*"]
      priority = 10
    }
    policy-api = {
      paths    = ["/policies", "/policies/*"]
      priority = 20
    }
  }

  api_scope            = "claims-api/claims.read"
  reserved_tool_arg    = "_caller_token"
  gateway_target_name  = "claims"
  workforce_idp_name   = "Workforce"
  broker_idp_name      = "Brokers"
  enable_workforce_idp = var.workforce_oidc_issuer != ""
  enable_broker_idp    = var.broker_oidc_issuer != ""

  supported_idps = concat(
    var.enable_test_users ? ["COGNITO"] : [],
    local.enable_workforce_idp ? [local.workforce_idp_name] : [],
    local.enable_broker_idp ? [local.broker_idp_name] : [],
  )

  cognito_issuer        = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
  cognito_discovery_url = "${local.cognito_issuer}/.well-known/openid-configuration"
}
