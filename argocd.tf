# ------------------------------------------------------------------------------
# Argo CD (GitOps)
#
# Terraform installs Argo CD and, optionally, one "root" Application that points
# at a Git repository. From there Argo CD installs everything that lives inside
# the cluster. The helm provider is configured by the calling root module.
# ------------------------------------------------------------------------------
locals {
  argocd_values = {
    configs = {
      cm = {
        # Lets Argo CD wait for a child Application to become healthy before it
        # continues with the next sync wave. Needed for the ordering in
        # examples/gitops: CRDs -> controller -> Gateway.
        "resource.customizations.health.argoproj.io_Application" = <<-EOT
          hs = {}
          hs.status = "Progressing"
          hs.message = ""
          if obj.status ~= nil then
            if obj.status.health ~= nil then
              hs.status = obj.status.health.status
              if obj.status.health.message ~= nil then
                hs.message = obj.status.health.message
              end
            end
          end
          return hs
        EOT
      }
    }
  }
}

resource "helm_release" "argocd" {
  count = local.argocd_enabled ? 1 : 0

  name             = "argocd"
  namespace        = var.argocd_namespace
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version

  max_history = 3
  timeout     = 900

  values = [
    yamlencode(local.argocd_values),
    yamlencode(var.argocd_values),
  ]

  depends_on = [
    # Argo CD pods need nodes and DNS.
    aws_eks_node_group.this,
    aws_eks_addon.this,
    aws_eks_access_entry.this,
    aws_eks_access_policy_association.this,
    # On destroy, keep the load balancer controller's permissions until Argo CD
    # (and the applications it manages) are gone.
    aws_eks_pod_identity_association.lb_controller,
    aws_iam_role_policy_attachment.lb_controller,
  ]
}

# The root Application ("app of apps"): Argo CD applies every manifest found in
# argocd_root_app.path of the repository and keeps the cluster in sync with it.
resource "helm_release" "argocd_root_app" {
  count = local.argocd_enabled && var.argocd_root_app != null ? 1 : 0

  name       = "argocd-root-app"
  namespace  = var.argocd_namespace
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version

  max_history = 3

  values = [
    yamlencode({
      applications = {
        root = {
          namespace = var.argocd_namespace
          project   = "default"
          # Deleting the root Application also deletes what it installed.
          finalizers = ["resources-finalizer.argocd.argoproj.io"]

          source = {
            repoURL        = var.argocd_root_app.repo_url
            targetRevision = var.argocd_root_app.target_revision
            path           = var.argocd_root_app.path
          }

          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = var.argocd_namespace
          }

          syncPolicy = {
            automated = { prune = true, selfHeal = true }
            retry = {
              limit   = 10
              backoff = { duration = "30s", factor = 2, maxDuration = "5m" }
            }
          }
        }
      }
    }),
  ]

  depends_on = [helm_release.argocd]
}
