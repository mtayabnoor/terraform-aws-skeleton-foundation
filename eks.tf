# ------------------------------------------------------------------------------
# EKS: control plane, IAM roles, add-ons, managed node groups and cluster access.
# Everything in this file is created only when var.enable_eks = true.
# ------------------------------------------------------------------------------

# Created up front so the control plane logs get a retention period instead of
# the "never expire" group EKS would create on its own.
resource "aws_cloudwatch_log_group" "eks_cluster" {
  count = local.eks_enabled && length(var.eks_cluster_log_types) > 0 ? 1 : 0

  name              = "/aws/eks/${local.eks_cluster_name}/cluster"
  retention_in_days = var.eks_cluster_log_retention_days

  tags = local.eks_tags
}

resource "aws_eks_cluster" "this" {
  count = local.eks_enabled ? 1 : 0

  name     = local.eks_cluster_name
  role_arn = aws_iam_role.eks_cluster[0].arn
  version  = var.eks_cluster_version

  enabled_cluster_log_types = var.eks_cluster_log_types
  deletion_protection       = var.eks_deletion_protection

  # vpc-cni, kube-proxy and coredns are installed as managed EKS add-ons
  # (further down in this file) instead of the unmanaged copies EKS would bootstrap.
  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = var.eks_enable_cluster_creator_admin_permissions
  }

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = var.eks_endpoint_public_access
    public_access_cidrs     = var.eks_endpoint_public_access ? var.eks_endpoint_public_access_cidrs : null
  }

  kubernetes_network_config {
    ip_family         = "ipv4"
    service_ipv4_cidr = var.eks_service_ipv4_cidr
  }

  # Stay on standard support by default so an outdated cluster is upgraded
  # automatically instead of silently moving to paid extended support.
  upgrade_policy {
    support_type = var.eks_support_type
  }

  # Optional: encrypt Kubernetes secrets with your own KMS key.
  dynamic "encryption_config" {
    for_each = var.eks_secrets_kms_key_arn != null ? [var.eks_secrets_kms_key_arn] : []

    content {
      resources = ["secrets"]

      provider {
        key_arn = encryption_config.value
      }
    }
  }

  tags = local.eks_tags

  lifecycle {
    precondition {
      condition     = length(local.private_subnets) >= 2
      error_message = "EKS needs private subnets in at least two availability zones. Pass at least two entries in azs."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster,
    aws_cloudwatch_log_group.eks_cluster,
  ]
}

# ------------------------------------------------------------------------------
# Optional IAM OIDC provider for IRSA. Not needed for anything this module
# installs (it uses EKS Pod Identity), only for workloads that still rely on IRSA.
# ------------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "eks" {
  count = local.eks_enabled && var.eks_enable_irsa ? 1 : 0

  url            = aws_eks_cluster.this[0].identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]

  tags = local.eks_tags
}

