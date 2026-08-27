output "instance_id" {
  description = "The loop host."
  value       = aws_instance.loop.id
}

output "connect" {
  description = "Shell on the instance. No SSH, no key, no open port; needs the Session Manager plugin locally."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.loop.id}"
}

output "retry_instance_id" {
  description = "The re-attempt host, if retry_host is on. Empty otherwise."
  value       = try(aws_instance.retry[0].id, "")
}

output "connect_retry" {
  description = "Shell on the re-attempt host. Empty unless retry_host is on."
  value       = try("aws ssm start-session --region ${var.region} --target ${aws_instance.retry[0].id}", "")
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

output "create_opencode_secret" {
  description = "Run this once, by hand, before the first run. Terraform never sees the key."
  value       = "aws secretsmanager create-secret --region ${var.region} --name ${var.opencode_secret_name} --secret-string 'opencode provider key for opencode-go'"
}
