#!/usr/bin/env bash
#
# quick-clash.sh — Ubuntu 一键部署 Clash.Meta (mihomo) 代理脚本
#
# 功能:
#   1. 自动下载安装 mihomo (Clash.Meta) 内核（国内多镜像 + 超时切换 + 进度条）
#   2. 自动下载 metacubexd Web UI 面板
#   3. 通过 sub2clash 公共 API 转换订阅地址为 Clash.Meta 配置
#   4. 配置 systemd 服务，开机自启
#   5. 提供 proxy_on / proxy_off / clash_nodes / clash_select / clash_test 快捷命令
#   6. 终端内查看节点列表、测速、选择节点
#
# 使用方法:
#   chmod +x quick-clash.sh
#   sudo ./quick-clash.sh
#
# 安装完成后在终端执行:
#   proxy_on    — 开启代理
#   proxy_off   — 关闭代理
#   clash_nodes — 查看节点列表
#   clash_test  — 测试所有节点延迟
#   clash_select <组名> <节点名> — 选择节点
#   clash_update <订阅地址>      — 更新订阅
#   clash_status — 查看 Clash 运行状态
#   clash_restart — 重启 Clash 服务
#   clash_log    — 查看 Clash 日志
#   clash_ui     — 打印 Web UI 地址
#

set -euo pipefail

# ============== 配置区域 ==============
CLASH_DIR="/opt/clash"
CLASH_CONFIG_DIR="/etc/clash"
CLASH_CONFIG_FILE="${CLASH_CONFIG_DIR}/config.yaml"
CLASH_LOG_FILE="/var/log/clash.log"
CLASH_SECRET="quick-clash-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
CLASH_HTTP_PORT=7890
CLASH_SOCKS_PORT=7891
CLASH_API_PORT=9090
CLASH_DNS_PORT=1053
URL_TEST_URL="https://www.gstatic.com/generate_204"
URL_TEST_TIMEOUT_MS=5000
MIHOMO_VERSION="v1.19.4"
METACUBEXD_VERSION="v1.173.0"
SUB2CLASH_API="https://clash.nite07.com"
SHELL_RC=""
TOTAL_STEPS=6
CURRENT_STEP=0

# 国内 GitHub 加速镜像（按顺序尝试，超时自动切下一个）
# ghproxy.com 已基本不可用，不再作为首选
GITHUB_PROXIES=(
    "https://ghfast.top/https://github.com"
    "https://gh-proxy.com/https://github.com"
    "https://mirror.ghproxy.com/https://github.com"
    "https://gitdl.cn/https://github.com"
    "https://ghproxy.net/https://github.com"
    "https://kkgithub.com"
    "https://github.com"
)

CURL_CONNECT_TIMEOUT=8
CURL_MAX_TIME=180
CURL_SPEED_LIMIT=1024
CURL_SPEED_TIME=20

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ============== 工具函数 ==============
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

print_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local title="$1"
    local width=28
    local filled=$((CURRENT_STEP * width / TOTAL_STEPS))
    local i bar=""
    for ((i = 0; i < width; i++)); do
        if ((i < filled)); then
            bar+="█"
        else
            bar+="░"
        fi
    done
    local pct=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    echo ""
    echo -e "${BOLD}${CYAN}[${bar}] ${pct}%  ${CURRENT_STEP}/${TOTAL_STEPS}  ${title}${NC}"
    echo ""
}

