# ------------------------------------------------------------------------------
# VPC
# ------------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = local.vpc_cidr
  enable_dns_hostnames = var.enable_dns_hostnames
  enable_dns_support   = var.enable_dns_support

  tags = merge(var.tags, { Name = "${var.name}-vpc" })
}

# ------------------------------------------------------------------------------
# Internet Gateway
# ------------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  count = length(local.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-igw" })
}

# ------------------------------------------------------------------------------
# Subnets
# ------------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = length(local.public_subnets)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnets[count.index]
  availability_zone       = element(local.azs, count.index)
  map_public_ip_on_launch = var.map_public_ip_on_launch

  tags = merge(var.tags, {
    Name = "${var.name}-public-${element(var.azs, count.index)}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  count = length(local.private_subnets)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = element(local.azs, count.index)

  tags = merge(var.tags, {
    Name = "${var.name}-private-${element(var.azs, count.index)}"
    Tier = "private"
  })
}

# ------------------------------------------------------------------------------
# NAT Gateway(s)
# ------------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count = local.nat_gw_count

  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.name}-nat-eip-${count.index + 1}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gw_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, { Name = "${var.name}-nat-${count.index + 1}" })

  depends_on = [aws_internet_gateway.this]
}

# ------------------------------------------------------------------------------
# Route Tables - Public
# ------------------------------------------------------------------------------
resource "aws_route_table" "public" {
  count = length(local.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route" "public_internet" {
  count = length(local.public_subnets) > 0 ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  count = length(local.public_subnets)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# ------------------------------------------------------------------------------
# Route Tables - Private
# One shared table with a single NAT, or one per AZ with a NAT per AZ.
# ------------------------------------------------------------------------------
resource "aws_route_table" "private" {
  count = local.private_rt_count

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = local.private_rt_count == 1 ? "${var.name}-private-rt" : "${var.name}-private-rt-${element(var.azs, count.index)}"
  })
}

resource "aws_route" "private_nat" {
  count = local.create_nat ? local.private_rt_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count = length(local.private_subnets)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[local.private_rt_count == 1 ? 0 : count.index].id
}