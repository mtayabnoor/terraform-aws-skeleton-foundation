output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_arn" {
  description = "ARN of the VPC."
  value       = aws_vpc.this.arn
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway (null if no public subnets)."
  value       = try(aws_internet_gateway.this[0].id, null)
}

output "public_subnet_ids" {
  description = "IDs of the public subnets."
  value       = aws_subnet.public[*].id
}

output "public_subnet_cidrs" {
  description = "CIDR blocks of the public subnets."
  value       = aws_subnet.public[*].cidr_block
}

output "private_subnet_ids" {
  description = "IDs of the private subnets."
  value       = aws_subnet.private[*].id
}

output "private_subnet_cidrs" {
  description = "CIDR blocks of the private subnets."
  value       = aws_subnet.private[*].cidr_block
}

output "nat_gateway_ids" {
  description = "IDs of the NAT gateways."
  value       = aws_nat_gateway.this[*].id
}

output "nat_public_ips" {
  description = "Public Elastic IPs attached to the NAT gateways."
  value       = aws_eip.nat[*].public_ip
}

output "public_route_table_id" {
  description = "ID of the public route table (null if no public subnets)."
  value       = try(aws_route_table.public[0].id, null)
}

output "private_route_table_ids" {
  description = "IDs of the private route tables."
  value       = aws_route_table.private[*].id
}

# ------------------------------------------------------------------------------
# EKS and Gateway API. All null (or empty) when enable_eks = false.
# ------------------------------------------------------------------------------

output "eks_cluster_name" {
  description = "Name of the EKS cluster."
  value       = try(aws_eks_cluster.this[0].name, null)
}

output "eks_cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = try(aws_eks_cluster.this[0].arn, null)
}

output "eks_cluster_endpoint" {
  description = "Kubernetes API endpoint of the cluster."
  value       = try(aws_eks_cluster.this[0].endpoint, null)
}

output "eks_cluster_certificate_authority_data" {
  description = "Base64 encoded CA certificate of the cluster."
  value       = try(aws_eks_cluster.this[0].certificate_authority[0].data, null)
}

output "eks_cluster_version" {
  description = "Kubernetes version of the control plane."
  value       = try(aws_eks_cluster.this[0].version, null)
}

output "eks_cluster_security_group_id" {
  description = "Security group EKS creates for the control plane and managed nodes."
  value       = try(aws_eks_cluster.this[0].vpc_config[0].cluster_security_group_id, null)
}

output "eks_cluster_oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster."
  value       = try(aws_eks_cluster.this[0].identity[0].oidc[0].issuer, null)
}

output "eks_oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider (null unless eks_enable_irsa = true)."
  value       = try(aws_iam_openid_connect_provider.eks[0].arn, null)
}

output "eks_cluster_iam_role_arn" {
  description = "IAM role ARN of the control plane."
  value       = try(aws_iam_role.eks_cluster[0].arn, null)
}

output "eks_node_iam_role_arn" {
  description = "IAM role ARN shared by the managed node groups."
  value       = try(aws_iam_role.eks_node[0].arn, null)
}

output "eks_node_group_names" {
  description = "Names of the managed node groups, keyed by node group key."
  value       = { for k, v in aws_eks_node_group.this : k => v.node_group_name }
}

output "eks_update_kubeconfig_command" {
  description = "Command that adds the cluster to your local kubeconfig."
  value       = try("aws eks update-kubeconfig --region ${data.aws_region.current.region} --name ${aws_eks_cluster.this[0].name}", null)
}

output "lb_controller_iam_role_arn" {
  description = "IAM role ARN of the AWS Load Balancer Controller."
  value       = try(aws_iam_role.lb_controller[0].arn, null)
}

output "lb_controller_helm_values" {
  description = "Cluster specific helm values for the aws-load-balancer-controller chart. Copy them into the controller's Argo CD Application (examples/gitops/platform/aws-load-balancer-controller.yaml)."
  value = local.eks_enabled ? {
    clusterName = aws_eks_cluster.this[0].name
    region      = data.aws_region.current.region
    vpcId       = aws_vpc.this.id
  } : null
}

output "argocd_namespace" {
  description = "Namespace Argo CD runs in (null when not installed)."
  value       = local.argocd_enabled ? var.argocd_namespace : null
}
