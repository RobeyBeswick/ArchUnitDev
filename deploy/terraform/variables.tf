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
    The loop is almost entirely waiting on the Bedrock API, so CPU count is not what decides this.
    Memory is: the gate runs `go test -race`, which costs 5-10x the memory of a plain test binary, on
    top of golangci-lint type-checking the whole package graph. The failure mode is the OOM killer
    taking out a gate step, which reads in the log as a code defect and sends the fixer after
    something that is not there — an hour of spend on a bug that does not exist.

    m5.large (2 vCPU / 8GiB), one size down from the m5.xlarge this used to be. t3.medium's 4GB is the
    *floor* for the gate rather than comfortable headroom — 8GiB is twice that — and a burstable
    instance puts the CPU credit balance in the path of the one sustained-CPU part of the run. See
    var.retry_instance_type for the longer version of both arguments.

    Changing this on an existing host is an in-place update that STOPS AND STARTS the instance.
    Under NO_PUSH the volume holds commits that exist nowhere else, and stopping mid-run kills the
    container along with the issue it was part-way through. Apply a resize between batches, never
    during one, and read the plan before saying yes.
  EOT
  type        = string
  default     = "m5.large"
}

variable "retry_host" {
  description = <<-EOT
    Create a second host for re-attempting abandoned issues in parallel with the main loop.

    It is off by default because it only earns its keep when there is something to re-attempt: the main
    loop's own retry phase covers the ordinary case, and it is unreachable only when the run ends on
    its spend cap, on the consecutive-abandon breaker, or by hand. Turning this on is the answer to
    "these two issues need many more rounds than the batch is configured for, and I am not stopping the
    batch to give them those rounds".
  EOT
  type        = bool
  default     = false
}

variable "retry_instance_type" {
  description = <<-EOT
    Sized so that the host is never the reason a re-attempt fails. This host runs the same
    `go test -race` and golangci-lint gate as the loop host, but against a diff that has already
    proved big enough to time an implementer out, and for up to 11 rounds instead of 5 — and an
    OOM-killed gate step is the one failure that reads in the log as a code defect and sends a fixer
    after something that is not there. m5.large is 2 vCPU / 8GiB.

    m5 rather than t3.xlarge at the same size: t3 is burstable, and the gate is precisely the
    sustained-CPU part of the run. Depleted CPU credits would show up as a gate step that takes
    minutes longer each round until it trips the step timeout — a failure that looks like a slow test
    suite and is actually the instance being throttled. Fixed performance costs ~15% more per hour and
    removes the whole failure mode.
  EOT
  type        = string
  default     = "m5.large"
}

variable "volume_size" {
  description = "GB. The image is ~1.5GB, plus the Docker build cache, the Go caches, the clones and the logs."
  type        = number
  default     = 30
}

variable "target_repo" {
  description = "The repository the loop works through, cloned onto the instance at boot."
  type        = string
  default     = "https://github.com/RobeyBeswick/ArchUnitSharp.git"
}

variable "harness_repo" {
  description = <<-EOT
    This repository, cloned onto the instance at boot. The image is built from it, and log-sync.sh is
    run out of it — the instance needs the harness as source, not only as an image.
  EOT
  type        = string
  default     = "https://github.com/RobeyBeswick/ArchUnitDev.git"
}

variable "gh_token_secret_name" {
  description = <<-EOT
    Secrets Manager secret holding the GitHub token, as a plain string. Created outside Terraform on
    purpose: a secret in state or in a .tf file is a secret in a git repository. Create it with

      aws secretsmanager create-secret --name archunitdev/gh-token --secret-string 'ghp_...'

    It has to be a *classic* PAT with the `repo` scope, and the reason is not preference: the target
    repository is owned by another account and reached as a collaborator, and a fine-grained token can
    only ever reach resources owned by the account that issued it. Give it the shortest expiry that
    covers the run — it is revocable and expiring, which a personal OAuth token taken from `gh auth
    token` is not without also breaking your own CLI login.
  EOT
  type        = string
  default     = "archunitdev/gh-token"
}

variable "opencode_secret_name" {
  description = <<-EOT
    Secrets Manager secret holding the opencode provider key, as a plain string. opencode carries its
    own provider auth (stored in ~/.local/share/opencode/auth.json on a workstation), and there is no
    instance-profile mechanism for it the way there was for Bedrock — so the key lives here, in its own
    secret (never the same one as the GH token), and the bootstrap writes it into the opencode auth
    file. Created outside Terraform on purpose, like the GH token:

      aws secretsmanager create-secret --name archunitdev/opencode-key --secret-string 'sk-...'

    The value is the provider key for the `opencode-go` provider the harness's MODEL/FLASH_MODEL name.
  EOT
  type        = string
  default     = "archunitdev/opencode-key"
}

variable "image_tag" {
  description = "Tag of the harness image in the private ECR repository this stack creates."
  type        = string
  default     = "latest"
}

variable "secretsmanager_vpc_endpoint" {
  description = "Fetch the GitHub token and the opencode key over PrivateLink rather than through the NAT gateway. ~$7/month."
  type        = bool
  default     = true
}
