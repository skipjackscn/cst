#!/bin/sh
# 读取实际监听端口并做 TCP 探活
PORT="$(cat /run/xrdp/runtime_port 2>/dev/null || echo "${PORT:-3389}")"
nc -z 127.0.0.1 "${PORT}"
