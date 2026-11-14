# Example GitOps repository

Copy this folder into its own Git repository and point the module at it with
`argocd_root_app`. Argo CD then installs everything in `platform/`, in this order:

| Wave | File | What |
|------|------|------|
| 0 | `platform/gateway-api-crds.yaml` | Gateway API CRDs, straight from the upstream repository |
| 1 | `platform/aws-load-balancer-controller.yaml` | AWS Load Balancer Controller helm chart |
| 2 | `platform/gateway.yaml` | GatewayClass and the shared Gateway (creates one ALB) |
| 3 | `platform/apps.yaml` | Everything under `apps/` |

Before the first sync, replace every `CHANGE_ME`:

- `platform/aws-load-balancer-controller.yaml`: `clusterName`, `region` and
  `vpcId` from `terraform output lb_controller_helm_values`
- `platform/apps.yaml`: the URL of this repository

To deploy an application, add a folder under `apps/` with its manifests and an
`HTTPRoute` that attaches to the shared Gateway, like `apps/demo`.

To upgrade something, change its version in Git and merge. Keep the controller
version, the Gateway API version and the module's IAM policy in step (see the
module README).
