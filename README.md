# Railway Remote Desktop (XRDP + XFCE + EasyTier)

把一个「随时可远程连接的云桌面」做成一个 **GitHub 仓库 → 一键部署到 Railway** 的项目。
原版 `windows-rdp.yml` 是 GitHub Actions 里跑 Windows runner 的方案（限 6 小时）；
本项目改成常驻容器，**无限时长、按分钟计费、随时可连**，并用国产开源组网工具 **EasyTier** 做私网接入。

## ⚠️ 先说清楚一件事

**Railway 跑的是 Linux 容器，没有嵌套虚拟化 / KVM，因此无法运行真正的 Windows 容器**
（`dockurr/windows` 这类方案在 Railway 上起不来）。

所以本仓库提供的是：**Ubuntu 22.04 + XFCE4 + XRDP 的 Linux 远程桌面**，
用 Windows 自带的 `mstsc`、macOS 的 Microsoft Remote Desktop、Linux 的 Remmina 都能直接连。

> 如果你**必须要 Windows 桌面**：请用支持 KVM 的 VPS / 云主机（Hetzner AX 系列、Azure、Oracle Cloud 等），
> 然后在那台机器上跑 `dockurr/windows`。Railway 不是合适的选择。

## 目录结构

```
.
├── Dockerfile                 # 镜像：xrdp + xorgxrdp + XFCE4 + Chrome + EasyTier
├── railway.toml               # Railway 配置即代码
├── docker-compose.yml         # 本地自测用
├── .env.example               # 环境变量样例
├── config/
│   ├── supervisord.conf       # 进程守护：dbus / xrdp-sesman / xrdp / easytier
│   ├── xrdp.ini               # xrdp 主配置（端口会被 entrypoint 覆写为 $PORT）
│   ├── startwm.sh             # 会话启动脚本（拉起 XFCE）
│   └── 45-xrdp-desktop.pkla   # 屏蔽 polkit 授权弹窗
├── scripts/
│   ├── entrypoint.sh          # 建账号 / 改密码 / 改端口 / 组装 EasyTier 启动参数
│   └── healthcheck.sh         # 端口探活
├── examples/
│   ├── easytier-server.toml   # 配置范例：本容器（无 TUN 模式）
│   ├── easytier-client.toml   # 配置范例：你自己的电脑
│   ├── easytier-relay.toml    # 配置范例：自建共享节点
│   └── docker-compose.relay.yml
└── .github/workflows/
    └── docker-publish.yml     # push 到 main 时构建并推送镜像到 GHCR
```

## 一、本地先跑一遍（强烈建议）

```bash
git clone <your-repo-url>
cd <repo>
cp .env.example .env      # 改掉 RDP_PASSWORD 和 EASYTIER_NETWORK_SECRET

docker compose up -d --build
docker compose logs -f    # 日志里会打印 用户/密码/地址
```

然后用 `mstsc` 连接 `localhost:3389`。

## 二、部署到 Railway

1. 把本仓库推到 GitHub。
2. 打开 <https://railway.com> → **New Project** → **Deploy from GitHub repo** → 选中该仓库。
3. Railway 读到根目录 `railway.toml`，自动用 Dockerfile 构建（首次构建约 5–10 分钟）。
4. 在服务 **Variables** 里设置环境变量（见下表），至少改掉 `RDP_PASSWORD`。
5. 打开 **Settings → Networking → TCP Proxy** → **Enable TCP Proxy**，
   Railway 会给出形如 `monorail.proxy.rlwy.net:12345` 的外网地址。
6. 用 `mstsc` 连接该地址，用户名 `rdpuser`，密码为你设的 `RDP_PASSWORD`。

> 容器里实际监听的端口取自 Railway 注入的 `PORT`，`entrypoint.sh` 会自动把 xrdp 改到这个端口。

### 可选：挂持久化卷

Settings → **Volumes** → 挂载路径填 `/home`，桌面文件在重新部署后不会丢。

### 可选：改用 GHCR 预构建镜像（部署更快）

`.github/workflows/docker-publish.yml` 会在 push 到 `main` 时把镜像推到 `ghcr.io/<owner>/<repo>:latest`。
在 Railway 服务里把 Source 改成 **Docker Image**，填 `ghcr.io/<owner>/<repo>:latest` 即可。

## 三、环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `RDP_USER` | `rdpuser` | 登录用户名 |
| `RDP_PASSWORD` | 随机生成 | 登录密码，**务必设置**（不设会在日志里打印随机密码） |
| `RDP_UID` | `1000` | 用户 UID，挂载卷权限对不上时可调 |
| `SUDO_NOPASSWD` | `true` | 是否免密 sudo |
| `TZ` | `Asia/Shanghai` | 时区 |
| `XRDP_SECURITY_LAYER` | `negotiate` | 客户端报协议错误时改 `rdp` 或 `tls` |
| `EASYTIER_NETWORK_NAME` | 空 | 组网名，**和客户端必须一致** |
| `EASYTIER_NETWORK_SECRET` | 空 | 组网密钥，**和客户端必须一致** |
| `EASYTIER_ENABLE` | `auto` | `auto`=填了上面两个就启用；也可 `true`/`false` 强制 |
| `EASYTIER_IPV4` | 空 | 本节点虚拟 IP，留空用 DHCP（IP 不固定，不建议） |
| `EASYTIER_HOSTNAME` | `railway-rdp` | 在 `easytier-cli peer` 里显示的名字 |
| `EASYTIER_PEERS` | 空 | 初始对端/共享节点，多个用逗号分隔 |
| `EASYTIER_LISTENERS` | 空 | 本地监听，多个用逗号分隔 |
| `EASYTIER_PROXY_NETWORKS` | 空 | 子网代理，如 `192.168.1.0/24` |
| `EASYTIER_NO_TUN` | `true` | 无 TUN 模式，Railway 上保持 `true` |
| `EASYTIER_RPC_PORTAL` | `127.0.0.1:15888` | 管理端口，供容器内 `easytier-cli` 使用 |
| `EASYTIER_EXTRA_ARGS` | 空 | 额外参数，原样追加 |
| `PORT` | `3389` | Railway 自动注入，不要手填 |

