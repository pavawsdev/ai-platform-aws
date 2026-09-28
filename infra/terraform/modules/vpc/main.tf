###############################################################################
# Multi-AZ VPC for the AI Platform
# - 3 AZs, public / private-app / private-data tiers
# - VPC endpoints so EKS data-plane traffic to AWS APIs never leaves the VPC
#   (also a large NAT cost saver for ECR image pulls and S3 model artifacts)
# - Flow logs to CloudWatch, KMS encrypted
###############################################################################

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /16 split: /20 public, /18 app, /20 data
  public_cidrs = [for i, az in local.azs : cidrsubnet(var.cidr_block, 4, i)]
  app_cidrs    = [for i, az in local.azs : cidrsubnet(var.cidr_block, 2, i + 1)]
  data_cidrs   = [for i, az in local.azs : cidrsubnet(var.cidr_block, 4, i + 12)]

  tags = merge(var.tags, { Module = "vpc" })
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${var.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-igw" })
}

# The VPC's auto-created default security group is unused - every real
# resource gets its own purpose-built SG - so it is locked to deny all
# traffic rather than left at its AWS default of "allow all within itself".
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-default-locked" })
}

resource "aws_subnet" "public" {
  for_each = { for i, az in local.azs : az => i }

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = local.public_cidrs[each.value]
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name                                        = "${var.name}-public-${each.key}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    Tier                                        = "public"
  })
}

resource "aws_subnet" "app" {
  for_each = { for i, az in local.azs : az => i }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = local.app_cidrs[each.value]

  tags = merge(local.tags, {
    Name                                        = "${var.name}-app-${each.key}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # Karpenter discovers subnets by this tag
    "karpenter.sh/discovery" = var.cluster_name
    Tier                     = "app"
  })
}

resource "aws_subnet" "data" {
  for_each = { for i, az in local.azs : az => i }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = local.data_cidrs[each.value]

  tags = merge(local.tags, { Name = "${var.name}-data-${each.key}", Tier = "data" })
}

###############################################################################
# NAT: one per AZ in prod (HA, no cross-AZ blast radius), single NAT in dev
###############################################################################
resource "aws_eip" "nat" {
  for_each = var.single_nat_gateway ? toset([local.azs[0]]) : toset(local.azs)
  domain   = "vpc"
  tags     = merge(local.tags, { Name = "${var.name}-nat-${each.key}" })
}

resource "aws_nat_gateway" "this" {
  for_each      = aws_eip.nat
  allocation_id = each.value.id
  subnet_id     = aws_subnet.public[each.key].id
  tags          = merge(local.tags, { Name = "${var.name}-nat-${each.key}" })
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(local.tags, { Name = "${var.name}-rt-public" })
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  for_each = toset(local.azs)
  vpc_id   = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.this[local.azs[0]].id : aws_nat_gateway.this[each.key].id
  }

  tags = merge(local.tags, { Name = "${var.name}-rt-private-${each.key}" })
}

resource "aws_route_table_association" "app" {
  for_each       = aws_subnet.app
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# Data tier has NO egress route -> fully isolated, reachable only inside the VPC.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-rt-data" })
}

resource "aws_route_table_association" "data" {
  for_each       = aws_subnet.data
  subnet_id      = each.value.id
  route_table_id = aws_route_table.data.id
}

###############################################################################
# VPC endpoints
###############################################################################
resource "aws_security_group" "endpoints" {
  name        = "${var.name}-vpce"
  description = "Interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.cidr_block]
  }

  egress {
    description = "Return traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.cidr_block]
  }

  tags = merge(local.tags, { Name = "${var.name}-vpce" })
}

resource "aws_vpc_endpoint" "gateway" {
  for_each = toset(["s3", "dynamodb"])

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([for rt in aws_route_table.private : rt.id], [aws_route_table.data.id])
  tags              = merge(local.tags, { Name = "${var.name}-vpce-${each.key}" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoints)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.app : s.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = merge(local.tags, { Name = "${var.name}-vpce-${each.key}" })
}

###############################################################################
# Flow logs
###############################################################################
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/aws/vpc/${var.name}/flowlogs"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = local.tags
}

resource "aws_iam_role" "flow" {
  name               = "${var.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "flow_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.flow.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow" {
  role   = aws_iam_role.flow.id
  policy = data.aws_iam_policy_document.flow.json
}

resource "aws_flow_log" "this" {
  iam_role_arn             = aws_iam_role.flow.arn
  log_destination          = aws_cloudwatch_log_group.flow.arn
  traffic_type             = "ALL"
  vpc_id                   = aws_vpc.this.id
  max_aggregation_interval = 60
  tags                     = local.tags
}
