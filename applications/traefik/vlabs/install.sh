#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname -- "$0")"
chart=(charts/traefik-*.tgz)
install_dir=/opt/vlabs/traefik
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# 在修改集群前校验环境变量。升级时读取现有列表，以保留现场的参数和中间件。
values=(--values defaults.yaml)
release="$(helm list --namespace traefik --filter '^traefik$' --short)"
if [[ "$release" == traefik ]]; then
    helm get values traefik --namespace traefik --output json | ./env-values > "$work/overrides.json"
    values=(--reset-then-reuse-values)
else
    printf '{}\n' | ./env-values > "$work/overrides.json"
fi

# 首次安装可先用包内同版本 CRD 创建中间件。已存在的资源沿用现场配置。
create_if_missing() {
    local resource="$1" present
    shift
    present="$(kubectl -n traefik get "$resource" --ignore-not-found -o name)"
    if [[ -z "$present" ]]; then
        kubectl "$@" || kubectl -n traefik get "$resource" -o name
    fi
}

if [[ "${TRAEFIK_GLOBAL_CORS:-}" == true ]]; then
    tar -xOf "${chart[0]}" traefik/crds/traefik.io_middlewares.yaml > "$work/middleware-crd.yaml"
    create_if_missing crd/middlewares.traefik.io create -f "$work/middleware-crd.yaml"
    kubectl wait --for=condition=Established crd/middlewares.traefik.io --timeout=1m
    create_if_missing namespace/traefik create namespace traefik
    create_if_missing middleware.traefik.io/global-cors create -f examples/global-cors.yaml
fi

# 将同版本 Chart 和配置示例留在控制节点，方便离线修改 Helm release。
install -d "$install_dir/charts" "$install_dir/examples"
install -m 0644 "${chart[0]}" "$install_dir/charts/"
install -m 0644 examples/*.yaml "$install_dir/examples/"
printf '部署 Traefik / Deploying Traefik (NodePort 32010, 32011, 32012)\n'
helm upgrade --install traefik "$install_dir/${chart[0]}" --namespace traefik --create-namespace \
    "${values[@]}" --values ports.yaml --values "$work/overrides.json" --wait --timeout 5m