## 四、推荐用法：EasyTier 私网访问（更安全）

把 3389 直接暴露到公网会被全网扫描爆破。EasyTier 是去中心化组网，
同一个 `网络名 + 密钥` 的机器会组成一个虚拟局域网，**不需要注册账号，也不依赖中心服务**。

### 关键：容器端跑「无 TUN 模式」

Railway 容器里没有 `/dev/net/tun`，所以容器端默认加 `--no-tun`。
无 TUN 模式下本节点**可以被虚拟 IP 访问（TCP/UDP/ICMP 都支持），只是不能主动访问别的节点**——
作为 RDP 被连接的一方正好够用。你自己的电脑有管理员权限，跑完整模式即可。

### 1. 容器端（Railway）

在 Railway Variables 里填：

```
EASYTIER_NETWORK_NAME   = my-rdp-net
EASYTIER_NETWORK_SECRET = 一个足够长的随机字符串
EASYTIER_IPV4           = 10.126.126.10
EASYTIER_HOSTNAME       = railway-rdp
EASYTIER_PEERS          = tcp://public.easytier.cn:11010
EASYTIER_LISTENERS      = tcp://0.0.0.0:11010,udp://0.0.0.0:11010
EASYTIER_NO_TUN         = true
```

> `tcp://public.easytier.cn:11010` 是 EasyTier 社区公共共享节点，
> 拥塞时会影响体验；有公网 VPS 的话建议照 `examples/easytier-relay.toml` 自建一个。

### 2. 你的电脑（Windows GUI）

下载 `easytier-gui`，填：

| 项 | 值 |
| --- | --- |
| 虚拟 IP | `10.126.126.100`（或勾选 DHCP） |
| Network Name | `my-rdp-net` |
| Network Secret | 与容器端一致 |
| Networking Method | Public Server → `tcp://public.easytier.cn:11010` |

点 Run Network，然后 `mstsc` 连 `10.126.126.10:3389`。

### 3. 你的电脑（Linux CLI）

```bash
sudo easytier-core -i 10.126.126.100 \
  --network-name my-rdp-net \
  --network-secret '你的密钥' \
  -p tcp://public.easytier.cn:11010

# 验证
easytier-cli peer          # 应能看到 railway-rdp
ping 10.126.126.10
```

也可以直接用配置文件：`sudo easytier-core -c examples/easytier-client.toml`。

### 4. 容器端改用配置文件

如果更习惯 TOML，把 `examples/easytier-server.toml` 挂进容器，并设：

```
EASYTIER_EXTRA_ARGS = -c /etc/easytier/easytier.toml
```

> 注意：不同版本对「命令行参数与配置文件谁覆盖谁」的约定不一致（老版本配置文件优先级更高，
> 新版本命令行覆盖配置文件）。**要么只用环境变量/命令行，要么只用配置文件**，别混着调。

### 5. 排障

```bash
docker exec -it railway-rdp easytier-cli node    # 看本节点拿到的虚拟 IP
docker exec -it railway-rdp easytier-cli peer    # 看已连上的对端
docker exec -it railway-rdp easytier-cli route   # 看路由
```

- `peer` 里看不到对方 → 网络名/密钥不一致，或共享节点地址写错。
- 看得见但 ping 不通 → 检查对方防火墙；容器端是 `--no-tun`，它**不能主动 ping 别人**，要从客户端 ping 容器。

## 五、常见问题

**黑屏 / 连上立刻断开**
- 看 Deploy Logs，多半是密码错误或会话残留，重启服务即可。同一账号多处登录会互相挤掉。

**登录时提示协议/加密错误**
- 把 `XRDP_SECURITY_LAYER` 设为 `rdp` 或 `tls` 后重新部署。

**中文乱码 / 方框**
- 镜像已装 `fonts-noto-cjk` 与文泉驿；若仍异常，在终端执行 `fc-cache -fv`。

**重新部署后文件没了**
- 挂 `/home` 卷。

**费用**
- 桌面容器常驻，会持续产生用量费。不用时暂停 / 删除服务。

## 六、安全提醒

- 别用弱密码；RDP 暴露公网会被持续爆破。
- 密码会出现在部署日志里（首次登录用），登录后请 `passwd` 改掉。
- 优先走 EasyTier 私网，其次再考虑 TCP Proxy + 强密码 + 及时下线。
- `EASYTIER_NETWORK_SECRET` 要足够长——它和组网名一起就是入网凭据。
