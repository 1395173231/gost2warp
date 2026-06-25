`mv gost/ gost_backup`

`git clone https://github.com/1395173231/gost2warp.git gost && cd gost`
```
mkdir -p secrets
chmod 700 secrets

# gost socks 入口的账号密码（格式：username<space>password）
printf "xxx 123456\n" > secrets/gost_socks_auth
chmod 600 secrets/gost_socks_auth
```

`docker compose up -d --build`

`crontab -e`

```
chmod +x looklog.sh 
./looklog.sh 
```

```
curl -x socks5h://xxx:123456@127.0.0.1:1080 https://chatgpt.com/cdn-cgi/trace
```

## k3s 部署

本仓库已新增 `k3s/` 清单，支持在 k3s 里部署 `warp1/warp2/warp3 + gost + rotator CronJob`。

### 1) 修改 socks 认证 Secret

编辑 `k3s/gost-socks-auth.secret.yaml`，将默认值改成你的账号密码：

```yaml
stringData:
	gost_socks_auth: |
		xxx 123456
```

### 2) 部署到 k3s

```bash
kubectl apply -k k3s
```

### 3) 检查运行状态

```bash
kubectl -n gost2warp get pods
kubectl -n gost2warp get svc gost
kubectl -n gost2warp get cronjobs
```

默认会暴露 `gost` 的 NodePort：`31080`。

### 4) 验证代理连通性

将 `<node-ip>` 替换为你的 k3s 节点 IP：

```bash
curl -x socks5h://xxx:123456@<node-ip>:31080 https://chatgpt.com/cdn-cgi/trace
```

### 5) 查看轮转日志

```bash
kubectl -n gost2warp get jobs --sort-by=.metadata.creationTimestamp
kubectl -n gost2warp logs job/<warp-rotator-job-name>
kubectl -n gost2warp logs job/<warp-sync-chain-job-name>
```

### 说明

- k3s 方案不再依赖 docker.sock，而是通过 `kubectl rollout restart deployment/warpX` 进行轮换。
- `warp` Pod 需要访问 `/dev/net/tun`，清单已包含 hostPath 挂载和 `NET_ADMIN` 能力。
- 若你的集群策略限制特权容器，需要在准入策略中允许 `gost2warp` 命名空间相关工作负载。