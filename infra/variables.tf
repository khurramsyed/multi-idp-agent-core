variable "region" {
  description = "AWS Region. Must support Amazon Bedrock AgentCore and the chosen model."
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Name prefix for every resource. Keep it short and lowercase."
  type        = string
  default     = "claims-assist"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project))
    error_message = "Use 3-21 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "image_tag" {
  description = "Tag of the images pushed by scripts/build_and_push.sh (the deploy script sets it)."
  type        = string
}

variable "model_id" {
  description = "Bedrock model or inference profile the agent uses. Enable access to it in the Bedrock console first."
  type        = string
  default     = "eu.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "vpc_cidr" {
  description = "CIDR block for the demo VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "enable_test_users" {
  description = "Allow admin-created Cognito users (and USER_PASSWORD_AUTH) so you can test without real IdPs. Turn off for anything real."
  type        = bool
  default     = true
}

variable "access_token_validity_minutes" {
  description = "Cognito access token lifetime. The agent holds this token for a conversation, so keep it short."
  type        = number
  default     = 15
}

variable "callback_urls" {
  description = "OAuth callback URLs for the web front end (used for federated sign-in)."
  type        = list(string)
  default     = ["http://localhost:8501/callback"]
}

variable "logout_urls" {
  description = "OAuth sign-out URLs for the web front end."
  type        = list(string)
  default     = ["http://localhost:8501/"]
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for all log groups."
  type        = number
  default     = 30
}

# --- Optional: real identity providers ------------------------------------
# Leave the issuer empty to skip an IdP. Test users work without either.

variable "workforce_oidc_issuer" {
  description = "Issuer URL of the corporate workforce IdP (OIDC). Empty to skip."
  type        = string
  default     = ""
}

variable "workforce_oidc_client_id" {
  type    = string
  default = ""
}

variable "workforce_oidc_client_secret" {
  type      = string
  default   = ""
  sensitive = true
}

variable "workforce_groups_claim" {
  description = "Claim in the workforce IdP token that lists the user's groups."
  type        = string
  default     = "groups"
}

variable "workforce_region_claim" {
  description = "Claim in the workforce IdP token that holds the adjuster's region."
  type        = string
  default     = "office_region"
}

variable "broker_oidc_issuer" {
  description = "Issuer URL of the broker (customer identity) IdP (OIDC). Empty to skip."
  type        = string
  default     = ""
}

variable "broker_oidc_client_id" {
  type    = string
  default = ""
}

variable "broker_oidc_client_secret" {
  type      = string
  default   = ""
  sensitive = true
}

variable "broker_agency_claim" {
  description = "Claim in the broker IdP token that holds the broker's agency ID."
  type        = string
  default     = "agency"
}
