variable "region" {
  description = "The region the loop runs in. Must be one the pinned Bedrock model is available in."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for every resource, so one `terraform destroy` leaves nothing behind."
  type        = string
  default     = "archunitdev"
}

variable "instance_type" {
  description = <<-EOT
    2 vCPU is plenty — the loop is almost entirely waiting on the Bedrock API. Memory is the one
    dimension that is not padding: the gate runs `go test -race`, which costs 5-10x the memory of a
    plain test binary, on top of golangci-lint type-checking the whole package graph. 1GB is not
    enough, and the failure mode is the OOM killer taking out a gate step, which reads in the log as
    a code defect and sends the fixer after something that is not there. t3.medium is 2 vCPU / 4GB.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "volume_size" {
  description = "GB. The image is ~1.9GB, plus the Go module and build caches, the clone, and the logs."
  type        = number
  default     = 30
}

variable "target_repo" {
  description = "The repository the loop works through, cloned onto the instance at boot."
  type        = string
  default     = "https://github.com/LukasNiessen/ArchUnitGo.git"
}

variable "gh_token_secret_name" {
  description = <<-EOT
    Secrets Manager secret holding the GitHub token, as a plain string. Created outside Terraform on
    purpose: a secret in state or in a .tf file is a secret in a git repository. Create it with

      aws secretsmanager create-secret --name archunitdev/gh-token --secret-string 'github_pat_...'

    A fine-grained PAT scoped to the target repository alone, with Contents and Issues read/write, is
    the right token here — not a personal OAuth token that can reach every repository you have.
  EOT
  type        = string
  default     = "archunitdev/gh-token"
}

variable "image_tag" {
  description = "Tag of the harness image in the private ECR repository this stack creates."
  type        = string
  default     = "latest"
}

variable "bedrock_vpc_endpoint" {
  description = <<-EOT
    Send Bedrock inference through a PrivateLink endpoint instead of out through the NAT gateway, so
    the diffs and prompts never traverse the public internet. Costs ~$7/month.

    Set to false if inference stops resolving: the pinned model is the *global* inference profile
    `global.anthropic.claude-opus-5`, which the SDK reaches through the regional endpoint but which
    routes across regions server-side. That should be unaffected by a regional PrivateLink endpoint,
    but it is the one assumption in this stack worth proving with a PREFLIGHT_ONLY=1 run rather than
    trusting.
  EOT
  type        = bool
  default     = true
}

variable "secretsmanager_vpc_endpoint" {
  description = "Fetch the GitHub token over PrivateLink rather than through the NAT gateway. ~$7/month."
  type        = bool
  default     = true
}
