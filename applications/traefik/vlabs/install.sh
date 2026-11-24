#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname -- "$0")"
chart=(charts/traefik-*.tgz)
install_dir=/opt/vlabs/traefik
# 将同版本 Chart 和配置示例留在控制节点，方便离线修改 Helm release。
install -d "$install_dir/charts" "$install_dir/examples"
install -m 0644 "${chart[0]}" "$install_dir/charts/"
install -m 0644 examples/*.yaml "$install_dir/examples/"

values=(--values defaults.yaml)
if helm status traefik --namespace traefik >/dev/null 2>&1; then
    # 升级时只覆盖本次指定的 Service 端口，沿用用户的监控、路由和资源配置。
    values=(--reset-then-reuse-values)
fi
printf '部署 Traefik / Deploying Traefik (NodePort 32010, 32011, 32012)\n'
helm upgrade --install traefik "$install_dir/${chart[0]}" --namespace traefik --create-namespace \
    "${values[@]}" --values ports.yaml --wait --timeout 5m
