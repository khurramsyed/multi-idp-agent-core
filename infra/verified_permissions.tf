# Amazon Verified Permissions: the authorization decision point at the tool boundary.

resource "aws_verifiedpermissions_policy_store" "this" {
  description = "${local.name} claims assistant"

  validation_settings {
    mode = "STRICT"
  }

  tags = { Component = "authorization" }
}

resource "aws_verifiedpermissions_schema" "this" {
  policy_store_id = aws_verifiedpermissions_policy_store.this.policy_store_id

  definition {
    value = jsonencode(jsondecode(file("${path.module}/../policies/schema.json")))
  }
}

# Access tokens from this pool and this app client only. Their claims arrive in
# Cedar as context.token; the principal is ClaimsAssist::User.
resource "aws_verifiedpermissions_identity_source" "cognito" {
  policy_store_id       = aws_verifiedpermissions_policy_store.this.id
  principal_entity_type = "ClaimsAssist::User"

  configuration {
    cognito_user_pool_configuration {
      user_pool_arn = aws_cognito_user_pool.this.arn
      client_ids    = [aws_cognito_user_pool_client.assistant.id]
    }
  }

  depends_on = [aws_verifiedpermissions_schema.this]
}

resource "aws_verifiedpermissions_policy" "this" {
  for_each        = fileset("${path.module}/../policies", "*.cedar")
  policy_store_id = aws_verifiedpermissions_policy_store.this.id

  definition {
    static {
      description = trimsuffix(each.key, ".cedar")
      statement   = file("${path.module}/../policies/${each.key}")
    }
  }

  depends_on = [aws_verifiedpermissions_schema.this]
}
