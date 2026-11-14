# ------------------------------------------------------------------------------
# Kubernetes Gateway API on EKS (replaces Ingress)
#
#   1. Gateway API CRDs            - vendored chart in charts/gateway-api-crds
#   2. AWS Load Balancer Controller - turns Gateway/HTTPRoute objects into ALBs
#                                     (and TCPRoute/UDPRoute/TLSRoute into NLBs)
#   3. GatewayClass(es) and an optional shared Gateway
#
# Created only when enable_eks and enable_gateway_api are both true.
# The helm provider is configured by the calling root module.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# IAM for the AWS Load Balancer Controller, handed to its service account
# through EKS Pod Identity (needs the eks-pod-identity-agent add-on).
# ------------------------------------------------------------------------------
data "aws_iam_policy_document" "lb_controller_assume" {
  count = local.gateway_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  count = local.gateway_enabled ? 1 : 0

  name               = "${local.eks_cluster_name}-lb-controller"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume[0].json

  tags = local.eks_tags
}

# Upstream policy for the pinned controller version, see policies/README.md.
resource "aws_iam_policy" "lb_controller" {
  count = local.gateway_enabled ? 1 : 0

  name   = "${local.eks_cluster_name}-lb-controller"
  policy = file("${path.module}/policies/aws-load-balancer-controller.json")

  tags = local.eks_tags
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  count = local.gateway_enabled ? 1 : 0

  role       = aws_iam_role.lb_controller[0].name
  policy_arn = aws_iam_policy.lb_controller[0].arn
}

resource "aws_eks_pod_identity_association" "lb_controller" {
  count = local.gateway_enabled ? 1 : 0

  cluster_name    = aws_eks_cluster.this[0].name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller[0].arn

  tags = local.eks_tags

  lifecycle {
    precondition {
      condition     = contains(keys(var.eks_addons), "eks-pod-identity-agent")
      error_message = "The AWS Load Balancer Controller gets its AWS permissions through EKS Pod Identity. Keep the eks-pod-identity-agent entry in eks_addons."
    }
  }
}

# ------------------------------------------------------------------------------
# 1. Gateway API CRDs (standard channel)
# ------------------------------------------------------------------------------
resource "helm_release" "gateway_api_crds" {
  count = local.gateway_enabled ? 1 : 0

  name      = "gateway-api-crds"
  namespace = "kube-system"
  chart     = "${path.module}/charts/gateway-api-crds"

  # Any admin can list the cluster's helm releases; the CRDs are public anyway.
  max_history = 3

  depends_on = [
    aws_eks_cluster.this,
    aws_eks_access_entry.this,
    aws_eks_access_policy_association.this,
  ]
}

# ------------------------------------------------------------------------------
# 2. AWS Load Balancer Controller
# The controller enables its Gateway API support at start-up, only when it finds
# the CRDs, so the CRD release has to come first.
# ------------------------------------------------------------------------------
resource "helm_release" "lb_controller" {
  count = local.gateway_enabled ? 1 : 0

  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lb_controller_chart_version

  max_history = 3
  timeout     = 600

  values = [
    yamlencode({
      clusterName  = aws_eks_cluster.this[0].name
      region       = data.aws_region.current.region
      vpcId        = aws_vpc.this.id
      replicaCount = var.lb_controller_replicas

      serviceAccount = {
        create = true
        name   = aws_eks_pod_identity_association.lb_controller[0].service_account
      }
    }),
    yamlencode(var.lb_controller_values),
  ]

  depends_on = [
    helm_release.gateway_api_crds,
    # The controller pods need nodes, DNS and their IAM role before they start.
    aws_eks_node_group.this,
    aws_eks_addon.this,
    aws_iam_role_policy_attachment.lb_controller,
  ]
}

# ------------------------------------------------------------------------------
# 3. GatewayClasses and the optional shared Gateway
#
# Rendered from HCL and installed through the tiny charts/raw-resources chart,
# so the objects are only sent to the cluster once the CRDs exist. On destroy
# the Gateway is removed first, while the controller is still running, so the
# load balancer is cleaned up properly.
# ------------------------------------------------------------------------------
locals {
  gateway_name      = var.eks_gateway.name
  gateway_namespace = var.eks_gateway.namespace
  gateway_https     = var.eks_gateway.certificate_arn != null

  gateway_allowed_routes = {
    namespaces = { from = var.eks_gateway.allowed_routes_from }
  }

  gateway_classes = concat(
    [
      {
        apiVersion = "gateway.networking.k8s.io/v1"
        kind       = "GatewayClass"
        metadata   = { name = var.gateway_class_alb_name }
        spec       = { controllerName = "gateway.k8s.aws/alb" }
      },
    ],
    var.gateway_class_nlb_enabled ? [
      {
        apiVersion = "gateway.networking.k8s.io/v1"
        kind       = "GatewayClass"
        metadata   = { name = var.gateway_class_nlb_name }
        spec       = { controllerName = "gateway.k8s.aws/nlb" }
      },
    ] : [],
  )

  # Default for every Service behind the Gateway: register pod IPs directly
  # (works with ClusterIP Services, no NodePort needed).
  gateway_target_group_configuration = {
    apiVersion = "gateway.k8s.aws/v1"
    kind       = "TargetGroupConfiguration"
    metadata   = { name = "${local.gateway_name}-defaults", namespace = local.gateway_namespace }
    spec = {
      defaultConfiguration = { targetType = var.eks_gateway.target_type }
    }
  }

  gateway_load_balancer_configuration = {
    apiVersion = "gateway.k8s.aws/v1"
    kind       = "LoadBalancerConfiguration"
    metadata   = { name = local.gateway_name, namespace = local.gateway_namespace }
    spec = {
      scheme                          = var.eks_gateway.scheme
      defaultTargetGroupConfiguration = { name = "${local.gateway_name}-defaults" }
      listenerConfigurations = [
        for arn in compact([var.eks_gateway.certificate_arn]) : { protocolPort = "HTTPS:443", defaultCertificate = arn }
      ]
    }
  }

  gateway = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata   = { name = local.gateway_name, namespace = local.gateway_namespace }
    spec = {
      gatewayClassName = var.gateway_class_alb_name
      infrastructure = {
        parametersRef = {
          group = "gateway.k8s.aws"
          kind  = "LoadBalancerConfiguration"
          name  = local.gateway_name
        }
      }
      listeners = [
        for l in [
          { name = "http", protocol = "HTTP", port = 80, enabled = true },
          { name = "https", protocol = "HTTPS", port = 443, enabled = local.gateway_https },
        ] : { name = l.name, protocol = l.protocol, port = l.port, allowedRoutes = local.gateway_allowed_routes } if l.enabled
      ]
    }
  }

  # Each object is JSON-encoded on its own so the list has a single element
  # type; the chart decodes it again.
  gateway_resources = concat(
    [for c in local.gateway_classes : jsonencode(c)],
    var.eks_gateway.create ? [
      jsonencode(local.gateway_target_group_configuration),
      jsonencode(local.gateway_load_balancer_configuration),
      jsonencode(local.gateway),
    ] : [],
  )
}

resource "helm_release" "gateway" {
  count = local.gateway_enabled ? 1 : 0

  name             = "gateway"
  namespace        = local.gateway_namespace
  create_namespace = true
  chart            = "${path.module}/charts/raw-resources"

  max_history = 3
  timeout     = 600

  values = [
    yamlencode({ resources = local.gateway_resources }),
  ]

  depends_on = [helm_release.lb_controller]
}
