# The network posture, and the one sentence that explains all of it: the loop needs to reach out
# (Bedrock, GitHub) and nothing ever needs to reach in.
#
# So the instance sits in a private subnet with no public address, and there is no route by which a
# packet from the internet could arrive: not an open port, not a closed one. Egress goes through a NAT
# gateway, which is one-way by construction — it has a public address, but a connection through it can
# only be opened from the inside. Shell access is AWS Systems Manager, which the instance opens
# *outbound* to AWS, so there is no listening SSH port and no key pair to lose.

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  # Both are required for interface endpoints to resolve to their in-VPC addresses.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

# The public subnet exists for the NAT gateway alone. Nothing of ours runs in it.
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.0.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = { Name = "${var.name}-public-nat-only" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  # Belt to the braces of not asking for one in the instance's network interface.
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-private" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = var.name }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.name}-nat" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  depends_on = [aws_internet_gateway.main]

  tags = { Name = var.name }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# --- security groups ---------------------------------------------------------------------------
#
# The instance group has NO ingress rules. That is not an omission: a security group with no ingress
# rule denies everything inbound, and there is no way to reach the instance's address from outside the
# VPC in any case. Shell access is Session Manager, which is an outbound connection.

resource "aws_security_group" "instance" {
  name        = "${var.name}-instance"
  description = "The loop. Outbound HTTPS only; nothing inbound."
  vpc_id      = aws_vpc.main.id

  # Written as an explicit empty list rather than left out. Omitted, ingress is *unmanaged*: the group
  # still starts with nothing inbound, but a rule opened by hand afterwards would survive every later
  # apply. Empty means Terraform owns the answer and takes such a rule away again.
  ingress = []

  egress {
    description = "Bedrock, GitHub, the Go module proxy, and the AWS APIs. All HTTPS."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-instance" }
}

# Interface endpoints are ENIs in the private subnet, so they need a group of their own that accepts
# HTTPS from the instance and from nothing else.
resource "aws_security_group" "endpoints" {
  name        = "${var.name}-vpc-endpoints"
  description = "PrivateLink endpoints. HTTPS from the loop instance only."
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTPS from the loop"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.instance.id]
  }

  # An endpoint ENI answers requests; it never makes any. Same reasoning as the empty ingress above.
  egress = []

  tags = { Name = "${var.name}-vpc-endpoints" }
}

# --- endpoints ---------------------------------------------------------------------------------
#
# The S3 gateway endpoint is free and does two jobs: the log sync writes through it, and ECR stores
# image layers in S3, so pulling the harness image uses it too. The two interface endpoints are the
# ones carrying content worth keeping off the public internet — the prompts and diffs (Bedrock) and
# the GitHub token (Secrets Manager). Everything else the instance talks to (STS for the credential
# check, SSM for the shell, the ECR API) goes out through NAT, because an endpoint each would cost
# more per month than the plumbing is worth defending.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name}-s3" }
}

resource "aws_vpc_endpoint" "bedrock_runtime" {
  count = var.bedrock_vpc_endpoint ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.name}-bedrock-runtime" }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  count = var.secretsmanager_vpc_endpoint ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.name}-secretsmanager" }
}
