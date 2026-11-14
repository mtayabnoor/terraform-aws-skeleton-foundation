data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  vpc_cidr = var.cidr_block
  azs      = var.azs

  # Explicit CIDR lists win; otherwise carve /(vpc prefix + subnet_newbits) blocks out of the VPC CIDR.
  private_subnets = var.private_subnet_cidrs != null ? var.private_subnet_cidrs : [for k, v in local.azs : cidrsubnet(local.vpc_cidr, var.subnet_newbits, k)]
  public_subnets  = var.public_subnet_cidrs != null ? var.public_subnet_cidrs : [for k, v in local.azs : cidrsubnet(local.vpc_cidr, var.subnet_newbits, k + var.public_subnet_netnum_offset)]

  create_nat       = var.enable_nat_gateway && length(local.public_subnets) > 0 && length(local.private_subnets) > 0
  nat_gw_count     = local.create_nat ? (var.single_nat_gateway ? 1 : length(local.public_subnets)) : 0
  private_rt_count = local.create_nat && !var.single_nat_gateway ? length(local.private_subnets) : (length(local.private_subnets) > 0 ? 1 : 0)

  # ----------------------------------------------------------------------------
  # EKS
  # ----------------------------------------------------------------------------
  eks_enabled      = var.enable_eks
  eks_cluster_name = coalesce(var.eks_cluster_name, "${var.name}-eks")
  eks_tags         = merge(var.tags, var.eks_tags)

  # Both only make sense on top of the cluster.
  lb_controller_enabled = local.eks_enabled && var.enable_lb_controller
  argocd_enabled        = local.eks_enabled && var.enable_argocd

  # Subnet discovery tags used by the AWS Load Balancer Controller to place
  # internet-facing (public) and internal (private) load balancers.
  eks_public_subnet_tags  = local.eks_enabled ? { "kubernetes.io/role/elb" = "1" } : {}
  eks_private_subnet_tags = local.eks_enabled ? { "kubernetes.io/role/internal-elb" = "1" } : {}
}
