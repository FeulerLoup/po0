#!/usr/bin/env bash
# ============================================================================
# 转发管理脚本 (forward.sh) v1.0
# ============================================================================
# 功能：以"前置(gateway) / 中转(relay)"两种节点模式，配合"手动(manual) /
#       自动(auto)"两种运行模式，统一管理基于 nftables 的端口转发链路。
#
# 工作模型：
#   ┌──────────────┐  gateway_port    ┌─────────────┐  relay_port    ┌──────────┐
#   │ 客户端       │ ───────────────▶ │ 前置(gw)    │ ─────────────▶ │ 中转(rly)│
#   └──────────────┘                  └─────────────┘                └─────┬────┘
#                                                                          │ relay_port
#                                                                          ▼ → target_ip:target_port
#                                                                    ┌──────────┐
#                                                                    │ 业务后端 │
#                                                                    └──────────┘
#
#   - 前置(gateway)：把本机 gateway_port 转发到 relay_ip:relay_port
#   - 中转(relay)  ：把本机 relay_port  转发到 target_ip:target_port
#   - 自动模式 + 前置：定时通过 rsync 从中转节点拉取 forward.json，更新规则
#   - 自动模式 + 中转：定时把 target_host 解析为 target_ip 写回 forward.json，更新规则
#
# 使用：
#   交互式：sudo ./forward.sh
#   定时：  sudo ./forward.sh --cron     （由 cron 通过 flock 串行调用，非交互）
#   帮助：  ./forward.sh --help
#
# 依赖：bash 4+, nftables, jq, rsync, openssh, getent/dig/host (任一), flock (util-linux)
# ============================================================================

set -o pipefail

# ============== 常量定义 ==============
readonly CONFIG_DIR="/root/.forward"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly FORWARD_FILE="${CONFIG_DIR}/forward.json"
readonly SSH_KEY_FILE="${CONFIG_DIR}/forward_rsync"
readonly SSH_KNOWN_HOSTS="${CONFIG_DIR}/known_hosts"

readonly NFT_CONF_DIR="/etc/nftables.d"
readonly NFT_CONF_FILE="${NFT_CONF_DIR}/forward.conf"
readonly NFT_MAIN_CONF="/etc/nftables.conf"
readonly NFT_TABLE="port_forward"

readonly SYSCTL_CONF="/etc/sysctl.d/99-forward.conf"
readonly LOG_FILE="/var/log/forward.log"
readonly LOGROTATE_CONF="/etc/logrotate.d/forward"
readonly CRON_FILE="/etc/cron.d/forward"

# 远端 forward.json 固定存放路径与固定 SSH 用户名（约定大于配置：脚本不再让用户输入这两段）
readonly REMOTE_FORWARD_PATH="/root/.forward/forward.json"
readonly REMOTE_SSH_USER="root"

# 连通性检测超时（秒）
readonly CONNECT_TIMEOUT=3
# 远端 SSH 连接超时（秒）
readonly SSH_CONNECT_TIMEOUT=5
# rsync 整体超时（秒）
readonly RSYNC_TIMEOUT=10
# rsync/ssh 默认连接端口（用户未在 config.json 中显式指定 relay_ssh_port 时使用）
readonly DEFAULT_RELAY_SSH_PORT=22

# 解析自身路径，cron 任务安装时需要绝对路径
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH

# 是否运行在非交互（--cron）模式
NON_INTERACTIVE=0

# ============== 全局可变状态 ==============
# RULES 数组的元素格式: "本机端口|目标IP|目标端口"
declare -a RULES=()

# ============== 输出辅助 ==============
# 使用 printf 而非 echo -e，避免不同 shell 的转义差异；颜色仅在 stdout 为 TTY 时启用。
_use_color() { [[ -t 1 && -z "${NO_COLOR:-}" ]]; }
INFO() { if _use_color; then printf '\033[32m[信息]\033[0m %s\n' "$*"; else printf '[信息] %s\n' "$*"; fi; }
WARN() { if _use_color; then printf '\033[33m[警告]\033[0m %s\n' "$*"; else printf '[警告] %s\n' "$*"; fi; }
ERR()  { if _use_color; then printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; else printf '[错误] %s\n' "$*" >&2; fi; }

# 写入持久化日志，所有变更与异常均经此通道，便于排查
log_action() {
    local msg="$*"
    # 即使无法写入日志也不应阻塞主流程
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

# ============== 基础工具 ==============
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 必须 root 运行：脚本会修改 /etc 下文件、操作 nftables、安装包等
check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        ERR "此脚本需要 root 权限运行，请使用 sudo 或 root 用户。"
        exit 1
    fi
}

# 创建必要目录与日志、logrotate 配置
ensure_dirs() {
    mkdir -p "${CONFIG_DIR}" "${NFT_CONF_DIR}" 2>/dev/null || {
        ERR "无法创建目录 ${CONFIG_DIR} 或 ${NFT_CONF_DIR}，请检查权限。"
        exit 1
    }
    # 配置目录权限收紧（含 ssh 私钥）
    chmod 700 "${CONFIG_DIR}" 2>/dev/null || true
    touch "${LOG_FILE}" 2>/dev/null || true

    # 安装 logrotate 配置（避免日志无限增长）
    if [[ ! -f "${LOGROTATE_CONF}" ]]; then
        cat > "${LOGROTATE_CONF}" 2>/dev/null <<'LOGROTATE' || true
/var/log/forward.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
LOGROTATE
    fi
}

# ============== 输入验证 ==============
# 端口必须为 1-65535 且不含前导零（避免 bash 八进制歧义，如 010 会被误判）
validate_port() {
    local port="$1"
    [[ -z "$port" ]] && return 1
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" =~ ^0[0-9] ]]; then
        return 1
    fi
    if (( port < 1 || port > 65535 )); then
        return 1
    fi
    return 0
}

# IPv4 校验：四段每段 0-255，且不含前导零
validate_ip() {
    local ip="$1"
    [[ -z "$ip" ]] && return 1
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    if [[ "$ip" =~ (^|\.)0[0-9] ]]; then
        return 1
    fi
    local IFS='.' octet
    local -a octets
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if (( octet > 255 )); then
            return 1
        fi
    done
    return 0
}

# 主机名 / 域名校验（也接受 IP 形式）
# RFC 1123 简化版：标签由字母数字与连字符组成，长度<=63，总长<=253
validate_host() {
    local h="$1"
    [[ -z "$h" ]] && return 1
    [[ ${#h} -gt 253 ]] && return 1
    if validate_ip "$h"; then
        return 0
    fi
    if [[ "$h" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi
    return 1
}

# ============== 网络辅助 ==============
# 自动获取本机出口 IPv4，用于 nftables 配置中的 SNAT 回源
get_local_ip() {
    local ip=""
    ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1) || true
    if [[ -n "$ip" ]] && validate_ip "$ip"; then
        echo "$ip"; return 0
    fi
    ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1) || true
    if [[ -n "$ip" ]] && validate_ip "$ip"; then
        echo "$ip"; return 0
    fi
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    if [[ -n "$ip" ]] && validate_ip "$ip"; then
        echo "$ip"; return 0
    fi
    return 1
}

# 解析域名为 IPv4：依次尝试 getent / dig / host，任一可用即可
resolve_host_to_ip() {
    local host="$1"
    [[ -z "$host" ]] && return 1
    # 已是 IP 直接返回
    if validate_ip "$host"; then
        echo "$host"; return 0
    fi
    local ip=""
    if have_cmd getent; then
        ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '/STREAM/ {print $1; exit}')
        if [[ -z "$ip" ]]; then
            ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')
        fi
    fi
    if [[ -z "$ip" ]] && have_cmd dig; then
        ip=$(dig +short +time=3 +tries=2 A "$host" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    fi
    if [[ -z "$ip" ]] && have_cmd host; then
        ip=$(host -W 3 "$host" 2>/dev/null | awk '/has address/ {print $4; exit}')
    fi
    if [[ -n "$ip" ]] && validate_ip "$ip"; then
        echo "$ip"; return 0
    fi
    return 1
}

# 测试 TCP 连通性（带超时），用于状态展示与 cron 自检
tcp_check() {
    local ip="$1" port="$2"
    [[ -z "$ip" || -z "$port" ]] && return 1
    timeout "${CONNECT_TIMEOUT}" bash -c ">/dev/tcp/${ip}/${port}" 2>/dev/null
}

# ============== 包管理器与依赖 ==============
detect_pkg_manager() {
    if have_cmd apt-get; then echo "apt"
    elif have_cmd dnf; then echo "dnf"
    elif have_cmd yum; then echo "yum"
    elif have_cmd pacman; then echo "pacman"
    elif have_cmd zypper; then echo "zypper"
    elif have_cmd apk; then echo "apk"
    else echo "unknown"
    fi
}

# 安装依赖包列表（不同发行版命名差异由 case 内部消化）
# 必装：curl、nftables、jq（JSON 解析）、rsync、openssh-client；附带 cron 与 util-linux(flock)
install_packages() {
    local pkg_mgr="$1"
    case "$pkg_mgr" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || return 1
            apt-get install -y --no-install-recommends \
                curl nftables jq rsync openssh-client cron util-linux || return 1
            ;;
        dnf)
            dnf install -y \
                curl nftables jq rsync openssh-clients cronie util-linux || return 1
            ;;
        yum)
            yum install -y \
                curl nftables jq rsync openssh-clients cronie util-linux || return 1
            ;;
        pacman)
            pacman -Sy --noconfirm \
                curl nftables jq rsync openssh cronie util-linux || return 1
            ;;
        zypper)
            zypper --non-interactive install \
                curl nftables jq rsync openssh cronie util-linux || return 1
            ;;
        apk)
            apk add --no-cache \
                curl nftables jq rsync openssh-client dcron util-linux || return 1
            ;;
        *)
            ERR "无法识别包管理器，请手动安装: curl nftables jq rsync openssh util-linux"
            return 1
            ;;
    esac
    return 0
}

# 关键命令缺失时的友好提示（不强制中断，部分功能仍可用）
require_jq_or_warn() {
    if ! have_cmd jq; then
        ERR "缺少 jq，请先选择菜单【1) 初始化环境】安装依赖。"
        return 1
    fi
    return 0
}

# ============== 内核参数：开启 IPv4 转发 ==============
enable_ip_forward() {
    local current
    current=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) || current="0"
    if [[ "$current" != "1" ]]; then
        if sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
            INFO "已开启 IPv4 转发。"
        else
            WARN "无法即时开启 IPv4 转发，请手动执行: sysctl -w net.ipv4.ip_forward=1"
        fi
    fi
    # 持久化：先尝试 sed 替换，未命中再追加；避免重复条目以最后值生效造成的歧义
    mkdir -p "$(dirname "${SYSCTL_CONF}")" 2>/dev/null || true
    touch "${SYSCTL_CONF}" 2>/dev/null || true
    if grep -qE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' "${SYSCTL_CONF}" 2>/dev/null; then
        sed -i -E 's|^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=.*|net.ipv4.ip_forward=1|' "${SYSCTL_CONF}" 2>/dev/null || true
    else
        echo "net.ipv4.ip_forward=1" >> "${SYSCTL_CONF}" 2>/dev/null || true
    fi
    sysctl -p "${SYSCTL_CONF}" >/dev/null 2>&1 || true
}

# ============== 防火墙集成（移植自 nftables.sh） ==============
# 总览：
#   - firewalld 优先：若运行则只走 firewall-cmd（其后端可能就是 iptables，
#     直接动 iptables 会被 firewalld reload 冲掉，导致放行规则无声丢失）
#   - UFW 次之：常见于 Ubuntu，需要同时放行 INPUT 与 route(FORWARD) 两类规则
#   - 最后回退到 iptables：兼顾 INPUT(本机端口) + FORWARD(目的端口) + 回程
#     ESTABLISHED,RELATED 三类规则，并尝试持久化
#
# 共享放行回收策略：
#   FORWARD 规则按目的 (dest_ip, dport) 匹配，若多条转发指向同一目标只能保留一份；
#   删除单条转发时需借助 dest_still_used 判断是否还有其他规则共享，
#   避免错删导致其他转发瞬间断流。

# 检测 iptables 是否真正可用：命令存在 + 能读规则
has_iptables() {
    have_cmd iptables && iptables -S &>/dev/null
}

# 尝试用各种方式持久化 iptables 规则；失败不抛错（仅返回非零）
try_persist_iptables() {
    if have_cmd netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1 && return 0
    fi
    if have_cmd iptables-save; then
        if [[ -d /etc/iptables ]]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null && return 0
        elif [[ -d /etc/sysconfig ]]; then
            iptables-save > /etc/sysconfig/iptables 2>/dev/null && return 0
        fi
    fi
    if have_cmd service; then
        service iptables save >/dev/null 2>&1 && return 0
    fi
    return 1
}

# 检查 (check_ip, check_dport) 是否仍被 RULES 中其他规则使用
# 参数: $1=目标IP  $2=目标端口  $3=要排除的本机端口（即正在删除/比对的那条）
# 返回 0 表示仍被使用（不应清理 FORWARD 规则）
dest_still_used() {
    local check_ip="$1" check_dport="$2" exclude_lport="$3"
    local rule lport dip dport
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport dip dport <<< "$rule"
        [[ "$lport" == "$exclude_lport" ]] && continue
        if [[ "$dip" == "$check_ip" && "$dport" == "$check_dport" ]]; then
            return 0
        fi
    done
    return 1
}

# 针对单条转发规则在防火墙中放行
# 参数: $1=本机监听端口  $2=目标IP  $3=目标端口
firewall_open_port() {
    local lport="$1" dest_ip="$2" dport="$3"

    # firewalld 优先：检测到 firewalld 则只走它，避免与底层 iptables 同时操作
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --add-port="${lport}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --add-port="${lport}/udp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        INFO "已在 firewalld 中放行端口 ${lport} (tcp+udp)。"
        log_action "firewalld 放行端口 ${lport}"
        return
    fi

    # UFW: Ubuntu 常见
    if have_cmd ufw && ufw status 2>/dev/null | grep -qw "active"; then
        ufw allow "${lport}/tcp" >/dev/null 2>&1 || true
        ufw allow "${lport}/udp" >/dev/null 2>&1 || true
        # ufw allow 只管 INPUT，转发流量需要 route allow
        ufw route allow proto tcp to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
        ufw route allow proto udp to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
        INFO "已在 UFW 中放行端口 ${lport} 及转发到 ${dest_ip}:${dport} (tcp+udp)。"
        log_action "UFW 放行端口 ${lport} 转发到 ${dest_ip}:${dport}"
        return
    fi

    # 无 firewalld / UFW，回退到 iptables
    if has_iptables; then
        # INPUT: 放行进入本机的流量（DNAT 之前匹配的是本机 lport）
        iptables -C INPUT -p tcp --dport "${lport}" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "${lport}" -j ACCEPT 2>/dev/null || true
        iptables -C INPUT -p udp --dport "${lport}" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport "${lport}" -j ACCEPT 2>/dev/null || true
        # FORWARD: DNAT 后包的目的已改写为 dest_ip:dport，按此匹配
        iptables -C FORWARD -d "${dest_ip}" -p tcp --dport "${dport}" -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -d "${dest_ip}" -p tcp --dport "${dport}" -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -d "${dest_ip}" -p udp --dport "${dport}" -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -d "${dest_ip}" -p udp --dport "${dport}" -j ACCEPT 2>/dev/null || true
        # FORWARD: 回程已建立连接放行（DNAT 转发的标配）
        iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        INFO "已在 iptables 中放行: INPUT ${lport}, FORWARD → ${dest_ip}:${dport} (tcp+udp)。"
        log_action "iptables 放行 INPUT:${lport} FORWARD:${dest_ip}:${dport}"
        if ! try_persist_iptables; then
            WARN "iptables 规则已生效但未能自动持久化，重启后可能丢失。"
            WARN "如需持久化请安装 iptables-persistent / netfilter-persistent。"
        fi
    fi
}

