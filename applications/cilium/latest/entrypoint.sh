#!/bin/bash

cp opt/cilium /usr/bin/
cp opt/hubble /usr/bin/

# 由 Cilium CLI 根据集群的 kube-proxy 状态选择模式。
helm_values="k8sServiceHost=apiserver.cluster.local,k8sServicePort=6443"
if [ -n "${ExtraValues:-}" ]; then
  helm_values="$helm_values,$ExtraValues"
fi

cilium install --chart-directory charts/cilium --helm-set "$helm_values"
