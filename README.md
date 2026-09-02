# Quick-Clash

Ubuntu 一键部署 Clash.Meta（mihomo）代理。国内机器也能把内核、面板、Geo 数据下下来，装完用终端命令管节点，不必再手改 YAML。

适合已经有机场订阅、想在云服务器或本机 Ubuntu 上快速拉起 HTTP / SOCKS 代理的场景。

## 它做什么

- 安装 mihomo 内核（GitHub 多镜像，超时自动换源，下载带进度条）
- 安装 metacubexd Web UI
- 订阅若已是 Clash YAML 则直接拉取，否则走 sub2clash 转换
- 写入 systemd，开机自启
- 预置 GeoSite / GeoIP（走国内 CDN，避免 GitHub 下到坏文件导致 GEOSITE 规则失败）
- 安装后提供 `proxy_on`、`clash_nodes`、`clash_test` 等快捷命令
- 启动时按延迟给策略组选节点

## 环境要求

- Ubuntu（需 systemd）
- root：`sudo` 运行安装脚本
- 架构：`amd64` / `arm64` / `armv7`
- 一份可用的订阅链接（v2ray / Clash / SS 等）

## 安装

```bash
chmod +x quick-clash.sh
sudo ./quick-clash.sh
```

按提示粘贴订阅地址。装完后重新打开终端，或：

```bash
source ~/.zshrc    # 或 source ~/.bashrc
```

## 脚本命令

| 命令 | 作用 |
| --- | --- |
| `sudo ./quick-clash.sh` | 安装 / 重新配置（交互输入订阅） |
| `sudo ./quick-clash.sh repair` | 修复：清洗配置、补 Geo 数据、重写快捷命令并拉起服务 |
| `sudo ./quick-clash.sh uninstall` | 卸载服务、文件和 shell 函数 |
| `./quick-clash.sh help` | 查看帮助 |

## 安装后命令

先 `source` 一次 shell 配置，再在**普通用户**终端使用：

| 命令 | 作用 |
| --- | --- |
| `proxy_on` | 当前终端走 HTTP `127.0.0.1:7890`、SOCKS `127.0.0.1:7891` |
| `proxy_off` | 关闭当前终端代理环境变量 |
| `proxy_status` | 查看当前终端是否已开代理 |
| `clash_nodes` | 列出策略组和节点 |
| `clash_test <组名>` | 测该组延迟 |
| `clash_select <组名> <节点名>` | 切换节点 |
| `clash_choose [组名]` | 交互式选组 / 选节点 |
| `clash_update [订阅地址]` | 更新订阅；省略地址则用上次保存的链接 |
| `clash_status` | systemd 状态；若没在跑会打出最近日志和配置校验 |
| `clash_restart` | 重启服务 |
| `clash_log [行数]` | 看 journal 日志，默认 50 行 |
| `clash_ui` | 打印 Web UI 地址和 API Secret |

示例：

```bash
proxy_on
clash_nodes
clash_test PROXY
clash_select PROXY '香港01'
clash_ui
```

## 端口与目录

| 项目 | 路径 / 端口 |
| --- | --- |
| HTTP 代理 | `127.0.0.1:7890` |
| SOCKS 代理 | `127.0.0.1:7891` |
| 外部控制器 / UI | `9090`（局域网可用机器 IP 访问） |
| 内核 | `/opt/clash/mihomo` |
| 配置 | `/etc/clash/config.yaml` |
| 订阅备份 | `/etc/clash/.subscription_url` |
| API Secret | `/etc/clash/.api_secret` |
| Geo 数据 | `/etc/clash/GeoSite.dat`、`/etc/clash/GeoIP.dat` |
| systemd | `clash.service` |

Web UI：

- 本机：`http://127.0.0.1:9090/ui`
- 局域网：`http://<服务器IP>:9090/ui`
- 也可打开 [metacubexd.pages.dev](https://metacubexd.pages.dev) 或 [d.metacubex.one](https://d.metacubex.one)，填入 API 地址和 Secret

安全提醒：`allow-lan` 为开启状态。公网机器请用防火墙限制 `7890` / `7891` / `9090`，不要把面板和代理端口暴露给所有人。

## 安装流程

脚本会按 6 步走，终端有总进度和下载进度：

1. 安装依赖（curl、jq、python3 等）
2. 下载 mihomo（失败会改试 compatible 构建，适配旧 glibc）
3. 下载 metacubexd
4. 输入订阅
5. 拉 Geo 数据、生成并校验 `config.yaml`
6. 写入 systemd、选低延迟节点、写入 shell 函数

## 常见问题

**`clash_nodes` 提示 API 无响应**

服务没起来。执行 `clash_status` 看日志，或：

```bash
sudo journalctl -u clash -n 50 --no-pager
sudo /opt/clash/mihomo -t -d /etc/clash
```

然后：

```bash
sudo ./quick-clash.sh repair
source ~/.zshrc
```

**配置校验：`yaml: control characters are not allowed`**

订阅或转换结果里混了 `\r`、空字节等。`repair` 会清洗后再写入。

**配置校验：`can't initial GeoSite` / `GEOSITE` 规则失败**

GeoSite.dat 从 GitHub 直接下经常是坏文件。脚本会改从 jsDelivr 等国内 CDN 预置。再跑一次 `repair` 即可。

**下载 GitHub 资源一直卡住**

已不再使用不可靠的 ghproxy.com。连接超时、速度过低会自动换镜像。

**`clash_status` 里既有服务信息又写「未安装」**

旧版把「服务崩溃」误判成未安装。更新脚本后执行 `repair` 会重写快捷命令。

**装完命令找不到**

新开一个终端，或 `source ~/.zshrc` / `source ~/.bashrc`。

## 卸载

```bash
sudo ./quick-clash.sh uninstall
```

会停掉服务、删除 `/opt/clash`、`/etc/clash`，并从 shell 配置里去掉快捷命令。

## 免责

本脚本只负责在你自己的机器上安装开源内核 mihomo 并导入**你已有的**订阅。请遵守当地法律法规和机场服务条款，勿用于未授权的网络访问。