# 移除单条转发对应的防火墙放行
# 参数: $1=本机监听端口  $2=目标IP  $3=目标端口  $4="force"=不检查共享，强制清理 FORWARD
firewall_close_port() {
    local lport="$1" dest_ip="$2" dport="$3" force="${4:-}"

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --remove-port="${lport}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --remove-port="${lport}/udp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        INFO "已从 firewalld 中移除端口 ${lport} 的放行规则。"
        log_action "firewalld 移除端口 ${lport}"
        return
    fi

    if have_cmd ufw && ufw status 2>/dev/null | grep -qw "active"; then
        # 用 yes 应对 ufw delete 的交互确认
        yes | ufw delete allow "${lport}/tcp" >/dev/null 2>&1 || true
        yes | ufw delete allow "${lport}/udp" >/dev/null 2>&1 || true
        # route 规则按目标匹配，仅在没有其他规则共享时才删除
        if [[ "$force" == "force" ]] || ! dest_still_used "$dest_ip" "$dport" "$lport"; then
            yes | ufw route delete allow proto tcp to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
            yes | ufw route delete allow proto udp to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
        fi
        INFO "已从 UFW 中移除端口 ${lport} 的放行规则。"
        log_action "UFW 移除端口 ${lport}"
        return
    fi

    if has_iptables; then
        # INPUT: 总是删除（lport 是唯一的）
        iptables -D INPUT -p tcp --dport "${lport}" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "${lport}" -j ACCEPT 2>/dev/null || true
        # FORWARD: 仅在没有共享同一目标的其他规则时才删除
        if [[ "$force" == "force" ]] || ! dest_still_used "$dest_ip" "$dport" "$lport"; then
            iptables -D FORWARD -d "${dest_ip}" -p tcp --dport "${dport}" -j ACCEPT 2>/dev/null || true
            iptables -D FORWARD -d "${dest_ip}" -p udp --dport "${dport}" -j ACCEPT 2>/dev/null || true
        fi
        # 注意：不删除 ESTABLISHED,RELATED 通用规则，其他转发可能仍需要
        INFO "已从 iptables 中移除: INPUT ${lport}, FORWARD → ${dest_ip}:${dport}。"
        log_action "iptables 移除 INPUT:${lport} FORWARD:${dest_ip}:${dport}"
        try_persist_iptables || true
    fi
}

# 仅提示用：检测当前活跃的防火墙
check_firewall_status() {
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        INFO "检测到 firewalld 正在运行，转发规则增删时将自动放行/回收对应端口。"
    elif have_cmd ufw && ufw status 2>/dev/null | grep -qw "active"; then
        INFO "检测到 UFW 正在运行，转发规则增删时将自动放行/回收对应端口。"
    elif has_iptables; then
        INFO "检测到 iptables 规则集存在，转发规则增删时将自动放行/回收对应端口。"
    else
        INFO "未检测到活跃的防火墙 (firewalld / UFW / iptables)。"
    fi
}

# 自动模式批量重建规则时计算新旧差集，只对增量变化操作防火墙
# 参数：第一段为旧规则数组，"--" 分隔，第二段为新规则数组
# 调用前应保证全局 RULES 已经是“新规则”，以便 firewall_close_port 中
# dest_still_used 能正确判断 FORWARD 规则是否仍被其他转发共享。
apply_firewall_diff() {
    local -a old_arr=() new_arr=()
    local mode="old" arg
    for arg in "$@"; do
        if [[ "$arg" == "--" ]]; then
            mode="new"; continue
        fi
        if [[ "$mode" == "old" ]]; then
            old_arr+=("$arg")
        else
            new_arr+=("$arg")
        fi
    done

    # 用关联数组做集合，O(1) 查找；rule 字符串本身就是天然的唯一键
    declare -A old_set new_set
    local r
    for r in "${old_arr[@]}"; do old_set["$r"]=1; done
    for r in "${new_arr[@]}"; do new_set["$r"]=1; done

    # 1) 已删除：旧有但新无 → 关闭防火墙
    local lport dip dport
    for r in "${old_arr[@]}"; do
        if [[ -z "${new_set[$r]:-}" ]]; then
            IFS='|' read -r lport dip dport <<< "$r"
            firewall_close_port "$lport" "$dip" "$dport"
        fi
    done

    # 2) 新增：新有但旧无 → 放行
    for r in "${new_arr[@]}"; do
        if [[ -z "${old_set[$r]:-}" ]]; then
            IFS='|' read -r lport dip dport <<< "$r"
            firewall_open_port "$lport" "$dip" "$dport"
        fi
    done
}

# ============== 本地配置文件 (config.json) ==============
# 初始化为合法空对象；保留已有配置原样
init_config_file() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo '{}' > "${CONFIG_FILE}" || {
            ERR "无法初始化 ${CONFIG_FILE}"
            return 1
        }
        chmod 600 "${CONFIG_FILE}" 2>/dev/null || true
    fi
    # 损坏自愈：若不是合法 JSON，备份后重置，避免后续 jq 整体崩溃
    if have_cmd jq && ! jq -e . "${CONFIG_FILE}" >/dev/null 2>&1; then
        local ts
        ts=$(date '+%Y%m%d_%H%M%S')
        WARN "${CONFIG_FILE} 不是合法 JSON，已备份为 ${CONFIG_FILE}.broken.${ts}"
        mv "${CONFIG_FILE}" "${CONFIG_FILE}.broken.${ts}" 2>/dev/null || true
        echo '{}' > "${CONFIG_FILE}"
        chmod 600 "${CONFIG_FILE}" 2>/dev/null || true
    fi
    return 0
}

# 读取顶层字段（不存在或解析失败均返回空字符串）
get_config_value() {
    local key="$1"
    [[ -f "${CONFIG_FILE}" ]] || { echo ""; return 0; }
    have_cmd jq || { echo ""; return 0; }
    jq -r --arg k "$key" '.[$k] // empty' "${CONFIG_FILE}" 2>/dev/null || echo ""
}

# 写入/更新顶层字段；空值则删除该字段。原子写避免半截文件
set_config_value() {
    local key="$1" value="$2"
    require_jq_or_warn || return 1
    init_config_file || return 1
    local tmp
    tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || { ERR "无法创建临时文件"; return 1; }
    if [[ -z "$value" ]]; then
        jq --arg k "$key" 'del(.[$k])' "${CONFIG_FILE}" > "$tmp" 2>/dev/null || {
            rm -f "$tmp"; ERR "更新配置失败"; return 1
        }
    else
        jq --arg k "$key" --arg v "$value" '.[$k] = $v' "${CONFIG_FILE}" > "$tmp" 2>/dev/null || {
            rm -f "$tmp"; ERR "更新配置失败"; return 1
        }
    fi
    mv -f "$tmp" "${CONFIG_FILE}" || { rm -f "$tmp"; return 1; }
    chmod 600 "${CONFIG_FILE}" 2>/dev/null || true
    return 0
}

# ============== 中转节点连接信息（仅 gateway 端使用） ==============
# 多 relay 模型：config.json 顶层 `relays` 数组，每个元素形如：
#   { "relay_host": "...", "relay_ip": "...", "relay_ssh_port": "2222" }
#   - relay_host / relay_ip 二选一互斥
#   - relay_ssh_port 缺省或非法 → DEFAULT_RELAY_SSH_PORT (22)
#
# rsync 路径固定按 ${REMOTE_SSH_USER}@<host_or_ip>:${REMOTE_FORWARD_PATH} 拼接，
# 用户只需为每个中转输入「地址 + 端口」。
#
# gateway 端聚合策略：
#   - 周期性从所有 relay 拉取各自的 forward.json
#   - 给每条 forward 打上 _source 元字段（来源 relay 地址，便于诊断）
#   - 按 gateway_port 去重，多 relay 间冲突时保留 jq unique_by 的稳定结果

# 取 relays 数组长度
get_relays_count() {
    [[ -f "${CONFIG_FILE}" ]] || { echo 0; return; }
    have_cmd jq || { echo 0; return; }
    jq '(.relays // []) | length' "${CONFIG_FILE}" 2>/dev/null || echo 0
}

# 读取第 idx 个 relay 的某个字段值（不存在时输出空串）
get_relay_field_at() {
    local idx="$1" field="$2"
    [[ -f "${CONFIG_FILE}" ]] || return 1
    have_cmd jq || return 1
    jq -r --argjson i "$idx" --arg f "$field" \
        '(.relays // [])[$i][$f] // empty' "${CONFIG_FILE}" 2>/dev/null
}

# 第 idx 个 relay 的实际"中转地址"：优先 relay_host
get_relay_addr_at() {
    local idx="$1" rh ri
    rh=$(get_relay_field_at "$idx" relay_host)
    ri=$(get_relay_field_at "$idx" relay_ip)
    if   [[ -n "$rh" ]]; then echo "$rh"
    elif [[ -n "$ri" ]]; then echo "$ri"
    else echo ""
    fi
}

# 第 idx 个 relay 的 SSH 端口（缺失/非法回退默认 22）
get_relay_ssh_port_at() {
    local idx="$1" v
    v=$(get_relay_field_at "$idx" relay_ssh_port)
    if validate_port "$v"; then echo "$v"
    else echo "${DEFAULT_RELAY_SSH_PORT}"
    fi
}

# 是否已存在指定地址的 relay（host 或 ip 字面匹配）
relay_addr_exists() {
    local addr="$1"
    [[ -z "$addr" ]] && return 1
    local total i cur
    total=$(get_relays_count)
    for ((i=0; i<total; i++)); do
        cur=$(get_relay_addr_at "$i")
        if [[ "$cur" == "$addr" ]]; then
            return 0
        fi
    done
    return 1
}

# 追加一个 relay 到 config.json
# 参数：host(可空)  ip(可空)  port(可空，等于默认时不写入字段)
add_relay_to_config() {
    local host="$1" ip="$2" port="$3"
    require_jq_or_warn || return 1
    init_config_file || return 1
    local persist_port="$port"
    if [[ "$port" == "${DEFAULT_RELAY_SSH_PORT}" ]]; then
        persist_port=""
    fi
    local tmp
    tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || return 1
    jq --arg h "$host" --arg i "$ip" --arg p "$persist_port" \
        '.relays = ((.relays // []) + [{relay_host:$h, relay_ip:$i, relay_ssh_port:$p}])' \
        "${CONFIG_FILE}" > "$tmp" 2>/dev/null || {
        rm -f "$tmp"; ERR "写入 relays 失败"; return 1
    }
    mv -f "$tmp" "${CONFIG_FILE}" || { rm -f "$tmp"; return 1; }
    chmod 600 "${CONFIG_FILE}" 2>/dev/null || true
}

# 移除第 idx 个 relay
remove_relay_from_config() {
    local idx="$1"
    require_jq_or_warn || return 1
    init_config_file || return 1
    local total
    total=$(get_relays_count)
    if (( idx < 0 || idx >= total )); then
        ERR "下标越界: ${idx} (合法范围 0..$((total-1)))"
        return 1
    fi
    local tmp
    tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || return 1
    jq --argjson i "$idx" '.relays = ((.relays // []) | del(.[$i]))' \
        "${CONFIG_FILE}" > "$tmp" 2>/dev/null || {
        rm -f "$tmp"; ERR "删除 relay 失败"; return 1
    }
    mv -f "$tmp" "${CONFIG_FILE}" || { rm -f "$tmp"; return 1; }
    chmod 600 "${CONFIG_FILE}" 2>/dev/null || true
}

# ============== 转发配置文件 (forward.json) ==============
# 初始化为 {"forwards": []}；损坏文件备份并重建
init_forward_file() {
    if [[ ! -f "${FORWARD_FILE}" ]]; then
        echo '{"forwards":[]}' > "${FORWARD_FILE}" || return 1
        chmod 600 "${FORWARD_FILE}" 2>/dev/null || true
    fi
    if have_cmd jq && ! jq -e '.forwards | type == "array"' "${FORWARD_FILE}" >/dev/null 2>&1; then
        local ts
        ts=$(date '+%Y%m%d_%H%M%S')
        WARN "${FORWARD_FILE} 结构不合法，已备份为 ${FORWARD_FILE}.broken.${ts}"
        mv "${FORWARD_FILE}" "${FORWARD_FILE}.broken.${ts}" 2>/dev/null || true
        echo '{"forwards":[]}' > "${FORWARD_FILE}"
        chmod 600 "${FORWARD_FILE}" 2>/dev/null || true
    fi
    return 0
}

forward_count() {
    init_forward_file >/dev/null 2>&1 || { echo 0; return; }
    have_cmd jq || { echo 0; return; }
    jq '.forwards | length' "${FORWARD_FILE}" 2>/dev/null || echo 0
}

# 通过名称查重：避免重名导致后续删除/编辑歧义
forward_name_exists() {
    local name="$1"
    init_forward_file >/dev/null 2>&1 || return 1
    have_cmd jq || return 1
    local found
    found=$(jq -r --arg n "$name" '.forwards[] | select(.name == $n) | .name' "${FORWARD_FILE}" 2>/dev/null | head -1)
    [[ -n "$found" ]]
}

# 通过 gateway_port 查重：同一前置端口指向不同目标会冲突
forward_gateway_port_exists() {
    local port="$1"
    init_forward_file >/dev/null 2>&1 || return 1
    have_cmd jq || return 1
    local found
    found=$(jq -r --arg p "$port" '.forwards[] | select((.gateway_port|tostring) == $p) | .name' "${FORWARD_FILE}" 2>/dev/null | head -1)
    [[ -n "$found" ]]
}

# 追加一条转发；写临时文件再原子替换
# 参数顺序: name gateway_port relay_host relay_ip relay_port target_host target_ip target_port
# relay_host / relay_ip 二选一即可，另一个传空串
forward_add_entry() {
    local name="$1" gw_port="$2" relay_host="$3" relay_ip="$4" relay_port="$5" \
          target_host="$6" target_ip="$7" target_port="$8"
    require_jq_or_warn || return 1
    init_forward_file || return 1
    local tmp
    tmp=$(mktemp "${FORWARD_FILE}.XXXXXX") || return 1
    jq --arg name "$name" \
       --argjson gp "$gw_port" \
       --arg rh "$relay_host" \
       --arg rip "$relay_ip" \
       --argjson rp "$relay_port" \
       --arg th "$target_host" \
       --arg ti "$target_ip" \
       --argjson tp "$target_port" \
       '.forwards += [{name:$name, gateway_port:$gp, relay_host:$rh, relay_ip:$rip, relay_port:$rp, target_host:$th, target_ip:$ti, target_port:$tp}]' \
       "${FORWARD_FILE}" > "$tmp" 2>/dev/null || {
        rm -f "$tmp"; ERR "写入转发配置失败"; return 1
    }
    mv -f "$tmp" "${FORWARD_FILE}" || { rm -f "$tmp"; return 1; }
    chmod 600 "${FORWARD_FILE}" 2>/dev/null || true
    return 0
}

