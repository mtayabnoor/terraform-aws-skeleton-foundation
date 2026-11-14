# IAM policies

`aws-load-balancer-controller.json` is the unmodified upstream IAM policy of the
AWS Load Balancer Controller, taken from `docs/install/iam_policy.json` at tag
**v3.6.3** of https://github.com/kubernetes-sigs/aws-load-balancer-controller.

When you raise the controller version in your GitOps repository, replace the
file with the policy from the matching controller tag.
