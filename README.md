# terraform-aws-skeleton-foundation

Terraform module for an AWS foundation: a VPC and, optionally, an EKS cluster
with Argo CD, prepared for the Kubernetes **Gateway API** (no Ingress).

The split follows the usual production setup:

- **Terraform (this module)** creates what lives in AWS: VPC, EKS, nodes, IAM.
  Its last step installs Argo CD and points it at a Git repository.
- **Argo CD** installs what lives inside the cluster from that repository: the
  Gateway API CRDs, the AWS Load Balancer Controller, the Gateway and your apps.
  `examples/gitops` is a ready-to-copy starting point.

Everything is driven by variables, so the same module serves dev, staging and
prod. EKS is off by default (`enable_eks = false`).

## Files

| File | What it creates |
|------|-----------------|
| `vpc.tf` | VPC, public/private subnets, internet gateway, NAT gateway(s), route tables |
| `eks.tf` | Everything EKS: control plane, IAM roles, add-ons, managed node groups, cluster access |
| `gateway.tf` | IAM role and Pod Identity for the AWS Load Balancer Controller |
| `argocd.tf` | Argo CD and the optional root Application |
| `main.tf` | Shared locals and data sources |
| `variables.tf` / `outputs.tf` | Inputs and outputs |
| `versions.tf` | Terraform and provider version constraints |
| `policies/` | Upstream IAM policy of the load balancer controller |
| `examples/gitops/` | Example Git repository content for Argo CD |

## Usage

### 1. Providers in your root module

The module needs the `aws` and `helm` providers. Declare and configure both in
the root module that calls it:

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 6.9" }
    helm = { source = "hashicorp/helm", version = "~> 3.0" }
  }
}

provider "aws" {
  region = "eu-central-1"
}

# Used to install Argo CD into the cluster. The token is fetched with the AWS
# CLI at run time, so a saved plan can still be applied later. Stays unused
# while enable_eks = false.
provider "helm" {
  kubernetes = {
    host                   = module.foundation.eks_cluster_endpoint
    cluster_ca_certificate = try(base64decode(module.foundation.eks_cluster_certificate_authority_data), null)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--region", "eu-central-1", "--cluster-name", coalesce(module.foundation.eks_cluster_name, "eks-disabled")]
    }
  }
}
```

The machine that runs Terraform needs the AWS CLI (preinstalled on
GitHub-hosted runners) and must be able to reach the Kubernetes API endpoint,
which is why `eks_endpoint_public_access` defaults to `true`.

### 2. Call the module

VPC only (the default):

```hcl
module "foundation" {
  source = "git::https://github.com/mtayabnoor/terraform-aws-skeleton-foundation.git?ref=v1.1.0"

  name       = "aws-foundation-dev"
  cidr_block = "10.0.0.0/16"
  azs        = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
}
```

VPC, EKS and Argo CD:

```hcl
module "foundation" {
  source = "git::https://github.com/mtayabnoor/terraform-aws-skeleton-foundation.git?ref=v1.1.0"

  name       = "aws-foundation-dev"
  cidr_block = "10.0.0.0/16"
  azs        = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]

  enable_nat_gateway = true # required: the nodes run in the private subnets
  single_nat_gateway = true

  enable_eks          = true
  eks_cluster_version = "1.36"

  eks_node_groups = {
    default = { instance_types = ["t3.medium"], min_size = 1, max_size = 3, desired_size = 2 }
  }

  # Your own IAM user / role, to use kubectl. The identity that creates the
  # cluster is admin automatically and must not be listed here.
  eks_access_entries = {
    me = { principal_arn = "arn:aws:iam::123456789012:user/me" }
  }

  # Git repository Argo CD installs the cluster content from (see step 3).
  # Leave it out to get Argo CD without any Application.
  argocd_root_app = {
    repo_url = "https://github.com/<you>/<gitops-repo>.git"
    path     = "platform"
  }
}
```

### 3. GitOps repository (Gateway API)

1. Create a Git repository and copy the content of `examples/gitops` into it.
2. Fill in the `CHANGE_ME` values (see `examples/gitops/README.md`). The cluster
   specific ones come from `terraform output lb_controller_helm_values`.
3. Set `argocd_root_app.repo_url` to that repository and apply.

Argo CD then installs, in order: the Gateway API CRDs, the AWS Load Balancer
Controller, a `GatewayClass` named `aws-alb` with one shared `Gateway` (this
creates one Application Load Balancer), and everything under `apps/`.

For a **private** repository, also pass a read-only token. With GitHub, create
a fine-grained personal access token limited to that repository with read-only
"Contents" permission:

```hcl
variable "gitops_repo_token" {
  type      = string
  sensitive = true
}

module "foundation" {
  # ...
  argocd_root_app   = { repo_url = "https://github.com/<you>/<gitops-repo>.git" }
  argocd_repo_token = var.gitops_repo_token
}
```

Supply the value outside Git, for example as the environment variable
`TF_VAR_gitops_repo_token` (a secret in CI). It is hidden in plan output but
stored in the Terraform state, so keep the state bucket private. When the token
expires, replace the value and apply again.

Applications attach to the shared Gateway with an `HTTPRoute`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-app
spec:
  parentRefs:
    - name: shared
      namespace: gateway-system
  rules:
    - backendRefs:
        - name: my-app # a normal ClusterIP Service
          port: 80
```

