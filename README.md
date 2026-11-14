# terraform-aws-skeleton-foundation

Terraform module for an AWS foundation: a VPC and, optionally, an EKS cluster
that exposes applications through the Kubernetes **Gateway API** (no Ingress).

Everything is driven by variables, so the same module serves dev, staging and
prod. EKS is off by default (`enable_eks = false`).

## Files

| File | What it creates |
|------|-----------------|
| `vpc.tf` | VPC, public/private subnets, internet gateway, NAT gateway(s), route tables |
| `eks.tf` | Everything EKS: control plane, IAM roles, add-ons, managed node groups, cluster access |
| `gateway.tf` | Gateway API CRDs, AWS Load Balancer Controller, GatewayClass, optional shared Gateway |
| `main.tf` | Shared locals and data sources |
| `variables.tf` / `outputs.tf` | Inputs and outputs |
| `versions.tf` | Terraform and provider version constraints |
| `charts/`, `policies/` | Vendored Gateway API CRDs, helper chart, controller IAM policy |

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

# Used to install the Gateway API components into the cluster. The token is
# fetched with the AWS CLI at run time, so a saved plan can still be applied
# later. Stays unused while enable_eks = false.
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

VPC, EKS and Gateway API:

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

  lb_controller_replicas = 1
  eks_gateway            = { create = true } # one shared internet-facing ALB
}
```

### 3. Dev and prod

Use the same module call and change only the values, for example through
variables and one `terraform.tfvars` per environment:

| Input | dev | prod |
|-------|-----|------|
| `cidr_block` | `10.0.0.0/16` | `10.1.0.0/16` |
| `single_nat_gateway` | `true` (one shared NAT) | `false` (one NAT per AZ) |
| `eks_node_groups` | 2 x `t3.medium` | 3+ x `m6i.large` |
| `eks_deletion_protection` | `false` | `true` |
| `eks_cluster_log_retention_days` | `7` | `90` |
| `lb_controller_replicas` | `1` | `2` |
| `eks_gateway.certificate_arn` | optional | ACM certificate, adds HTTPS:443 |

### 4. Connect

```sh
aws eks update-kubeconfig --region eu-central-1 --name aws-foundation-dev-eks
kubectl get gatewayclass
kubectl get gateway -A
```

The exact command is also in the `eks_update_kubeconfig_command` output.

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
| `enable_gateway_api` | `true` | Gateway API CRDs, load balancer controller, GatewayClass |
| `gateway_class_nlb_enabled` | `false` | Extra GatewayClass for NLBs (TCP/UDP/TLS routes) |
| `eks_gateway` | not created | Shared Gateway: scheme, certificate, namespace |

## Upgrading from v1.0.0

- The module now requires AWS provider >= 6.9 and the helm provider. Update the
  version constraints in your root module, add the `provider "helm"` block, run
  `terraform init -upgrade` and commit `.terraform.lock.hcl`.
- With `enable_eks` left at `false` an existing VPC is not touched: the subnet
  layout and all VPC resources are unchanged.

## How the Gateway API part works

1. The standard-channel Gateway API CRDs are installed from the vendored chart
   in `charts/gateway-api-crds`.
2. The AWS Load Balancer Controller is installed with helm and gets its AWS
   permissions through EKS Pod Identity.
3. A `GatewayClass` named `aws-alb` is created (plus `aws-nlb` when
   `gateway_class_nlb_enabled = true`).
4. With `eks_gateway.create = true` a shared `Gateway` is created, which makes
   the controller provision one Application Load Balancer.

Applications then attach to the Gateway with an `HTTPRoute`:

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

The load balancer address is in `kubectl get gateway -n gateway-system shared`.

## Versions that belong together

| Component | Pinned to | Where |
|-----------|-----------|-------|
| AWS Load Balancer Controller chart | 3.6.3 | `lb_controller_chart_version` |
| Controller IAM policy | v3.6.3 | `policies/aws-load-balancer-controller.json` |
| Gateway API CRDs | v1.6.0 | `charts/gateway-api-crds` (`scripts/update-gateway-api-crds.sh`) |

Each controller release is built for one Gateway API version, so read its
release notes before raising any of the three. Helm only installs the
controller's own CRDs on the first install; after a chart upgrade apply them
once by hand:

```sh
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"
```

## Things to know

- **Costs.** With EKS enabled you pay for the control plane, the NAT
  gateway(s), the nodes and, with `eks_gateway.create = true`, one ALB.
- **Destroy.** Delete the Gateways and routes you created yourself (outside this
  module) before `terraform destroy` or before turning `enable_gateway_api` off.
  Otherwise their load balancers stay behind in AWS and block the VPC deletion.
- **Cluster admin.** The identity that creates the cluster is cluster admin.
  Give people access with `eks_access_entries`; do not list the creator there.
- **Kubernetes upgrades.** Raise `eks_cluster_version` one minor version at a
  time. Node groups follow the control plane in the same apply.
- **Existing VPCs.** The default subnet layout is unchanged. Enabling EKS only
  adds the `kubernetes.io/role/elb` / `internal-elb` tags to the subnets.
