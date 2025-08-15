FROM alpine:3.18

# 安装运行时必需工具
RUN apk add --no-cache ipset

# 复制预编译的可执行文件
COPY chinadns-ng /usr/local/bin/
RUN chmod +x /usr/local/bin/chinadns-ng

# 声明端口（实际生效需要运行时-p参数或--network host）
EXPOSE 5353/tcp 5353/udp

# 启动命令（使用数组形式避免shell解析）
ENTRYPOINT ["chinadns-ng"]