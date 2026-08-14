output "instance_id" {
  description = "The loop host."
  value       = aws_instance.loop.id
}

output "connect" {
  description = "Shell on the instance. No SSH, no key, no open port; needs the Session Manager plugin locally."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.loop.id}"
}

output "ecr_repository_url" {
  description = "Push the harness image here; the instance pulls it from inside the VPC."
  value       = aws_ecr_repository.harness.repository_url
}

output "log_bucket" {
  description = "Where log-sync.sh writes. Pull the run back with: aws s3 sync s3://<bucket>/loop/<run-id> ./logs"
  value       = aws_s3_bucket.logs.id
}

output "create_gh_token_secret" {
  description = "Run this once, by hand, before the first push-enabled run. Terraform never sees the token."
  value       = "aws secretsmanager create-secret --region ${var.region} --name ${var.gh_token_secret_name} --secret-string 'github_pat_...'"
}
