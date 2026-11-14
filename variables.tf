variable "name" {
  description = "Name prefix applied to all VPC resources."
  type        = string
}

variable "cidr_block" {
  description = "IPv4 CIDR block for the VPC."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "cidr_block must be a valid IPv4 CIDR, e.g. 10.0.0.0/16."
  }
}

variable "azs" {
  description = "Availability zones to spread subnets across."
  type        = list(string)
}

variable "subnet_newbits" {
  description = "Bits added to the VPC prefix for the generated subnets (8 turns a /16 VPC into /24 subnets). Ignored for a tier when its explicit CIDR list is set."
  type        = number
  default     = 8
}

variable "public_subnet_netnum_offset" {
  description = "Offset of the generated public subnets inside the VPC CIDR (private subnets start at 0). Must be >= the number of AZs."
  type        = number
  default     = 4
}

variable "private_subnet_cidrs" {
  description = "Explicit private subnet CIDRs, one per AZ. Leave null to generate them from cidr_block."
  type        = list(string)
  default     = null
}

variable "public_subnet_cidrs" {
  description = "Explicit public subnet CIDRs, one per AZ. Leave null to generate them from cidr_block."
  type        = list(string)
  default     = null
}

variable "public_subnet_tags" {
  description = "Extra tags for the public subnets."
  type        = map(string)
  default     = {}
}

variable "private_subnet_tags" {
  description = "Extra tags for the private subnets."
  type        = map(string)
  default     = {}
}

variable "enable_dns_hostnames" {
  description = "Enable DNS hostnames in the VPC."
  type        = bool
  default     = true
}

variable "enable_dns_support" {
  description = "Enable DNS support in the VPC."
  type        = bool
  default     = true
}

variable "map_public_ip_on_launch" {
  description = "Auto-assign public IPs to instances launched in public subnets."
  type        = bool
  default     = true
}

variable "enable_nat_gateway" {
  description = "Create NAT gateway(s) so private subnets can reach the internet."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway (cheaper) instead of one per AZ (highly available)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# EKS cluster
# ------------------------------------------------------------------------------
variable "enable_eks" {
  description = "Create an EKS cluster in the VPC. When false, none of the EKS / Gateway API resources are created."
  type        = bool
  default     = false
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster. Defaults to \"<name>-eks\"."
  type        = string
  default     = null
}

variable "eks_cluster_version" {
  description = "Kubernetes minor version of the control plane, e.g. \"1.36\". Upgrade one minor version at a time."
  type        = string
  default     = "1.36"
}

variable "eks_support_type" {
  description = "STANDARD: EKS auto-upgrades the cluster when its version leaves standard support. EXTENDED: keep the version and pay for extended support."
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.eks_support_type)
    error_message = "eks_support_type must be STANDARD or EXTENDED."
  }
}

variable "eks_deletion_protection" {
  description = "Block deletion of the cluster until this is set back to false. Recommended for prod."
  type        = bool
  default     = false
}

variable "eks_endpoint_public_access" {
  description = "Expose the Kubernetes API endpoint on the internet (still IAM-authenticated). Terraform running on GitHub-hosted runners needs this to install the Gateway API components."
  type        = bool
  default     = true
}

variable "eks_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "eks_service_ipv4_cidr" {
  description = "CIDR for Kubernetes Service IPs. Leave null for the EKS default. Cannot be changed after creation."
  type        = string
  default     = null
}

variable "eks_cluster_log_types" {
  description = "Control plane log types sent to CloudWatch. Empty list disables control plane logging."
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "eks_cluster_log_retention_days" {
  description = "Retention of the control plane log group in days."
  type        = number
  default     = 30
}

variable "eks_secrets_kms_key_arn" {
  description = "KMS key ARN for envelope encryption of Kubernetes secrets. Leave null to use the EKS default encryption."
  type        = string
  default     = null
}

variable "eks_enable_irsa" {
  description = "Create the IAM OIDC provider for IAM Roles for Service Accounts. Not needed by this module (it uses EKS Pod Identity)."
  type        = bool
  default     = false
}

variable "eks_tags" {
  description = "Extra tags for the EKS resources, merged over tags."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# Cluster access
# ------------------------------------------------------------------------------
variable "eks_enable_cluster_creator_admin_permissions" {
  description = "Make the identity that creates the cluster (the Terraform / CI identity) a cluster admin. Required for Terraform to install the Gateway API components. Cannot be changed after creation."
  type        = bool
  default     = true
}

variable "eks_access_entries" {
  description = <<-EOT
    Additional IAM principals that get access to the cluster, keyed by a free name.
      principal_arn - IAM user or role ARN
      policy        - EKS access policy name: AmazonEKSClusterAdminPolicy, AmazonEKSAdminPolicy,
                      AmazonEKSEditPolicy or AmazonEKSViewPolicy
      namespaces    - limit the policy to these namespaces (empty = whole cluster)
    Do not add the identity that creates the cluster here, it already has an entry.
  EOT
  type = map(object({
    principal_arn = string
    policy        = optional(string, "AmazonEKSClusterAdminPolicy")
    namespaces    = optional(list(string), [])
  }))
  default = {}
}

# ------------------------------------------------------------------------------
# Nodes
# ------------------------------------------------------------------------------
variable "eks_node_groups" {
  description = "Managed node groups, keyed by name. Every attribute is optional; `default = {}` gives two t3.medium on-demand nodes."
  type = map(object({
    instance_types             = optional(list(string), ["t3.medium"])
    capacity_type              = optional(string, "ON_DEMAND") # ON_DEMAND or SPOT
    ami_type                   = optional(string, "AL2023_x86_64_STANDARD")
    kubernetes_version         = optional(string)
    disk_size                  = optional(number, 30)
    min_size                   = optional(number, 1)
    max_size                   = optional(number, 3)
    desired_size               = optional(number, 2)
    max_unavailable_percentage = optional(number, 33)
    labels                     = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string # NO_SCHEDULE, NO_EXECUTE or PREFER_NO_SCHEDULE
    })), [])
  }))
  default = {
    default = {}
  }
}

