output "AWS_DEPLOY_ROLE_ARN" {
  description = "Set as a GitHub environment variable on the deployment environment."
  value       = aws_iam_role.deploy.arn
}

output "TF_STATE_BUCKET" {
  description = "Set as a GitHub environment variable on the deployment environment."
  value       = aws_s3_bucket.state.bucket
}
