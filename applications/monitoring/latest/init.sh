#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd -- "$(dirname -- "$0")" && pwd)/vlabs-monitoring"
cache_dir="$(mktemp -d)"
trap 'rm -rf -- "$cache_dir"' EXIT
repo_args=(--repository-config "$cache_dir/repositories.yaml" --repository-cache "$cache_dir/index")

# 固定 Chart 版本和摘要，交付镜像内的 Chart 与验收包一致。
helm pull oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack --version 93.9.0 "${repo_args[@]}" --destination "$app_dir"
helm pull loki --repo https://grafana-community.github.io/helm-charts --version 21.5.1 "${repo_args[@]}" --destination "$app_dir"
helm pull alloy --repo https://grafana.github.io/helm-charts --version 1.16.0 "${repo_args[@]}" --destination "$app_dir"

cd "$app_dir"
sha256sum --check <<'CHECKSUMS'
b45d041d3f97c645c13dabc5d54af4cb1409644317b81eb2490be20cb2d6e718  kube-prometheus-stack-93.9.0.tgz
fd7172d46feb75c7477b8599d08a94e1befe0ba4a6a27b9ccea0f5bb4f88a84d  loki-21.5.1.tgz
efb95c875245af3c73a93b50331dfcece7cd573d5f788d934748a741c9c1747a  alloy-1.16.0.tgz
CHECKSUMS