### 4. Connect

```sh
aws eks update-kubeconfig --region eu-central-1 --name aws-foundation-dev-eks
kubectl get applications -n argocd
kubectl get gateway -n gateway-system shared # shows the load balancer address
```

The exact kubeconfig command is also in the `eks_update_kubeconfig_command` output.

Argo CD UI (nothing is exposed to the internet by default):

```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:443
# open https://localhost:8080 and log in as admin
```

### 5. Dev and prod

Use the same module call and change only the values, for example through
variables and one `terraform.tfvars` per environment:

| Input | dev | prod |
|-------|-----|------|
| `cidr_block` | `10.0.0.0/16` | `10.1.0.0/16` |
| `single_nat_gateway` | `true` (one shared NAT) | `false` (one NAT per AZ) |
| `eks_node_groups` | 2 x `t3.medium` | 3+ x `m6i.large` |
| `eks_deletion_protection` | `false` | `true` |
| `eks_cluster_log_retention_days` | `7` | `90` |
| `argocd_root_app.path` or `target_revision` | dev folder / branch | prod folder / branch |

## Main inputs

All inputs with their descriptions and defaults are in `variables.tf`.

| Input | Default | Purpose |
|-------|---------|---------|
| `name`, `cidr_block`, `azs` | required | Name prefix, VPC CIDR, availability zones |
| `enable_nat_gateway` / `single_nat_gateway` | `true` / `true` | NAT for the private subnets |
| `private_subnet_cidrs` / `public_subnet_cidrs` | generated | Explicit subnet CIDRs instead of the generated /24s |
| `enable_eks` | `false` | Create the EKS cluster |
| `eks_cluster_name` | `<name>-eks` | Cluster name |
| `eks_cluster_version` | `1.36` | Kubernetes version |
| `eks_node_groups` | one group, 2 x `t3.medium` | Managed node groups |
| `eks_addons` | vpc-cni, kube-proxy, coredns, eks-pod-identity-agent | EKS add-ons and optional version pins |
| `eks_access_entries` | `{}` | IAM users / roles with cluster access |
| `eks_endpoint_public_access_cidrs` | `["0.0.0.0/0"]` | Who can reach the Kubernetes API endpoint |
| `enable_lb_controller` | `true` | IAM role and Pod Identity for the AWS Load Balancer Controller |
| `enable_argocd` | `true` | Install Argo CD |
| `argocd_chart_version` | `10.18.0` | Version of the `argo-cd` helm chart |
| `argocd_values` | `{}` | Extra helm values for Argo CD |
| `argocd_root_app` | not created | Git repository Argo CD syncs the cluster from |
| `argocd_repo_token` | `null` | Read-only token for a private `argocd_root_app` repository |

## Releases

Every merge to `main` is tagged automatically by `.github/workflows/tag-on-merge.yml`:

- default: patch bump (`v1.1.0` -> `v1.1.1`)
- pull request labelled `minor`: `v1.1.0` -> `v1.2.0`
- pull request labelled `major`: `v1.1.0` -> `v2.0.0`

For a direct push, put `#minor` or `#major` in the commit message. Use `major`
whenever callers have to change their code, for example a removed input.

## Upgrading from v1.0.0

- The module now requires AWS provider >= 6.9 and the helm provider. Update the
  version constraints in your root module, add the `provider "helm"` block, run
  `terraform init -upgrade` and commit `.terraform.lock.hcl`.
- With `enable_eks` left at `false` an existing VPC is not touched: the subnet
  layout and all VPC resources are unchanged.

## Versions that belong together

| Component | Version | Where |
|-----------|---------|-------|
| AWS Load Balancer Controller chart | 3.6.3 | GitOps repo, `platform/aws-load-balancer-controller.yaml` |
| Controller IAM policy | v3.6.3 | this module, `policies/aws-load-balancer-controller.json` |
| Gateway API CRDs | v1.6.0 | GitOps repo, `platform/gateway-api-crds.yaml` |

Each controller release is built for one Gateway API version, so read its
release notes before raising any of the three.

## Things to know

- **Costs.** With EKS enabled you pay for the control plane, the NAT
  gateway(s), the nodes and one ALB per Gateway.
- **Destroy.** Delete the Gateways first (remove `platform/gateway.yaml` from
  Git and let Argo CD sync) and check the load balancer is gone, then run
  `terraform destroy`. A load balancer that is left behind blocks the VPC deletion.
- **Cluster admin.** The identity that creates the cluster is cluster admin.
  Give people access with `eks_access_entries`; do not list the creator there.
- **Kubernetes upgrades.** Raise `eks_cluster_version` one minor version at a
  time. Node groups follow the control plane in the same apply.
- **Existing VPCs.** The default subnet layout is unchanged. Enabling EKS only
  adds the `kubernetes.io/role/elb` / `internal-elb` tags to the subnets.
