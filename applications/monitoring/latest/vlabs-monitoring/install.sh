#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
namespace=monitoring
local_storage_class=vlabs-monitoring-local
local_data=/var/lib/vlabs/loki

log() {
    printf '%s / %s\n' "$1" "$2"
}

export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
command -v helm >/dev/null
command -v kubectl >/dev/null

kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -

loki_ephemeral="${LOKI_EPHEMERAL:-false}"
storage_class="${LOKI_STORAGE_CLASS:-}"
existing_claim="$(kubectl -n "$namespace" get pvc storage-loki-0 --ignore-not-found \
    -o jsonpath='{.metadata.name}{"|"}{.spec.storageClassName}')"
if [[ "$loki_ephemeral" == true && ( -n "$existing_claim" || -n "$storage_class" ) ]]; then
    log "Loki 已有 PVC 或指定了存储类，无法启用临时模式" "Loki ephemeral mode requires no existing PVC or explicit StorageClass"
    exit 1
fi

if [[ -n "$existing_claim" ]]; then
    existing_class="${existing_claim#*|}"
    existing_class="${existing_class:--}"
    if [[ -n "$storage_class" && "$storage_class" != "$existing_class" ]]; then
        log "Loki 已有 PVC 使用 $existing_class，请保留现有存储类" "Loki already uses StorageClass $existing_class"
        exit 1
    fi
    storage_class="$existing_class"
fi

if [[ "$loki_ephemeral" != true && -z "$storage_class" ]]; then
    # 有多个默认存储类时，采用创建时间最新的一个。
    storage_class="$(kubectl get storageclass --sort-by=.metadata.creationTimestamp \
        -o go-template='{{range .items}}{{if .metadata.annotations}}{{if or (eq (index .metadata.annotations "storageclass.kubernetes.io/is-default-class") "true") (eq (index .metadata.annotations "storageclass.beta.kubernetes.io/is-default-class") "true")}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' \
        | awk 'NF { value=$0 } END { print value }')"
fi

loki_options=()
if [[ "$loki_ephemeral" == true ]]; then
    loki_options+=(--set singleBinary.persistence.enabled=false)
    log "Loki 使用临时卷" "Loki uses an ephemeral volume"
elif [[ -z "$storage_class" ]]; then
    # 裸集群使用控制面的本地卷，现场也可通过 LOKI_STORAGE_CLASS 选择已有存储。
    hostname_full="$(hostname)"
    hostname_short="$(hostname -s)"
    storage_host="$(kubectl get nodes \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.kubernetes\.io/hostname}{"\n"}{end}' \
        | awk -v short="$hostname_short" -v full="$hostname_full" \
            '($1==short || $1==full || $2==short || $2==full) && !found { print $2; found=1 }')"
    : "${storage_host:?无法识别当前控制面的节点标签 / cannot identify the local Kubernetes node}"
    install -d -m 0750 -o 10001 -g 10001 "$local_data"
    storage_class="$local_storage_class"
    log "创建 Loki 本地持久卷" "Creating local persistent volume for Loki"
    kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${storage_class}
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: vlabs-monitoring-loki
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${storage_class}
  claimRef:
    namespace: ${namespace}
    name: storage-loki-0
  local:
    path: ${local_data}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - "${storage_host}"
EOF
elif [[ "$storage_class" != "-" ]]; then
    kubectl get storageclass "$storage_class" >/dev/null
fi

if [[ -n "$storage_class" ]]; then
    loki_options+=(--set-string "singleBinary.persistence.storageClass=$storage_class")
fi
if [[ "$storage_class" == "$local_storage_class" ]]; then
    loki_options+=(
        --set-string 'singleBinary.tolerations[0].key=node-role.kubernetes.io/control-plane'
        --set-string 'singleBinary.tolerations[0].operator=Exists'
        --set-string 'singleBinary.tolerations[0].effect=NoSchedule'
    )
fi

log "安装 Loki" "Installing Loki"
helm upgrade --install loki "$app_dir/loki-21.5.1.tgz" \
    -n "$namespace" -f "$app_dir/loki-acr-values.yaml" "${loki_options[@]}" \
    --wait --timeout 12m

log "安装 Prometheus Stack 和 Grafana" "Installing Prometheus Stack and Grafana"
helm upgrade --install monitor "$app_dir/kube-prometheus-stack-93.9.0.tgz" \
    -n "$namespace" -f "$app_dir/monitor-acr-values.yaml" --wait --timeout 12m

log "安装 Alloy" "Installing Alloy"
helm upgrade --install alloy "$app_dir/alloy-1.16.0.tgz" \
    -n "$namespace" -f "$app_dir/alloy-acr-values.yaml" --wait --timeout 12m
helm list -n "$namespace"
