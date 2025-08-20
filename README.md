## chinadns-ng + v2ray-tproxy 智能分流（IstoreOS/OpenWrt）

### 目标

- 国内域名解析出的 IP 直连（不走代理）
- 国外域名解析出的 IP 走 v2ray 透明代理（TPROXY 端口 12345）
- 通过 chinadns-ng 提供 DNS 分流与 ipset 标记
- 通过 v2ray-tproxy 提供透明代理与策略路由
- ipset/iptables 规则可持久化与开机恢复

### 架构（数据路径）

```
终端 → chinadns-ng（DNS）→
├─ 命中国内域名 → IP ∈ chnip/chnip6 → iptables RETURN → 直连
└─ 命中国外域名 → IP ∈ gfwip/gfwip6 → fwmark 0x1 → v2ray TPROXY:12345
```

---

## 1. 目录与文件概览

- Docker 运行必需：

  - `chinadns-ng`（二进制，可执行）
  - `config/chinadns-ng.conf`, `config/chnlist.txt`, `config/gfwlist.txt`
  - `Dockerfile`
  - `docker-compose.yml`
  - `.dockerignore`（已忽略宿主机脚本等非镜像必需文件）

- 宿主机脚本（IstoreOS/OpenWrt 上执行，不会进入镜像）：
  - `install-ipset.sh`：安装 ipset 持久化系统（目录与 init 脚本）
  - `ipset-persist.sh`：创建/保存/恢复 ipset 集合与配套 iptables 规则
  - `ipset-restore.init`：OpenWrt init 脚本（开机自动恢复）
  - `ipset-restore.service`：systemd 版本（如非 OpenWrt 环境）
  - `build.sh`：在开发机构建镜像并推送到远端 IstoreOS 后启动
  - `update-lists.sh`：更新 `chnlist.txt`/`gfwlist.txt`

---

## 2. 先决条件

- 目标系统：IstoreOS/OpenWrt（root 权限）
- 已安装：Docker（含 docker-compose/docker compose）、iptables、ipset
- v2ray 程序已独立部署并监听 TPROXY 端口 12345（或与你的透明代理一致）

---

## 3. 构建与部署方式

### 方式 A：在开发机构建并远程部署（推荐）

1. 在开发机执行（替换 IP）：

```bash
cd chinadns-ng
export TARGET_SERVER="root@<IstoreOS-IP>"
export TARGET_PATH="/overlay/upper/opt/docker/tmp"   # 默认即可
# 可选：export TAG="latest"
./build.sh
```

- 功能：
  - 本地 `docker build` → `docker save` 出 tar
  - 将 tar 与 `docker-compose.yml` 上传到远端 `${TARGET_PATH}/chinadns-ng`
  - 在远端加载镜像并 `docker compose up -d` 启动

2. SSH 到 IstoreOS，继续执行“运行与验证”（见第 5 节）。

### 方式 B：在 IstoreOS 上直接 git + compose 启动

1. 在 IstoreOS 执行：

```bash
cd /home
# 建议从你的私有仓库拉取，如有
# git clone https://your.repo/chinadns-ng.git
# 这里假设已经把项目放到 /home/chinadns-ng
cd /home/chinadns-ng

# 首次启动（构建在本机进行，镜像较大时速度取决于设备性能）
docker compose up -d
```

---

## 4. 脚本与文件使用说明

### 4.1 Dockerfile 与 .dockerignore

- Dockerfile 仅复制运行必需文件（可执行与配置），镜像最小化。
- `.dockerignore` 已忽略所有宿主机用的脚本与文档，避免进入镜像。

### 4.2 docker-compose.yml

- 使用 host 网络；添加 `NET_ADMIN` 能力以支持容器内可选 ipset 功能。
- 映射持久化目录：`/etc/chinadns-ng/ipset`（用于保存/恢复 ipset 状态文件）。
- 默认入口：`chinadns-ng -C /etc/chinadns-ng/chinadns-ng.conf`。

### 4.3 build.sh（开发机执行）

- 用途：一键构建镜像 → 远端部署（IstoreOS）。
- 环境变量：
  - `TARGET_SERVER`：`root@<IstoreOS-IP>`（必填）
  - `TARGET_PATH`：默认 `/overlay/upper/opt/docker/tmp`
  - `TAG`：默认 `latest`
- 步骤：构建 → 保存 → 上传 → 远端加载 → compose 启动。

### 4.4 install-ipset.sh（IstoreOS 上执行）

- 用途：安装 ipset 持久化系统。
- 主要动作：
  - 安装 `ipset-persist.sh` 至 `/etc/chinadns-ng/ipset/`
  - 安装 `ipset-restore.init` 至 `/etc/init.d/ipset-restore`
  - 创建持久化目录 `/etc/chinadns-ng/ipset/`
- 用法：

```bash
cd /home/chinadns-ng
chmod +x *.sh *.init
./install-ipset.sh
# 如需开机自启（OpenWrt）
/etc/init.d/ipset-restore enable
```

### 4.5 ipset-persist.sh（IstoreOS 上执行）

- 用途：创建/保存/恢复 ipset 集合与配套的 iptables 规则。
- 关键集合名（需与 `chinadns-ng.conf` 保持一致）：
  - 国内：`chnip`/`chnip6`，路由表：`chnroute`/`chnroute6`
  - 国外：`gfwip`/`gfwip6`
- 子命令：

