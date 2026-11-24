# vlabs Traefik 的安装与部署后配置

镜像内含 Traefik v3.7.19、Helm Chart 42.4.1 和对应平台的离线工作负载镜像。使用集群控制节点上的 Sealos 和 Helm（升级已有 release 需支持 `--reset-then-reuse-values`）。

```bash
sealos run registry.cn-beijing.aliyuncs.com/vlabs/traefik:v3.7.19-r3
kubectl -n traefik get svc traefik
```

| 入口 | Service 端口 | NodePort | 用途 |
| --- | ---: | ---: | --- |
| traefik | 9000/TCP | 32010 | 管理入口，健康检查路径为 `/ping`。Dashboard 路由默认关闭 |
| web | 80/TCP | 32011 | HTTP |
| websecure | 443/TCP | 32012 | HTTPS |

## 用环境变量交付

在 Sealos 控制节点运行以下命令。新部署可直接运行，已有同标签时 `--force` 会重新执行这个应用的安装脚本。

```bash
sealos run --force registry.cn-beijing.aliyuncs.com/vlabs/traefik:v3.7.19-r3 \
  -e TRAEFIK_REQUEST_TIMEOUT=7200s
```

`TRAEFIK_REQUEST_TIMEOUT` 同时设置 HTTP 和 HTTPS 两个入口的 `readTimeout`、`writeTimeout`，以及默认后端的 `responseHeaderTimeout`。建连和空闲连接仍使用现场设置。时长支持 `7200s`、`2h`、`0s` 等非负值，纯数字按秒处理。单项环境变量优先于本次命令的快捷参数。

| 环境变量 | 控制项 |
| --- | --- |
| `TRAEFIK_READ_TIMEOUT` | 客户端完整请求的读取时限，含上传 |
| `TRAEFIK_WRITE_TIMEOUT` | 客户端响应写完的时限，含流式输出 |
| `TRAEFIK_IDLE_TIMEOUT` | 客户端保活连接等待下一次请求 |
| `TRAEFIK_DIAL_TIMEOUT` | 与后端建连 |
| `TRAEFIK_RESPONSE_HEADER_TIMEOUT` | 请求体发完后等待后端响应头 |
| `TRAEFIK_IDLE_CONN_TIMEOUT` | 后端连接池空闲回收 |
| `TRAEFIK_GLOBAL_CORS` | `true` 给两个入口挂载全局跨域中间件，`false` 解除挂载 |

下面的示例给长请求两小时、上传两分钟，并开启全局跨域。

```bash
sealos run --force registry.cn-beijing.aliyuncs.com/vlabs/traefik:v3.7.19-r3 \
  -e TRAEFIK_REQUEST_TIMEOUT=7200s \
  -e TRAEFIK_READ_TIMEOUT=120s \
  -e TRAEFIK_GLOBAL_CORS=true
```

省略的设置在新装时采用 Chart 默认值，在升级时沿用现有 Helm 配置。超时和入口中间件挂载属于启动配置，更新后由 Helm 滚动升级，`helm get values traefik -n traefik` 可查看结果。显式使用自定义 `ServersTransport` 的业务仍在自己的 transport 中配置后端超时。

首次开启全局跨域时，安装脚本先创建 `traefik/global-cors`，再将它挂到已有入口中间件链之前。如果该 Middleware 已存在，则沿用现场定义。设为 `false` 时保留 Middleware 对象，业务路由仍可单独引用。修改允许来源、请求头及凭据时使用下方的 Middleware 配置。

## 使用本地配置文件

镜像升级 `traefik/traefik` 时保留已有 Helm values，覆盖上述 Service 端口并应用显式传入的环境变量。Chart 安装到 `/opt/vlabs/traefik/charts`。示例安装到 `/opt/vlabs/traefik/examples`。可将要维护的配置复制到自己的目录。

```bash
install -d -m 0700 /root/traefik-config
cd /root/traefik-config
cp -n /opt/vlabs/traefik/examples/*.yaml .
chart=/opt/vlabs/traefik/charts/traefik-42.4.1.tgz
helm get values traefik -n traefik -o yaml
helm history traefik -n traefik
```

