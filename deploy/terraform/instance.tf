data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "loop" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.loop.name

  # No public address and no key pair: nothing to connect *to*, and nothing to lose. Shell access is
  # Session Manager, which the SSM agent opens outbound.
  associate_public_ip_address = false

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"

    # 2, not the default 1, and this is the step that silently breaks everything if it is missed:
    # Docker's bridge network adds a hop, so with a limit of 1 the container cannot reach IMDS at all
    # and the Bedrock credentials simply never resolve. `--network host` avoids it instead.
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.volume_size
    volume_type = "gp3"
    encrypted   = true

    # The volume is the only copy of the work under NO_PUSH, and delete-on-terminate is the default.
    # Keeping it means a fat-fingered terminate costs an EBS volume rather than a night of commits.
    delete_on_termination = false
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region               = var.region
    registry             = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
    image                = "${aws_ecr_repository.harness.repository_url}:${var.image_tag}"
    target_repo          = var.target_repo
    harness_repo         = var.harness_repo
    log_bucket           = aws_s3_bucket.logs.id
    gh_token_secret_name = var.gh_token_secret_name
  })

  # Terraform infers dependencies from references, and the instance references neither the NAT gateway
  # nor the route table it is reached through — so without this it can boot, and run its whole
  # bootstrap, before the private subnet has any route off the VPC. That is a race that resolves
  # differently on a fast day than a slow one, which is the worst kind.
  depends_on = [
    aws_nat_gateway.main,
    aws_route_table_association.private,
  ]

  # Replacing the instance because the bootstrap script changed would destroy the working tree with it.
  # The script only runs at first boot anyway, so a change to it is not a reason to rebuild the host.
  lifecycle {
    ignore_changes = [user_data, ami]
  }

  tags = { Name = "${var.name}-loop" }
}

# A second host, so issues the main loop abandoned can be re-attempted *while it is still working
# through the queue*. Everything it needs is shared with the loop host — same subnet, same security
# group, same instance profile, same log bucket — so it is one resource and a variable rather than a
# second stack.
#
# Why not a second container on the loop host, which needs no new instance at all: memory. 4GB is
# already the floor for `go test -race` plus golangci-lint type-checking the package graph (see
# var.instance_type), and two gates on one box means the OOM killer taking out a step of whichever loop
# reached it second. That reads in the log as a code defect, sends a fixer after something that is not
# there, and — the part that decides it — the run it would corrupt is the one holding a night of
# commits that exist nowhere else.
#
# `count` rather than folding both hosts into one `for_each`: converting aws_instance.loop to a keyed
# address would make Terraform destroy and recreate the running host, and its root volume is the only
# copy of the work under NO_PUSH.
resource "aws_instance" "retry" {
  count = var.retry_host ? 1 : 0

  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.retry_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.loop.name

  associate_public_ip_address = false

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # Docker's bridge network adds a hop; with the default limit of 1 the container cannot reach IMDS
    # and the Bedrock credentials never resolve. The same trap as on the loop host.
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.volume_size
    volume_type = "gp3"
    encrypted   = true

    # Same reasoning as the loop host: under NO_PUSH the volume is the only copy of what it produced,
    # and this host exists to produce exactly the commits the loop host could not.
    delete_on_termination = false
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region               = var.region
    registry             = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
    image                = "${aws_ecr_repository.harness.repository_url}:${var.image_tag}"
    target_repo          = var.target_repo
    harness_repo         = var.harness_repo
    log_bucket           = aws_s3_bucket.logs.id
    gh_token_secret_name = var.gh_token_secret_name
  })

  depends_on = [
    aws_nat_gateway.main,
    aws_route_table_association.private,
  ]

  lifecycle {
    ignore_changes = [user_data, ami]
  }

  tags = { Name = "${var.name}-retry" }
}
