FROM alpine:latest

# 安装依赖（增加 ca-certificates 以支持 DoT/DoH）
RUN apk add --no-cache \
    ipset \
    ca-certificates \
    bash \
    busybox-extras \
    bind-tools

# 创建配置目录
RUN mkdir -p /etc/chinadns-ng

# 复制可执行文件和配置文件
COPY chinadns-ng /usr/local/bin/
COPY config/chinadns-ng.conf /etc/chinadns-ng/
COPY config/chnlist.txt /etc/chinadns-ng/
COPY config/gfwlist.txt /etc/chinadns-ng/

# 设置权限（保持 root 以便可选 ipset 权限）
RUN chmod +x /usr/local/bin/chinadns-ng && \
    chmod 644 /etc/chinadns-ng/*

# 建议使用配置文件启动（可通过 -C 覆盖）
ENTRYPOINT ["/usr/local/bin/chinadns-ng", "-C", "/etc/chinadns-ng/chinadns-ng.conf"]

# 声明端口（实际使用建议 --network host）
EXPOSE 65353/tcp 65353/udp