记下改动前的 release 修订号。Helm 完整替换列表字段。若已有 `ports.web.http.middlewares`、`ports.websecure.http.middlewares` 或 `additionalArguments`，先将现有条目合并进对应文件。已有同名启动参数时直接更新其值。

## 全局允许跨域

`global-cors.yaml` 允许任意来源，显式允许 `Authorization`，凭据开关默认关闭。浏览器需要跨域携带 Cookie 时，在 `accessControlAllowOriginList` 填写允许的完整来源（协议、域名及非默认端口），将 `accessControlAllowCredentials` 设为 `true`，并显式列出允许的请求头。

先创建 Middleware，再在 HTTP 和 HTTPS 入口引用它。这样经这两个入口匹配到的 Ingress 和 IngressRoute 都会应用该策略。若已启用 `providers.kubernetesCRD.safeNaming: true`，将示例内的引用名改为 `traefik_global-cors@kubernetescrd`。

```bash
kubectl apply -f global-cors.yaml
helm upgrade traefik "$chart" -n traefik --reuse-values -f cors-entrypoints.yaml --wait --timeout 5m
```

以后修改来源、请求头或方法，只需再次执行 `kubectl apply -f global-cors.yaml`。预检用实际业务路由的域名和路径，例如在 35 上执行，请替换域名和路径。

```bash
curl -i -X OPTIONS http://12.2.40.35:32011/api \
  -H 'Host: api.example.com' -H 'Origin: https://app.example.com' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: authorization,content-type'
```

预检响应应带 `Access-Control-Allow-Origin` 和允许的方法及请求头。撤销策略时先从两个入口移除该引用并等待 Helm 滚动升级完成，再删除 Middleware。

## 调整超时

编辑 `timeouts.yaml`，按业务时长修改以下参数。文件中的数值是可选示例。两条入口共用同一组示例值。

| 方向 | 参数 | Traefik v3.7 默认 | 示例 | 生效阶段 |
| --- | --- | ---: | ---: | --- |
| 客户端 → Traefik | readTimeout | 60s | 120s | 读取完整请求，含上传的请求体 |
| Traefik → 客户端 | writeTimeout | 0s | 600s | 从读完请求头到写完响应，覆盖长响应和流式输出 |
| 客户端连接 | idleTimeout | 180s | 180s | HTTP 保活连接空闲等待下一次请求 |
| Traefik → 后端 | dialTimeout | 30s | 10s | 建立后端连接 |
| Traefik → 后端 | responseHeaderTimeout | 0s | 300s | 请求体发完后等待后端响应头 |
| 后端连接池 | idleConnTimeout | 90s | 90s | 回收连接池中空闲的保活连接 |

`0s` 表示关闭相应时限。长时间 SSE 请求可按需将入口 `writeTimeout` 设为 `0s`。Chart 42.4.1 用 `ports.<入口>.transport.respondingTimeouts` 配置入口超时，v3.7.19 支持通过 `additionalArguments` 配置表中三项默认后端超时。显式绑定自定义 `ServersTransport` 的服务应修改自己的 transport。

```bash
helm upgrade traefik "$chart" -n traefik --reuse-values -f timeouts.yaml --wait --timeout 5m
kubectl -n traefik get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].args}'
```

第一次同时启用两项时，先创建 Middleware，再在同一条 Helm 命令中传入 `-f cors-entrypoints.yaml -f timeouts.yaml`，即可只滚动升级一次。需要恢复时，运行 `helm rollback traefik <改动前修订号> -n traefik --wait`。如果回退后已移除两个入口的 CORS 引用，可再执行 `kubectl delete -f global-cors.yaml`。

字段定义见 [Traefik v3.7 入口配置](https://doc.traefik.io/traefik/v3.7/reference/install-configuration/entrypoints/)、[Headers 中间件](https://doc.traefik.io/traefik/v3.7/reference/routing-configuration/http/middlewares/headers/) 和 [后端传输](https://doc.traefik.io/traefik/v3.7/reference/routing-configuration/http/load-balancing/serverstransport/)。