print_inline_progress() {
    local current="$1"
    local total="$2"
    local title="$3"
    local width=24
    local filled=0
    if ((total > 0)); then
        filled=$((current * width / total))
    fi
    local i bar=""
    for ((i = 0; i < width; i++)); do
        if ((i < filled)); then
            bar+="█"
        else
            bar+="░"
        fi
    done
    local pct=0
    if ((total > 0)); then
        pct=$((current * 100 / total))
    fi
    if ((${#title} > 42)); then
        title="${title:0:42}..."
    fi
    printf "\r${CYAN}[%s] %3d%%  %s/%s  %s${NC}" "$bar" "$pct" "$current" "$total" "$title"
    if ((current >= total)); then
        echo ""
    fi
}

curl_progress_flags() {
    if [[ -t 2 ]]; then
        echo "--progress-bar"
    else
        echo "-#"
    fi
}

# 从 GitHub 多镜像下载文件；成功返回 0，全部失败返回 1
download_github() {
    local dest="$1"
    local rel_path="$2"
    local label="${3:-下载}"
    local tmp="${dest}.part"
    local i=0
    local total=${#GITHUB_PROXIES[@]}
    local progress_flag
    progress_flag=$(curl_progress_flags)

    mkdir -p "$(dirname "$dest")"

    for prefix in "${GITHUB_PROXIES[@]}"; do
        i=$((i + 1))
        local url="${prefix}/${rel_path}"
        info "${label} 镜像 ${i}/${total}"
        echo -e "  ${BLUE}${url}${NC}"
        rm -f "$tmp"

        if curl -fL \
            --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
            --max-time "${CURL_MAX_TIME}" \
            --retry 0 \
            --speed-limit "${CURL_SPEED_LIMIT}" \
            --speed-time "${CURL_SPEED_TIME}" \
            "${progress_flag}" \
            -o "$tmp" \
            "$url"; then
            local filesize=0
            if [[ -f "$tmp" ]]; then
                filesize=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
            fi
            # 镜像有时返回 HTML 错误页且 HTTP 200，过小文件直接视为失败
            if ((filesize >= 51200)); then
                mv "$tmp" "$dest"
                local size
                size=$(du -h "$dest" | awk '{print $1}')
                info "${label} 完成 (${size})"
                return 0
            fi
            warn "下载内容异常（${filesize} 字节），切换镜像..."
        fi
        warn "${label} 失败或过慢，切换下一个镜像..."
        rm -f "$tmp"
    done

    return 1
}

download_from_urls() {
    local dest="$1"
    local min_size="$2"
    local label="$3"
    shift 3
    local tmp="${dest}.part"
    local progress_flag
    progress_flag=$(curl_progress_flags)
    local i=0
    local total=$#
    local url filesize size

    mkdir -p "$(dirname "$dest")"

    for url in "$@"; do
        i=$((i + 1))
        info "${label} 镜像 ${i}/${total}"
        echo -e "  ${BLUE}${url}${NC}"
        rm -f "$tmp"
        if curl -fL \
            --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
            --max-time "${CURL_MAX_TIME}" \
            --retry 0 \
            --speed-limit "${CURL_SPEED_LIMIT}" \
            --speed-time "${CURL_SPEED_TIME}" \
            "${progress_flag}" \
            -o "$tmp" \
            "$url"; then
            filesize=0
            if [[ -f "$tmp" ]]; then
                filesize=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
            fi
            if ((filesize >= min_size)); then
                mv "$tmp" "$dest"
                size=$(du -h "$dest" | awk '{print $1}')
                info "${label} 完成 (${size})"
                return 0
            fi
            warn "下载内容异常（${filesize} 字节），切换下一个镜像..."
        else
            warn "${label} 失败或过慢，切换下一个镜像..."
        fi
        rm -f "$tmp"
    done
    return 1
}

install_geodata() {
    mkdir -p "${CLASH_CONFIG_DIR}"
    local geosite="${CLASH_CONFIG_DIR}/GeoSite.dat"
    local geoip="${CLASH_CONFIG_DIR}/GeoIP.dat"
    local min_size=1048576

    info "准备 GeoSite / GeoIP 数据（国内 CDN，避免 GitHub 下到坏文件）..."

    if [[ -f "$geosite" ]] && (( $(stat -c%s "$geosite") >= min_size )); then
        info "GeoSite.dat 已存在，跳过下载"
    else
        rm -f "$geosite"
        download_from_urls "$geosite" "$min_size" "GeoSite.dat" \
            "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat" \
            "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat" \
            "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat" \
            "https://ghfast.top/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat" \
            "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat" \
            || error "GeoSite.dat 下载失败。没有这份数据，配置里的 GEOSITE 规则无法加载"
    fi

    if [[ -f "$geoip" ]] && (( $(stat -c%s "$geoip") >= min_size )); then
        info "GeoIP.dat 已存在，跳过下载"
    else
        rm -f "$geoip"
        download_from_urls "$geoip" "$min_size" "GeoIP.dat" \
            "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat" \
            "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat" \
            "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat" \
            "https://ghfast.top/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat" \
            "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat" \
            || warn "GeoIP.dat 下载失败，GEOIP 规则可能不可用"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 sudo 运行此脚本: sudo $0"
    fi
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *)       error "不支持的架构: $arch" ;;
    esac
}

detect_shell_rc() {
    local real_user="${SUDO_USER:-$USER}"
    local real_home
    real_home=$(eval echo "~${real_user}")

    if [[ -f "${real_home}/.zshrc" ]]; then
        SHELL_RC="${real_home}/.zshrc"
    elif [[ -f "${real_home}/.bashrc" ]]; then
        SHELL_RC="${real_home}/.bashrc"
    else
        SHELL_RC="${real_home}/.bashrc"
    fi
    info "检测到 Shell 配置文件: ${SHELL_RC}"
}

get_local_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
}

url_encode() {
    python3 - "$1" <<'PY' 2>/dev/null || echo "$1"
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
}

clash_api_request() {
    local method="${1:-GET}"
    local path="$2"
    local data="${3:-}"
    local auth_header="Authorization: Bearer ${CLASH_SECRET}"

    if [[ "$method" == "GET" ]]; then
        curl -sS -H "$auth_header" "http://127.0.0.1:${CLASH_API_PORT}${path}" 2>/dev/null
    else
        curl -sS -X "$method" -H "$auth_header" -H "Content-Type: application/json" \
            -d "$data" "http://127.0.0.1:${CLASH_API_PORT}${path}" 2>/dev/null
    fi
}

wait_for_clash_api() {
    local retries=20
    local i
    for ((i = 1; i <= retries; i++)); do
        print_inline_progress "$i" "$retries" "等待 Clash API 就绪"
        if clash_api_request GET /version | jq -e '.version' >/dev/null 2>&1; then
            print_inline_progress "$retries" "$retries" "Clash API 已就绪"
            return 0
        fi
        sleep 1
    done
    echo ""
    return 1
}

# Base64 URL Safe 编码 (兼容 macOS 和 Linux)
base64url_encode() {
    echo -n "$1" | base64 -w0 2>/dev/null || echo -n "$1" | base64 | tr -d '\n'
    # 标准 base64 转 base64url
}

base64url_encode_safe() {
    local input="$1"
    echo -n "$input" | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '=' || \
    echo -n "$input" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

# ============== 安装依赖 ==============
install_deps() {
    info "更新软件源..."
    apt-get update
    info "安装 curl wget tar gzip jq python3..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget tar gzip jq python3
    info "依赖安装完成"
}

# ============== 下载安装 mihomo ==============
install_mihomo() {
    local arch
    arch=$(detect_arch)

    mkdir -p "${CLASH_DIR}"

    if [[ -x "${CLASH_DIR}/mihomo" ]] && "${CLASH_DIR}/mihomo" -v >/dev/null 2>&1; then
        local current_version
        current_version=$("${CLASH_DIR}/mihomo" -v 2>/dev/null | head -1 | grep -oP 'v[\d.]+' || echo "unknown")
        info "已检测到可运行的 mihomo ${current_version}，跳过下载"
        return 0
    fi

    info "下载 mihomo ${MIHOMO_VERSION} (${arch})..."

    local dest="${CLASH_DIR}/mihomo.gz"
    local assets=(
        "mihomo-linux-${arch}-${MIHOMO_VERSION}.gz"
        "mihomo-linux-${arch}-compatible-${MIHOMO_VERSION}.gz"
    )
    local asset
    local extracted=0

    for asset in "${assets[@]}"; do
        rm -f "$dest" "${CLASH_DIR}/mihomo"
        if ! download_github "$dest" \
            "MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${asset}" \
            "mihomo ${asset}"; then
            warn "资源 ${asset} 全部镜像失败，尝试备用文件名..."
            continue
        fi
        gzip -t "$dest" || { warn "压缩包损坏，换下一个"; continue; }
        gzip -df "$dest"
        chmod +x "${CLASH_DIR}/mihomo"
        if "${CLASH_DIR}/mihomo" -v >/dev/null 2>&1; then
            extracted=1
            info "mihomo 可执行: $("${CLASH_DIR}/mihomo" -v 2>/dev/null | head -1)"
            break
        fi
        warn "${asset} 无法在当前系统运行（多为 glibc 过旧），尝试 compatible 版本..."
    done

    [[ "$extracted" -eq 1 ]] || error "下载的 mihomo 无法运行，请检查架构或系统 glibc"
    info "mihomo 安装完成: ${CLASH_DIR}/mihomo"
}

# ============== 下载 Web UI ==============
install_webui() {
    local ui_dir="${CLASH_DIR}/ui"

    if [[ -d "${ui_dir}" && -f "${ui_dir}/index.html" ]]; then
        info "Web UI 已存在，跳过下载"
        return 0
    fi

    info "下载 metacubexd Web UI..."
    mkdir -p "${ui_dir}"

    local ui_tgz="/tmp/metacubexd.tgz"
    if download_github "$ui_tgz" \
        "MetaCubeX/metacubexd/releases/download/${METACUBEXD_VERSION}/compressed-dist.tgz" \
        "metacubexd UI"; then
        tar -xzf "$ui_tgz" -C "${ui_dir}" --strip-components=0 2>/dev/null || \
        tar -xzf "$ui_tgz" -C "${ui_dir}" 2>/dev/null
        rm -f "$ui_tgz"
        if [[ -f "${ui_dir}/index.html" ]]; then
            info "Web UI 安装完成: ${ui_dir}"
        else
            warn "Web UI 解压后未找到 index.html，你可以稍后手动安装"
        fi
    else
        warn "Web UI 下载失败，你可以稍后手动安装"
        rm -f "$ui_tgz"
    fi
}

# 去掉 YAML 不允许的控制字符（CR、NUL、ANSI 进度条残留等）
sanitize_yaml_text() {
    python3 -c '
import re, sys
data = sys.stdin.buffer.read()
if data.startswith(b"\xef\xbb\xbf"):
    data = data[3:]
text = data.decode("utf-8", errors="replace")
text = text.replace("\r\n", "\n").replace("\r", "\n")
text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)
if text and not text.endswith("\n"):
    text += "\n"
sys.stdout.write(text)
'
}

sanitize_yaml_file() {
    local f="$1"
    local tmp="${f}.sanitized"
    sanitize_yaml_text < "$f" > "$tmp"
    mv "$tmp" "$f"
}

# ============== 订阅转换 ==============
looks_like_clash_yaml() {
    local f="$1"
    grep -qE '^(proxies|proxy-groups|rules):' "$f"
}

fetch_direct_clash_yaml() {
    local sub_url="$1"
    local dest="$2"
    local tmp
    tmp=$(mktemp)
    local progress_flag
    progress_flag=$(curl_progress_flags)

    info "尝试直接下载订阅（若已是 Clash YAML 则不用转换）..."
    echo -e "  ${BLUE}${sub_url}${NC}"
    if ! curl -fL --connect-timeout 15 --max-time 60 --retry 0 \
        "${progress_flag}" -o "$tmp" "${sub_url}"; then
        rm -f "$tmp"
        return 1
    fi
    sanitize_yaml_text < "$tmp" > "$dest"
    rm -f "$tmp"
    if [[ -s "$dest" ]] && looks_like_clash_yaml "$dest"; then
        info "订阅本身已是 Clash YAML，跳过 sub2clash"
        return 0
    fi
    rm -f "$dest"
    return 1
}

convert_subscription() {
    local sub_url="$1"
    local dest="$2"

    if fetch_direct_clash_yaml "$sub_url" "$dest"; then
        return 0
    fi

    info "使用 sub2clash 转换订阅地址..."

    local json_config
    json_config=$(cat <<EOF
{"clashType":2,"subscriptions":["${sub_url}"],"autoTest":true,"useUDP":true}
EOF
    )

    local encoded_config
    encoded_config=$(base64url_encode_safe "$json_config")

    local convert_url="${SUB2CLASH_API}/convert/${encoded_config}"
    info "正在从 sub2clash 获取配置..."
    echo -e "  ${BLUE}${SUB2CLASH_API}/convert/...${NC}"

    local tmp
    tmp=$(mktemp)
    local progress_flag
    progress_flag=$(curl_progress_flags)
    if ! curl -fL --connect-timeout 15 --max-time 120 --retry 0 \
        "${progress_flag}" -o "$tmp" "${convert_url}"; then
        rm -f "$tmp"
        error "订阅转换失败，请检查网络或订阅地址"
    fi

    sanitize_yaml_text < "$tmp" > "$dest"
    rm -f "$tmp"

    if [[ ! -s "$dest" ]]; then
        error "订阅转换返回空内容"
    fi

    local head
    head=$(python3 -c 'import sys; print(sys.stdin.read(400))' < "$dest")
    if [[ "$head" == "{"* ]] && [[ "$head" == *"error"* || "$head" == *"message"* ]]; then
        error "订阅转换返回错误: ${head}"
    fi
    if [[ "$head" == "<"* ]]; then
        error "订阅转换返回了网页而不是 YAML，请稍后重试"
    fi
}

append_converted_yaml() {
    python3 -c '
import re, sys
data = sys.stdin.buffer.read()
if data.startswith(b"\xef\xbb\xbf"):
    data = data[3:]
text = data.decode("utf-8", errors="replace")
text = text.replace("\r\n", "\n").replace("\r", "\n")
text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)
skip = re.compile(
    r"^(port|socks-port|redir-port|tproxy-port|mixed-port|allow-lan|bind-address|"
    r"mode|log-level|ipv6|external-controller|external-ui|external-ui-name|"
    r"secret|authentication|geox-url|geo-auto-update|geodata-mode)\s*:",
    re.I,
)
block_keys = {"geox-url"}
lines = []
skipping_block = False
for line in text.split("\n"):
    if skipping_block:
        if line.strip() == "" or line.startswith(" ") or line.startswith("\t"):
            continue
        skipping_block = False
    if line.strip() == "---":
        continue
    if skip.match(line):
        key = line.split(":", 1)[0].strip().lower()
        if key in block_keys:
            skipping_block = True
        continue
    lines.append(line)
while lines and lines[-1] == "":
    lines.pop()
sys.stdout.write("\n".join(lines) + "\n")
'
}

write_clash_header() {
    local dest="$1"
    local sub_url="$2"
    local secret="$3"
    sub_url="${sub_url//$'\r'/}"
    secret="${secret//$'\r'/}"
    local ui_line=""
    if [[ -f "${CLASH_DIR}/ui/index.html" ]]; then
        ui_line="external-ui: ${CLASH_DIR}/ui"
    fi

    cat > "$dest" <<HEADER
# Quick-Clash 自动生成配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 订阅地址: ${sub_url}

port: ${CLASH_HTTP_PORT}
socks-port: ${CLASH_SOCKS_PORT}
allow-lan: true
bind-address: '*'
mode: rule
log-level: info
ipv6: false
external-controller: 0.0.0.0:${CLASH_API_PORT}
${ui_line}
secret: "${secret}"
geodata-mode: true
geo-auto-update: true
geox-url:
  geoip: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
  geosite: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
  mmdb: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"

HEADER
}

validate_mihomo_config() {
    info "校验 mihomo 配置..."
    local out
    set +e
    out=$("${CLASH_DIR}/mihomo" -t -d "${CLASH_CONFIG_DIR}" 2>&1)
    local rc=$?
    set -e
    echo "$out"
    if [[ $rc -ne 0 ]]; then
        error "配置校验失败，mihomo 无法启动。原始转换结果在 ${CLASH_CONFIG_FILE}.raw"
    fi
    info "配置校验通过"
}

# ============== 生成配置文件 ==============
generate_config() {
    local sub_url="$1"
    mkdir -p "${CLASH_CONFIG_DIR}"

    install_geodata
    convert_subscription "$sub_url" "${CLASH_CONFIG_FILE}.raw"

    write_clash_header "${CLASH_CONFIG_FILE}" "$sub_url" "${CLASH_SECRET}"
    append_converted_yaml < "${CLASH_CONFIG_FILE}.raw" >> "${CLASH_CONFIG_FILE}"
    sanitize_yaml_file "${CLASH_CONFIG_FILE}"

    info "配置文件已生成: ${CLASH_CONFIG_FILE}"

    echo "${sub_url}" > "${CLASH_CONFIG_DIR}/.subscription_url"
    echo "${CLASH_SECRET}" > "${CLASH_CONFIG_DIR}/.api_secret"

    validate_mihomo_config
}

# ============== 配置 systemd 服务 ==============
setup_systemd() {
    info "配置 systemd 服务..."
    validate_mihomo_config

    cat > /etc/systemd/system/clash.service <<EOF
[Unit]
Description=Clash Meta Daemon
After=network.target NetworkManager.service systemd-networkd.service

[Service]
Type=simple
WorkingDirectory=${CLASH_CONFIG_DIR}
ExecStart=${CLASH_DIR}/mihomo -d ${CLASH_CONFIG_DIR}
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable clash.service >/dev/null
    systemctl restart clash.service
    sleep 2

    if systemctl is-active --quiet clash.service; then
        info "Clash 服务启动成功"
    else
        warn "Clash 服务启动失败，最近日志如下:"
        journalctl -u clash -n 40 --no-pager --no-hostname || true
        "${CLASH_DIR}/mihomo" -t -d "${CLASH_CONFIG_DIR}" || true
        error "Clash 未能保持运行，请根据上方日志修复配置后重试: sudo $0 repair"
    fi
}

auto_select_best_nodes() {
    info "自动为策略组选择最低延迟节点..."

    local response
    response=$(clash_api_request GET /proxies)
    if [[ -z "$response" ]]; then
        warn "Clash API 无响应，跳过自动选节点"
        return 0
    fi

    local groups
    groups=$(echo "$response" | jq -r '
        .proxies | to_entries[] |
        select(.value.type == "Selector" or .value.type == "URLTest" or .value.type == "Fallback") |
        .key
    ' 2>/dev/null)

    if [[ -z "$groups" ]]; then
        warn "没有找到可用策略组，跳过自动选节点"
        return 0
    fi

    while IFS= read -r group; do
        [[ -z "$group" ]] && continue

        local group_encoded
        group_encoded=$(url_encode "$group")
        local group_info
        group_info=$(clash_api_request GET "/proxies/${group_encoded}")
        local nodes
        nodes=$(echo "$group_info" | jq -r '.all[]? // empty' 2>/dev/null)

        [[ -z "$nodes" ]] && continue

        local best_node=""
        local best_delay=999999
        local node_list=()
        while IFS= read -r node; do
            [[ -z "$node" ]] && continue
            if [[ "$node" == "DIRECT" || "$node" == "REJECT" || "$node" == "GLOBAL" ]]; then
                continue
            fi
            node_list+=("$node")
        done <<< "$nodes"

        local idx=0
        local node_total=${#node_list[@]}
        local node
        for node in "${node_list[@]}"; do
            idx=$((idx + 1))
            print_inline_progress "$idx" "$node_total" "测速 [${group}] ${node}"

            local node_encoded
            node_encoded=$(url_encode "$node")

            local delay_result
            delay_result=$(clash_api_request GET "/proxies/${node_encoded}/delay?timeout=${URL_TEST_TIMEOUT_MS}&url=${URL_TEST_URL}")
            local delay
            delay=$(echo "$delay_result" | jq -r '.delay // empty' 2>/dev/null)

            if [[ -n "$delay" && "$delay" =~ ^[0-9]+$ ]] && (( delay < best_delay )); then
                best_delay=$delay
                best_node="$node"
            fi
        done
        if ((node_total > 0)); then
            echo ""
        fi

        if [[ -n "$best_node" ]]; then
            clash_api_request PUT "/proxies/${group_encoded}" "{\"name\":\"${best_node}\"}" >/dev/null || true
            info "策略组 [${group}] 已选择最低延迟节点: ${best_node} (${best_delay}ms)"
        else
            warn "策略组 [${group}] 没有可用测速节点，保留原配置"
        fi
    done <<< "$groups"
}

# ============== 配置 Shell 快捷命令 ==============
setup_shell_aliases() {
    detect_shell_rc

    local api_secret
    api_secret="${CLASH_SECRET}"

    # 定义要写入的函数块
    local MARKER_START="# >>> quick-clash >>>"
    local MARKER_END="# <<< quick-clash <<<"

    # 先移除旧的配置
    if [[ -f "$SHELL_RC" ]]; then
        sed -i "/${MARKER_START}/,/${MARKER_END}/d" "$SHELL_RC"
    fi

    cat >> "$SHELL_RC" <<'ALIASES_START'
# >>> quick-clash >>>
# Clash 代理快捷命令 (由 quick-clash.sh 自动生成)

# 代理开启
proxy_on() {
    export http_proxy="http://127.0.0.1:7890"
    export https_proxy="http://127.0.0.1:7890"
    export all_proxy="socks5://127.0.0.1:7891"
    export HTTP_PROXY="http://127.0.0.1:7890"
    export HTTPS_PROXY="http://127.0.0.1:7890"
    export ALL_PROXY="socks5://127.0.0.1:7891"
    export no_proxy="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    export NO_PROXY="$no_proxy"
    echo -e "\033[0;32m[✓] 代理已开启\033[0m"
    echo "  HTTP  代理: http://127.0.0.1:7890"
    echo "  SOCKS 代理: socks5://127.0.0.1:7891"
    curl -sS --connect-timeout 5 --max-time 10 https://ipinfo.io/json 2>/dev/null | \
        jq -r '"  当前 IP: \(.ip) (\(.city), \(.country))"' 2>/dev/null || true
}

# 代理关闭
proxy_off() {
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
    echo -e "\033[0;31m[✗] 代理已关闭\033[0m"
    curl -sS --connect-timeout 5 --max-time 10 https://ipinfo.io/json 2>/dev/null | \
        jq -r '"  当前 IP: \(.ip) (\(.city), \(.country))"' 2>/dev/null || true
}

# 查看代理状态
proxy_status() {
    if [[ -n "${http_proxy:-}" ]]; then
        echo -e "\033[0;32m[✓] 代理已开启\033[0m (${http_proxy})"
    else
        echo -e "\033[0;31m[✗] 代理未开启\033[0m"
    fi
}

# 读取 Clash API Secret
_clash_secret() {
    cat /etc/clash/.api_secret 2>/dev/null || echo ""
}

# Clash API 请求封装
_clash_api() {
    local method="${1:-GET}"
    local path="$2"
    local data="${3:-}"
    local secret
    secret=$(_clash_secret)
    local auth_header=""
    if [[ -n "$secret" ]]; then
        auth_header="Authorization: Bearer ${secret}"
    fi
    if [[ "$method" == "GET" ]]; then
        curl -sS -H "$auth_header" "http://127.0.0.1:9090${path}" 2>/dev/null
    else
        curl -sS -X "$method" -H "$auth_header" -H "Content-Type: application/json" \
            -d "$data" "http://127.0.0.1:9090${path}" 2>/dev/null
    fi
}

# 查看所有代理组和节点
clash_nodes() {
    echo -e "\033[1;36m━━━━━━━━━━━━━━━ Clash 节点列表 ━━━━━━━━━━━━━━━\033[0m"
    local response
    response=$(_clash_api GET /proxies)

    if [[ -z "$response" ]]; then
        echo -e "\033[0;31mClash API 无响应，请检查服务是否运行\033[0m"
        return 1
    fi

    # 获取所有 Selector 类型的组
    echo "$response" | jq -r '
        .proxies | to_entries[] |
        select(.value.type == "Selector" or .value.type == "URLTest" or .value.type == "Fallback") |
        "\n\033[1;33m▸ \(.key)\033[0m (类型: \(.value.type), 当前: \033[0;32m\(.value.now // "自动")\033[0m)\n" +
        (
            [.value.all[]? // empty] |
            to_entries[] |
            "    \(.key + 1). \(.value)"
        )
    ' 2>/dev/null || echo "$response" | jq -r '
        .proxies | to_entries[] |
        select(.value.type == "Selector" or .value.type == "URLTest" or .value.type == "Fallback") |
        .key + " => " + (.value.now // "auto")
    ' 2>/dev/null

    echo -e "\n\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "使用 \033[1mclash_select <组名> <节点名>\033[0m 切换节点"
    echo -e "使用 \033[1mclash_test <组名>\033[0m 测试延迟"
}

# 测试节点延迟
clash_test() {
    local group="${1:-}"
    local test_url="https://www.gstatic.com/generate_204"
    local timeout=5000

    if [[ -z "$group" ]]; then
        # 列出可用的组
        echo -e "\033[1;36m可用代理组:\033[0m"
        _clash_api GET /proxies | jq -r '
            .proxies | to_entries[] |
            select(.value.type == "Selector" or .value.type == "URLTest" or .value.type == "Fallback") |
            "  • \(.key)"
        ' 2>/dev/null
        echo ""
        echo "用法: clash_test <组名>"
        echo "例如: clash_test PROXY"
        return 0
    fi

    echo -e "\033[1;36m测试 [${group}] 组节点延迟...\033[0m\n"

    local group_encoded
    group_encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${group}'))" 2>/dev/null || echo "$group")

    # 获取组内节点列表
    local group_info
    group_info=$(_clash_api GET "/proxies/${group_encoded}")
    local nodes
    nodes=$(echo "$group_info" | jq -r '.all[]? // empty' 2>/dev/null)

    if [[ -z "$nodes" ]]; then
        echo "该组没有找到节点或组名不正确"
        return 1
    fi

    # 逐个测试延迟
    printf "%-50s %s\n" "节点" "延迟"
    echo "────────────────────────────────────────────────────────────"

    while IFS= read -r node; do
        local node_encoded
        node_encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${node}'))" 2>/dev/null || echo "$node")

        local delay_result
        delay_result=$(_clash_api GET "/proxies/${node_encoded}/delay?timeout=${timeout}&url=${test_url}")
        local delay
        delay=$(echo "$delay_result" | jq -r '.delay // "timeout"' 2>/dev/null || echo "error")

        if [[ "$delay" == "timeout" || "$delay" == "error" || "$delay" == "null" ]]; then
            printf "%-50s \033[0;31m%s\033[0m\n" "$node" "超时"
        elif [[ "$delay" -lt 200 ]] 2>/dev/null; then
            printf "%-50s \033[0;32m%sms\033[0m\n" "$node" "$delay"
        elif [[ "$delay" -lt 500 ]] 2>/dev/null; then
            printf "%-50s \033[1;33m%sms\033[0m\n" "$node" "$delay"
        else
            printf "%-50s \033[0;31m%sms\033[0m\n" "$node" "$delay"
        fi
    done <<< "$nodes"
}

# 选择节点
clash_select() {
    local group="${1:-}"
    local node="${2:-}"

    if [[ -z "$group" || -z "$node" ]]; then
        echo "用法: clash_select <组名> <节点名>"
        echo "例如: clash_select PROXY '香港01'"
        echo ""
        echo -e "\033[1;36m可用代理组:\033[0m"
        _clash_api GET /proxies | jq -r '
            .proxies | to_entries[] |
            select(.value.type == "Selector") |
            "  • \(.key) (当前: \(.value.now // "无"))"
        ' 2>/dev/null
        return 0
    fi

    local group_encoded
    group_encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${group}'))" 2>/dev/null || echo "$group")

    local result
    result=$(_clash_api PUT "/proxies/${group_encoded}" "{\"name\":\"${node}\"}")

    if [[ -z "$result" ]]; then
        echo -e "\033[0;32m[✓] 已切换 [${group}] => ${node}\033[0m"
    else
        echo -e "\033[0;31m[✗] 切换失败: ${result}\033[0m"
    fi
}

# 交互式选择节点
clash_choose() {
    local group="${1:-}"

    if [[ -z "$group" ]]; then
        echo -e "\033[1;36m可用代理组:\033[0m"
        local groups
        groups=$(_clash_api GET /proxies | jq -r '
            .proxies | to_entries[] |
            select(.value.type == "Selector") |
            .key
        ' 2>/dev/null)

        if [[ -z "$groups" ]]; then
            echo "没有找到可用的代理组"
            return 1
        fi

        local i=1
        while IFS= read -r g; do
            echo "  ${i}. ${g}"
            i=$((i + 1))
        done <<< "$groups"

        echo ""
        read -rp "选择代理组编号: " group_num
        group=$(echo "$groups" | sed -n "${group_num}p")

        if [[ -z "$group" ]]; then
            echo "无效选择"
            return 1
        fi
    fi

    echo -e "\n\033[1;33m▸ ${group}\033[0m 的节点列表:"

    local group_encoded
    group_encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${group}'))" 2>/dev/null || echo "$group")

    local group_info
    group_info=$(_clash_api GET "/proxies/${group_encoded}")
    local current
    current=$(echo "$group_info" | jq -r '.now // "无"' 2>/dev/null)
    local nodes
    nodes=$(echo "$group_info" | jq -r '.all[]? // empty' 2>/dev/null)

    if [[ -z "$nodes" ]]; then
        echo "没有找到节点"
        return 1
    fi

    echo -e "当前节点: \033[0;32m${current}\033[0m\n"

    local i=1
    while IFS= read -r node; do
        if [[ "$node" == "$current" ]]; then
            echo -e "  \033[0;32m${i}. ${node} ◄ 当前\033[0m"
        else
            echo "  ${i}. ${node}"
        fi
        i=$((i + 1))
    done <<< "$nodes"

    echo ""
    read -rp "选择节点编号 (回车取消): " node_num

    if [[ -z "$node_num" ]]; then
        echo "已取消"
        return 0
    fi

    local selected
    selected=$(echo "$nodes" | sed -n "${node_num}p")

    if [[ -z "$selected" ]]; then
        echo "无效选择"
        return 1
    fi

    clash_select "$group" "$selected"
}

# 更新订阅
clash_update() {
    local sub_url="${1:-}"

    if [[ -z "$sub_url" ]]; then
        # 尝试读取保存的订阅地址
        if [[ -f /etc/clash/.subscription_url ]]; then
            sub_url=$(cat /etc/clash/.subscription_url)
            echo "使用保存的订阅地址进行更新..."
        else
            echo "用法: clash_update <订阅地址>"
            return 1
        fi
    fi

    echo "正在转换订阅..."

    local json_config="{\"clashType\":2,\"subscriptions\":[\"${sub_url}\"],\"autoTest\":true,\"useUDP\":true}"
    local encoded_config
    encoded_config=$(echo -n "$json_config" | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '=' || \
                     echo -n "$json_config" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')

    local convert_url="https://clash.nite07.com/convert/${encoded_config}"
    echo "正在下载转换结果..."
    local tmp
    tmp=$(mktemp)
    if ! curl -fL --connect-timeout 15 --max-time 120 --retry 0 --progress-bar -o "$tmp" "$convert_url"; then
        rm -f "$tmp"
        echo -e "\033[0;31m订阅转换失败\033[0m"
        return 1
    fi

    python3 -c '
import re, sys
data = open(sys.argv[1], "rb").read()
if data.startswith(b"\xef\xbb\xbf"):
    data = data[3:]
text = data.decode("utf-8", errors="replace")
text = text.replace("\r\n", "\n").replace("\r", "\n")
text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)
head = text.lstrip()[:400]
if not text.strip():
    sys.exit(2)
if head.startswith("{") and ("error" in head.lower() or "message" in head.lower()):
    sys.exit(3)
if head.startswith("<"):
    sys.exit(4)
open(sys.argv[1], "w", encoding="utf-8").write(text if text.endswith("\n") else text + "\n")
' "$tmp"
    local py_rc=$?
    if [[ $py_rc -ne 0 ]]; then
        rm -f "$tmp"
        echo -e "\033[0;31m订阅转换结果无效\033[0m"
        return 1
    fi

    sudo cp /etc/clash/config.yaml "/etc/clash/config.yaml.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    local secret
    secret=$(cat /etc/clash/.api_secret 2>/dev/null || echo "")
    secret="${secret//$'\r'/}"

    local ui_line=""
    if [[ -f /opt/clash/ui/index.html ]]; then
        ui_line="external-ui: /opt/clash/ui"
    fi

    sudo tee /etc/clash/config.yaml > /dev/null <<HEADER
# Quick-Clash 自动生成配置
# 更新时间: $(date '+%Y-%m-%d %H:%M:%S')
# 订阅地址: ${sub_url}

port: 7890
socks-port: 7891
allow-lan: true
bind-address: '*'
mode: rule
log-level: info
ipv6: false
external-controller: 0.0.0.0:9090
${ui_line}
secret: "${secret}"
geodata-mode: true
geo-auto-update: true
geox-url:
  geoip: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
  geosite: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
  mmdb: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"

HEADER

    python3 -c '
import re, sys
data = open(sys.argv[1], "rb").read()
text = data.decode("utf-8", errors="replace")
skip = re.compile(
    r"^(port|socks-port|redir-port|tproxy-port|mixed-port|allow-lan|bind-address|"
    r"mode|log-level|ipv6|external-controller|external-ui|external-ui-name|"
    r"secret|authentication)\s*:",
    re.I,
)
lines = []
for line in text.split("\n"):
    if line.strip() == "---":
        continue
    if skip.match(line):
        continue
    lines.append(line)
while lines and lines[-1] == "":
    lines.pop()
sys.stdout.write("\n".join(lines) + "\n")
' "$tmp" | sudo tee -a /etc/clash/config.yaml > /dev/null
    rm -f "$tmp"

    echo "$sub_url" | sudo tee /etc/clash/.subscription_url > /dev/null

    # 重启服务
    sudo systemctl restart clash
    sleep 2

    if systemctl is-active --quiet clash; then
        echo -e "\033[0;32m[✓] 订阅更新成功，Clash 已重启\033[0m"
    else
        echo -e "\033[0;31m[✗] Clash 重启失败，请检查配置\033[0m"
    fi
}

# Clash 服务管理
clash_status() {
    if [[ ! -f /etc/systemd/system/clash.service ]]; then
        echo -e "\033[0;31mClash 服务未安装\033[0m"
        return 1
    fi
    # systemctl status 在服务失败时也会返回非 0，不能当成「未安装」
    systemctl status clash --no-pager || true
    if systemctl is-active --quiet clash; then
        return 0
    fi
    echo ""
    echo -e "\033[0;31mClash 已安装，但进程在反复退出，所以 API 无响应。最近日志:\033[0m"
    journalctl -u clash -n 30 --no-pager --no-hostname 2>/dev/null || true
    if [[ -x /opt/clash/mihomo ]]; then
        echo ""
        echo -e "\033[1;33m配置校验:\033[0m"
        /opt/clash/mihomo -t -d /etc/clash || true
    fi
    return 1
}

clash_restart() {
    sudo systemctl restart clash
    sleep 2
    if systemctl is-active --quiet clash; then
        echo -e "\033[0;32m[✓] Clash 已重启\033[0m"
    else
        echo -e "\033[0;31m[✗] Clash 重启失败\033[0m"
    fi
}

clash_log() {
    sudo journalctl -u clash -n "${1:-50}" --no-pager
}

clash_ui() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    local secret
    secret=$(cat /etc/clash/.api_secret 2>/dev/null || echo "")
    echo -e "\033[1;36m━━━━━━━━━ Clash Web UI ━━━━━━━━━\033[0m"
    echo -e "  本地访问: \033[1mhttp://127.0.0.1:9090/ui\033[0m"
    echo -e "  局域网:   \033[1mhttp://${ip}:9090/ui\033[0m"
    echo -e "  API 地址: \033[1mhttp://${ip}:9090\033[0m"
    echo -e "  Secret:   \033[1m${secret}\033[0m"
    echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo ""
    echo "你也可以使用在线面板:"
    echo "  https://metacubexd.pages.dev"
    echo "  https://d.metacubex.one"
    echo "  然后填入 API 地址和 Secret 即可连接"
}

# <<< quick-clash <<<
ALIASES_START

    # 修正文件权限
    local real_user="${SUDO_USER:-$USER}"
    chown "${real_user}:${real_user}" "$SHELL_RC" 2>/dev/null || true

    info "Shell 快捷命令已添加到 ${SHELL_RC}"
}

# ============== 卸载 ==============
uninstall() {
    warn "正在卸载 Quick-Clash..."

    systemctl stop clash 2>/dev/null || true
    systemctl disable clash 2>/dev/null || true
    rm -f /etc/systemd/system/clash.service
    systemctl daemon-reload

    rm -rf "${CLASH_DIR}"
    rm -rf "${CLASH_CONFIG_DIR}"

    # 清理 shell 配置
    detect_shell_rc
    if [[ -f "$SHELL_RC" ]]; then
        sed -i '/# >>> quick-clash >>>/,/# <<< quick-clash <<</d' "$SHELL_RC"
    fi

    info "Quick-Clash 已卸载"
}

# ============== 主流程 ==============
main() {
    echo -e "${BOLD}${CYAN}"
    cat << 'BANNER'
   ____        _      _         ____ _           _
  / __ \      (_)    | |       / ___| |         | |
 | |  | |_   _ _  ___| | __  | |   | | __ _ ___| |__
 | |  | | | | | |/ __| |/ /  | |   | |/ _` / __| '_ \
 | |__| | |_| | | (__|   <   | |___| | (_| \__ \ | | |
  \___\_\\__,_|_|\___|_|\_\   \____|_|\__,_|___/_| |_|

BANNER
    echo -e "${NC}"
    echo -e "${BOLD}  Ubuntu 一键 Clash.Meta 代理部署工具${NC}"
    echo -e "  基于 mihomo + metacubexd + sub2clash"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # 处理参数
    case "${1:-}" in
        uninstall|remove)
            check_root
            uninstall
            exit 0
            ;;
        repair)
            check_root
            [[ -x "${CLASH_DIR}/mihomo" ]] || error "未找到 ${CLASH_DIR}/mihomo"
            [[ -f "${CLASH_CONFIG_FILE}" ]] || error "未找到 ${CLASH_CONFIG_FILE}"
            if [[ -f "${CLASH_CONFIG_DIR}/.api_secret" ]]; then
                CLASH_SECRET=$(cat "${CLASH_CONFIG_DIR}/.api_secret")
            fi
            install_geodata
            if [[ -f "${CLASH_CONFIG_FILE}.raw" ]]; then
                local sub_url=""
                [[ -f "${CLASH_CONFIG_DIR}/.subscription_url" ]] && sub_url=$(cat "${CLASH_CONFIG_DIR}/.subscription_url")
                info "清洗本地转换结果并重建配置..."
                sanitize_yaml_file "${CLASH_CONFIG_FILE}.raw"
                write_clash_header "${CLASH_CONFIG_FILE}" "$sub_url" "${CLASH_SECRET}"
                append_converted_yaml < "${CLASH_CONFIG_FILE}.raw" >> "${CLASH_CONFIG_FILE}"
                sanitize_yaml_file "${CLASH_CONFIG_FILE}"
            else
                info "未找到 raw 备份，直接清洗现有 config.yaml..."
                sanitize_yaml_file "${CLASH_CONFIG_FILE}"
            fi
            setup_systemd
            setup_shell_aliases
            info "已重写快捷命令并尝试拉起 Clash。请执行: source ${SHELL_RC:-~/.bashrc}"
            exit 0
            ;;
        update)
            # 不需要 root 来触发更新 (函数内部用 sudo)
            echo "请在普通用户终端使用 clash_update 命令"
            exit 0
            ;;
        help|--help|-h)
            echo "用法:"
            echo "  sudo ./quick-clash.sh              — 安装/配置 (交互式)"
            echo "  sudo ./quick-clash.sh repair        — 修复服务/快捷命令（不重下订阅）"
            echo "  sudo ./quick-clash.sh uninstall     — 卸载"
            echo "  ./quick-clash.sh help               — 帮助"
            echo ""
            echo "安装后可用命令:"
            echo "  proxy_on           — 开启终端代理"
            echo "  proxy_off          — 关闭终端代理"
            echo "  proxy_status       — 查看代理状态"
            echo "  clash_nodes        — 查看节点列表"
            echo "  clash_test <组名>  — 测试节点延迟"
            echo "  clash_select <组> <节点> — 切换节点"
            echo "  clash_choose [组名]     — 交互式选择节点"
            echo "  clash_update [订阅地址] — 更新订阅"
            echo "  clash_status       — 查看 Clash 状态"
            echo "  clash_restart      — 重启 Clash"
            echo "  clash_log [行数]   — 查看日志"
            echo "  clash_ui           — 显示 Web UI 地址"
            exit 0
            ;;
    esac

    check_root

    print_step "检查并安装依赖"
    install_deps

    print_step "安装 mihomo (Clash.Meta) 内核"
    install_mihomo

    print_step "安装 metacubexd Web UI"
    install_webui

    print_step "配置订阅"
    local sub_url=""

    if [[ -n "${2:-}" ]]; then
        sub_url="$2"
    else
        echo ""
        echo -e "${YELLOW}请粘贴你的机场订阅地址:${NC}"
        echo -e "${BLUE}(支持 v2ray/clash/ss 等格式的订阅链接)${NC}"
        echo ""
        read -rp "订阅地址: " sub_url
    fi

    if [[ -z "$sub_url" ]]; then
        error "订阅地址不能为空"
    fi

    # 基本 URL 验证
    if [[ ! "$sub_url" =~ ^https?:// ]]; then
        error "无效的订阅地址，必须以 http:// 或 https:// 开头"
    fi

    print_step "转换订阅并生成配置"
    generate_config "$sub_url"

    print_step "配置服务和快捷命令"
    setup_systemd
    if wait_for_clash_api; then
        auto_select_best_nodes
    else
        warn "Clash API 未在预期时间内就绪，跳过自动选节点"
    fi
    setup_shell_aliases

    # 完成
    local local_ip
    local_ip=$(get_local_ip)

    echo ""
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━ 安装完成 ━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Clash 状态:${NC}  $(systemctl is-active clash 2>/dev/null || echo '未知')"
    echo -e "  ${BOLD}HTTP  代理:${NC}  http://127.0.0.1:${CLASH_HTTP_PORT}"
    echo -e "  ${BOLD}SOCKS 代理:${NC}  socks5://127.0.0.1:${CLASH_SOCKS_PORT}"
    echo ""
    echo -e "  ${BOLD}Web UI:${NC}"
    echo -e "    本地: ${CYAN}http://127.0.0.1:${CLASH_API_PORT}/ui${NC}"
    echo -e "    局域网: ${CYAN}http://${local_ip}:${CLASH_API_PORT}/ui${NC}"
    echo -e "    Secret: ${YELLOW}${CLASH_SECRET}${NC}"
    echo ""
    echo -e "  ${BOLD}在线面板 (填入上方 API 地址+Secret):${NC}"
    echo -e "    ${CYAN}https://metacubexd.pages.dev${NC}"
    echo -e "    ${CYAN}https://d.metacubex.one${NC}"
    echo ""
    echo -e "  ${BOLD}快捷命令:${NC}"
    echo -e "    ${GREEN}proxy_on${NC}           — 开启终端代理"
    echo -e "    ${RED}proxy_off${NC}          — 关闭终端代理"
    echo -e "    ${BLUE}clash_nodes${NC}        — 查看节点列表"
    echo -e "    ${BLUE}clash_test${NC} <组名>  — 测试节点延迟"
    echo -e "    ${BLUE}clash_choose${NC}       — 交互式选择节点"
    echo -e "    ${BLUE}clash_select${NC} <组> <节点> — 指定切换节点"
    echo -e "    ${BLUE}clash_update${NC}       — 更新订阅"
    echo -e "    ${BLUE}clash_ui${NC}           — 显示 Web UI 地址"
    echo -e "    ${BLUE}clash_status${NC}       — 查看运行状态"
    echo -e "    ${BLUE}clash_restart${NC}      — 重启 Clash"
    echo -e "    ${BLUE}clash_log${NC}          — 查看日志"
    echo ""
    echo -e "${YELLOW}  ⚠ 请重新打开终端或执行 source ${SHELL_RC} 使快捷命令生效${NC}"
    echo ""
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

main "$@"
