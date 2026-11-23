#!/usr/bin/env bash
set -euo pipefail

version="$1"
image="$2"
output="$3"
arch="$4"
runtime="$5"

# 从官方稳定镜像提取与平台、运行时对应的 Sealos 引导文件。
case "$runtime/$arch" in
    docker/amd64)
        base_image='docker.io/labring/kubernetes-docker@sha256:7ecba2b2fd9e282242b460648a3204203d0d1271a6059c6f0826400be1227f01'
        cri_dockerd_checksum='eb8a965169e82da1e57339a2f0a9296fcaff3202455fd7254080cdb53f4d0522'
        ;;
    docker/arm64)
        base_image='docker.io/labring/kubernetes-docker@sha256:f86fb59d8d0cbb0e6064ea6ede4fc4897a5d9ff60c553a5fab8e88c764e9e93b'
        cri_dockerd_checksum='3c96b0ab6eaa12135caaa0e1fcf1570b8d058635c25da52d7070b23a87711ac2'
        ;;
    containerd/amd64)
        base_image='docker.io/labring/kubernetes@sha256:835e4702e614db96ab003181181e70892d8bd4faf78a3265dd3aedba6985226f'
        containerd_checksum='da656542e754c699a0f438eab925e6ffdbd6346a4428e659f83dc058f04dcffe'
        ;;
    containerd/arm64)
        base_image='docker.io/labring/kubernetes@sha256:98965a45b6ff1466df502ed78f48ccd12b03a3507f42c0d7e2c20d83cb23611c'
        containerd_checksum='37b84b9534533672528141b9d815f58621a2fe5deee2daa84317800255756689'
        ;;
    *)
        printf '未知平台或运行时 / Unknown platform or runtime: %s/%s\n' "$runtime" "$arch" >&2
        exit 1
        ;;
esac
runtime_commit='ac453ddb30234dbec93005e97c08a8b7b55dbba9'
lvscare_image='ghcr.io/labring/lvscare:v5.2.0'
workspace="$(mktemp -d "$RUNNER_TEMP/sealos-kubernetes.XXXXXXXX")"
rootfs="$workspace/rootfs"
mkdir -p "$rootfs" "$output"

# 保留官方集群镜像的运行时引导，并重新生成目标版本的离线镜像库。
base_container="$(sudo buildah from --platform "linux/$arch" "$base_image")"
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
    "https://raw.githubusercontent.com/labring-actions/runtime/$runtime_commit/$runtime/Kubefile"

if [[ "$runtime" == docker ]]; then
    # 使用支持新 CRI API 的官方 cri-dockerd 发行包。
    cri_dockerd_version='0.4.11'
    download -o "$rootfs/cri/cri-dockerd.tgz" \
        "https://github.com/Mirantis/cri-dockerd/releases/download/v$cri_dockerd_version/cri-dockerd-$cri_dockerd_version.$arch.tgz"
    printf '%s  %s\n' "$cri_dockerd_checksum" "$rootfs/cri/cri-dockerd.tgz" | sha256sum --check --status
else
    # 保留引导脚本需要的 usr/bin 路径和原有的 OCI 运行时文件。
    containerd_version='2.4.2'
    release="containerd-static-$containerd_version-linux-$arch.tar.gz"
    download -o "$workspace/$release"         "https://github.com/containerd/containerd/releases/download/v$containerd_version/$release"
    printf '%s  %s\n' "$containerd_checksum" "$workspace/$release" | sha256sum --check --status
    mkdir -p "$workspace/containerd-bundle" "$workspace/containerd-release"
    tar -xzf "$rootfs/cri/cri-containerd.tar.gz" -C "$workspace/containerd-bundle"
    tar -xzf "$workspace/$release" -C "$workspace/containerd-release"
    cp -a "$workspace/containerd-release/bin/." "$workspace/containerd-bundle/usr/bin/"
    tar -czf "$rootfs/cri/cri-containerd.tar.gz" -C "$workspace/containerd-bundle" usr/bin
    "$workspace/containerd-bundle/usr/bin/containerd" --version | grep -F "v$containerd_version"
fi

printf '下载并校验 Kubernetes 工具 / Downloading and verifying Kubernetes tools for %s\n' "$version"
for tool in kubeadm kubelet kubectl; do
    url="https://dl.k8s.io/release/$version/bin/linux/$arch/$tool"
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
    --platform "linux/$arch" \
    --label "sealos.io.type=rootfs" \
    --label "sealos.io.version=v1beta1" \
    --label "version=$version" \
    --label "image=$lvscare_image" \
    --label "org.opencontainers.image.source=https://github.com/$GITHUB_REPOSITORY" \
    --env 'defaultVIP=10.103.97.2' \
    --env "sandboxImage=${pause_image#*/}" \
    --tag "$image" "$rootfs"

# 核对最终镜像中的二进制版本及离线仓库，防止只更新外层标签。
built_container="$(sudo buildah from "$image")"
trap 'sudo buildah rm "$built_container" "$base_container" >/dev/null 2>&1 || true' EXIT
built_root="$(sudo buildah mount "$built_container")"
test "$(sudo "$built_root/bin/kubeadm" version -o short)" = "$version"
test "$(sudo "$built_root/bin/kubelet" --version)" = "Kubernetes $version"
test "$(sudo "$built_root/bin/kubectl" version --client -o json | jq -r '.clientVersion.gitVersion')" = "$version"
if [[ "$runtime" == docker ]]; then
    sudo test -s "$built_root/cri/docker.tgz"
    sudo test -s "$built_root/cri/cri-dockerd.tgz"
else
    sudo test -s "$built_root/cri/cri-containerd.tar.gz"
fi

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
archive="kubernetes-$runtime-$version-linux-$arch.tar"
sudo sealos save --format oci-archive --output "$output/$archive" "$image"
sudo chown "$(id -u):$(id -g)" "$output/$archive"
(cd "$output" && sha256sum "$archive" > "$archive.sha256")
printf '镜像和 OCI 归档已校验 / Verified cluster image and OCI archive for %s\n' "$version"
