variable "github_owner" {
  description = "GitHub user or organisation that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "Repository name, without the owner."
  type        = string
}

variable "github_environment" {
  description = "GitHub deployment environment the deploy and destroy workflows run in."
  type        = string
  default     = "aws-dev"
}

variable "project" {
  description = "Must match the main stack's project variable."
  type        = string
  default     = "claims-assist"
}

variable "region" {
  description = "Must match the main stack's region."
  type        = string
  default     = "eu-west-1"
}

variable "create_oidc_provider" {
  description = "Set to false if this AWS account already has the token.actions.githubusercontent.com provider."
  type        = bool
  default     = true
}

variable "oidc_subject" {
  description = "Optional override for the OIDC subject GitHub jobs must present, e.g. repo:OWNER/REPO:ref:refs/heads/main when deployment environments are not available on your plan."
  type        = string
  default     = ""
}
