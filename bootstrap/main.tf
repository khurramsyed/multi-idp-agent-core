# One-off bootstrap for GitHub Actions. Run it once, locally, with admin credentials:
#   terraform -chdir=bootstrap init
#   terraform -chdir=bootstrap apply -var github_owner=<you> -var github_repo=<repo>
# It creates:
#   * an S3 bucket for the main stack's Terraform state (versioned, encrypted, private),
#   * the GitHub OIDC identity provider (skip with create_oidc_provider = false if it exists),
#   * an IAM role that only GitHub Actions jobs in this repo's deployment environment can assume.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.38.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.project, Component = "ci-bootstrap", ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  oidc_host   = "token.actions.githubusercontent.com"
  oidc_arn    = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:${local.partition}:iam::${local.account_id}:oidc-provider/${local.oidc_host}"
  role_prefix = "arn:${local.partition}:iam::${local.account_id}:role/${var.project}-"
  # Default: only jobs in the deployment environment. Override for plans without environments.
  oidc_subject = var.oidc_subject != "" ? var.oidc_subject : "repo:${var.github_owner}/${var.github_repo}:environment:${var.github_environment}"
}

# --- Terraform state ------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket        = "${var.project}-tfstate-${local.account_id}-${var.region}"
  force_destroy = true # lets you remove the bootstrap completely when you are finished
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

# --- GitHub OIDC ------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only jobs that run in this repo's deployment environment, which can require approval.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [local.oidc_subject]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.project}-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

# PowerUserAccess covers every service in the stack but excludes IAM.
resource "aws_iam_role_policy_attachment" "power_user" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

# IAM rights limited to roles whose names start with the project prefix.
data "aws_iam_policy_document" "iam_scoped" {
  statement {
    sid = "ManageProjectRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole", "iam:PassRole",
    ]
    resources = ["${local.role_prefix}*"]
  }
  statement {
    sid       = "DenySelfEscalation"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = [aws_iam_role.deploy.arn]
  }
}

resource "aws_iam_role_policy" "iam_scoped" {
  name   = "project-roles-only"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.iam_scoped.json
}