```bash
/etc/chinadns-ng/ipset/ipset-persist.sh create   # 只创建集合/规则（不保存）
/etc/chinadns-ng/ipset/ipset-persist.sh save     # 保存当前集合至 /etc/chinadns-ng/ipset/
/etc/chinadns-ng/ipset/ipset-persist.sh restore  # 从保存文件恢复集合并加载规则
/etc/chinadns-ng/ipset/ipset-persist.sh status   # 显示集合与规则简况
/etc/chinadns-ng/ipset/ipset-persist.sh setup    # 一次性完成：create + 规则 + save
```

- 注意：脚本默认在宿主机执行。若在容器内执行，ipset/iptables 对宿主不生效。

### 4.6 ipset-restore.init（OpenWrt）

- 用途：开机自动执行 `ipset-persist.sh restore`。
- 开机启用：

```bash
/etc/init.d/ipset-restore enable
/etc/init.d/ipset-restore start
```

### 4.7 ipset-restore.service（systemd 环境可选）

- 非 OpenWrt 系统可使用：

```bash
# 拷贝到 /etc/systemd/system/ipset-restore.service 并启用
systemctl enable ipset-restore.service
systemctl start ipset-restore.service
```

### 4.8 update-lists.sh

- 用途：按需更新 `config/chnlist.txt` 与 `config/gfwlist.txt`。
- 更新后重启 chinadns-ng 容器使其生效：

```bash
# 在项目根目录
./update-lists.sh
# 然后重启服务
docker compose restart
```

---

## 5. 运行与验证（IstoreOS）

1. 启动 chinadns-ng（方式 A 已自动启动；方式 B 手动）：

```bash
cd /home/chinadns-ng
docker compose up -d
```

2. 安装并设置 ipset 持久化（首次必做）：

```bash
cd /home/chinadns-ng
chmod +x *.sh *.init
./install-ipset.sh
# 等待 DNS 服务就绪
docker ps | grep chinadns-ng
sleep 10
# 创建集合与规则并保存
/etc/chinadns-ng/ipset/ipset-persist.sh setup
```

3. 配置 v2ray-tproxy（在 v2ray-tproxy 项目目录）：

```bash
cd /home/v2ray-tproxy
# 确认 config.conf:
# TPROXY_PORT=12345
# FW_MARK=0x1
# ROUTE_TABLE=100
./install.sh
```

4. 验证：

```bash
# ipset 集合与规则
/etc/chinadns-ng/ipset/ipset-persist.sh status

# mangle 链顺序（应见 CHINADNS_CHN、CHINADNS_GFW 在前，V2RAY_EXCLUDE 其后）
iptables -t mangle -L PREROUTING -n --line-numbers

# DNS 测试
apk add bind-tools 2>/dev/null || opkg update && opkg install bind-dig 2>/dev/null || true
dig @127.0.0.1 -p 65353 baidu.com
dig @127.0.0.1 -p 65353 google.com

# v2ray 端口
ss -tlnp | grep :12345 || netstat -tlnp | grep :12345 || true
```

---

## 6. 关键配置（chinadns-ng.conf 摘要）

```ini
# 监听
bind-addr 0.0.0.0
bind-addr ::
bind-port 65353

# 上游 DNS（国内/可信）
china-dns 223.5.5.5,119.29.29.29,114.114.114.114
trust-dns tls://8.8.8.8,tls://1.1.1.1,tls://9.9.9.9

# 列表与分流策略（纯域名分流）
chnlist-file /etc/chinadns-ng/chnlist.txt
gfwlist-file /etc/chinadns-ng/gfwlist.txt
chnlist-first
default-tag chn

# ipset 集合名（与脚本保持一致）
ipset-name4 chnroute
ipset-name6 chnroute6
add-tagchn-ip chnip,chnip6
add-taggfw-ip gfwip,gfwip6

# 其余缓存/性能参数按需调整
```

---

## 7. 故障排除（FAQ）

- 国内/国外未正确分流：
  - `ipset list chnip | head` 与 `ipset list gfwip | head` 是否有条目
  - `iptables -t mangle -L PREROUTING -n --line-numbers` 顺序是否正确
  - v2ray 是否监听 12345，`ss -tlnp | grep :12345`
- 重启后规则丢失：
  - 确认 `/etc/init.d/ipset-restore enable` 已开启
  - 手动恢复：`/etc/chinadns-ng/ipset/ipset-persist.sh restore`
- fwmark 冲突：
  - v2ray 与 chinadns 标记一致：`0x1`；如冲突，统一修改为独占值，并同步 `config.conf`
- IPv6：
  - 仅在 `ENABLE_IPV6=1` 且 `ip6tables` 可用时启用；若不需要可保持关闭

---

## 8. 安全与最佳实践

- 仅允许内网访问本地 DNS 端口 65353：

```bash
iptables -A INPUT -p udp --dport 65353 -s 192.168.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 65353 -s 192.168.0.0/16 -j ACCEPT
iptables -A INPUT -p udp --dport 65353 -j DROP
iptables -A INPUT -p tcp --dport 65353 -j DROP
```

- 定期更新列表并重启服务：`./update-lists.sh && docker compose restart`
- 合理配置缓存与超时，减少上游压力与延迟

---

## 9. 参考

- chinadns-ng（上游 README 与用法参考）：`https://github.com/zfl9/chinadns-ng/blob/master/README.md`

如需进一步自动化（例如一键上传+安装），可另行增加部署脚本；当前设计将“镜像内运行必需内容”与“宿主机管理脚本”彻底分离，方便维护与升级。
