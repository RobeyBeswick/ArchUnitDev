# The log bucket and the image registry. Both private, and both explicitly so rather than by default —
# the point of writing the negative settings out is that a later change has to argue with them.

resource "aws_s3_bucket" "logs" {
  bucket_prefix = "${var.name}-logs-"

  # The logs are reproducible in principle (re-run the loop) and irreplaceable in practice (the diffs
  # and verdicts explaining decisions already made), so they are worth keeping but not worth guarding
  # against a deliberate `terraform destroy`.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id

  # Disables ACLs outright, so "public-read on one object" is not a mistake that can be made.
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning is what makes a flat prefix safe: a re-run of an issue overwrites that issue's artifacts,
# and the version history keeps what the first attempt looked like. log-sync.sh also writes under a
# per-run prefix, so this is the second of two independent protections against losing that evidence.
resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "logs_tls_only" {
  bucket = aws_s3_bucket.logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.logs.arn,
          "${aws_s3_bucket.logs.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  # A bucket policy cannot be attached while the public-access block is still settling.
  depends_on = [aws_s3_bucket_public_access_block.logs]
}

# --- the harness image -------------------------------------------------------------------------
#
# A private registry, so the image is pulled from inside the VPC (through the S3 gateway endpoint for
# the layers) rather than from a public registry. It also means the image can be built somewhere with
# working DNS for the Go module proxy and pushed here — which matters, because the build fetches from
# proxy.golang.org and that is blocked on the network this repository is developed on.

resource "aws_ecr_repository" "harness" {
  name                 = var.name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  force_delete = true
}

# One image is all that is ever wanted; the rest is yesterday's untagged layers.
resource "aws_ecr_lifecycle_policy" "harness" {
  repository = aws_ecr_repository.harness.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
    ]
  })
}