variable "eks_node_enable_ssm" {
  description = "Attach AmazonSSMManagedInstanceCore to the node role so nodes can be reached with SSM Session Manager."
  type        = bool
  default     = true
}

variable "eks_node_iam_additional_policies" {
  description = "Additional IAM policy ARNs for the node role, keyed by a free name."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# Add-ons
# ------------------------------------------------------------------------------
variable "eks_addons" {
  description = <<-EOT
    EKS managed add-ons, keyed by add-on name.
      version                     - pin a version; null lets EKS choose the default for the cluster version
      before_compute              - install before the node groups (needed for node networking)
      configuration_values        - JSON string with add-on configuration
      resolve_conflicts_on_update - OVERWRITE, PRESERVE or NONE
    vpc-cni, kube-proxy and coredns are required for a working cluster.
    eks-pod-identity-agent is required by the AWS Load Balancer Controller.
  EOT
  type = map(object({
    version                     = optional(string)
    before_compute              = optional(bool, false)
    configuration_values        = optional(string)
    resolve_conflicts_on_update = optional(string, "OVERWRITE")
  }))
  default = {
    vpc-cni                = { before_compute = true }
    kube-proxy             = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    coredns                = {}
  }
}

# ------------------------------------------------------------------------------
# Gateway API (AWS Load Balancer Controller)
# ------------------------------------------------------------------------------
variable "enable_gateway_api" {
  description = "Install the Gateway API CRDs, the AWS Load Balancer Controller and the GatewayClass(es). Only used when enable_eks = true."
  type        = bool
  default     = true
}

variable "lb_controller_chart_version" {
  description = "Version of the aws-load-balancer-controller helm chart. Keep policies/aws-load-balancer-controller.json and the vendored Gateway API CRDs in step with it."
  type        = string
  default     = "3.6.3"
}

variable "lb_controller_replicas" {
  description = "Replicas of the AWS Load Balancer Controller. Use 2 for prod."
  type        = number
  default     = 2
}

variable "lb_controller_values" {
  description = "Extra helm values for the aws-load-balancer-controller chart, merged over the module's values."
  type        = any
  default     = {}
}

variable "gateway_class_alb_name" {
  description = "Name of the GatewayClass for Application Load Balancers (HTTPRoute, GRPCRoute)."
  type        = string
  default     = "aws-alb"
}

variable "gateway_class_nlb_enabled" {
  description = "Also create a GatewayClass for Network Load Balancers (TCPRoute, UDPRoute, TLSRoute)."
  type        = bool
  default     = false
}

variable "gateway_class_nlb_name" {
  description = "Name of the GatewayClass for Network Load Balancers."
  type        = string
  default     = "aws-nlb"
}

variable "eks_gateway" {
  description = <<-EOT
    Shared Gateway that provisions one Application Load Balancer for the cluster.
    Applications attach to it with HTTPRoute objects.
      create              - create the Gateway (this creates an ALB, which costs money)
      name / namespace    - where the Gateway lives
      scheme              - internet-facing (ALB in the public subnets) or internal (private subnets)
      certificate_arn     - ACM certificate ARN; adds an HTTPS:443 listener next to HTTP:80
      allowed_routes_from - which namespaces may attach routes: All or Same
      target_type         - ip (pod IPs, works with ClusterIP Services) or instance (NodePort)
  EOT
  type = object({
    create              = optional(bool, false)
    name                = optional(string, "shared")
    namespace           = optional(string, "gateway-system")
    scheme              = optional(string, "internet-facing")
    certificate_arn     = optional(string)
    allowed_routes_from = optional(string, "All")
    target_type         = optional(string, "ip")
  })
  default = {}

  validation {
    condition     = contains(["internet-facing", "internal"], var.eks_gateway.scheme)
    error_message = "eks_gateway.scheme must be internet-facing or internal."
  }

  validation {
    condition     = contains(["All", "Same"], var.eks_gateway.allowed_routes_from)
    error_message = "eks_gateway.allowed_routes_from must be All or Same."
  }

  validation {
    condition     = contains(["ip", "instance"], var.eks_gateway.target_type)
    error_message = "eks_gateway.target_type must be ip or instance."
  }
}
