# The instance role. An instance profile rather than credentials is the load-bearing decision of the
# whole deployment: the run lasts hours, so anything short-lived expires partway through and every
# invocation after that fails. run.sh enforces it — an unbounded run on static temporary credentials is
# refused at startup rather than discovered failing at 03:00.

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "loop" {
  name        = "${var.name}-loop"
  description = "The ArchUnitDev loop: Bedrock inference, its own log prefix, its own secret."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })
}

# The region is a wildcard on purpose: the pinned model is the *global* inference profile
# `global.anthropic.claude-opus-5`, which may route across regions.
resource "aws_iam_role_policy" "bedrock" {
  name = "InvokeClaudeOnBedrock"
  role = aws_iam_role.loop.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeClaudeOnBedrock"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/anthropic.*",
          "arn:aws:bedrock:*:*:inference-profile/*anthropic.*",
          "arn:aws:bedrock:*:*:application-inference-profile/*",
        ]
      },
    ]
  })
}

# Write-only, and only under one prefix. Reading the logs back is something a human does from a laptop
# with their own credentials, so the instance has no need of GetObject and does not get it.
resource "aws_iam_role_policy" "logs" {
  name = "WriteLoopLogs"
  role = aws_iam_role.loop.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteLoopLogs"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload",
        ]
        Resource = "${aws_s3_bucket.logs.arn}/loop/*"
      },
      {
        Sid      = "ListOnlyTheLoopPrefix"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.logs.arn
        Condition = {
          StringLike = { "s3:prefix" = "loop/*" }
        }
      },
    ]
  })
}

# The handoff prefix: how one host gives another the work it has done. Under NO_PUSH the commits exist
# only on the volume that produced them, so a second host re-attempting an abandoned issue has no way
# to see the tree it is supposed to build on — a git bundle through S3 is the transport.
#
# A separate prefix rather than GetObject on loop/*, because "the loop cannot read its own logs back"
# is a property worth keeping: the logs are the evidence a human judges the run by, and a run that can
# read them is a run that can be asked to. What lands here is a bundle and a set of verdicts, put there
# deliberately, by a human or by the host that produced them.
resource "aws_iam_role_policy" "handoff" {
  name = "ReadWriteHandoff"
  role = aws_iam_role.loop.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadWriteHandoff"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload",
        ]
        Resource = "${aws_s3_bucket.logs.arn}/handoff/*"
      },
      {
        Sid      = "ListOnlyTheHandoffPrefix"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.logs.arn
        Condition = {
          StringLike = { "s3:prefix" = "handoff/*" }
        }
      },
    ]
  })
}

# One secret, by name. The token is the only thing on this instance that could do damage if the box
# were compromised — it can write to the target repository — so it is worth the extra resource not to
# have it in a shell history, an AMI, or Terraform state.
resource "aws_iam_role_policy" "gh_token" {
  name = "ReadGitHubToken"
  role = aws_iam_role.loop.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.gh_token_secret_name}-*"
      },
    ]
  })
}

# Session Manager: this is what replaces SSH, and with it there is no inbound rule, no key pair and no
# bastion. The agent connects outbound to AWS; a session is an authenticated API call, logged in
# CloudTrail like any other.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.loop.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.loop.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "loop" {
  name = "${var.name}-loop"
  role = aws_iam_role.loop.name
}
