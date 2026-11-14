# ------------------------------------------------------------------------------
# Gateway API on EKS (replaces Ingress): AWS side
#
# Gateway / HTTPRoute objects are turned into Application Load Balancers by the
# AWS Load Balancer Controller. Terraform only prepares what lives in AWS: the
# controller's IAM role, bound to its service account with EKS Pod Identity
# (needs the eks-pod-identity-agent add-on).
#
# Everything inside the cluster (Gateway API CRDs, the controller itself, the
# GatewayClass and Gateway) is installed by Argo CD from Git, see argocd.tf and
# examples/gitops.
# ------------------------------------------------------------------------------
data "aws_iam_policy_document" "lb_controller_assume" {
  count = local.lb_controller_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  count = local.lb_controller_enabled ? 1 : 0

  name               = "${local.eks_cluster_name}-lb-controller"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume[0].json

  tags = local.eks_tags
}

# Upstream policy of the controller, see policies/README.md.
resource "aws_iam_policy" "lb_controller" {
  count = local.lb_controller_enabled ? 1 : 0

  name   = "${local.eks_cluster_name}-lb-controller"
  policy = file("${path.module}/policies/aws-load-balancer-controller.json")

  tags = local.eks_tags
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  count = local.lb_controller_enabled ? 1 : 0

  role       = aws_iam_role.lb_controller[0].name
  policy_arn = aws_iam_policy.lb_controller[0].arn
}

resource "aws_eks_pod_identity_association" "lb_controller" {
  count = local.lb_controller_enabled ? 1 : 0

  cluster_name    = aws_eks_cluster.this[0].name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller[0].arn

  tags = local.eks_tags

  lifecycle {
    precondition {
      condition     = contains(keys(var.eks_addons), "eks-pod-identity-agent")
      error_message = "The AWS Load Balancer Controller gets its AWS permissions through EKS Pod Identity. Keep the eks-pod-identity-agent entry in eks_addons, or set enable_lb_controller = false."
    }
  }
}
