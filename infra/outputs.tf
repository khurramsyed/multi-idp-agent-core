output "region" {
  value = var.region
}

output "user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "app_client_id" {
  value = aws_cognito_user_pool_client.assistant.id
}

output "cognito_issuer" {
  value = local.cognito_issuer
}

output "cognito_hosted_domain" {
  description = "Hosted sign-in domain for federated users."
  value       = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.region}.amazoncognito.com"
}

output "gateway_id" {
  value = aws_bedrockagentcore_gateway.this.gateway_id
}

output "gateway_url" {
  value = aws_bedrockagentcore_gateway.this.gateway_url
}

output "agent_runtime_arn" {
  value = aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn
}

output "policy_store_id" {
  value = aws_verifiedpermissions_policy_store.this.id
}

output "api_alb_dns_name" {
  description = "Internal only: reachable from inside the VPC."
  value       = aws_lb.api.dns_name
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}