# 删除指定下标的转发（0 起始）
forward_remove_index() {
    local idx="$1"
    require_jq_or_warn || return 1
    init_forward_file || return 1
    local total
    total=$(forward_count)
    if (( idx < 0 || idx >= total )); then
        ERR "下标越界: ${idx} (合法范围 0..$((total-1)))"
        return 1
    fi
    local tmp
    tmp=$(mktemp "${FORWARD_FILE}.XXXXXX") || return 1
    jq --argjson i "$idx" 'del(.forwards[$i])' "${FORWARD_FILE}" > "$tmp" 2>/dev/null || {
        rm -f "$tmp"; ERR "删除转发失败"; return 1
    }
    mv -f "$tmp" "${FORWARD_FILE}" || { rm -f "$tmp"; return 1; }
    chmod 600 "${FORWARD_FILE}" 2>/dev/null || true
    return 0
}

# 更新指定下标转发的 target_ip
forward_set_target_ip() {
    local idx="$1" ip="$2"
    require_jq_or_warn || return 1
    init_forward_file || return 1
    local tmp
    tmp=$(mktemp "${FORWARD_FILE}.XXXXXX") || return 1
    jq --argjson i "$idx" --arg v "$ip" '.forwards[$i].target_ip = $v' "${FORWARD_FILE}" > "$tmp" 2>/dev/null || {
        rm -f "$tmp"; return 1
    }
    mv -f "$tmp" "${FORWARD_FILE}" || { rm -f "$tmp"; return 1; }
    chmod 600 "${FORWARD_FILE}" 2>/dev/null || true
    return 0
}

