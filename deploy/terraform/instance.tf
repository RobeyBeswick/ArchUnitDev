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
    log_bucket           = aws_s3_bucket.logs.id
    gh_token_secret_name = var.gh_token_secret_name
  })

  # Replacing the instance because the bootstrap script changed would destroy the working tree with it.
  # The script only runs at first boot anyway, so a change to it is not a reason to rebuild the host.
  lifecycle {
    ignore_changes = [user_data, ami]
  }

  tags = { Name = "${var.name}-loop" }
}
