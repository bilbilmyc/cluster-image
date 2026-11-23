#!/usr/bin/env bash
set -euo pipefail

arch="$1"
group="$2"
output="$3"
registry='registry.cn-beijing.aliyuncs.com/vlabs'
helm_version='v4.3.2'
traefik_version='v3.7.19'
traefik_chart='42.4.1'
workspace="$(mktemp -d "$RUNNER_TEMP/sealos-addons.XXXXXXXX")"
mkdir -p "$output" "$workspace/helm/opt"

download() {
    curl --fail --silent --show-error --location --retry 4 --connect-timeout 15 --max-time 300 "$@"
}

helm_archive="helm-$helm_version-linux-$arch.tar.gz"
download -o "$workspace/$helm_archive" "https://get.helm.sh/$helm_archive"
helm_checksum="$(download "https://get.helm.sh/$helm_archive.sha256sum" | awk 'NR == 1 {print $1}')"
printf '%s  %s\n' "$helm_checksum" "$workspace/$helm_archive" | sha256sum --check --status
tar -xzf "$workspace/$helm_archive" -C "$workspace/helm/opt" --strip-components=1 "linux-$arch/helm"
helm_bin="$workspace/helm/opt/helm"
test "$("$helm_bin" version --template '{{.Version}}')" = "$helm_version"

package_image() {
    local name="$1" version="$2" context="$3"
    local image="$registry/$name:$version-$arch"
    local archive="$name-$version-linux-$arch.tar"

    printf '打包配套组件 / Packaging addon %s for linux/%s\n' "$name:$version" "$arch"
    sudo sealos build --platform "linux/$arch" \
        --label "org.opencontainers.image.source=https://github.com/$GITHUB_REPOSITORY" \
        --tag "$image" "$context"
    sudo buildah inspect --type image "$image" | jq -e --arg arch "$arch" \
        '(.OCIv1.architecture // .Docker.architecture) == $arch' >/dev/null
    sudo sealos save --format oci-archive --output "$output/$archive" "$image"
    sudo chown "$(id -u):$(id -g)" "$output/$archive"
    (cd "$output" && sha256sum "$archive" > "$archive.sha256")
}

chart_images() {
    local chart="$1" name="$2" namespace="$3" values="$4" kube_version="$5" output_list="$6"

    # 用实际的 Helm 渲染结果收集容器镜像，保留固定的标签和 digest。
    "$helm_bin" template "$name" "$chart" --namespace "$namespace" \
        --kube-version "$kube_version" --values "$values" --skip-tests |
        /usr/bin/python3 -c '
import sys
import yaml

def images(obj):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key == "image" and isinstance(value, str) and value:
                yield value
            else:
                yield from images(value)
    elif isinstance(obj, list):
        for item in obj:
            yield from images(item)

print("\n".join(sorted({ref for doc in yaml.safe_load_all(sys.stdin) for ref in images(doc)})))
' > "$output_list"
    test -s "$output_list"
}

cilium_image() {
    local version="$1" kube_version="$2"
    local context="$workspace/cilium"
    local chart="$context/charts/cilium-${version#v}.tgz"
    mkdir -p "$context/charts" "$context/images/shim"
    "$helm_bin" pull 'oci://quay.io/cilium/charts/cilium' --version "${version#v}" \
        --destination "$context/charts"
    cat > "$context/values.yaml" <<'YAML'
# 保留 kube-proxy，Sealos 内置的 API Server 域名供 Cilium 启动时使用。
kubeProxyReplacement: false
k8sServiceHost: apiserver.cluster.local
k8sServicePort: 6443
# 离线仓库保存单平台镜像，使用上游发行版标签来匹配本地镜像。
image:
  useDigest: false
envoy:
  image:
    useDigest: false
operator:
  replicas: 1
  image:
    useDigest: false
YAML
    cat > "$context/Kubefile" <<'KUBEFILE'
FROM scratch
COPY . .
CMD ["bash entrypoint.sh"]
KUBEFILE
    cat > "$context/entrypoint.sh" <<'ENTRYPOINT'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname -- "$0")"
chart=(charts/cilium-*.tgz)
helm upgrade --install cilium "${chart[0]}" --namespace kube-system \
    --values values.yaml --wait --timeout 7m
ENTRYPOINT
    chart_images "$chart" cilium kube-system "$context/values.yaml" "$kube_version" \
        "$context/images/shim/DefaultImageList"
    package_image cilium "$version" "$context"
}

traefik_image() {
    local context="$workspace/traefik"
    local chart="$context/charts/traefik-$traefik_chart.tgz"
    mkdir -p "$context/charts" "$context/images/shim"
    "$helm_bin" pull 'oci://ghcr.io/traefik/helm/traefik' --version "$traefik_chart" \
        --destination "$context/charts"
    cat > "$context/values.yaml" <<'YAML'
# 沿用测试环境的单副本和两个 NodePort。
deployment:
  replicas: 1
ingressClass:
  enabled: true
  name: traefik
  isDefaultClass: false
providers:
  kubernetesIngress:
    ingressClass: traefik
  kubernetesGateway:
    enabled: false
gateway:
  enabled: false
gatewayClass:
  enabled: false
service:
  spec:
    type: NodePort
    externalTrafficPolicy: Cluster
ports:
  web:
    nodePort: 30080
  websecure:
    nodePort: 30443
YAML
    cat > "$context/Kubefile" <<'KUBEFILE'
FROM scratch
COPY . .
CMD ["bash entrypoint.sh"]
KUBEFILE
    cat > "$context/entrypoint.sh" <<'ENTRYPOINT'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname -- "$0")"
chart=(charts/traefik-*.tgz)
helm upgrade --install traefik "${chart[0]}" --namespace traefik --create-namespace \
    --values values.yaml --wait --timeout 5m
ENTRYPOINT
    chart_images "$chart" traefik traefik "$context/values.yaml" 1.37.2 \
        "$context/images/shim/DefaultImageList"
    package_image traefik "$traefik_version" "$context"
}

if [[ "$group" == preview ]]; then
    cilium_image v1.21.0-pre.4 1.37.2
else
    cp applications/helm/latest/Kubefile "$workspace/helm/"
    package_image helm "$helm_version" "$workspace/helm"
    cilium_image v1.20.5 1.36.6
    traefik_image
fi
