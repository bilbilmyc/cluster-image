# Traefik

The Cloud Native Application Proxy.

vlabs 的镜像安装、三个 NodePort、全局跨域和超时调整见 [Traefik 部署手册](VLABS.md)。

## Prerequisites

- Kubernetes(depends on the app requirements)
- Sealos 4.x.x
- Helm 3.x.x
- Network load balancer

## Installing the app

Run app with sealos

```shell
$ sealos run docker.io/labring/traefik:v2.10.5
```

Get app status

```shell
$ helm -n traefik ls
```

## Uninstalling the app

Uninstall with helm command

```shell
helm -n traefik uninstall traefik
```

## Configuration

Refer to traefik values.yaml for the full run-down on defaults.

Specify each parameter using the `--set key=value[,key=value]` argument to `seaos run -e HELM_OPTS=`. For example,

```shell
$ sealos run docker.io/labring/traefik:v2.10.5 \
-e NAME=my-traefik -e NAMESPACE=my-traefik -e HELM_OPTS="--set service.type=NodePort"
