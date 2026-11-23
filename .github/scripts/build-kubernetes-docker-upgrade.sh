#!/usr/bin/env bash
set -euo pipefail

version="$1"
image="$2"
output="$3"
base_image='docker.io/labring/kubernetes-docker@sha256:7ecba2b2fd9e282242b460648a3204203d0d1271a6059c6f0826400be1227f01'
runtime_commit='ac453ddb30234dbec93005e97c08a8b7b55dbba9'
lvscare_image='ghcr.io/labring/lvscare:v5.2.0'
workspace="$(mktemp -d "$RUNNER_TEMP/sealos-docker.XXXXXXXX")"
rootfs="$workspace/rootfs"
mkdir -p "$rootfs" "$output"

# 保留官方 Docker 版的运行时文件和脚本，重新生成目标版本的离线镜像库。
base_container="$(sudo buildah from --platform linux/amd64 "$base_image")"
trap 'sudo buildah rm "$base_container" >/dev/null 2>&1 || true' EXIT
base_root="$(sudo buildah mount "$base_container")"
for entry in bin cri etc images opt scripts statics; do
    sudo cp -a "$base_root/$entry" "$rootfs/"
done
sudo buildah umount "$base_container" >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$rootfs"

download() {
    curl --fail --show-error --silent --location --retry 4 --connect-timeout 15 --max-time 300 "$@"
}

download -o "$rootfs/Kubefile" \
    "https://raw.githubusercontent.com/labring-actions/runtime/$runtime_commit/docker/Kubefile"

printf '下载并校验 Kubernetes 工具 / Downloading and verifying Kubernetes tools for %s\n' "$version"
for tool in kubeadm kubelet kubectl; do
    url="https://dl.k8s.io/release/$version/bin/linux/amd64/$tool"
    download -o "$rootfs/bin/$tool" "$url"
    checksum="$(download "$url.sha256")"
    printf '%s  %s\n' "$checksum" "$rootfs/bin/$tool" | sha256sum --check --status
    chmod 0755 "$rootfs/bin/$tool"
done

# 用目标版本 kubeadm 推导控制面、etcd、DNS 及 pause 的准确标签。
"$rootfs/bin/kubeadm" config images list --kubernetes-version "$version" > "$rootfs/images/shim/DefaultImageList"
printf '%s\n' "$lvscare_image" > "$rootfs/images/shim/LvscareImageList"
pause_image="$(grep '/pause:' "$rootfs/images/shim/DefaultImageList")"

printf '构建离线集群镜像 / Building offline cluster image %s\n' "$image"
sudo sealos build \
    --platform linux/amd64 \
    --label "sealos.io.type=rootfs" \
    --label "sealos.io.version=v1beta1" \
    --label "version=$version" \
    --label "image=$lvscare_image" \
    --label "org.opencontainers.image.source=https://github.com/$GITHUB_REPOSITORY" \
    --env 'defaultVIP=10.103.97.2' \
    --env "sandboxImage=${pause_image#*/}" \
    --tag "$image" "$rootfs"

# 核对最终镜像中的二进制版本及离线仓库，防止只更新外层标签。
built_container="$(sudo buildah from --pull never "$image")"
trap 'sudo buildah rm "$built_container" "$base_container" >/dev/null 2>&1 || true' EXIT
built_root="$(sudo buildah mount "$built_container")"
test "$(sudo "$built_root/bin/kubeadm" version -o short)" = "$version"
test "$(sudo "$built_root/bin/kubelet" --version)" = "Kubernetes $version"
test "$(sudo "$built_root/bin/kubectl" version --client -o json | jq -r '.clientVersion.gitVersion')" = "$version"
sudo test -s "$built_root/cri/docker.tgz"
sudo test -s "$built_root/cri/cri-dockerd.tgz"

while IFS= read -r reference; do
    name="${reference#*/}"
    repository="${name%:*}"
    tag="${reference##*:}"
    manifest="$(sudo find "$built_root/registry" -path "*/$repository/_manifests/tags/$tag/current/link" -print -quit)"
    if [[ -z "$manifest" ]]; then
        printf '离线仓库缺少镜像 / Bundled image missing: %s\n' "$reference" >&2
        exit 1
    fi
done < <(cat "$rootfs/images/shim/DefaultImageList" "$rootfs/images/shim/LvscareImageList")

sudo buildah umount "$built_container" >/dev/null
archive="kubernetes-docker-$version-linux-amd64.tar"
sudo sealos save --format oci-archive --output "$output/$archive" "$image"
sudo chown "$(id -u):$(id -g)" "$output/$archive"
(cd "$output" && sha256sum "$archive" > "$archive.sha256")
printf '镜像和 OCI 归档已校验 / Verified cluster image and OCI archive for %s\n' "$version"
