#!/usr/bin/env bash
# Re-vendors the Gateway API CRDs for a new upstream release.
#
#   scripts/update-gateway-api-crds.sh v1.6.0
#
# Check the AWS Load Balancer Controller release notes first: each controller
# version is built for a specific Gateway API version.
set -euo pipefail

version="${1:?usage: $0 <gateway-api-version, e.g. v1.6.0>}"
chart_dir="$(cd "$(dirname "$0")/.." && pwd)/charts/gateway-api-crds"

curl -fsSL -o "$chart_dir/templates/standard-install.yaml" \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${version}/standard-install.yaml"

if grep -q '{{' "$chart_dir/templates/standard-install.yaml"; then
  echo "The manifest contains '{{', which helm would try to template. Escape it before committing." >&2
  exit 1
fi

sed -i -E "s/^version: .*/version: ${version#v}/; s/^appVersion: .*/appVersion: ${version}/" "$chart_dir/Chart.yaml"
echo "Vendored Gateway API ${version} into ${chart_dir}"
