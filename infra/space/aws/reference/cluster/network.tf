# A minimal VPC for one EKS cluster: a private and a public subnet per AZ, and a
# single NAT gateway to keep an always-on reference deployment inexpensive.
# Losing its AZ cuts egress for every private subnet; use a gateway per AZ
# when that availability tradeoff is unacceptable.
#
# The VPC is named `<cluster>-vpc` and each private subnet
# `<cluster>-private-<az>`. The eks-cluster module takes their ids as inputs;
# the SPACE cluster module's tag discovery also needs secondary CG-NAT subnets,
# which this network doesn't create.

locals {
  # Private subnets take the low /20s (4,091 usable addresses each, sized for
  # VPC CNI prefix delegation); public subnets take /24s from 10.x.240.0 up,
  # well clear of any private block. Each AZ's block comes from its letter
  # (a = 0 … h = 7), not its position in the list, so adding, dropping or
  # reordering AZs never renumbers, and so never replaces, another AZ's subnets.
  az_index = {
    for az in var.availability_zones : az => index(split("", "abcdefgh"), substr(az, -1, 1))
  }

  # Sorted for the same reason: reordering the list must not move the gateway.
  nat_az = sort(var.availability_zones)[0]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

resource "aws_subnet" "public" {
  for_each = local.az_index

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 240 + each.value)
  map_public_ip_on_launch = false

  tags = {
    Name                     = "${var.cluster_name}-public-${each.key}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  for_each = local.az_index

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, each.value)

  tags = {
    Name                              = "${var.cluster_name}-private-${each.key}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.cluster_name}-public"
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-nat-${local.nat_az}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[local.nat_az].id

  tags = {
    Name = "${var.cluster_name}-nat-${local.nat_az}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.cluster_name}-private"
  }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