# ------------------------------------------------------------------------------
# IAM role for the EKS control plane
# ------------------------------------------------------------------------------
data "aws_iam_policy_document" "eks_cluster_assume" {
  count = local.eks_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  count = local.eks_enabled ? 1 : 0

  name               = "${local.eks_cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume[0].json

  tags = local.eks_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  count = local.eks_enabled ? 1 : 0

  role       = aws_iam_role.eks_cluster[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ------------------------------------------------------------------------------
# IAM role shared by all managed node groups
# ------------------------------------------------------------------------------
locals {
  eks_node_policy_arns = local.eks_enabled ? merge(
    {
      worker = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
      ecr    = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      cni    = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
    },
    # Lets you open a shell on a node with SSM Session Manager, no SSH keys or open ports.
    var.eks_node_enable_ssm ? { ssm = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore" } : {},
    var.eks_node_iam_additional_policies,
  ) : {}
}

data "aws_iam_policy_document" "eks_node_assume" {
  count = local.eks_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  count = local.eks_enabled ? 1 : 0

  name               = "${local.eks_cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume[0].json

  tags = local.eks_tags
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = local.eks_node_policy_arns

  role       = aws_iam_role.eks_node[0].name
  policy_arn = each.value
}

# ------------------------------------------------------------------------------
# EKS managed add-ons, driven by var.eks_addons.
#
# Split in two because of ordering:
#   before_compute = true  -> installed before the node groups (networking the
#                             nodes need to become Ready: vpc-cni, kube-proxy, ...)
#   before_compute = false -> installed after the node groups (add-ons that run
#                             as Deployments and need a node: coredns, ...)
# ------------------------------------------------------------------------------
locals {
  eks_addons_before_compute = { for k, v in var.eks_addons : k => v if local.eks_enabled && v.before_compute }
  eks_addons_after_compute  = { for k, v in var.eks_addons : k => v if local.eks_enabled && !v.before_compute }
}

resource "aws_eks_addon" "before_compute" {
  for_each = local.eks_addons_before_compute

  cluster_name = aws_eks_cluster.this[0].name
  addon_name   = each.key
  # null = let EKS pick the default version for the cluster's Kubernetes version.
  addon_version = each.value.version

  configuration_values        = each.value.configuration_values
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = each.value.resolve_conflicts_on_update

  tags = local.eks_tags
}

resource "aws_eks_addon" "this" {
  for_each = local.eks_addons_after_compute

  cluster_name = aws_eks_cluster.this[0].name
  addon_name   = each.key
  # null = let EKS pick the default version for the cluster's Kubernetes version.
  addon_version = each.value.version

  configuration_values        = each.value.configuration_values
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = each.value.resolve_conflicts_on_update

  tags = local.eks_tags

  depends_on = [aws_eks_node_group.this]
}

# ------------------------------------------------------------------------------
# Managed node groups, one per entry in var.eks_node_groups.
# Nodes run in the private subnets and reach the internet through the NAT gateway.
# ------------------------------------------------------------------------------
resource "aws_eks_node_group" "this" {
  for_each = local.eks_enabled ? var.eks_node_groups : {}

  cluster_name    = aws_eks_cluster.this[0].name
  node_group_name = "${local.eks_cluster_name}-${each.key}"
  node_role_arn   = aws_iam_role.eks_node[0].arn
  subnet_ids      = aws_subnet.private[*].id

  # Follows the control plane version unless pinned per node group.
  version = coalesce(each.value.kubernetes_version, aws_eks_cluster.this[0].version)

  ami_type       = each.value.ami_type
  capacity_type  = each.value.capacity_type
  instance_types = each.value.instance_types
  disk_size      = each.value.disk_size
  labels         = each.value.labels

  scaling_config {
    min_size     = each.value.min_size
    max_size     = each.value.max_size
    desired_size = each.value.desired_size
  }

  update_config {
    max_unavailable_percentage = each.value.max_unavailable_percentage
  }

  dynamic "taint" {
    for_each = each.value.taints

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(local.eks_tags, { Name = "${local.eks_cluster_name}-${each.key}" })

  lifecycle {
    # desired_size is only the initial size; an autoscaler may change it later.
    ignore_changes = [scaling_config[0].desired_size]

    precondition {
      condition     = local.create_nat
      error_message = "EKS nodes run in the private subnets and need outbound internet to join the cluster and pull images. Set enable_nat_gateway = true."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node,
    # Nodes only become Ready once vpc-cni and kube-proxy are running.
    aws_eks_addon.before_compute,
    # Keep the route to the NAT gateway in place until the nodes are gone.
    aws_route.private_nat,
    aws_route_table_association.private,
  ]
}

# ------------------------------------------------------------------------------
# Cluster access (EKS access entries, authentication mode "API").
#
# The identity that creates the cluster (the CI user) is cluster admin through
# bootstrap_cluster_creator_admin_permissions. Add humans / other roles here.
# ------------------------------------------------------------------------------
resource "aws_eks_access_entry" "this" {
  for_each = local.eks_enabled ? var.eks_access_entries : {}

  cluster_name  = aws_eks_cluster.this[0].name
  principal_arn = each.value.principal_arn
  type          = "STANDARD"

  tags = local.eks_tags
}

resource "aws_eks_access_policy_association" "this" {
  for_each = local.eks_enabled ? var.eks_access_entries : {}

  cluster_name  = aws_eks_cluster.this[0].name
  principal_arn = aws_eks_access_entry.this[each.key].principal_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/${each.value.policy}"

  access_scope {
    type       = length(each.value.namespaces) > 0 ? "namespace" : "cluster"
    namespaces = length(each.value.namespaces) > 0 ? each.value.namespaces : null
  }
}
