# chinadns-ng (Docker)

## 用途
使用 Docker 部署 `chinadns-ng`，根据 `chnlist`/`gfwlist` 智能分流。

## 快速开始
1. 构建镜像：
   ```bash
   docker build -t chinadns-ng:latest .
   ```
2. 启动（推荐 host 网络）：
   ```bash
   docker compose up -d
   ```
3. 宿主机或路由器将上游 DNS 指向 `127.0.0.1#65353`。

## 配置
- 主配置：`config/chinadns-ng.conf`（镜像内路径：`/etc/chinadns-ng/chinadns-ng.conf`）
- 规则列表：`config/chnlist.txt`, `config/gfwlist.txt`
- 可运行 `./run.sh` 更新规则列表。

## 运行时
- 端口：TCP/UDP 65353（镜像已 `EXPOSE`，常用 `network_mode: host`）。
- 权限：默认仅添加 `NET_ADMIN`（用于 `ipset`）；如不需要 `ipset`，可移除该能力。

## 远程部署
使用脚本：
```bash
TARGET_SERVER=user@host ./build.sh
```
脚本会：构建 → 导出 → 上传 → 远端加载镜像并 `docker compose up -d`。