# ============== nftables 配置生成 / 加载 ==============
# 主配置存在 + include 我们的目录，确保 nftables 服务启动时自动加载
ensure_nft_main_conf() {
    if [[ ! -f "${NFT_MAIN_CONF}" ]]; then
        cat > "${NFT_MAIN_CONF}" <<'NFTCONF'
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/*.conf"
NFTCONF
        INFO "已创建 ${NFT_MAIN_CONF}（系统中原本不存在）。"
        log_action "创建 ${NFT_MAIN_CONF}"
    elif ! grep -qF 'include "/etc/nftables.d/*.conf"' "${NFT_MAIN_CONF}" 2>/dev/null; then
        echo 'include "/etc/nftables.d/*.conf"' >> "${NFT_MAIN_CONF}"
        INFO "已在 ${NFT_MAIN_CONF} 末尾追加 include 指令。"
        log_action "在 ${NFT_MAIN_CONF} 中追加 include 指令"
    fi
}

# 备份当前 nftables 配置文件（带时间戳，最多保留近 10 份）
backup_nft_conf() {
    [[ -f "${NFT_CONF_FILE}" ]] || return 0
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="${NFT_CONF_DIR}/backups"
    mkdir -p "${backup_dir}" 2>/dev/null || return 0
    cp "${NFT_CONF_FILE}" "${backup_dir}/forward.conf.${ts}" 2>/dev/null || true
    # 仅保留最新 10 份
    ls -1t "${backup_dir}"/forward.conf.* 2>/dev/null | tail -n +11 | xargs -r rm -f 2>/dev/null || true
}

# 根据当前 RULES 数组写出 nft 配置
# nft 表结构：
#   - prerouting (priority -100): DNAT 入站
#   - postrouting (priority 100): 仅对 DNAT 后的流量做 SNAT 回源，避免回包绕过本机
write_nft_conf() {
    local local_ip
    if ! local_ip=$(get_local_ip); then
        ERR "无法获取本机 IP，请检查网络配置后重试。"
        return 1
    fi

    local tmp="${NFT_CONF_FILE}.tmp.$$"

    {
        cat <<EOF
#!/usr/sbin/nft -f
# 由 forward.sh 自动生成，请勿手工修改
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# --- 本机 IP（自动获取，用于 SNAT 回源，避免目标机回包绕过本机） ---
define LOCAL_IP = ${local_ip}

table ip ${NFT_TABLE} {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
EOF

        local rule lport dip dport
        for rule in "${RULES[@]}"; do
            IFS='|' read -r lport dip dport <<< "$rule"
            cat <<EOF

        # 转发: 本机:${lport} -> ${dip}:${dport}
        tcp dport ${lport} dnat to ${dip}:${dport}
        udp dport ${lport} dnat to ${dip}:${dport}
EOF
        done

        cat <<EOF
    }

    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
EOF

        for rule in "${RULES[@]}"; do
            IFS='|' read -r lport dip dport <<< "$rule"
            cat <<EOF

        # 回源: 发往 ${dip}:${dport} 的已 DNAT 流量, SNAT 为本机 IP
        ip daddr ${dip} tcp dport ${dport} ct status dnat snat to \$LOCAL_IP
        ip daddr ${dip} udp dport ${dport} ct status dnat snat to \$LOCAL_IP
EOF
        done

        cat <<'EOF'
    }
}
EOF
    } > "${tmp}" || { rm -f "${tmp}"; ERR "写入临时配置失败"; return 1; }

    mv -f "${tmp}" "${NFT_CONF_FILE}" || { rm -f "${tmp}"; ERR "替换配置文件失败"; return 1; }
    return 0
}

# 重新加载我们这张表的规则（只 flush 自己的 table，避免影响其他业务规则）
reload_nft_rules() {
    if ! have_cmd nft; then
        ERR "未安装 nftables，请先选择【初始化环境】。"
        return 1
    fi
    nft flush table ip "${NFT_TABLE}" 2>/dev/null || true
    nft delete table ip "${NFT_TABLE}" 2>/dev/null || true
    if [[ ! -f "${NFT_CONF_FILE}" ]]; then
        return 0
    fi
    if ! nft -f "${NFT_CONF_FILE}" 2>/dev/null; then
        # 单独跑一次产生标准错误供用户排查
        ERR "加载 ${NFT_CONF_FILE} 失败，错误详情如下："
        nft -f "${NFT_CONF_FILE}" || true
        return 1
    fi
    return 0
}

# 从已写出的 nft 配置文件解析当前生效规则
# 由于 tcp / udp 成对生成，按 tcp 行解析即可避免重复
load_running_rules() {
    RULES=()
    [[ -f "${NFT_CONF_FILE}" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ tcp\ dport\ ([0-9]+)\ dnat\ to\ ([0-9.]+):([0-9]+) ]]; then
            RULES+=("${BASH_REMATCH[1]}|${BASH_REMATCH[2]}|${BASH_REMATCH[3]}")
        fi
    done < "${NFT_CONF_FILE}"
}

# ============== 业务：基于 forward.json 构建 RULES ==============
# 参数: $1 = node_mode (gateway|relay)
# 纯函数：仅构建 RULES，不做任何变化检测/缓存写入。
# 目标 IP 变化（含 relay_host 解析结果变更）由 update_rules_from_config
# 比对 nft 中"上一轮已生效规则"的 lport->dip 映射来检测。
build_rules_from_forward() {
    local node_mode="$1"
    RULES=()
    require_jq_or_warn || return 1
    init_forward_file || return 1

    local lport dip dport seen_ports=""

    case "$node_mode" in
        gateway)
            # 前置：本机 gateway_port -> 目标 IP:relay_port
            #   - 若条目含 relay_host：每次实时解析得 IP（不缓存）
            #   - 否则使用 relay_ip 字面值
            local total i rh rip rp eff_ip
            total=$(forward_count)
            for (( i=0; i<total; i++ )); do
                lport=$(jq -r ".forwards[$i].gateway_port // empty" "${FORWARD_FILE}" 2>/dev/null)
                rh=$(   jq -r ".forwards[$i].relay_host  // empty" "${FORWARD_FILE}" 2>/dev/null)
                rip=$(  jq -r ".forwards[$i].relay_ip    // empty" "${FORWARD_FILE}" 2>/dev/null)
                rp=$(   jq -r ".forwards[$i].relay_port  // empty" "${FORWARD_FILE}" 2>/dev/null)

                if [[ -n "$rh" ]]; then
                    if ! eff_ip=$(resolve_host_to_ip "$rh"); then
                        WARN "条目 [$i] 无法解析 relay_host=${rh}，跳过"
                        continue
                    fi
                    dip="$eff_ip"
                elif [[ -n "$rip" ]]; then
                    dip="$rip"
                else
                    WARN "条目 [$i] 同时缺少 relay_host 与 relay_ip，跳过"
                    continue
                fi
                dport="$rp"

                if ! validate_port "$lport"; then WARN "跳过无效本机端口: $lport"; continue; fi
                if ! validate_ip "$dip";    then WARN "跳过无效目标 IP: $dip (port=$lport)"; continue; fi
                if ! validate_port "$dport";then WARN "跳过无效目标端口: $dport (port=$lport)"; continue; fi
                if [[ ",${seen_ports}," == *",${lport},"* ]]; then
                    WARN "本机端口 ${lport} 在配置中重复出现，仅保留首条。"
                    continue
                fi
                seen_ports="${seen_ports},${lport}"
                RULES+=("${lport}|${dip}|${dport}")
            done
            ;;

        relay)
            # 中转：本机 relay_port -> target_ip:target_port，target_ip 为空则跳过
            local query='.forwards[] | select((.target_ip // "") != "") | "\(.relay_port)|\(.target_ip)|\(.target_port)"'
            while IFS='|' read -r lport dip dport; do
                [[ -z "$lport" || "$lport" == "null" ]] && continue
                if ! validate_port "$lport"; then WARN "跳过无效本机端口: $lport"; continue; fi
                if ! validate_ip "$dip";    then WARN "跳过无效目标 IP: $dip (port=$lport)"; continue; fi
                if ! validate_port "$dport";then WARN "跳过无效目标端口: $dport (port=$lport)"; continue; fi
                if [[ ",${seen_ports}," == *",${lport},"* ]]; then
                    WARN "本机端口 ${lport} 在配置中重复出现，仅保留首条。"
                    continue
                fi
                seen_ports="${seen_ports},${lport}"
                RULES+=("${lport}|${dip}|${dport}")
            done < <(jq -r "$query" "${FORWARD_FILE}" 2>/dev/null)
            ;;

        *)
            ERR "未知节点模式: ${node_mode}"
            return 1
            ;;
    esac
    return 0
}

# 写盘 + 重新加载，用于自动模式更新流程的最后一步
# 行为说明：
#   1. 旧规则：从 nft 实际生效的配置文件读出（即上一轮已经写盘的 RULES）
#   2. 新规则：build_rules_from_forward 根据当前 forward.json 现场推算
#   3. 检测目标 IP 变化：构建 lport->dip 映射，若任一 lport 在新旧映射中 dip 不同
#      → 视为"目标 IP 变化"（无论是 DNS 解析改变还是 forward.json 中 relay_ip 字面值改变）
#      → 触发"全量"防火墙重设（force close 所有旧 + 全量 open 所有新），保证不残留过期 ACL
#   4. 否则按"差集增量"调整防火墙（仅对增/删条目操作），减少 firewall 系统调用
update_rules_from_config() {
    local node_mode="$1"

    # 1) 旧规则
    load_running_rules
    local -a old_rules=("${RULES[@]}")

    # 2) 新规则
    if ! build_rules_from_forward "$node_mode"; then
        return 1
    fi
    local -a new_rules=("${RULES[@]}")

    # 3) 检测目标 IP 变化（对所有节点模式都启用：relay 也可能因 target_host 解析变化触发）
    local force_full=0
    declare -A old_dip_by_lport
    local r lp dp
    # IFS 切出三段，第三段（dport）此处不需要，丢弃即可
    for r in "${old_rules[@]}"; do
        IFS='|' read -r lp dp _ <<< "$r"
        old_dip_by_lport["$lp"]="$dp"
    done
    for r in "${new_rules[@]}"; do
        IFS='|' read -r lp dp _ <<< "$r"
        if [[ -n "${old_dip_by_lport[$lp]:-}" && "${old_dip_by_lport[$lp]}" != "$dp" ]]; then
            force_full=1
            log_action "目标 IP 变化: lport=${lp} ${old_dip_by_lport[$lp]} -> ${dp}, 触发全量更新"
            break
        fi
    done

    # 4) 写盘并重载 nftables；只有重载成功才动防火墙
    backup_nft_conf
    if ! write_nft_conf; then
        return 1
    fi
    if ! reload_nft_rules; then
        return 1
    fi

    # 5) 防火墙联动：全量 vs 差集
    #    注意：此时全局 RULES 已是新规则，dest_still_used 在新规则集合中查找共享，
    #    符合"旧规则被移除后还有谁继续使用同一目标"的语义。
    if (( force_full == 1 )); then
        local lport dip dport
        for r in "${old_rules[@]}"; do
            IFS='|' read -r lport dip dport <<< "$r"
            firewall_close_port "$lport" "$dip" "$dport" "force"
        done
        for r in "${new_rules[@]}"; do
            IFS='|' read -r lport dip dport <<< "$r"
            firewall_open_port "$lport" "$dip" "$dport"
        done
        log_action "已全量更新 ${#new_rules[@]} 条规则 (node_mode=${node_mode}, 触发原因: 目标 IP 变化, 旧 ${#old_rules[@]} -> 新 ${#new_rules[@]})"
    else
        apply_firewall_diff "${old_rules[@]}" "--" "${new_rules[@]}"
        log_action "已增量更新 ${#new_rules[@]} 条规则 (node_mode=${node_mode}, 旧 ${#old_rules[@]} -> 新 ${#new_rules[@]})"
    fi
    return 0
}

# ============== 业务：rsync 拉取 forward.json (gateway, 多 relay) ==============
# 拼接策略：远端 user 与远端路径固定（${REMOTE_SSH_USER} + ${REMOTE_FORWARD_PATH}）；
# 用户只在 config.json 的 relays[] 中维护「地址 + 端口」。
#
# 单 relay 拉取：写入指定输出路径（不直接覆盖 ${FORWARD_FILE}），返回 0/1
gateway_pull_one_relay() {
    local idx="$1" output_file="$2"
    local addr port remote_path
    addr=$(get_relay_addr_at "$idx")
    port=$(get_relay_ssh_port_at "$idx")

    if [[ -z "$addr" ]]; then
        log_action "拉取跳过: relays[${idx}] 地址为空"
        return 1
    fi
    if [[ ! -f "${SSH_KEY_FILE}" ]]; then
        log_action "拉取失败: 缺少 ${SSH_KEY_FILE}"
        return 1
    fi
    if ! have_cmd rsync; then
        log_action "拉取失败: 缺少 rsync"
        return 1
    fi

    remote_path="${REMOTE_SSH_USER}@${addr}:${REMOTE_FORWARD_PATH}"
    local ssh_opts
    ssh_opts="ssh -p ${port} -i ${SSH_KEY_FILE} -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${SSH_KNOWN_HOSTS} -o ConnectTimeout=${SSH_CONNECT_TIMEOUT}"

    rsync --timeout="${RSYNC_TIMEOUT}" -q -e "${ssh_opts}" "${remote_path}" "${output_file}" 2>>"${LOG_FILE}"
}

# 拉取所有 relay 的 forward.json，聚合到本地 ${FORWARD_FILE}
#   - 每条 forward 自动追加 _source 元字段（值为来源 relay 地址，便于诊断）
#   - 按 gateway_port 去重（jq unique_by 稳定保留首条）
#   - 全部失败 → 返回 1，本地 forward.json 保持原状
#   - 部分成功 → 返回 0，并按已成功部分聚合（最大化可用性）
gateway_pull_all_relays() {
    require_jq_or_warn || return 1
    local total
    total=$(get_relays_count)
    if (( total == 0 )); then
        ERR "未配置任何中转节点 → 主菜单【4) 管理中转节点 → 增加中转节点】"
        return 1
    fi

    local staging_dir="${CONFIG_DIR}/.staging"
    rm -rf "${staging_dir}" 2>/dev/null || true
    mkdir -p "${staging_dir}" 2>/dev/null || {
        ERR "无法创建临时目录 ${staging_dir}"; return 1
    }

    local i addr port tmp_file ok_count=0 fail_count=0
    # per_relay_files 存储 "<file>|<source_addr>" 形式
    local -a per_relay_files=()

    for ((i=0; i<total; i++)); do
        addr=$(get_relay_addr_at "$i")
        port=$(get_relay_ssh_port_at "$i")
        tmp_file="${staging_dir}/${i}.json"

        if [[ -z "$addr" ]]; then
            ERR "  [${i}] 跳过: 未配置地址"
            ((fail_count++))
            continue
        fi

        if gateway_pull_one_relay "$i" "${tmp_file}"; then
            if jq -e '.forwards | type == "array"' "${tmp_file}" >/dev/null 2>&1; then
                local cnt
                cnt=$(jq '.forwards | length' "${tmp_file}" 2>/dev/null) || cnt=0
                INFO "  [${i}] ${addr}:${port} 拉取成功 (${cnt} 条)"
                per_relay_files+=("${tmp_file}|${addr}")
                ((ok_count++))
            else
                ERR "  [${i}] ${addr}:${port} 拉取的文件结构非法"
                ((fail_count++))
            fi
        else
            ERR "  [${i}] ${addr}:${port} rsync 拉取失败 (详见 ${LOG_FILE})"
            ((fail_count++))
        fi
    done

    if (( ok_count == 0 )); then
        ERR "所有中转节点均拉取失败，本地 ${FORWARD_FILE} 保持不变"
        rm -rf "${staging_dir}" 2>/dev/null || true
        log_action "聚合失败: 全部 ${total} 个 relay 不可用"
        return 1
    fi

    # 聚合：合并各 relay 的 forwards 数组，逐条追加 _source 字段
    local agg_tmp
    agg_tmp=$(mktemp "${FORWARD_FILE}.agg.XXXXXX") || {
        rm -rf "${staging_dir}" 2>/dev/null || true; return 1
    }
    echo '{"forwards":[]}' > "${agg_tmp}"

    local entry file source_addr merged_tmp
    for entry in "${per_relay_files[@]}"; do
        file="${entry%%|*}"
        source_addr="${entry#*|}"
        merged_tmp=$(mktemp) || continue
        # map(. + {_source: $src})：为每条 forward 追加来源标识
        if jq --arg src "$source_addr" --slurpfile new "${file}" \
            '.forwards += ($new[0].forwards | map(. + {_source: $src}))' \
            "${agg_tmp}" > "${merged_tmp}" 2>/dev/null; then
            mv -f "${merged_tmp}" "${agg_tmp}"
        else
            rm -f "${merged_tmp}"
            WARN "  聚合时跳过损坏的临时文件: ${file}"
        fi
    done

    # 去重：按 gateway_port，保留首条；同时统计冲突数
    local pre_count post_count dup_count
    pre_count=$(jq '.forwards | length' "${agg_tmp}" 2>/dev/null) || pre_count=0
    local dedup_tmp
    dedup_tmp=$(mktemp) || { rm -f "${agg_tmp}"; rm -rf "${staging_dir}"; return 1; }
    jq '.forwards |= unique_by(.gateway_port)' "${agg_tmp}" > "${dedup_tmp}" 2>/dev/null \
        && mv -f "${dedup_tmp}" "${agg_tmp}" || rm -f "${dedup_tmp}"
    post_count=$(jq '.forwards | length' "${agg_tmp}" 2>/dev/null) || post_count=0
    dup_count=$(( pre_count - post_count ))
    if (( dup_count > 0 )); then
        WARN "  聚合时按 gateway_port 去重，丢弃 ${dup_count} 条重复条目（保留首次出现）"
        log_action "聚合去重: 丢弃 ${dup_count} 条重复 gateway_port"
    fi

    # 原子替换最终 forward.json
    mv -f "${agg_tmp}" "${FORWARD_FILE}" || {
        rm -f "${agg_tmp}"; rm -rf "${staging_dir}"; return 1
    }
    chmod 600 "${FORWARD_FILE}" 2>/dev/null || true
    rm -rf "${staging_dir}" 2>/dev/null || true

    INFO "聚合完成: 来自 ${ok_count}/${total} 个中转节点, 共 ${post_count} 条转发"
    log_action "聚合 forward.json: ok=${ok_count} fail=${fail_count} total=${post_count} dup_dropped=${dup_count}"
    return 0
}

# 引导用户增加一个中转节点：地址 + 端口 → 写入 relays[] → 部署公钥 → 拉取测试
setup_rsync_flow_add_relay() {
    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        ERR "增加中转节点需要交互输入，无法在 --cron 模式中运行。"
        return 1
    fi
    if ! have_cmd ssh-keygen || ! have_cmd ssh-copy-id || ! have_cmd rsync; then
        ERR "缺少 ssh / rsync 工具，请先选择【初始化环境】安装依赖。"
        return 1
    fi

    echo ""
    echo "=== 增加中转节点 ==="
    echo "提示：脚本会以 ${REMOTE_SSH_USER}@<中转地址>:${REMOTE_FORWARD_PATH} 拼接拉取路径。"

    # 1) 输入并去重
    local relay_input relay_host="" relay_ip=""
    while true; do
        read -rp "请输入中转节点地址 (域名或 IP，例: relay.example.com 或 10.0.0.1): " relay_input
        if [[ -z "$relay_input" ]]; then ERR "不能为空"; continue; fi
        if relay_addr_exists "$relay_input"; then
            ERR "中转地址已存在: ${relay_input}"; continue
        fi
        if validate_ip "$relay_input"; then
            relay_ip="$relay_input"; break
        fi
        if validate_host "$relay_input"; then
            relay_host="$relay_input"
            local probe_ip
            if probe_ip=$(resolve_host_to_ip "$relay_input"); then
                INFO "  当前解析结果: ${relay_input} -> ${probe_ip}"
            else
                WARN "  当前解析失败，请确保 DNS 可用或后续在 cron 中重试"
            fi
            break
        fi
        ERR "格式无效，请输入合法 IP 或域名。"
    done

    # 2) SSH 端口
    local ssh_port_input ssh_port
    while true; do
        read -rp "请输入 SSH 端口 (1-65535) [回车=${DEFAULT_RELAY_SSH_PORT}]: " ssh_port_input
        ssh_port_input="${ssh_port_input:-${DEFAULT_RELAY_SSH_PORT}}"
        if validate_port "$ssh_port_input"; then
            ssh_port="$ssh_port_input"; break
        fi
        ERR "端口无效，请输入 1-65535。"
    done

    # 3) 写入 relays[]
    add_relay_to_config "$relay_host" "$relay_ip" "$ssh_port" || return 1
    local new_idx
    new_idx=$(( $(get_relays_count) - 1 ))
    INFO "已添加中转节点 [${new_idx}]: ${relay_input} (port=${ssh_port})"
    log_action "新增 relay [${new_idx}]: ${relay_input}:${ssh_port}"

    # 4) 生成 SSH 密钥（共享一对密钥，复用）
    if [[ ! -f "${SSH_KEY_FILE}" ]]; then
        INFO "生成 SSH 密钥: ${SSH_KEY_FILE}"
        if ! ssh-keygen -t ed25519 -N "" -C "forward_rsync" -f "${SSH_KEY_FILE}" >/dev/null 2>&1; then
            ERR "生成 SSH 密钥失败"; return 1
        fi
        chmod 600 "${SSH_KEY_FILE}" 2>/dev/null || true
        chmod 644 "${SSH_KEY_FILE}.pub" 2>/dev/null || true
        log_action "生成 SSH 密钥 ${SSH_KEY_FILE}"
    else
        INFO "复用已有 SSH 密钥: ${SSH_KEY_FILE}"
    fi

    # 5) 上传公钥
    local ssh_target="${REMOTE_SSH_USER}@${relay_input}"
    INFO "向 ${ssh_target} (port=${ssh_port}) 部署公钥..."
    INFO "（接下来会提示输入中转节点的密码，仅本次部署使用）"
    if ssh-copy-id -i "${SSH_KEY_FILE}.pub" \
        -p "${ssh_port}" \
        -o "StrictHostKeyChecking=accept-new" \
        -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}" \
        -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}" \
        "$ssh_target" 2>&1 | tee -a "${LOG_FILE}"; then
        INFO "公钥已部署到 ${relay_input}"
    else
        WARN "公钥自动部署失败。可手动操作："
        WARN "  cat ${SSH_KEY_FILE}.pub | ssh -p ${ssh_port} ${ssh_target} 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'"
    fi

    # 6) 拉取测试（写到临时文件，不影响现有 forward.json）
    INFO "测试 rsync 拉取..."
    local test_file="${CONFIG_DIR}/.test.json"
    if gateway_pull_one_relay "$new_idx" "$test_file"; then
        if jq -e '.forwards | type == "array"' "$test_file" >/dev/null 2>&1; then
            INFO "rsync 测试成功 (远端含 $(jq '.forwards | length' "$test_file" 2>/dev/null) 条转发)"
            rm -f "$test_file"
            return 0
        fi
        ERR "拉取的文件结构非法"; rm -f "$test_file"; return 1
    fi
    rm -f "$test_file"
    ERR "rsync 测试失败，请确认中转节点上 ${REMOTE_FORWARD_PATH} 已存在且公钥已正确授权。"
    return 1
}

# 列表展示所有 relay（用于菜单 / display_status / 卸载提示等）
list_relays_table() {
    require_jq_or_warn || return 1
    local total
    total=$(get_relays_count)
    if (( total == 0 )); then
        echo "  (尚未配置任何中转节点)"
        return 0
    fi
    printf "  %-4s %-30s %-10s %s\n" "序号" "中转地址" "SSH端口" "类型"
    echo "  ──────────────────────────────────────────────────────────────"
    local i addr port rh
    for ((i=0; i<total; i++)); do
        addr=$(get_relay_addr_at "$i")
        port=$(get_relay_ssh_port_at "$i")
        rh=$(get_relay_field_at "$i" relay_host)
        local kind
        if [[ -n "$rh" ]]; then kind="域名"; else kind="IP"; fi
        printf "  %-4s %-30s %-10s %s\n" "$i" "${addr:-?}" "$port" "$kind"
    done
}

# 测试所有 relay 的连通性（仅 SSH true 检查，不修改本地配置）
test_all_relays() {
    local total
    total=$(get_relays_count)
    if (( total == 0 )); then
        INFO "尚未配置任何中转节点"
        return 0
    fi
    if [[ ! -f "${SSH_KEY_FILE}" ]]; then
        ERR "SSH 私钥不存在，无法测试 (${SSH_KEY_FILE})"
        return 1
    fi
    echo ""
    INFO "正在测试所有中转节点连通性..."
    local i addr port ok=0 fail=0
    for ((i=0; i<total; i++)); do
        addr=$(get_relay_addr_at "$i")
        port=$(get_relay_ssh_port_at "$i")
        if ssh -p "$port" -i "${SSH_KEY_FILE}" \
            -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="${SSH_KNOWN_HOSTS}" \
            -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" \
            "${REMOTE_SSH_USER}@${addr}" "true" >/dev/null 2>&1; then
            INFO "  [${i}] ${addr}:${port} 通"
            ((ok++))
        else
            ERR "  [${i}] ${addr}:${port} 不通 / 公钥未授权"
            ((fail++))
        fi
    done
    echo ""
    INFO "连通测试完成: ${ok} 通 / ${fail} 不通"
}

# 删除某个中转节点（交互式）
delete_relay_interactive() {
    require_jq_or_warn || return 1
    local total
    total=$(get_relays_count)
    if (( total == 0 )); then
        INFO "当前未配置任何中转节点，无可删除"
        return 0
    fi
    list_relays_table
    echo ""
    local choice
    read -rp "请输入要删除的序号 (空/非数字取消): " choice
    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]]; then
        INFO "已取消"; return 0
    fi
    if (( choice < 0 || choice >= total )); then
        ERR "序号越界 (合法范围 0..$((total-1)))"
        return 1
    fi
    local addr port
    addr=$(get_relay_addr_at "$choice")
    port=$(get_relay_ssh_port_at "$choice")
    local confirm
    read -rp "确认删除 [${choice}] ${addr}:${port}？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        INFO "已取消"; return 0
    fi
    if remove_relay_from_config "$choice"; then
        INFO "已删除中转节点 [${choice}] ${addr}"
        log_action "删除 relay [${choice}] ${addr}:${port}"
        WARN "提示：仍需手工到中转节点 ${addr} 上执行："
        WARN "  sudo sed -i '/forward_rsync/d' /root/.ssh/authorized_keys"
    fi
}

# 「管理中转节点」子菜单（仅 gateway 模式可用）
do_manage_relays_menu() {
    while true; do
        echo ""
        echo "=== 管理中转节点 ==="
        list_relays_table
        echo ""
        echo "  1) 增加中转节点"
        echo "  2) 删除中转节点"
        echo "  3) 测试所有中转连通性"
        echo "  0) 返回"
        local choice
        read -rp "请选择: " choice
        case "$choice" in
            1) setup_rsync_flow_add_relay ;;
            2) delete_relay_interactive ;;
            3) test_all_relays ;;
            0|"") return 0 ;;
            *) ERR "无效选择" ;;
        esac
    done
}

# ============== 业务：relay 解析 target_host -> target_ip ==============
# 遍历 forward.json：解析每条转发的 target_host，必要时更新 target_ip
relay_resolve_and_update() {
    require_jq_or_warn || return 1
    init_forward_file || return 1
    local total
    total=$(forward_count)
    if (( total == 0 )); then
        return 0
    fi

    local i target_host cur_ip new_ip changed=0
    for (( i=0; i<total; i++ )); do
        target_host=$(jq -r ".forwards[$i].target_host // empty" "${FORWARD_FILE}" 2>/dev/null)
        if [[ -z "$target_host" ]]; then
            continue
        fi
        cur_ip=$(jq -r ".forwards[$i].target_ip // empty" "${FORWARD_FILE}" 2>/dev/null)

        if new_ip=$(resolve_host_to_ip "$target_host"); then
            if [[ "$cur_ip" != "$new_ip" ]]; then
                if forward_set_target_ip "$i" "$new_ip"; then
                    INFO "更新转发 [$i] target_host=${target_host}: target_ip ${cur_ip:-空} -> ${new_ip}"
                    log_action "解析更新: [$i] ${target_host} -> ${new_ip}"
                    changed=1
                fi
            fi
        else
            WARN "无法解析 target_host: ${target_host} (条目 [$i])"
            log_action "解析失败: ${target_host}"
        fi
    done

    return $(( changed == 0 ? 0 : 0 ))  # 不论是否变更都视为成功
}

# ============== 业务：清空所有转发规则 ==============
# 参数: $1 = "silent" 时不再二次确认（用于模式切换内部调用）
clear_all_rules() {
    local silent="${1:-}"
    load_running_rules
    if (( ${#RULES[@]} == 0 )) && [[ ! -f "${NFT_CONF_FILE}" ]]; then
        [[ "$silent" == "silent" ]] || INFO "当前没有任何转发规则，无需清空。"
        return 0
    fi
    if [[ "$silent" != "silent" && "$NON_INTERACTIVE" -eq 0 ]]; then
        WARN "即将清空全部 ${#RULES[@]} 条转发规则！"
        local ans
        read -rp "确认清空？[y/N]: " ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            INFO "已取消"
            return 1
        fi
    fi

    # 先快照旧规则，待 nft 重载成功后用 force 模式批量回收防火墙放行
    local -a old_rules=("${RULES[@]}")

    RULES=()
    backup_nft_conf
    if ! write_nft_conf; then
        return 1
    fi
    if reload_nft_rules; then
        # 全量清空场景，所有 FORWARD 共享检查都不再有意义，使用 force 跳过
        local r lport dip dport
        for r in "${old_rules[@]}"; do
            IFS='|' read -r lport dip dport <<< "$r"
            firewall_close_port "$lport" "$dip" "$dport" "force"
        done
        INFO "已清空所有转发规则。"
        log_action "清空所有转发规则 (回收 ${#old_rules[@]} 条防火墙放行)"
        return 0
    fi
    return 1
}

# ============== 业务：诊断 / 自检 ==============
# 整体设计：
#   - 9 个区块，逐块输出 [OK]/[WARN]/[FAIL]，末尾汇总三类计数
#   - [OK]   = 该项满足预期
#   - [WARN] = 不阻塞主流程，但建议关注（重启可能丢失、解析暂时失败等）
#   - [FAIL] = 关键问题，会导致功能不工作；输出后附带"修复建议"
#   - 不修改任何配置、不发起 nft/防火墙变更，纯只读检查
#
# 区块构成：
#   1. 依赖与命令      （nft/jq/rsync/ssh/flock/nc + DNS 解析工具）
#   2. 内核参数        （ip_forward 当前值 + 持久化）
#   3. nftables 服务   （服务状态 + 主配置 include）
#   4. 本地配置        （config.json 合法性 + 节点/运行模式 + 关键字段）
#   5. SSH/rsync 链路  （仅 gateway：私钥、SSH 连通、远端文件可读）
#   6. forward.json    （存在性 + 结构 + 各条目字段健康度）
#   7. nft 规则一致性  （已加载、实际数 vs 期望数）
#   8. 转发连通性      （逐条 TCP 三次握手）
#   9. 防火墙与定时任务（活跃防火墙、cron 安装/服务、flock）

# 诊断结果计数器（do_diagnose 内部使用）
CHECK_OK_COUNT=0
CHECK_WARN_COUNT=0
CHECK_FAIL_COUNT=0

_check_ok() {
    if _use_color; then printf '  \033[32m[OK]  \033[0m %s\n' "$*"
    else                printf '  [OK]   %s\n' "$*"
    fi
    ((CHECK_OK_COUNT++))
}
_check_warn() {
    if _use_color; then printf '  \033[33m[WARN]\033[0m %s\n' "$*"
    else                printf '  [WARN] %s\n' "$*"
    fi
    ((CHECK_WARN_COUNT++))
}
_check_fail() {
    if _use_color; then printf '  \033[31m[FAIL]\033[0m %s\n' "$*"
    else                printf '  [FAIL] %s\n' "$*"
    fi
    ((CHECK_FAIL_COUNT++))
}
_check_section() {
    echo ""
    echo "[${1}] ${2}"
    echo "  ──────────────────────────────────────────────────"
}

# --- 区块 1：依赖与命令 ---
_diagnose_deps() {
    local cmd ver
    for cmd in nft jq rsync ssh ssh-keygen ssh-copy-id flock; do
        if have_cmd "$cmd"; then
            ver=""
            case "$cmd" in
                nft)   ver=" $(nft --version 2>/dev/null | head -1)" ;;
                jq)    ver=" ($(jq --version 2>/dev/null))" ;;
                rsync) ver=" ($(rsync --version 2>/dev/null | head -1 | awk '{print $1, $3}'))" ;;
            esac
            _check_ok "${cmd}${ver}"
        else
            _check_fail "${cmd} 未安装 → 主菜单【1) 初始化环境】"
        fi
    done

    if have_cmd getent || have_cmd dig || have_cmd host; then
        local tools=()
        have_cmd getent && tools+=(getent)
        have_cmd dig    && tools+=(dig)
        have_cmd host   && tools+=(host)
        _check_ok "DNS 解析工具：${tools[*]}"
    else
        _check_warn "未发现 getent/dig/host，无法解析域名"
    fi

    if [[ -n "${BASH_VERSION:-}" ]]; then
        local major="${BASH_VERSION%%.*}"
        if (( major >= 4 )); then
            _check_ok "bash 版本: ${BASH_VERSION}"
        else
            _check_fail "bash 版本过低: ${BASH_VERSION} (需要 4 或更高，关联数组等特性依赖)"
        fi
    fi
}

# --- 区块 2：内核参数 ---
_diagnose_kernel() {
    local v
    v=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) || v="?"
    if [[ "$v" == "1" ]]; then
        _check_ok "net.ipv4.ip_forward = 1"
    else
        _check_fail "net.ipv4.ip_forward = ${v} (应为 1) → 主菜单【1) 初始化环境】"
    fi
    if [[ -f "${SYSCTL_CONF}" ]] && \
        grep -qE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1' "${SYSCTL_CONF}" 2>/dev/null; then
        _check_ok "持久化: ${SYSCTL_CONF} 已写入 ip_forward=1"
    else
        _check_warn "${SYSCTL_CONF} 未持久化 ip_forward (重启后可能失效)"
    fi
}

# --- 区块 3：nftables 服务与主配置 ---
_diagnose_nft_service() {
    if ! have_cmd nft; then
        _check_fail "nftables 未安装 (跳过服务检查)"
        return
    fi
    if have_cmd systemctl; then
        local enabled active
        enabled=$(systemctl is-enabled nftables 2>/dev/null) || enabled="unknown"
        active=$(systemctl is-active  nftables 2>/dev/null) || active="unknown"
        if [[ "$active" == "active" ]]; then
            _check_ok "nftables 服务: active"
        else
            _check_warn "nftables 服务: ${active} → systemctl start nftables"
        fi
        if [[ "$enabled" == "enabled" ]]; then
            _check_ok "nftables 开机启动: enabled"
        else
            _check_warn "nftables 未设置开机启动 → systemctl enable nftables"
        fi
    else
        _check_warn "无 systemctl，无法检查 nftables 服务状态"
    fi
    if [[ -f "${NFT_MAIN_CONF}" ]]; then
        if grep -qF 'include "/etc/nftables.d/*.conf"' "${NFT_MAIN_CONF}" 2>/dev/null; then
            _check_ok "${NFT_MAIN_CONF} 含 include /etc/nftables.d/*.conf"
        else
            _check_warn "${NFT_MAIN_CONF} 缺少 include 指令 (重启后规则可能不加载)"
        fi
    else
        _check_warn "${NFT_MAIN_CONF} 不存在 → 主菜单【1) 初始化环境】"
    fi
}

# --- 区块 4：本地配置文件 ---
_diagnose_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        _check_warn "${CONFIG_FILE} 不存在 (设置节点/运行模式后会自动创建)"
        return
    fi
    if ! have_cmd jq || ! jq -e . "${CONFIG_FILE}" >/dev/null 2>&1; then
        _check_fail "${CONFIG_FILE} 不是合法 JSON"
        return
    fi
    _check_ok "config.json 是合法 JSON"

    local node_mode run_mode
    node_mode=$(get_config_value node_mode)
    run_mode=$(get_config_value run_mode)
    case "$node_mode" in
        gateway|relay) _check_ok "node_mode = ${node_mode}" ;;
        "")            _check_fail "node_mode 未设置 → 主菜单【2) 设置节点模式】" ;;
        *)             _check_fail "node_mode = ${node_mode} (非法)" ;;
    esac
    case "$run_mode" in
        manual|auto) _check_ok "run_mode = ${run_mode}" ;;
        "")          _check_fail "run_mode 未设置 → 主菜单【3) 设置运行模式】" ;;
        *)           _check_fail "run_mode = ${run_mode} (非法)" ;;
    esac

    if [[ "$node_mode" == "gateway" ]]; then
        local total
        total=$(get_relays_count)
        if (( total == 0 )); then
            if [[ "$run_mode" == "auto" ]]; then
                _check_fail "relays[] 为空 → 主菜单【4) 管理中转节点 → 增加中转节点】"
            else
                _check_warn "relays[] 为空 (manual 模式不强制需要)"
            fi
        else
            _check_ok "relays[] 共 ${total} 个中转节点"
            local i addr port
            for ((i=0; i<total; i++)); do
                addr=$(get_relay_addr_at "$i")
                port=$(get_relay_ssh_port_at "$i")
                if [[ -n "$addr" ]]; then
                    _check_ok "  [${i}] ${addr}:${port}"
                else
                    _check_fail "  [${i}] 地址为空"
                fi
            done
        fi
    fi
}

# --- 区块 5：SSH/rsync 链路（仅 gateway，遍历所有 relay） ---
_diagnose_rsync() {
    local key="${SSH_KEY_FILE}"

    local total
    total=$(get_relays_count)
    if (( total == 0 )); then
        _check_warn "relays[] 为空 (跳过 SSH/rsync 检查)"
        return
    fi

    # 共享密钥检查（一次性）
    if [[ -f "$key" ]]; then
        local perm
        perm=$(stat -c '%a' "$key" 2>/dev/null) || perm="?"
        if [[ "$perm" == "600" ]]; then
            _check_ok "SSH 私钥 ${key} 存在，权限 600"
        else
            _check_warn "SSH 私钥 ${key} 权限为 ${perm} (推荐 600)"
        fi
    else
        _check_fail "SSH 私钥 ${key} 不存在 → 主菜单【4) 管理中转节点 → 增加中转节点】"
        return
    fi
    if [[ ! -f "${key}.pub" ]]; then
        _check_warn "SSH 公钥 ${key}.pub 不存在 (无法重新部署)"
    fi
    if ! have_cmd ssh; then
        _check_fail "ssh 命令缺失 (跳过连通测试)"
        return
    fi

    # 遍历每个 relay：DNS 解析 → SSH 连通 → 远端文件可读
    local i addr port
    for ((i=0; i<total; i++)); do
        addr=$(get_relay_addr_at "$i")
        port=$(get_relay_ssh_port_at "$i")
        if [[ -z "$addr" ]]; then
            _check_fail "  [${i}] 地址为空"
            continue
        fi

        # DNS 解析检查
        if validate_ip "$addr"; then
            _check_ok "  [${i}] ${addr}:${port} 形式: IP"
        elif resolve_host_to_ip "$addr" >/dev/null 2>&1; then
            _check_ok "  [${i}] ${addr}:${port} 形式: 域名 (解析为 $(resolve_host_to_ip "$addr"))"
        else
            _check_fail "  [${i}] ${addr}:${port} 既不是合法 IP 也无法解析"
            continue
        fi

        # SSH 连通
        if ssh -p "$port" -i "$key" \
            -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="${SSH_KNOWN_HOSTS}" \
            -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" \
            "${REMOTE_SSH_USER}@${addr}" "true" >/dev/null 2>&1; then
            _check_ok "  [${i}] SSH 连通成功"
        else
            _check_fail "  [${i}] SSH 连通失败 → 检查公钥授权与网络"
            continue
        fi

        # 远端文件可读
        if ssh -p "$port" -i "$key" \
            -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="${SSH_KNOWN_HOSTS}" \
            -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" \
            "${REMOTE_SSH_USER}@${addr}" \
            "test -r ${REMOTE_FORWARD_PATH}" >/dev/null 2>&1; then
            _check_ok "  [${i}] 远端 ${REMOTE_FORWARD_PATH} 存在且可读"
        else
            _check_fail "  [${i}] 远端 ${REMOTE_FORWARD_PATH} 不存在或不可读 (中转节点尚未编辑转发配置)"
        fi
    done
}

# --- 区块 6：转发配置 forward.json ---
_diagnose_forward_file() {
    local node_mode="$1"
    if [[ ! -f "${FORWARD_FILE}" ]]; then
        if [[ "$node_mode" == "gateway" ]]; then
            _check_warn "${FORWARD_FILE} 不存在 (gateway 端 cron 会自动 rsync 拉取)"
        else
            _check_warn "${FORWARD_FILE} 不存在 (relay 端【编辑转发配置文件】后会创建)"
        fi
        return
    fi
    if ! have_cmd jq || ! jq -e '.forwards | type=="array"' "${FORWARD_FILE}" >/dev/null 2>&1; then
        _check_fail "${FORWARD_FILE} 结构非法 (缺少 forwards 数组)"
        return
    fi
    local total
    total=$(forward_count)
    _check_ok "forward.json 合法，共 ${total} 条转发"

    if (( total == 0 )); then
        _check_warn "forwards 数组为空 (无规则可下发)"
        return
    fi

    # 字段完备性：每条都必须含必要字段
    local missing
    missing=$(jq -r '[.forwards[] | select(
        (.gateway_port // 0) == 0 or
        (.relay_port   // 0) == 0 or
        (.target_port  // 0) == 0 or
        ((.relay_host // "") == "" and (.relay_ip // "") == "") or
        ((.target_host // "") == "" and (.target_ip // "") == "")
    )] | length' "${FORWARD_FILE}" 2>/dev/null) || missing=0
    if (( missing == 0 )); then
        _check_ok "所有条目字段完备"
    else
        _check_fail "${missing} 条目缺少必要字段（端口为 0、relay/target 双空等）"
    fi

    # 中转节点：检查 target_ip 是否齐全
    if [[ "$node_mode" == "relay" ]]; then
        local empty_count
        empty_count=$(jq '[.forwards[] | select((.target_ip // "") == "")] | length' "${FORWARD_FILE}" 2>/dev/null) || empty_count=0
        if (( empty_count == 0 )); then
            _check_ok "所有条目 target_ip 已解析"
        else
            _check_warn "${empty_count} 条目 target_ip 为空 → 主菜单【立刻更新】重新解析"
        fi
    fi

    # 前置节点：抽查 relay_host 解析（最多 5 条，避免大量 DNS 查询）
    if [[ "$node_mode" == "gateway" ]]; then
        local i tot rh checked=0 fail_count=0
        tot=$total
        for ((i=0; i<tot && checked<5; i++)); do
            rh=$(jq -r ".forwards[$i].relay_host // empty" "${FORWARD_FILE}" 2>/dev/null)
            [[ -z "$rh" ]] && continue
            ((checked++))
            if ! resolve_host_to_ip "$rh" >/dev/null 2>&1; then
                ((fail_count++))
                _check_warn "条目 [$i] relay_host=${rh} 当前无法解析"
            fi
        done
        if (( checked > 0 && fail_count == 0 )); then
            _check_ok "已抽查 ${checked} 个 relay_host，全部可解析"
        elif (( checked == 0 )); then
            _check_ok "无 relay_host 字段需解析 (全部使用 relay_ip)"
        fi
    fi
}

# --- 区块 7：nftables 规则一致性 ---
_diagnose_nft_rules() {
    local node_mode="$1"
    if ! have_cmd nft; then
        _check_fail "nft 未安装 (跳过规则检查)"
        return
    fi
    if nft list table ip "${NFT_TABLE}" >/dev/null 2>&1; then
        _check_ok "${NFT_TABLE} 表已加载"
    else
        _check_warn "${NFT_TABLE} 表未加载 (无规则或服务未启动)"
    fi

    load_running_rules
    local actual=${#RULES[@]}
    _check_ok "nft 实际规则数: ${actual}"

    # 仅 auto 模式 + 已设置节点模式时与 forward.json 对比
    local run_mode
    run_mode=$(get_config_value run_mode)
    if [[ "$run_mode" == "auto" && -n "$node_mode" && -f "${FORWARD_FILE}" ]]; then
        # 保护现场：build_rules_from_forward 会覆盖全局 RULES
        local -a saved=("${RULES[@]}")
        if build_rules_from_forward "$node_mode" >/dev/null 2>&1; then
            local expected=${#RULES[@]}
            if (( expected == actual )); then
                _check_ok "forward.json 期望规则数 = ${expected}，与实际一致"
            else
                _check_warn "forward.json 期望 ${expected} 条 vs 实际 ${actual} 条 → 主菜单【立刻更新】"
            fi
        fi
        RULES=("${saved[@]}")
    fi
}

# --- 区块 8：转发连通性 ---
_diagnose_connectivity() {
    load_running_rules
    if (( ${#RULES[@]} == 0 )); then
        _check_warn "无规则可测"
        return
    fi
    local rule lp dp dpt idx=1 ok_n=0 fail_n=0
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lp dp dpt <<< "$rule"
        if tcp_check "$dp" "$dpt"; then
            _check_ok "#${idx} ${lp} → ${dp}:${dpt} 通"
            ((ok_n++))
        else
            _check_fail "#${idx} ${lp} → ${dp}:${dpt} 不通 / 超时 (${CONNECT_TIMEOUT}s)"
            ((fail_n++))
        fi
        ((idx++))
    done
    if (( fail_n == 0 && ok_n > 0 )); then
        _check_ok "全部 ${ok_n} 条规则的目标连通正常"
    fi
}

# --- 区块 9：防火墙与定时任务 ---
_diagnose_firewall_and_cron() {
    local run_mode="$1"

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        _check_ok "firewalld 活跃 (forward.sh 增删规则时会自动联动)"
    elif have_cmd ufw && ufw status 2>/dev/null | grep -qw "active"; then
        _check_ok "UFW 活跃 (forward.sh 增删规则时会自动联动)"
    elif has_iptables; then
        local fwd_policy
        fwd_policy=$(iptables -S FORWARD 2>/dev/null | grep -- '^-P FORWARD' | awk '{print $3}') || fwd_policy=""
        if [[ "$fwd_policy" == "DROP" || "$fwd_policy" == "REJECT" ]]; then
            _check_warn "iptables FORWARD 默认策略 = ${fwd_policy} (可能阻止转发)"
        else
            _check_ok "iptables 可用，FORWARD 默认策略 = ${fwd_policy:-ACCEPT}"
        fi
    else
        _check_ok "未检测到活跃防火墙 (规则仅由 nft 控制)"
    fi

    if [[ "$run_mode" == "auto" ]]; then
        if [[ -f "${CRON_FILE}" ]]; then
            _check_ok "${CRON_FILE} 已安装"
            if have_cmd systemctl; then
                local cron_alive=0 c
                for c in cron crond cronie; do
                    if systemctl is-active --quiet "$c" 2>/dev/null; then
                        cron_alive=1
                        _check_ok "cron 服务: ${c} (active)"
                        break
                    fi
                done
                (( cron_alive == 0 )) && _check_warn "cron 服务未运行 (定时任务不会触发)"
            fi
        else
            _check_warn "${CRON_FILE} 未安装 → 主菜单【6) 设置定时任务】"
        fi
        if have_cmd flock; then
            _check_ok "flock 可用 (cron 串行化锁)"
        else
            _check_warn "flock 未安装 (cron 可能并发执行) → 主菜单【1) 初始化环境】"
        fi
    else
        _check_ok "当前为 ${run_mode:-未设置} 模式，无需 cron"
    fi
}

# --- 主入口 ---
do_diagnose() {
    CHECK_OK_COUNT=0
    CHECK_WARN_COUNT=0
    CHECK_FAIL_COUNT=0

    echo ""
    echo "============================================================"
    echo "             转发管理工具 - 诊断 / 自检"
    echo "============================================================"

    local node_mode run_mode
    node_mode=$(get_config_value node_mode 2>/dev/null || echo "")
    run_mode=$(get_config_value  run_mode  2>/dev/null || echo "")

    _check_section "1/9" "依赖与命令"
    _diagnose_deps

    _check_section "2/9" "内核参数 (sysctl)"
    _diagnose_kernel

    _check_section "3/9" "nftables 服务与持久化"
    _diagnose_nft_service

    _check_section "4/9" "本地配置 (${CONFIG_FILE})"
    _diagnose_config

    if [[ "$node_mode" == "gateway" ]]; then
        _check_section "5/9" "SSH / rsync 链路 (gateway 专属)"
        _diagnose_rsync
    else
        _check_section "5/9" "SSH / rsync 链路"
        _check_ok "当前为 ${node_mode:-未设置} 节点模式，跳过 gateway 专属检查"
    fi

    _check_section "6/9" "转发配置 (${FORWARD_FILE})"
    _diagnose_forward_file "$node_mode"

    _check_section "7/9" "nftables 规则一致性"
    _diagnose_nft_rules "$node_mode"

    _check_section "8/9" "转发连通性 (TCP)"
    _diagnose_connectivity

    _check_section "9/9" "防火墙与定时任务"
    _diagnose_firewall_and_cron "$run_mode"

    # ----- 汇总 -----
    echo ""
    echo "============================================================"
    if (( CHECK_FAIL_COUNT > 0 )); then
        if _use_color; then
            printf '诊断结果: \033[32m%d OK\033[0m / \033[33m%d WARN\033[0m / \033[31m%d FAIL\033[0m\n' \
                "$CHECK_OK_COUNT" "$CHECK_WARN_COUNT" "$CHECK_FAIL_COUNT"
        else
            printf '诊断结果: %d OK / %d WARN / %d FAIL\n' \
                "$CHECK_OK_COUNT" "$CHECK_WARN_COUNT" "$CHECK_FAIL_COUNT"
        fi
        echo "存在严重问题，请按上方提示处理。"
    elif (( CHECK_WARN_COUNT > 0 )); then
        if _use_color; then
            printf '诊断结果: \033[32m%d OK\033[0m / \033[33m%d WARN\033[0m / 0 FAIL\n' \
                "$CHECK_OK_COUNT" "$CHECK_WARN_COUNT"
        else
            printf '诊断结果: %d OK / %d WARN / 0 FAIL\n' "$CHECK_OK_COUNT" "$CHECK_WARN_COUNT"
        fi
        echo "环境基本可用，但存在警告项需关注。"
    else
        if _use_color; then
            printf '诊断结果: \033[32m全部 %d 项通过\033[0m\n' "$CHECK_OK_COUNT"
        else
            printf '诊断结果: 全部 %d 项通过\n' "$CHECK_OK_COUNT"
        fi
        echo "环境与配置一切正常。"
    fi
    echo "============================================================"

    log_action "诊断完成: ${CHECK_OK_COUNT} OK / ${CHECK_WARN_COUNT} WARN / ${CHECK_FAIL_COUNT} FAIL"

    # 退出码：FAIL>0 返回 2；WARN>0 返回 1；全 OK 返回 0（便于 --diagnose 在 CI 中使用）
    if (( CHECK_FAIL_COUNT > 0 )); then return 2
    elif (( CHECK_WARN_COUNT > 0 )); then return 1
    else return 0
    fi
}

# ============== 业务：卸载 ==============
# 设计原则：
#   - 默认不破坏已安装的依赖程序（其他业务可能也在用 nft/jq/rsync/openssh/cron/util-linux）
#   - 默认不动 ${NFT_MAIN_CONF} 中的 include 指令（其他业务可能也用 /etc/nftables.d/）
#   - 默认不动当前运行中的 net.ipv4.ip_forward 值（仅删除我们的 sysctl 持久化文件）
#   - 中转节点上 ~/.ssh/authorized_keys 中的公钥需手工到 relay 删除（无法跨机操作）
# 二次确认：
#   - 第一次：[y/N] 确认是否卸载
#   - 第二次：要求输入大写 'YES' 字面量，避免误按 y 触发不可逆删除
do_uninstall() {
    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        ERR "卸载操作要求交互确认，无法在 --cron 模式中运行"
        return 1
    fi

    echo ""
    echo "============================================================"
    echo "                  卸载 forward.sh 管理项"
    echo "============================================================"
    echo ""
    echo "本操作将执行以下清理（不删除已安装的依赖程序）："
    echo "  1) 清空所有 nftables 转发规则 + 回收已放行的防火墙规则"
    echo "  2) 删除定时任务: ${CRON_FILE}"
    echo "  3) 删除 nft 配置: ${NFT_CONF_FILE} 与 ${NFT_CONF_DIR}/backups/"
    echo "  4) 删除本地配置目录: ${CONFIG_DIR}"
    echo "       (含 config.json/forward.json/SSH 密钥/known_hosts/cron.lock)"
    echo "  5) 删除内核参数持久化: ${SYSCTL_CONF}"
    echo "  6) 删除 logrotate 配置: ${LOGROTATE_CONF}"
    echo "  7) 删除日志文件: ${LOG_FILE} 及其轮转副本"
    echo ""
    echo "保留项："
    echo "  - 依赖程序 (nft/jq/rsync/openssh-client/cron/util-linux 等)"
    echo "  - ${NFT_MAIN_CONF} 中的 include 指令（不影响其他 nftables 用途）"
    echo "  - 当前运行中的 net.ipv4.ip_forward 值（仅删持久化文件）"
    echo ""

    # 卸载前列出所有已配置的中转节点，便于用户逐一登录清理 authorized_keys
    local node_mode_now relays_total
    node_mode_now=$(get_config_value node_mode 2>/dev/null || echo "")
    relays_total=$(get_relays_count 2>/dev/null || echo 0)
    if [[ "$node_mode_now" == "gateway" ]] && (( relays_total > 0 )); then
        WARN "本节点为 gateway，已配置 ${relays_total} 个中转节点。"
        WARN "卸载完成后请逐一登录以下节点，移除 forward_rsync 公钥授权："
        local i addr port
        for ((i=0; i<relays_total; i++)); do
            addr=$(get_relay_addr_at "$i")
            port=$(get_relay_ssh_port_at "$i")
            echo "    [${i}] ssh -p ${port} ${REMOTE_SSH_USER}@${addr} \\"
            echo "          \"sed -i '/forward_rsync/d' ~/.ssh/authorized_keys\""
        done
    else
        WARN "若曾作为 gateway 部署过公钥，请到对应中转节点 ~/.ssh/authorized_keys 中清理 forward_rsync 公钥"
    fi
    echo ""

    local ans
    read -rp "是否确认卸载？[y/N]: " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        INFO "已取消卸载"
        return 0
    fi

    # 二次确认：要求输入大写 YES 字面量，避免误触
    echo ""
    WARN "此操作不可逆！将永久删除上述所有数据与配置。"
    local ans2
    read -rp "请输入 'YES' (大写三字母) 二次确认: " ans2
    if [[ "$ans2" != "YES" ]]; then
        INFO "二次确认未通过，已取消"
        return 0
    fi

    log_action "开始卸载流程"

    # 1) 清空规则 + 回收防火墙
    INFO "[1/7] 清空 nftables 规则与回收防火墙放行..."
    clear_all_rules silent || true
    # 兜底：彻底删除我们的 nft 表（即使配置文件已被删，也尝试清理运行时表）
    if have_cmd nft; then
        nft flush  table ip "${NFT_TABLE}" 2>/dev/null || true
        nft delete table ip "${NFT_TABLE}" 2>/dev/null || true
    fi

    # 2) cron
    INFO "[2/7] 删除定时任务 ${CRON_FILE} ..."
    rm -f "${CRON_FILE}" 2>/dev/null || true
    if have_cmd systemctl; then
        local c
        for c in cron crond cronie; do
            systemctl reload "$c" 2>/dev/null && break
        done
    fi

    # 3) nft 配置
    INFO "[3/7] 删除 nft 配置文件与备份..."
    rm -f  "${NFT_CONF_FILE}" 2>/dev/null || true
    rm -rf "${NFT_CONF_DIR}/backups" 2>/dev/null || true

    # 4) 本地配置目录（含 SSH 密钥）
    INFO "[4/7] 删除本地配置目录 ${CONFIG_DIR} ..."
    rm -rf "${CONFIG_DIR}" 2>/dev/null || true

    # 5) sysctl 持久化（不动当前运行值）
    INFO "[5/7] 删除 sysctl 持久化文件 ${SYSCTL_CONF} ..."
    rm -f "${SYSCTL_CONF}" 2>/dev/null || true

    # 6) logrotate
    INFO "[6/7] 删除 logrotate 配置 ${LOGROTATE_CONF} ..."
    rm -f "${LOGROTATE_CONF}" 2>/dev/null || true

    # 7) 日志（最后操作：前面的 log_action 写入还在用此文件）
    log_action "卸载流程结束（即将删除日志文件）"
    INFO "[7/7] 删除日志文件 ${LOG_FILE} 及其轮转副本..."
    rm -f "${LOG_FILE}" "${LOG_FILE}".* 2>/dev/null || true

    echo ""
    echo "============================================================"
    INFO "卸载完成。所有 forward.sh 管理项已清理。"
    echo "============================================================"
    echo "如需彻底关闭 IPv4 转发（其他业务不依赖时再做）："
    echo "  sudo sysctl -w net.ipv4.ip_forward=0"
    echo ""
    echo "如需移除中转节点的公钥授权，请逐个到 relay 节点上执行："
    echo "  sudo sed -i '/forward_rsync/d' /root/.ssh/authorized_keys"
    echo "============================================================"

    # 状态已被全部清空，继续运行无意义，主动退出
    exit 0
}

# ============== 菜单：初始化环境 ==============
do_init_env() {
    echo ""
    echo "=== 初始化环境 ==="
    local pkg_mgr
    pkg_mgr=$(detect_pkg_manager)
    if [[ "$pkg_mgr" == "unknown" ]]; then
        ERR "无法识别包管理器，请手动安装: curl nftables jq rsync openssh util-linux"
        return 1
    fi
    INFO "检测到包管理器: ${pkg_mgr}"
    INFO "将安装依赖: curl nftables jq rsync openssh util-linux(flock)"
    if ! install_packages "$pkg_mgr"; then
        ERR "依赖安装失败，请检查网络或手动安装。"
        return 1
    fi
    log_action "依赖安装完成 (pkg_mgr=${pkg_mgr})"

    enable_ip_forward
    ensure_nft_main_conf

    # 启用并启动 nftables 服务（重启后规则自动加载）
    if have_cmd systemctl; then
        if systemctl enable --now nftables 2>/dev/null; then
            INFO "已启用并启动 nftables 服务。"
        else
            WARN "nftables 服务启用失败，重启后规则可能丢失。"
            WARN "请手动执行: systemctl enable --now nftables"
        fi
        # cron 服务也确保开启
        for c in cron crond cronie; do
            systemctl enable --now "$c" 2>/dev/null && break
        done
    fi

    # 防火墙状态检测（仅提示）：增删转发时会通过 firewall_open_port/close_port 自动联动
    check_firewall_status

    INFO "环境初始化完成。"
}

# ============== 菜单：设置节点模式 ==============
set_node_mode_menu() {
    require_jq_or_warn || return 1
    local current new
    current=$(get_config_value node_mode)

    echo ""
    echo "=== 设置节点模式 ==="
    echo "  当前: ${current:-未设置}"
    echo "  1) 前置 (gateway) - 把本机 gateway_port 转发到 relay_ip:relay_port"
    echo "  2) 中转 (relay)   - 把本机 relay_port 转发到 target_ip:target_port"
    echo "  0) 取消"
    local choice
    read -rp "请选择: " choice
    case "$choice" in
        1) new="gateway" ;;
        2) new="relay" ;;
        0|"") return 0 ;;
        *) ERR "无效选择"; return 1 ;;
    esac

    if [[ "$current" == "$new" ]]; then
        INFO "当前已是 ${new} 模式，无需修改。"
        return 0
    fi

    # 已有节点模式 → 切换需要二次确认 + 清空规则
    if [[ -n "$current" ]]; then
        WARN "节点模式将由 [${current}] 切换为 [${new}]，将清空所有现有转发规则！"
        local ans
        read -rp "确认切换？[y/N]: " ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            INFO "已取消切换。"
            return 0
        fi
        clear_all_rules silent || true
        # 切换节点模式后，运行模式相关的 rsync 设置可能失效，提示用户重新设置
        local run_mode
        run_mode=$(get_config_value run_mode)
        if [[ "$run_mode" == "auto" && "$new" == "gateway" ]]; then
            WARN "已切换为 gateway 模式，建议重新进入【设置运行模式】完成 rsync 配置。"
        fi
    fi

    if ! set_config_value node_mode "$new"; then
        ERR "保存节点模式失败"
        return 1
    fi
    INFO "节点模式已设为: ${new}"
    log_action "设置节点模式: ${current:-空} -> ${new}"
}

# ============== 菜单：设置运行模式 ==============
set_run_mode_menu() {
    require_jq_or_warn || return 1
    local current new node_mode
    current=$(get_config_value run_mode)
    node_mode=$(get_config_value node_mode)

    echo ""
    echo "=== 设置运行模式 ==="
    echo "  当前: ${current:-未设置}"
    echo "  1) 手动 (manual) - 通过菜单手工增删转发"
    echo "  2) 自动 (auto)   - 通过 forward.json 与定时任务统一管理"
    echo "  0) 取消"
    local choice
    read -rp "请选择: " choice
    case "$choice" in
        1) new="manual" ;;
        2) new="auto" ;;
        0|"") return 0 ;;
        *) ERR "无效选择"; return 1 ;;
    esac

    if [[ "$current" == "$new" ]]; then
        INFO "当前已是 ${new} 模式。"
    elif [[ -n "$current" ]]; then
        WARN "运行模式将由 [${current}] 切换为 [${new}]，将清空所有现有转发规则！"
        local ans
        read -rp "确认切换？[y/N]: " ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            INFO "已取消切换。"
            return 0
        fi
        clear_all_rules silent || true
        if ! set_config_value run_mode "$new"; then
            ERR "保存运行模式失败"; return 1
        fi
        INFO "运行模式已设为: ${new}"
        log_action "设置运行模式: ${current} -> ${new}"
    else
        if ! set_config_value run_mode "$new"; then
            ERR "保存运行模式失败"; return 1
        fi
        INFO "运行模式已设为: ${new}"
        log_action "设置运行模式: 空 -> ${new}"
    fi

    # 关键：节点为前置且运行模式为自动时，校验/引导中转节点配置
    if [[ "$node_mode" == "gateway" && "$new" == "auto" ]]; then
        local total
        total=$(get_relays_count)
        if (( total > 0 )); then
            INFO "本地已配置 ${total} 个中转节点，测试聚合拉取..."
            if gateway_pull_all_relays; then
                INFO "拉取测试成功（已聚合到 ${FORWARD_FILE}）。"
            else
                WARN "聚合拉取失败，请进入【4) 管理中转节点】排查或追加可用节点。"
            fi
        else
            INFO "尚未配置任何中转节点，进入【增加中转节点】流程..."
            setup_rsync_flow_add_relay || true
        fi
    fi
}

# ============== 菜单：手动模式 - 新增转发 ==============
do_manual_add() {
    if ! have_cmd nft; then
        ERR "未安装 nftables，请先选择【初始化环境】。"
        return 1
    fi
    local node_mode
    node_mode=$(get_config_value node_mode)
    if [[ -z "$node_mode" ]]; then
        ERR "请先设置节点模式。"
        return 1
    fi

    enable_ip_forward
    load_running_rules

    echo ""
    case "$node_mode" in
        gateway) echo "=== 新增转发 (前置: 本机 gateway_port -> relay_ip:relay_port) ===" ;;
        relay)   echo "=== 新增转发 (中转: 本机 relay_port -> target_ip:target_port) ===" ;;
    esac

    local lport_prompt dip_prompt dport_prompt
    if [[ "$node_mode" == "gateway" ]]; then
        lport_prompt="请输入本机监听端口 gateway_port (1-65535): "
        dip_prompt="请输入中转节点 IP (relay_ip): "
        dport_prompt="请输入中转节点端口 relay_port (1-65535): "
    else
        lport_prompt="请输入本机监听端口 relay_port (1-65535): "
        dip_prompt="请输入目标 IP (target_ip): "
        dport_prompt="请输入目标端口 target_port (1-65535): "
    fi

    local lport
    while true; do
        read -rp "$lport_prompt" lport
        if validate_port "$lport"; then break; fi
        ERR "端口无效，请输入 1-65535 之间的数字。"
    done

    # 重复检测：本机端口唯一
    local rule rp
    for rule in "${RULES[@]}"; do
        IFS='|' read -r rp _ _ <<< "$rule"
        if [[ "$rp" == "$lport" ]]; then
            ERR "本机端口 ${lport} 已存在转发规则，请先删除后再添加。"
            return 1
        fi
    done

    local dip
    while true; do
        read -rp "$dip_prompt" dip
        if validate_ip "$dip"; then break; fi
        ERR "IP 地址格式无效（不含前导零，如 192.168.1.100）。"
    done

    local dport
    while true; do
        read -rp "${dport_prompt}[默认: ${lport}]: " dport
        dport="${dport:-$lport}"
        if validate_port "$dport"; then break; fi
        ERR "端口无效，请输入 1-65535 之间的数字。"
    done

    echo ""
    echo "即将添加: ${lport} (tcp+udp) -> ${dip}:${dport}"
    local confirm
    read -rp "确认添加？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        INFO "已取消"
        return 0
    fi

    backup_nft_conf
    RULES+=("${lport}|${dip}|${dport}")
    if ! write_nft_conf; then return 1; fi
    if reload_nft_rules; then
        # nft 加载成功后再放行防火墙，避免规则未生效就开洞
        firewall_open_port "$lport" "$dip" "$dport"
        INFO "添加成功: ${lport} -> ${dip}:${dport}"
        log_action "手动新增: ${lport} -> ${dip}:${dport} (node_mode=${node_mode})"
    else
        ERR "规则加载失败，请检查配置。"
        return 1
    fi
}

# ============== 菜单：手动模式 - 删除转发 ==============
do_manual_delete() {
    if ! have_cmd nft; then
        ERR "未安装 nftables，请先选择【初始化环境】。"
        return 1
    fi
    load_running_rules
    if (( ${#RULES[@]} == 0 )); then
        INFO "当前没有转发规则，无需删除。"
        return 0
    fi

    echo ""
    echo "=== 删除转发 ==="
    printf "%-6s %-10s %-10s    %s\n" "序号" "协议" "本机端口" "目标地址"
    echo "──────────────────────────────────────────────────"
    local idx=1 rule lport dip dport
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport dip dport <<< "$rule"
        printf "%-6s %-10s %-10s -> %s\n" "$idx" "tcp+udp" "$lport" "${dip}:${dport}"
        ((idx++))
    done
    echo ""

    local choice
    read -rp "请输入要删除的序号 (0 取消): " choice
    if [[ -z "$choice" || "$choice" == "0" ]]; then
        INFO "已取消"
        return 0
    fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#RULES[@]} )); then
        ERR "无效序号"
        return 1
    fi

    local target="${RULES[$((choice-1))]}"
    IFS='|' read -r lport dip dport <<< "$target"
    echo "即将删除: ${lport} (tcp+udp) -> ${dip}:${dport}"
    local confirm
    read -rp "确认删除？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        INFO "已取消"
        return 0
    fi

    backup_nft_conf
    unset 'RULES[$((choice-1))]'
    RULES=("${RULES[@]}")
    if ! write_nft_conf; then return 1; fi
    if reload_nft_rules; then
        # 此时全局 RULES 已不含被删条目，dest_still_used 能正确判断是否还有共享
        firewall_close_port "$lport" "$dip" "$dport"
        INFO "删除成功: ${lport} -> ${dip}:${dport}"
        log_action "手动删除: ${lport} -> ${dip}:${dport}"
    else
        ERR "规则加载失败"
        return 1
    fi
}

# ============== 菜单：自动模式 - 编辑转发配置文件 ==============
edit_forward_menu() {
    require_jq_or_warn || return 1
    init_forward_file || return 1
    local node_mode
    node_mode=$(get_config_value node_mode)

    if [[ "$node_mode" == "gateway" ]]; then
        WARN "当前为前置(gateway)节点，本地编辑的 forward.json 会被下次 rsync 拉取覆盖。"
        WARN "建议在中转(relay)节点上编辑配置文件。"
        local ans
        read -rp "仍然继续编辑？[y/N]: " ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    while true; do
        echo ""
        echo "=== 编辑转发配置文件 (${FORWARD_FILE}) ==="
        list_forwards_table
        echo ""
        echo "  1) 增加转发"
        echo "  2) 删除转发"
        echo "  0) 返回"
        local choice
        read -rp "请选择: " choice
        case "$choice" in
            1) auto_add_forward "$node_mode" ;;
            2) auto_delete_forward "$node_mode" ;;
            0|"") return 0 ;;
            *) ERR "无效选择" ;;
        esac
    done
}

# 列出 forward.json 中所有转发（含序号和详情）
# 由于 relay_host 与 relay_ip 二选一，合并展示为"中转地址"列：
#   - 有 relay_host：显示 "<host>"（gateway 端会动态实时解析使用，不缓存）
#   - 否则使用 relay_ip 字面值
list_forwards_table() {
    require_jq_or_warn || return 1
    init_forward_file || return 1
    local total
    total=$(forward_count)
    if (( total == 0 )); then
        INFO "当前转发配置为空。"
        return 0
    fi
    echo ""
    printf "%-4s %-14s %-7s %-24s %-7s %-22s %-16s %-7s\n" \
        "序号" "名称" "前置端口" "中转地址(host/ip)" "中转端口" "目标域名" "目标ip" "目标端口"
    echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────"
    local i name gp rh rip rp th ti tp relay_disp
    for (( i=0; i<total; i++ )); do
        name=$(jq -r ".forwards[$i].name // \"\"" "${FORWARD_FILE}" 2>/dev/null)
        gp=$(jq -r   ".forwards[$i].gateway_port // \"\"" "${FORWARD_FILE}" 2>/dev/null)
        rh=$(jq -r   ".forwards[$i].relay_host // \"\"" "${FORWARD_FILE}" 2>/dev/null)
        rip=$(jq -r  ".forwards[$i].relay_ip // \"\"" "${FORWARD_FILE}" 2>/dev/null)
        rp=$(jq -r   ".forwards[$i].relay_port // \"\"" "${FORWARD_FILE}" 2>/dev/null)
        th=$(jq -r   ".forwards[$i].target_host // \"\"" "${FORWARD_FILE}" 2>/dev/null)
        ti=$(jq -r   ".forwards[$i].target_ip // \"\"" "${FORWARD_FILE}" 2>/dev/null)
        tp=$(jq -r   ".forwards[$i].target_port // \"\"" "${FORWARD_FILE}" 2>/dev/null)

        if [[ -n "$rh" ]]; then
            relay_disp="${rh}"
        else
            relay_disp="${rip:--}"
        fi

        printf "%-4s %-14s %-7s %-24s %-7s %-22s %-16s %-7s\n" \
            "$i" "$name" "$gp" "$relay_disp" "$rp" "$th" "${ti:--}" "$tp"
    done
}

# 自动模式新增一条转发：要求所有 6 个字段，立即解析 target_host -> target_ip，写入并触发更新
auto_add_forward() {
    local node_mode="$1"
    echo ""
    echo "=== 增加转发 ==="

    local name
    while true; do
        read -rp "名称 (name, 唯一): " name
        if [[ -z "$name" ]]; then
            ERR "名称不能为空"; continue
        fi
        if [[ ! "$name" =~ ^[A-Za-z0-9_.-]{1,64}$ ]]; then
            ERR "名称仅允许字母数字 . _ - ，长度 1-64"; continue
        fi
        if forward_name_exists "$name"; then
            ERR "名称已存在: ${name}"
            continue
        fi
        break
    done

    local gw_port
    while true; do
        read -rp "前置端口 (gateway_port, 1-65535): " gw_port
        if ! validate_port "$gw_port"; then ERR "端口无效"; continue; fi
        if forward_gateway_port_exists "$gw_port"; then
            ERR "前置端口 ${gw_port} 已被其他转发使用"; continue
        fi
        break
    done

    # 中转地址：relay_host(域名) 与 relay_ip 二选一
    #   - 输入域名 → 写入 relay_host，relay_ip 留空（gateway 端按 relay_host 解析使用）
    #   - 输入 IP   → 写入 relay_ip，relay_host 留空
    local relay_input relay_host="" relay_ip=""
    while true; do
        read -rp "中转地址 (域名或 IP，relay_host/relay_ip 二选一): " relay_input
        if [[ -z "$relay_input" ]]; then ERR "不能为空"; continue; fi
        if validate_ip "$relay_input"; then
            relay_ip="$relay_input"
            INFO "识别为 IP，将写入 relay_ip=${relay_ip}"
            break
        fi
        if validate_host "$relay_input"; then
            relay_host="$relay_input"
            INFO "识别为域名，将写入 relay_host=${relay_host}（gateway 端会动态解析）"
            # 顺手做一次解析探测，仅做提示，不影响写入
            local probe_ip
            if probe_ip=$(resolve_host_to_ip "$relay_host"); then
                INFO "  当前解析结果: ${relay_host} -> ${probe_ip}"
            else
                WARN "  当前解析失败，gateway 端首次拉取后会重试"
            fi
            break
        fi
        ERR "格式无效，请输入合法 IP 或域名"
    done

    local relay_port
    while true; do
        read -rp "中转端口 (relay_port, 1-65535) [默认: ${gw_port}]: " relay_port
        relay_port="${relay_port:-$gw_port}"
        if validate_port "$relay_port"; then break; fi
        ERR "端口无效"
    done

    local target_host
    while true; do
        read -rp "目标域名/IP (target_host): " target_host
        if validate_host "$target_host"; then break; fi
        ERR "目标主机格式无效"
    done

    local target_port
    while true; do
        read -rp "目标端口 (target_port, 1-65535) [默认: ${relay_port}]: " target_port
        target_port="${target_port:-$relay_port}"
        if validate_port "$target_port"; then break; fi
        ERR "端口无效"
    done

    # 立即解析 target_host -> target_ip
    local target_ip=""
    if target_ip=$(resolve_host_to_ip "$target_host"); then
        INFO "解析 target_host=${target_host} -> ${target_ip}"
    else
        WARN "无法解析 target_host=${target_host}，target_ip 将留空，可稍后【立刻更新】重试。"
        target_ip=""
    fi

    if ! forward_add_entry "$name" "$gw_port" "$relay_host" "$relay_ip" "$relay_port" "$target_host" "$target_ip" "$target_port"; then
        return 1
    fi
    INFO "已写入 forward.json：${name}"
    log_action "新增转发条目: ${name} (gw=${gw_port} relay=${relay_host:-$relay_ip}:${relay_port} tgt=${target_host}/${target_ip}:${target_port})"

    # 立即触发规则更新
    if [[ -n "$node_mode" ]]; then
        if update_rules_from_config "$node_mode"; then
            INFO "已根据最新配置更新转发规则。"
        else
            WARN "更新规则失败，请检查日志。"
        fi
    fi
}

# 自动模式删除一条转发：选序号 → 删除 → 触发规则更新
auto_delete_forward() {
    local node_mode="$1"
    local total
    total=$(forward_count)
    if (( total == 0 )); then
        INFO "当前没有转发可删除。"
        return 0
    fi
    list_forwards_table
    echo ""
    local choice
    read -rp "请输入要删除的序号 (空或非数字取消): " choice
    if [[ -z "$choice" ]] || [[ ! "$choice" =~ ^[0-9]+$ ]]; then
        INFO "已取消"
        return 0
    fi
    if (( choice < 0 || choice >= total )); then
        ERR "序号越界 (合法范围 0..$((total-1)))"
        return 1
    fi
    local name
    name=$(jq -r ".forwards[$choice].name // \"\"" "${FORWARD_FILE}" 2>/dev/null)
    local confirm
    read -rp "确认删除 [${choice}] ${name}？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        INFO "已取消"
        return 0
    fi
    if forward_remove_index "$choice"; then
        INFO "已删除: [${choice}] ${name}"
        log_action "删除转发条目: [${choice}] ${name}"
        if [[ -n "$node_mode" ]]; then
            update_rules_from_config "$node_mode" || WARN "更新规则失败"
        fi
    fi
}

# 自动模式 - 立刻更新
# gateway: 从所有 relay 拉取并聚合 forward.json + 重写规则
# relay  : 解析 target_host + 重写规则
auto_update_now() {
    local node_mode
    node_mode=$(get_config_value node_mode)
    if [[ -z "$node_mode" ]]; then
        ERR "请先设置节点模式"
        return 1
    fi
    enable_ip_forward
    case "$node_mode" in
        gateway)
            INFO "[gateway] 从所有中转节点聚合拉取 forward.json..."
            if gateway_pull_all_relays; then
                update_rules_from_config "$node_mode" && INFO "更新完成。"
            else
                ERR "全部 relay 拉取失败，未更新规则。"
                return 1
            fi
            ;;
        relay)
            INFO "[relay] 解析 target_host 并更新..."
            relay_resolve_and_update
            update_rules_from_config "$node_mode" && INFO "更新完成。"
            ;;
        *)
            ERR "未知节点模式: ${node_mode}"
            return 1
            ;;
    esac
}

# 自动模式 - 设置定时任务
# 使用 flock(util-linux) 加锁串行化，避免上一轮未完成就触发新一轮造成竞争；
# 系统中无 flock 时退化为直接调用并提示并发风险。
setup_cron_menu() {
    local interval=10
    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
        echo ""
        echo "=== 设置定时任务 ==="
        echo "默认每 10 分钟执行一次连通性检查与必要的更新。"
        local ans
        read -rp "使用默认 10 分钟间隔？[Y/n]: " ans
        if [[ "$ans" =~ ^[Nn]$ ]]; then
            local custom
            while true; do
                read -rp "请输入间隔分钟数 (1-59): " custom
                if [[ "$custom" =~ ^[0-9]+$ ]] && (( custom >= 1 && custom <= 59 )); then
                    interval="$custom"
                    break
                fi
                ERR "无效间隔"
            done
        fi
    fi

    local cron_cmd
    if have_cmd flock; then
        # -n 非阻塞：上一轮还没结束就直接放弃本轮，避免堆积
        cron_cmd="flock -n ${CONFIG_DIR}/cron.lock ${SCRIPT_PATH} --cron"
    else
        WARN "未发现 flock(util-linux)，定时任务可能并发执行；建议先执行【初始化环境】。"
        cron_cmd="${SCRIPT_PATH} --cron"
    fi

    cat > "${CRON_FILE}" <<EOF
# 由 forward.sh 自动生成 - 转发自检与更新
# 每 ${interval} 分钟执行一次；通过 flock 串行化避免重叠运行
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/${interval} * * * * root ${cron_cmd} >/dev/null 2>&1
EOF
    chmod 644 "${CRON_FILE}" 2>/dev/null || true
    INFO "已写入定时任务: ${CRON_FILE}"
    INFO "  → ${cron_cmd}"
    log_action "安装定时任务 (interval=${interval} min)"

    # 触发 cron 重读（不同发行版略有差异，能成则成，不阻塞）
    if have_cmd systemctl; then
        for c in cron crond cronie; do
            systemctl reload "$c" 2>/dev/null && break
        done
    fi
}

# ============== 状态展示 ==============
display_status() {
    echo ""
    echo "============================================================"
    echo "             转发管理工具 - 当前状态"
    echo "============================================================"

    local node_mode run_mode
    node_mode=$(get_config_value node_mode)
    run_mode=$(get_config_value run_mode)

    case "$node_mode" in
        gateway) echo "  节点模式: 前置 (gateway)" ;;
        relay)   echo "  节点模式: 中转 (relay)" ;;
        "")      echo "  节点模式: 未设置" ;;
        *)       echo "  节点模式: 未知 (${node_mode})" ;;
    esac
    case "$run_mode" in
        manual) echo "  运行模式: 手动 (manual)" ;;
        auto)   echo "  运行模式: 自动 (auto)" ;;
        "")     echo "  运行模式: 未设置" ;;
        *)      echo "  运行模式: 未知 (${run_mode})" ;;
    esac

    if [[ "$node_mode" == "gateway" ]]; then
        local total
        total=$(get_relays_count)
        if (( total == 0 )); then
            echo "  中转节点: (未配置)"
        else
            echo "  中转节点 (共 ${total} 个):"
            local i addr port
            for ((i=0; i<total; i++)); do
                addr=$(get_relay_addr_at "$i")
                port=$(get_relay_ssh_port_at "$i")
                printf "    [%d] %s  (port=%s)\n" "$i" "${addr:-?}" "$port"
            done
            echo "  远端文件路径: ${REMOTE_SSH_USER}@<relay>:${REMOTE_FORWARD_PATH}"
        fi
    fi

    if [[ "$run_mode" == "auto" ]] && [[ -f "${CRON_FILE}" ]]; then
        echo "  定时任务: 已安装 (${CRON_FILE})"
    elif [[ "$run_mode" == "auto" ]]; then
        echo "  定时任务: 未安装"
    fi

    echo ""
    echo "  --- 当前运行的转发规则 ---"
    load_running_rules
    if (( ${#RULES[@]} == 0 )); then
        echo "  (无)"
    else
        printf "  %-4s %-10s %-22s %s\n" "序号" "本机端口" "目标地址" "连通性"
        echo "  ────────────────────────────────────────────────────"
        local idx=1 rule lport dip dport status
        for rule in "${RULES[@]}"; do
            IFS='|' read -r lport dip dport <<< "$rule"
            if tcp_check "$dip" "$dport"; then
                if _use_color; then
                    status=$'\033[32m通\033[0m'
                else
                    status="通"
                fi
            else
                if _use_color; then
                    status=$'\033[31m不通\033[0m'
                else
                    status="不通"
                fi
            fi
            printf "  %-4s %-10s %-22s %b\n" "$idx" "$lport" "${dip}:${dport}" "$status"
            ((idx++))
        done
    fi
    echo "============================================================"
}

# ============== 主菜单 ==============
main_menu() {
    while true; do
        display_status

        local node_mode run_mode
        node_mode=$(get_config_value node_mode)
        run_mode=$(get_config_value run_mode)

        echo ""
        echo "============== 主菜单 =============="
        echo "  1) 初始化环境"
        echo "  2) 设置节点模式"
        echo "  3) 设置运行模式"
        # 4) 在 auto 模式下根据节点模式区分：
        #    - gateway+auto：管理中转节点（forward.json 由远端拉取，本地不直接编辑）
        #    - relay+auto  ：编辑转发配置文件（中转节点是配置源头）
        case "$run_mode" in
            manual)
                echo "  4) 新增转发"
                echo "  5) 删除转发"
                ;;
            auto)
                if [[ "$node_mode" == "gateway" ]]; then
                    echo "  4) 管理中转节点"
                else
                    echo "  4) 编辑转发配置文件"
                fi
                echo "  5) 立刻更新"
                echo "  6) 设置定时任务"
                ;;
            *)
                echo "  (设置运行模式后将显示对应菜单)"
                ;;
        esac
        echo "  d) 诊断 / 自检"
        echo "  c) 清空所有转发规则"
        echo "  u) 卸载 forward.sh 管理项"
        echo "  0) 退出"
        echo "===================================="
        local choice
        read -rp "请选择操作: " choice
        case "$choice" in
            1) do_init_env ;;
            2) set_node_mode_menu ;;
            3) set_run_mode_menu ;;
            4)
                case "$run_mode" in
                    manual) do_manual_add ;;
                    auto)
                        if [[ "$node_mode" == "gateway" ]]; then
                            do_manage_relays_menu
                        else
                            edit_forward_menu
                        fi
                        ;;
                    *) ERR "请先设置运行模式" ;;
                esac
                ;;
            5)
                case "$run_mode" in
                    manual) do_manual_delete ;;
                    auto)   auto_update_now ;;
                    *)      ERR "请先设置运行模式" ;;
                esac
                ;;
            6)
                if [[ "$run_mode" == "auto" ]]; then
                    setup_cron_menu
                else
                    ERR "无效选择"
                fi
                ;;
            d|D) do_diagnose ;;
            c|C) clear_all_rules ;;
            u|U) do_uninstall ;;
            0|q|Q|exit) INFO "再见！"; exit 0 ;;
            *) ERR "无效选择" ;;
        esac
    done
}

# ============== 非交互入口：cron 自检与更新 ==============
# 触发条件：当存在任意一条规则不通时，或 nft 表为空但应有规则时，按节点模式触发更新。
cron_main() {
    NON_INTERACTIVE=1
    log_action "[cron] 开始执行"

    # 容错：若 jq/nft 不可用，直接退出，避免无意义反复报错
    if ! have_cmd jq; then
        log_action "[cron] 跳过：缺少 jq"
        return 0
    fi
    if ! have_cmd nft; then
        log_action "[cron] 跳过：缺少 nft"
        return 0
    fi

    local node_mode run_mode
    node_mode=$(get_config_value node_mode)
    run_mode=$(get_config_value run_mode)
    if [[ "$run_mode" != "auto" ]]; then
        log_action "[cron] 当前 run_mode=${run_mode:-空}，非 auto，跳过"
        return 0
    fi
    if [[ -z "$node_mode" ]]; then
        log_action "[cron] node_mode 未设置，跳过"
        return 0
    fi

    enable_ip_forward >/dev/null 2>&1

    load_running_rules
    local need_update=0 reason=""

    # 期望规则数（从 forward.json 推算）
    local expected_count
    if build_rules_from_forward "$node_mode" >/dev/null 2>&1; then
        expected_count=${#RULES[@]}
    else
        expected_count=0
    fi
    # build_rules_from_forward 复用了 RULES，重新加载一次实际运行规则用于连通性检查
    load_running_rules

    if (( ${#RULES[@]} != expected_count )); then
        need_update=1
        reason="规则数不一致 (运行=${#RULES[@]}, 期望=${expected_count})"
    fi
    if (( need_update == 0 )) && (( ${#RULES[@]} > 0 )); then
        local rule lport dip dport
        for rule in "${RULES[@]}"; do
            IFS='|' read -r lport dip dport <<< "$rule"
            if ! tcp_check "$dip" "$dport"; then
                need_update=1
                reason="目标不通: ${lport} -> ${dip}:${dport}"
                break
            fi
        done
    fi

    if (( need_update == 0 )); then
        log_action "[cron] 全部规则连通正常，跳过更新"
    else
        log_action "[cron] 触发更新: ${reason}"
        case "$node_mode" in
            gateway)
                if gateway_pull_all_relays >/dev/null 2>&1; then
                    if update_rules_from_config "$node_mode" >/dev/null 2>&1; then
                        log_action "[cron][gateway] 更新成功"
                    else
                        log_action "[cron][gateway] 更新规则失败"
                    fi
                else
                    log_action "[cron][gateway] rsync 拉取失败"
                fi
                ;;
            relay)
                relay_resolve_and_update >/dev/null 2>&1
                if update_rules_from_config "$node_mode" >/dev/null 2>&1; then
                    log_action "[cron][relay] 更新成功"
                else
                    log_action "[cron][relay] 更新规则失败"
                fi
                ;;
        esac
    fi

    log_action "[cron] 执行结束"
}

# ============== 帮助信息 ==============
print_help() {
    cat <<EOF
用法: $(basename "${SCRIPT_PATH}") [选项]

选项:
  (无)       进入交互式主菜单
  --cron     非交互模式（供 cron + flock 调用）：检测连通性并按需触发更新
  --status   打印当前状态后退出
  --diagnose 运行完整诊断/自检（9 大维度），退出码 0=全 OK / 1=有 WARN / 2=有 FAIL
  -h|--help  显示本帮助

文件:
  ${CONFIG_FILE}    本地配置文件 (node_mode/run_mode/relay_host/relay_ip/relay_ssh_port)
  ${FORWARD_FILE}   转发配置文件 (forwards 数组)
  ${NFT_CONF_FILE}  实际生效的 nftables 配置
  ${LOG_FILE}             运行日志
EOF
}

# ============== 入口 ==============
main() {
    # 优先解析命令行参数（即便是 --help 也无需 root）
    case "${1:-}" in
        -h|--help)
            print_help
            exit 0
            ;;
    esac

    check_root
    ensure_dirs
    init_config_file >/dev/null 2>&1 || true

    case "${1:-}" in
        --cron)
            cron_main
            ;;
        --status)
            display_status
            ;;
        --diagnose|--diag)
            do_diagnose
            exit $?
            ;;
        "")
            # 交互模式启动前确保关键依赖；缺失则提示先初始化
            if ! have_cmd jq || ! have_cmd nft; then
                WARN "检测到缺少 jq 或 nftables，部分功能不可用。"
                WARN "请先选择菜单【1) 初始化环境】完成依赖安装。"
            fi
            main_menu
            ;;
        *)
            ERR "未知参数: $1"
            print_help
            exit 1
            ;;
    esac
}

main "$@"
