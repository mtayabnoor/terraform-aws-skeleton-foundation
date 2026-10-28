locals {
  vpc_cidr = var.cidr_block
  azs      = var.azs
  private_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  public_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]

  create_nat       = var.enable_nat_gateway && length(local.public_subnets) > 0 && length(local.private_subnets) > 0
  nat_gw_count     = local.create_nat ? (var.single_nat_gateway ? 1 : length(local.public_subnets)) : 0
  private_rt_count = local.create_nat && !var.single_nat_gateway ? length(local.private_subnets) : (length(local.private_subnets) > 0 ? 1 : 0)
}
