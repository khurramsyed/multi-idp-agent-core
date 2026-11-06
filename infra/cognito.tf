# One Cognito user pool brokers both identity providers, so AgentCore and every
# tool see exactly one issuer and one token shape.

resource "random_id" "suffix" {
  byte_length = 3
}

resource "aws_cognito_user_pool" "this" {
  name = "${local.name}-users"

  # Access-token customisation with a pre token generation trigger needs Essentials or Plus.
  user_pool_tier      = "ESSENTIALS"
  deletion_protection = "INACTIVE" # demo: let terraform destroy remove it

  username_configuration {
    case_sensitive = false
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  lambda_config {
    pre_token_generation_config {
      lambda_arn     = aws_lambda_function.pre_token.arn
      lambda_version = "V2_0"
    }
  }

  # Attributes mapped from the external IdPs (written at each federated sign-in).
  dynamic "schema" {
    for_each = ["idp_groups", "idp_region", "idp_agency"]
    content {
      name                     = schema.value
      attribute_data_type      = "String"
      mutable                  = true
      developer_only_attribute = false
      string_attribute_constraints {
        min_length = 0
        max_length = 2048
      }
    }
  }

  # Attributes for admin-created test users. The app client cannot write these.
  dynamic "schema" {
    for_each = ["t_population", "t_role", "t_region", "t_agency"]
    content {
      name                     = schema.value
      attribute_data_type      = "String"
      mutable                  = true
      developer_only_attribute = false
      string_attribute_constraints {
        min_length = 0
        max_length = 64
      }
    }
  }

  tags = { Component = "identity" }

  lifecycle {
    # Cognito does not allow schema attributes to be changed after creation.
    ignore_changes = [schema]
  }
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${local.name}-${random_id.suffix.hex}"
  user_pool_id = aws_cognito_user_pool.this.id
}

resource "aws_cognito_resource_server" "claims_api" {
  user_pool_id = aws_cognito_user_pool.this.id
  identifier   = "claims-api"
  name         = "Claims API"

  scope {
    scope_name        = "claims.read"
    scope_description = "Read claims and policies"
  }
}

resource "aws_cognito_identity_provider" "workforce" {
  count         = local.enable_workforce_idp ? 1 : 0
  user_pool_id  = aws_cognito_user_pool.this.id
  provider_name = local.workforce_idp_name
  provider_type = "OIDC"

  provider_details = {
    oidc_issuer               = var.workforce_oidc_issuer
    client_id                 = var.workforce_oidc_client_id
    client_secret             = var.workforce_oidc_client_secret
    authorize_scopes          = "openid profile email"
    attributes_request_method = "GET"
  }

  attribute_mapping = {
    email               = "email"
    username            = "sub"
    "custom:idp_groups" = var.workforce_groups_claim
    "custom:idp_region" = var.workforce_region_claim
  }
}

resource "aws_cognito_identity_provider" "brokers" {
  count         = local.enable_broker_idp ? 1 : 0
  user_pool_id  = aws_cognito_user_pool.this.id
  provider_name = local.broker_idp_name
  provider_type = "OIDC"

  provider_details = {
    oidc_issuer               = var.broker_oidc_issuer
    client_id                 = var.broker_oidc_client_id
    client_secret             = var.broker_oidc_client_secret
    authorize_scopes          = "openid profile email"
    attributes_request_method = "GET"
  }

  attribute_mapping = {
    email               = "email"
    username            = "sub"
    "custom:idp_agency" = var.broker_agency_claim
  }
}

resource "aws_cognito_user_pool_client" "assistant" {
  name         = "${local.name}-assistant"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  # aws.cognito.signin.user.admin is deliberately absent: tokens from the hosted
  # sign-in page cannot be used to edit the user's own attributes.
  allowed_oauth_scopes         = concat(["openid", "email", "profile"], aws_cognito_resource_server.claims_api.scope_identifiers)
  supported_identity_providers = local.supported_idps
  callback_urls                = var.callback_urls
  logout_urls                  = var.logout_urls

  explicit_auth_flows = concat(
    ["ALLOW_REFRESH_TOKEN_AUTH"],
    var.enable_test_users ? ["ALLOW_USER_PASSWORD_AUTH"] : [],
  )

  # Federated attribute mapping requires the mapped attributes to be writable by
  # the client. The t_* test attributes are not, so test users cannot change
  # their own population, role, region or agency.
  write_attributes = ["email", "custom:idp_groups", "custom:idp_region", "custom:idp_agency"]

  access_token_validity  = var.access_token_validity_minutes
  id_token_validity      = var.access_token_validity_minutes
  refresh_token_validity = 8
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "hours"
  }

  enable_token_revocation       = true
  prevent_user_existence_errors = "ENABLED"

  depends_on = [aws_cognito_identity_provider.workforce, aws_cognito_identity_provider.brokers]

  lifecycle {
    precondition {
      condition     = length(local.supported_idps) > 0
      error_message = "Enable test users or configure at least one identity provider."
    }
  }
}
