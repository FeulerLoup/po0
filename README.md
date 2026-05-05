# 此脚本魔改自[syrcco](https://www.nodeseek.com/post-616160-1)

# forward.sh — 双节点端口转发管理脚本

基于 `nftables` 的端口转发管理工具，统一管理「前置(gateway) — 中转(relay)」两类节点，
支持手动 / 自动两种运行模式，自动模式下通过 `cron + flock` 周期性自检与自愈。

---

## 目录

- [一、概览与拓扑](#一概览与拓扑)
- [二、依赖](#二依赖)
- [三、文件与目录](#三文件与目录)
- [四、配置文件](#四配置文件)
- [五、使用方式](#五使用方式)
- [六、典型部署流程](#六典型部署流程)
- [七、实现原理](#七实现原理)
- [八、完整测试验证步骤](#八完整测试验证步骤)
- [九、卸载与清理](#九卸载与清理)
- [十、常见问题](#十常见问题)

---

## 一、概览与拓扑

```text
   ┌──────────────┐  gateway_port    ┌─────────────┐  relay_port    ┌──────────┐
   │   客户端     │ ───────────────▶ │  前置(gw)   │ ─────────────▶ │ 中转(rly)│
   └──────────────┘                  └─────────────┘                └─────┬────┘
                                                                          │ relay_port
                                                                          ▼ → target_ip:target_port
                                                                    ┌──────────┐
                                                                    │ 业务后端 │
                                                                    └──────────┘
```


| 节点模式             | 责任                                                                                                    |
| ---------------- | ----------------------------------------------------------------------------------------------------- |
| **前置 (gateway)** | 把本机 `gateway_port` 转发到 `relay_ip:relay_port`；自动模式下通过 rsync 从中转节点拉取 `forward.json`                     |
| **中转 (relay)**   | 把本机 `relay_port` 转发到 `target_ip:target_port`；自动模式下定时把 `target_host` 解析为 `target_ip` 写回 `forward.json` |



| 运行模式            | 行为                                                  |
| --------------- | --------------------------------------------------- |
| **手动 (manual)** | 通过菜单逐条增删；规则只存在于 nftables，不写 `forward.json`          |
| **自动 (auto)**   | 由 `forward.json` 驱动 nftables 规则，cron 周期检查连通性并按需触发更新 |


---

## 二、依赖


| 依赖                          | 用途                        |
| --------------------------- | ------------------------- |
| `bash 4+`                   | 主语言（脚本明确依赖关联数组、`<<<` 等特性） |
| `nftables` (`nft`)          | 实际生效的转发规则                 |
| `jq`                        | JSON 配置解析与原子写             |
| `rsync` + `openssh-client`  | 前置节点拉取 `forward.json`     |
| `getent` / `dig` / `host`   | DNS 解析（任一可用即可）            |
| `util-linux` (`flock`)      | cron 任务串行化锁               |
| `cron` / `cronie` / `dcron` | 定时调度                      |


> 所有依赖均可由脚本内置的【1) 初始化环境】一键安装，自动适配 6 类包管理器：
> `apt / dnf / yum / pacman / zypper / apk`。

---

## 三、文件与目录


| 路径                                 | 说明                                             |
| ---------------------------------- | ---------------------------------------------- |
| `/root/.forward/config.json`       | 本地配置（节点模式 / 运行模式 / 中转地址 / SSH 端口）              |
| `/root/.forward/forward.json`      | 转发配置数组（gateway 拉取自 relay，relay 直接编辑）           |
| `/root/.forward/forward_rsync`     | gateway 用于拉取 relay 配置的 ed25519 SSH 私钥          |
| `/root/.forward/forward_rsync.pub` | 对应公钥，需安装到 relay 的 `~/.ssh/authorized_keys`     |
| `/root/.forward/known_hosts`       | 私有 known_hosts，避免污染 `~/.ssh/known_hosts`       |
| `/root/.forward/cron.lock`         | flock 串行化锁文件                                   |
| `/etc/nftables.d/forward.conf`     | 实际生效的 nft 配置（脚本生成，请勿手改）                        |
| `/etc/nftables.d/backups/`         | nft 配置备份（最多 10 份）                              |
| `/etc/nftables.conf`               | 系统主配置（自动注入 `include "/etc/nftables.d/*.conf"`） |
| `/etc/sysctl.d/99-forward.conf`    | `net.ipv4.ip_forward=1` 持久化                    |
| `/etc/cron.d/forward`              | cron 任务（每 N 分钟执行 `--cron`）                     |
| `/etc/logrotate.d/forward`         | 日志轮转配置（月度，6 份）                                 |
| `/var/log/forward.log`             | 运行日志（变更、cron 自检、错误）                            |


---

## 四、配置文件

### 4.1 本地配置 `config.json`

**前置节点（gateway）支持同时连接多个中转节点**，每个中转节点是 `relays[]` 数组中的一个对象：

```json
{
  "node_mode": "gateway",
  "run_mode":  "auto",
  "relays": [
    {
      "relay_host":     "relay1.example.com",
      "relay_ip":       "",
      "relay_ssh_port": "2222"
    },
    {
      "relay_host":     "",
      "relay_ip":       "10.0.0.2",
      "relay_ssh_port": ""
    }
  ]
}
```

**顶层字段**

| 字段 | 必需 | 说明 |
|---|---|---|
| `node_mode` | 是 | `gateway` / `relay` |
| `run_mode` | 是 | `manual` / `auto` |
| `relays` | gateway+auto | 中转节点数组；relay 端不需要此字段 |

**`relays[i]` 内字段**

| 字段 | 必需 | 说明 |
|---|---|---|
| `relay_host` | 与 `relay_ip` **二选一** | 中转节点域名 |
| `relay_ip` | 与 `relay_host` **二选一** | 中转节点 IP |
| `relay_ssh_port` | 否 | 远端 SSH 端口；缺省/空 → `22`，仅非默认值才写入字段保持 config 整洁 |

**自动补全的固定项**（不暴露给用户配置，避免字符串解析歧义）

| 项 | 固定值 |
|---|---|
| 远端 SSH 用户 | `root` |
| 远端 forward.json 路径 | `/root/.forward/forward.json` |

实际拼接的 rsync 远端路径为：`root@<relay_host 或 relay_ip>:/root/.forward/forward.json`

**多 relay 聚合策略**

- 每次 cron / 立刻更新时，依次从所有 `relays[]` 拉取各自的 forward.json
- 给每条 forward 自动附加 `_source` 元字段（值为来源 relay 地址，便于诊断）
- 按 `gateway_port` 去重（jq `unique_by` 稳定保留首次出现），冲突条目数会写入日志
- **部分 relay 失败时仍按已成功部分聚合**（最大化可用性）；只有全部 relay 失败时才中止更新，本地 forward.json 保持不变

### 4.2 转发配置 `forward.json`

```json
{
  "forwards": [
    {
      "name":         "example",
      "gateway_port": 9001,
      "relay_host":   "relay.example.com",
      "relay_ip":     "",
      "relay_port":   9001,
      "target_host":  "target.example.com",
      "target_ip":    "93.184.216.34",
      "target_port":  9001
    }
  ]
}
```


| 字段             | 责任节点         | 说明                             |
| -------------- | ------------ | ------------------------------ |
| `name`         | relay 编辑     | 唯一名称，仅字母数字 `._-`，长度 1-64       |
| `gateway_port` | relay 编辑     | gateway 节点本机监听端口               |
| `relay_host`   | relay 编辑（可选） | 中转节点域名；与 `relay_ip` **二选一**    |
| `relay_ip`     | relay 编辑（可选） | 中转节点 IP；与 `relay_host` **二选一** |
| `relay_port`   | relay 编辑     | 中转节点本机监听端口（也是 gateway 转发的目标端口） |
| `target_host`  | relay 编辑     | 后端业务域名/IP                      |
| `target_ip`    | relay 节点自动维护 | 由 `target_host` 解析，gateway 不读取 |
| `target_port`  | relay 编辑     | 后端业务端口                         |


**字段读取约定**

- **gateway 端**读取顺序：`relay_host` 非空 → 解析为 IP 使用；否则使用 `relay_ip`
- **relay 端**读取顺序：使用 `relay_port` / `target_ip` / `target_port`，与 `relay_host` 无关

**目标 IP 变化检测（无独立缓存文件）**

`update_rules_from_config` 每次调用时，把 nft 中"上一轮已生效规则"的
`本机端口 → 目标 IP` 映射作为旧基准，与本轮 `build_rules_from_forward`
推算出的新基准比对：


| 检测结果                       | 行为                                         |
| -------------------------- | ------------------------------------------ |
| 任一 `lport` 在新旧映射中 `dip` 不同 | **全量更新**：先 `force` 回收所有旧规则的防火墙放行，再为新规则全量放行 |
| 所有 `lport` 的 `dip` 一致      | **增量差集**：仅对增/删条目操作防火墙                      |


> 该机制对 `relay_host` DNS 解析变化、`relay_ip`/`target_ip` 字面值改写、
> 中转节点搬迁等所有"目标 IP 改变"场景都生效，无需独立缓存文件。

---

## 五、使用方式

### 5.1 命令行

```bash
sudo ./forward.sh             # 进入交互式主菜单
sudo ./forward.sh --status    # 仅打印当前状态
sudo ./forward.sh --cron      # 非交互（cron 调用）：连通性自检 + 必要更新
sudo ./forward.sh --diagnose  # 完整诊断 / 自检（9 大维度），退出码 0/1/2
./forward.sh --help           # 显示帮助
```

`--diagnose` 退出码语义（便于在 CI / 运维检查脚本中使用）：

| 退出码 | 含义 |
|---|---|
| `0` | 全部 OK，环境与配置一切正常 |
| `1` | 仅有 WARN，环境基本可用但建议关注 |
| `2` | 出现 FAIL，关键问题需立即处理 |

### 5.2 主菜单

```text
============== 主菜单 ==============
  1) 初始化环境
  2) 设置节点模式
  3) 设置运行模式
  ── 以下根据【运行模式】动态显示 ──
  4) 新增转发        (manual)
  5) 删除转发        (manual)
  ──
  4) 编辑转发配置文件 (auto)
  5) 立刻更新         (auto)
  6) 设置定时任务     (auto)
  ──
  d) 诊断 / 自检
  c) 清空所有转发规则
  u) 卸载 forward.sh 管理项
  0) 退出
====================================
```

> **`gateway + auto` 时第 4 项语义不同**：
> - `gateway + auto` → `4) 管理中转节点`（增/删/测试 `relays[]`）
> - `relay + auto`   → `4) 编辑转发配置文件`（中转节点是配置源头）
>
> 「管理中转节点」子菜单：
>
> ```text
> === 管理中转节点 ===
>   序号  中转地址                       SSH端口    类型
>   0     relay1.example.com             2222       域名
>   1     10.0.0.2                       22         IP
>
>   1) 增加中转节点
>   2) 删除中转节点
>   3) 测试所有中转连通性
>   0) 返回
> ```

### 5.3 模式切换语义


| 场景                  | 行为                                                  |
| ------------------- | --------------------------------------------------- |
| 首次设置                | 直接保存，不提示                                            |
| 切换为不同模式             | 弹二次确认 + 清空所有现有 nft 规则 + 同步回收防火墙放行                   |
| 设为 `gateway + auto` | 自动检查 `relay_host`/`relay_ip`：有则测试拉取，无则进入 rsync 设置流程 |


---

## 六、典型部署流程

### 6.1 中转节点 (relay) 部署

```bash
sudo ./forward.sh
# 1) 初始化环境          → 安装依赖、开启 ip_forward、启用 nftables/cron
# 2) 设置节点模式        → 选 2 (relay)
# 3) 设置运行模式        → 选 2 (auto)
# 4) 编辑转发配置文件    → 增加转发，输入 name/gateway_port/relay_ip/relay_port/target_host/target_port
# 6) 设置定时任务        → 默认 10 分钟
```

### 6.2 前置节点 (gateway) 部署

```bash
sudo ./forward.sh
# 1) 初始化环境
# 2) 设置节点模式        → 选 1 (gateway)
# 3) 设置运行模式        → 选 2 (auto)
#    ── 自动进入「增加中转节点」流程 ──
#    a. 输入中转地址        # "relay1.example.com" 或 "10.0.0.1"
#                           # 自动识别 IP/域名并写入 relays[] 中对应字段
#                           # 不需要输入 root@ 与文件路径，脚本固定补全
#    b. 输入 SSH 端口        # 留空 = 22；自定义端口（如 2222）写入 relay_ssh_port
#    c. 生成 /root/.forward/forward_rsync (ed25519，所有 relay 共享一对密钥)
#    d. ssh-copy-id -p <port> root@<addr> 部署公钥（仅本次提示输入 relay 密码）
#    e. rsync 拉取测试：root@<addr>:/root/.forward/forward.json

# 如需追加更多中转节点：
sudo ./forward.sh
# 4) 管理中转节点 → 1) 增加中转节点
#   重复 a~e 即可（密钥复用，无需重新生成）

# 6) 设置定时任务
```

> 后续 cron / 立刻更新时，gateway 会**并行**从所有 `relays[]` 拉取 forward.json
> 并按 `gateway_port` 去重聚合到本地一份大的 `/root/.forward/forward.json`。

完成后两节点都将每 N 分钟自动自检：检测到任一目标不通即按节点模式触发更新。

---

## 七、实现原理

### 7.1 nftables 规则结构

脚本独占一张表 `ip port_forward`，包含两条链：

```nftables
table ip port_forward {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
        # DNAT：把进入 lport 的包改写为 dest_ip:dport
        tcp dport <lport> dnat to <dest_ip>:<dport>
        udp dport <lport> dnat to <dest_ip>:<dport>
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        # SNAT 回源：保证 dest 回包必经本机，避免不对称路由断流
        ip daddr <dest_ip> tcp dport <dport> ct status dnat snat to $LOCAL_IP
        ip daddr <dest_ip> udp dport <dport> ct status dnat snat to $LOCAL_IP
    }
}
```

刷新时使用 `nft flush table ip port_forward; nft delete table ip port_forward; nft -f forward.conf`，
**只动这张表**，不影响系统其他 nftables 规则。

### 7.2 自动模式更新链路

```text
            ┌───────────────────────┐
   cron ──▶ │ flock -n cron.lock    │
            │ forward.sh --cron     │
            └───────────┬───────────┘
                        ▼
        ┌─ run_mode != auto → 立即返回
        │
   load_running_rules     (从 forward.conf 读出当前规则)
   build_rules_from_forward(node_mode)  (从 forward.json 推算期望规则)
        │
        ├─ 数量不一致 ─┐
        │             ▼
        │    需要更新 ─→ gateway: gateway_pull_forward_file → update_rules_from_config
        │              relay  : relay_resolve_and_update   → update_rules_from_config
        │
        └─ 逐条 tcp_check 目标
              不通 ─┐
                    ▼
                同上分支
```

### 7.3 update_rules_from_config 的「差集 / 全量」联动

为避免每 10 分钟把所有 firewall-cmd / iptables 规则推倒重来，自动模式重建时：

1. `load_running_rules` 拿到旧规则集合（即上一轮已写盘的 nft 规则）
2. `build_rules_from_forward` 拿到新规则集合（gateway 模式下会**实时解析** `relay_host`）
3. 对新旧规则构建 `lport → dip` 映射，逐条比对，发现任一相同 `lport` 但 `dip` 不同
  即置 `force_full=1`
4. 写盘 + nft 重载
5. 根据 `force_full` 选择：
  - **全量更新 (`force_full=1`)**：
    - 对所有旧规则调用 `firewall_close_port ... force`（跳过共享检查）
    - 对所有新规则调用 `firewall_open_port`
    - 触发场景：`relay_host` DNS 解析变化、`relay_ip` / `target_ip` 字面值被改写、中转/后端搬迁
  - **增量差集 (`force_full=0`)**：
    - `apply_firewall_diff` 用关联数组 O(1) 计算差集：
      - 旧有但新无 → `firewall_close_port`
      - 新有但旧无 → `firewall_open_port`

> 该方案省去了独立缓存文件：「上一轮的解析结果」直接以 nft 配置中已写入的目标 IP 为准，
> 既避免了缓存与实际生效规则不一致的风险，也省去了缓存读写开销。

### 7.4 防火墙三级降级策略


| 优先级 | 检测条件                            | 行为                                                                       |
| --- | ------------------------------- | ------------------------------------------------------------------------ |
| 1   | `systemctl is-active firewalld` | 仅走 `firewall-cmd`（避免 firewalld reload 冲掉手动 iptables）                     |
| 2   | `ufw status                     | grep active`                                                             |
| 3   | `iptables -S` 可读                | INPUT (lport) + FORWARD (dest_ip:dport) + ESTABLISHED,RELATED 三类规则 + 持久化 |


删除时 FORWARD 规则按 `(dest_ip, dport)` 共享检测：仅在没有其他规则共享同一目标时才回收，
全量清空场景使用 `force` 模式跳过检查。

### 7.5 rsync 链路（多 relay 聚合）

- **多 relay 来源**：`config.json` 中 `relays[]` 数组，每项二选一填 `relay_host`(域名) 或 `relay_ip`(IP)
- 远端 SSH 用户固定 `root`，远端文件路径固定 `/root/.forward/forward.json`（避免 user@host:path 解析歧义）
- 实际拉取命令：`root@<relay_host 或 relay_ip>:/root/.forward/forward.json`
- SSH 端口：每个 relay 独立的 `relay_ssh_port`，缺省 22
- 私钥固定文件名 `forward_rsync`，ed25519 算法，无 passphrase；**所有 relay 共享同一对密钥**
- SSH 选项：`-p ${ssh_port}`、`BatchMode=yes` 严禁交互、`StrictHostKeyChecking=accept-new` 首次自动信任、`UserKnownHostsFile=/root/.forward/known_hosts` 隔离系统 known_hosts
- 公钥部署使用 `ssh-copy-id -p ${ssh_port}` 对齐端口

**聚合流程**：

```text
┌─────────────────────────────────────────────────────────────────┐
│  gateway_pull_all_relays()                                       │
├─────────────────────────────────────────────────────────────────┤
│  for i in 0..N-1:                                                │
│    rsync root@<relays[i]>:/root/.forward/forward.json            │
│        → /root/.forward/.staging/<i>.json                        │
│                                                                   │
│  jq 合并：每条 forward 追加 _source 字段（=来源 relay 地址）      │
│  jq unique_by(.gateway_port)：按 gateway_port 去重                │
│  原子替换：mv -f .agg.tmp /root/.forward/forward.json            │
└─────────────────────────────────────────────────────────────────┘
```

- 任意一个 relay 拉取失败不会中断整体流程（输出 ERR + 继续下一个）
- 全部 relay 失败时本地 forward.json 保持不变，等下一轮 cron 重试
- 聚合结果中每条 forward 都带 `_source: "<relay_addr>"` 元字段，便于诊断追溯

### 7.6 健壮性细节

- **JSON 损坏自愈**：`config.json` / `forward.json` 解析失败时自动备份 `.broken.<ts>` 并重建空结构
- **原子写**：所有 jq 写入均经 `mktemp` + `mv -f`，无半截文件
- **端口/IP 校验**：拒绝前导零（`010` ≠ `10`）、范围校验、RFC 1123 域名校验
- **nft 配置备份**：每次写盘前备份到 `/etc/nftables.d/backups/`，自动保留最新 10 份
- **颜色降级**：非 TTY 自动关闭 ANSI 颜色，便于 cron 输出与日志解析

### 7.7 诊断 / 自检 (`--diagnose`)

`do_diagnose` 是只读检查（不会触发任何 nft / 防火墙变更），分 9 个区块依次输出
`[OK]` / `[WARN]` / `[FAIL]` 三类结果，最后给出汇总并以特定退出码退出，便于
集成到 CI / 监控告警 / 运维巡检脚本中。

| # | 区块 | 检查项 |
|---|---|---|
| 1 | 依赖与命令 | `nft / jq / rsync / ssh / ssh-keygen / ssh-copy-id / flock / nc` 是否安装；DNS 解析工具任一可用；bash 4+ |
| 2 | 内核参数 | `net.ipv4.ip_forward` 当前值 + `/etc/sysctl.d/99-forward.conf` 持久化 |
| 3 | nftables 服务 | systemd `is-active` / `is-enabled`、`/etc/nftables.conf` 是否含 `include` |
| 4 | 本地配置 | `config.json` 合法性、`node_mode` / `run_mode` 取值合规、gateway 专属字段（`relay_host`/`relay_ip`/`relay_ssh_port`） |
| 5 | SSH/rsync 链路（仅 gateway） | 私钥存在 + 权限 600；中转地址形式（IP/域名 + 解析）；`ssh root@addr true` 连通；远端 `forward.json` 可读 |
| 6 | 转发配置 | `forward.json` 合法、字段完备性；relay 端 `target_ip` 是否齐全；gateway 端抽查 5 个 `relay_host` 解析 |
| 7 | nft 规则一致性 | `port_forward` 表是否加载、实际规则数 vs `forward.json` 期望规则数 |
| 8 | 转发连通性 | 逐条 TCP 三次握手测试 |
| 9 | 防火墙与定时任务 | 检测活跃防火墙；auto 模式下 `/etc/cron.d/forward` + cron 服务 + flock 可用性 |

**汇总与退出码**

| 退出码 | 状态 | 含义 |
|---|---|---|
| 0 | 全部 OK | 环境与配置一切正常 |
| 1 | 仅 WARN | 基本可用，存在警告项需关注 |
| 2 | 出现 FAIL | 关键问题，对应功能不工作；按 FAIL 行内提示修复 |

每条 `[FAIL]` 都会在行尾附带具体修复建议（如「→ 主菜单【1) 初始化环境】」）。
诊断结果同时写入 `/var/log/forward.log`，便于审计回溯。

---

## 八、完整测试验证步骤

> 测试假设：你有两台测试机：
>
> - **中转节点**（运行 relay 模式，IP `10.0.0.1`）
> - **前置节点**（运行 gateway 模式，IP `10.0.0.2`）
>
> 后端业务：用任意一台机器（可以是中转节点本身或第三台机器，本文档示例 IP `10.0.0.3`，
> 测试端口 `8080`）启动一个**纯 TCP 监听服务**模拟业务（避免引入 HTTP/TLS 等应用层协议干扰）。
>
> 启动后端 TCP 监听（在「后端」机器上执行）：
>
> ```bash
> # 用 shell while 循环 + 每次启动单连接 nc，确保上一个连接结束后立即重新监听
> # —— 不依赖 -k 选项，对所有 nc 变体都稳定（包含传统 netcat v1.10-47）
> # 客户端发来的内容会原样打印到本机终端（验证数据真的穿过转发链路）
> while true; do nc -l -p 8080; done
> ```
>
> **替代方案**（任选其一，按可用性选择）：
>
> | 命令 | 备注 |
> |---|---|
> | `ncat -lk 8080` | nmap 提供的 ncat，对 `-k` 支持最完善；多发行版包名 `nmap-ncat` |
> | `socat -v TCP-LISTEN:8080,reuseaddr,fork -` | socat fork 子进程支持并发连接，输出会带 `>>>` / `<<<` 方向标记 |
> | `python3 -m http.server 8080` | **不要使用**，本测试要求纯 TCP 不引入 HTTP 协议 |
>
> 不要使用 `nc -lk -p 8080`，传统 netcat（`nc -h` 输出含 `[v1.10-47]`）的 `-k` 不稳定，
> 完成首次连接后就会退出，导致后续的端到端测试无法进行。
>
> 没有两台机时可先做 §8.1 ~ §8.3 的单机检查。
>
> **路径约定**：本章后续所有 cron 手工触发命令都使用 `"$FWD"` 表示 `forward.sh` 的绝对路径。
> 实操时请先在测试 shell 中导出该变量（视实际放置位置而定）：
>
> ```bash
> export FWD=$(readlink -f ./forward.sh)   # 例：当前目录下的 forward.sh
> echo "$FWD"                              # 确认路径正确
> ```

### 8.1 静态检查（无需 root）

```bash
# 1. 语法检查
bash -n forward.sh && echo "语法 OK"

# 2. 帮助输出
./forward.sh --help

# 3. 未知参数
./forward.sh --bogus 2>&1 | head -3   # 应提示需要 root

# 4. shellcheck（如已安装）
shellcheck -s bash forward.sh
```

**预期**：语法 OK；--help 正常；未知参数返回非零并提示 root。

### 8.2 初始化环境

```bash
sudo ./forward.sh
# 选择 1) 初始化环境
```

**验证**（推荐直接调用一键诊断，覆盖度最高）：

```bash
sudo "$FWD" --diagnose
# 预期：[1/9] 依赖与命令 / [2/9] 内核参数 / [3/9] nftables 服务 三块全部 [OK]
# 后续区块由于尚未设置节点模式会出现 [FAIL]：
#   node_mode 未设置 → 主菜单【2) 设置节点模式】
#   run_mode  未设置 → 主菜单【3) 设置运行模式】
# 此时只关心前 3 块即可。
```

也可以做散点验证：

```bash
command -v nft jq rsync ssh-keygen flock nc | wc -l    # 应为 6
sysctl net.ipv4.ip_forward                              # 应为 1
systemctl is-active nftables                            # 应为 active
ls /etc/sysctl.d/99-forward.conf                        # 应存在
ls /etc/logrotate.d/forward                             # 应存在
```

### 8.2.1 一键诊断（建议在每次部署完成后必跑）

```bash
sudo "$FWD" --diagnose
# 预期（全部就绪时）：
#   [1/9] 依赖与命令         全部 [OK]
#   [2/9] 内核参数           [OK] net.ipv4.ip_forward = 1
#   [3/9] nftables 服务      [OK] active + enabled，主配置含 include
#   [4/9] 本地配置           [OK] node_mode/run_mode 合规，gateway 字段齐全
#   [5/9] SSH/rsync 链路     [OK] 私钥 600 + SSH 连通 + 远端文件可读
#   [6/9] 转发配置           [OK] forward.json 合法，字段完备
#   [7/9] nft 规则一致性     [OK] 实际 = 期望
#   [8/9] 转发连通性         [OK] 全部规则目标连通
#   [9/9] 防火墙与定时任务   [OK] 已安装 cron + flock 可用
#
#   诊断结果: 全部 N 项通过

echo "上次诊断退出码: $?"   # 0=全 OK, 1=有 WARN, 2=有 FAIL
```

> 任何 `[FAIL]` 行尾都会附带具体修复建议（如「→ 主菜单【1) 初始化环境】」），
> 按提示操作即可。诊断结果同时写入 `/var/log/forward.log`。

### 8.3 输入校验（在主菜单内尝试以下错误输入，均应被拒绝）


| 输入项              | 错误样例                              | 预期  |
| ---------------- | --------------------------------- | --- |
| 端口               | `0`, `65536`, `070`, `abc`        | 拒绝  |
| IPv4             | `1.2.3`, `1.2.3.256`, `010.1.1.1` | 拒绝  |
| 域名               | `-foo`, `foo..com`, `空字符串`        | 拒绝  |
| 中转地址（rsync 设置流程） | 既不是合法 IP 也不是合法域名                  | 拒绝  |


### 8.4 中转节点端到端（中转节点单机）

> 适用：仅准备了一台机器、想先验证中转节点本身的 nft 转发是否生效。
> 中转节点 `10.0.0.1` 把本机 `9001` 转发到后端 `10.0.0.3:8080`（后端 nc 监听已就绪）。

```bash
# 中转节点上：
sudo ./forward.sh
# 2) 设置节点模式 → relay
# 3) 设置运行模式 → auto
# 4) 编辑转发配置文件 → 增加转发：
#    name=test, gateway_port=9001
#    中转地址：可直接回车（默认 = 本机出口 IP，由 get_local_ip 自动检测）
#      - 直接回车 → 写入 relay_ip = 本机 IP（中转节点最常见场景）
#      - 输入 IP   → 自动写入 relay_ip 字段
#      - 输入域名 → 自动写入 relay_host 字段（前置节点会动态解析）
#    relay_port=9001
#    target_host=10.0.0.3 （或后端域名），target_port=8080
```

**验证**：

```bash
# 配置文件应被生成且 target_ip 已解析
sudo jq . /root/.forward/forward.json

# 域名 vs IP 字段应符合二选一规则
sudo jq '.forwards[] | {name, relay_host, relay_ip}' /root/.forward/forward.json

# nft 表应已创建
sudo nft list table ip port_forward

# 本机端口应已监听到 nft 规则
sudo ./forward.sh --status              # "通" 表示连通正常

# ===== 实际转发测试（在前置/客户端上发起）=====
# 1) TCP 三次握手测试：仅验证端口可达
nc -zv -w 3 10.0.0.1 9001
# 预期：Connection to 10.0.0.1 9001 port [tcp/*] succeeded!

# 2) 端到端数据流测试：验证字节真的穿过整条链路
echo "PING_FROM_CLIENT" | nc -w 3 10.0.0.1 9001
# 预期：后端监听终端 (while true; do nc -l -p 8080; done) 打印出 "PING_FROM_CLIENT"

# 备注：不要在中转节点中发起，因为本机流量不会走 PREROUTING → DNAT 不生效
```

### 8.5 模式切换与清空

```bash
sudo ./forward.sh
# 2) 设置节点模式 → 切换到 gateway
#    应弹「将清空所有现有转发规则」二次确认
# 输入 y 后：
sudo nft list table ip port_forward 2>&1   # 应报错：表已被删除
```

### 8.6 前置节点端到端（前置节点 + 中转节点）

> 完整链路：客户端 → 前置节点:9001 → 中转节点:9001 → 后端:8080

```bash
# 先在【中转节点】上确保 forward.json 已含转发条目（见 §8.4）

# 在【前置节点】上：
sudo ./forward.sh
# 1) 初始化环境
# 2) 设置节点模式 → gateway
# 3) 设置运行模式 → auto
#    rsync 设置流程：
#      - 输入 10.0.0.1            （IP 形式 → 自动写入 relay_ip）
#        或输入 relay.example.com （域名形式 → 自动写入 relay_host）
#      - 输入 SSH 端口（默认 22；输入 2222 写入 relay_ssh_port）
#      - 输入【中转节点】的 root 密码（仅本次部署公钥）
#    自动测试 rsync 拉取（命令实际为 ssh -p <port> root@<addr> rsync .../forward.json）
```

**验证**：

```bash
# 在【前置节点】上：
sudo cat /root/.forward/config.json
# 预期字段示例：
#   "relays": [
#     {
#       "relay_host":     "relay.example.com",   （或 relay_ip 二选一）
#       "relay_ip":       "",
#       "relay_ssh_port": "2222"                  （留空表示使用默认 22）
#     }
#   ]

sudo ls /root/.forward/forward_rsync*   # 私钥 + 公钥已生成
sudo cat /root/.forward/forward.json    # 已从【中转节点】拉取

# ===== 端到端转发测试 =====
# 在任一可访问【前置节点】的客户端上：
nc -zv -w 3 10.0.0.2 9001
# 预期：Connection to 10.0.0.2 9001 port [tcp/*] succeeded!

echo "PING_THROUGH_GATEWAY" | nc -w 3 10.0.0.2 9001
# 预期：后端机器（10.0.0.3）监听终端打印 "PING_THROUGH_GATEWAY"
# 这表明完整数据流：前置:9001 → 中转:9001 → 后端:8080 全部畅通
```

### 8.6.1 SSH 端口与域名连接验证 + 多 relay 聚合

```bash
# 假设有两台中转节点：
#   relay1.example.com:2222     业务端口 9001
#   10.0.0.2:22                 业务端口 9002

# 【前置节点】上清空已有 relays 重新配置
sudo jq '.relays = []' /root/.forward/config.json \
  | sudo tee /root/.forward/config.json.new
sudo mv /root/.forward/config.json.new /root/.forward/config.json

sudo ./forward.sh
# 4) 管理中转节点 → 1) 增加中转节点
#   输入 relay1.example.com  →  自动识别为域名 → relays[0].relay_host
#   输入 2222                 →  写入 relays[0].relay_ssh_port
# 再次 4) 管理中转节点 → 1) 增加中转节点
#   输入 10.0.0.2             →  自动识别为 IP   → relays[1].relay_ip
#   回车                     →  默认 22，relays[1].relay_ssh_port 留空

# 验证字段：脚本固定补全 root@ 与文件路径
sudo jq '.relays' /root/.forward/config.json
# 预期：
# [
#   {"relay_host":"relay1.example.com","relay_ip":"","relay_ssh_port":"2222"},
#   {"relay_host":"","relay_ip":"10.0.0.2","relay_ssh_port":""}
# ]

# 触发一次拉取，验证两个 relay 都被访问且按 _source 标识
sudo "$FWD" --cron
sudo tail -20 /var/log/forward.log
# 预期日志含两条："rsync 拉取成功: root@relay1.example.com:..."
#                  和 "rsync 拉取成功: root@10.0.0.2:..."
sudo jq '.forwards[] | {gateway_port, _source}' /root/.forward/forward.json
# 预期：每条 forward 都附带 _source 字段，标识来自哪个 relay

# 测试所有中转连通性（菜单 4 → 3 等价）
sudo ./forward.sh
# 4) 管理中转节点 → 3) 测试所有中转连通性
#   预期: [0] / [1] 都输出"通"
```

### 8.7 自动模式 cron 自愈

```bash
# 任一节点上：
sudo ./forward.sh
# 6) 设置定时任务 → 默认 10 分钟

cat /etc/cron.d/forward
# 应见类似（cron 文件中是 forward.sh 的真实绝对路径，不会展开 shell 变量）：
# */10 * * * * root flock -n /root/.forward/cron.lock <forward.sh 绝对路径> --cron >/dev/null 2>&1

# 立即手工触发一次 cron 入口（与 cron 调用等价）
sudo flock -n /root/.forward/cron.lock "$FWD" --cron
sudo tail -20 /var/log/forward.log
# 预期日志包含 [cron] 开始执行 / 全部规则连通正常 / 执行结束
```

### 8.8 故障注入（验证自愈）

#### 场景 A：中转节点的 target_host 解析变化（仅中转节点）

```bash
# 在【中转节点】上：手工破坏 forward.json 中的 target_ip
sudo jq '.forwards[0].target_ip="0.0.0.0"' /root/.forward/forward.json \
  | sudo tee /root/.forward/forward.json.new
sudo mv /root/.forward/forward.json.new /root/.forward/forward.json

# 触发 cron
sudo flock -n /root/.forward/cron.lock "$FWD" --cron

# 验证 target_ip 被重新解析为正确值
sudo jq '.forwards[0].target_ip' /root/.forward/forward.json
sudo tail -10 /var/log/forward.log     # 应见 "解析更新" / "[cron][relay] 更新成功"
```

#### 场景 B：前置节点的 forward.json 缺失（仅前置节点）

```bash
# 在【前置节点】上：手工删除 forward.json
sudo rm /root/.forward/forward.json

# 触发 cron
sudo flock -n /root/.forward/cron.lock "$FWD" --cron

# 验证：rsync 重新拉取
sudo cat /root/.forward/forward.json
sudo tail -10 /var/log/forward.log     # 应见 "rsync 拉取成功" / "[cron][gateway] 更新成功"
```

#### 场景 C：目标 IP 变化触发全量更新（仅前置节点）

`update_rules_from_config` 把 nft 中已生效规则的 `lport→dip` 当作"上一轮基准"，
不依赖任何独立缓存文件。下面演示如何模拟"DNS 解析变化"：

```bash
# 前置条件：【中转节点】上至少有一条转发使用 relay_host=relay.example.com 形式

# 在【前置节点】上：正常跑一次 cron，让 nft 配置写入正确的目标 IP
sudo flock -n /root/.forward/cron.lock "$FWD" --cron
sudo grep 'dnat to' /etc/nftables.d/forward.conf | head -2
# 预期：dnat to <真实IP>:<port>

# 模拟"上一轮的目标 IP 是错的"：手工把 nft 配置文件中的 dest IP 改为 9.9.9.9
sudo sed -i 's/dnat to [0-9.]*/dnat to 9.9.9.9/g' /etc/nftables.d/forward.conf

# 再次触发 cron：脚本会检测到新解析(<真实IP>) ≠ 旧已生效(9.9.9.9) → 触发全量
sudo flock -n /root/.forward/cron.lock "$FWD" --cron
sudo tail -15 /var/log/forward.log
# 预期日志包含：
#   目标 IP 变化: lport=<port> 9.9.9.9 -> <真实IP>, 触发全量更新
#   已全量更新 N 条规则 (... 触发原因: 目标 IP 变化 ...)

# 第三次再跑（此时已无变化）：
sudo flock -n /root/.forward/cron.lock "$FWD" --cron
sudo tail -5 /var/log/forward.log
# 预期：已增量更新 N 条规则 ...
```

### 8.9 防火墙联动验证

#### 场景 A：UFW 活跃

```bash
# 在测试机上：
sudo ufw enable
sudo ufw status                         # 应为 active

# 通过菜单新增/删除一条手动转发，观察 ufw 规则
sudo ufw status verbose
# 新增后预期出现：
#   <lport>/tcp ALLOW IN
#   <lport>/udp ALLOW IN
#   <dest_ip> <dport>/tcp (route)
#   <dest_ip> <dport>/udp (route)
# 删除后这些规则应消失
```

#### 场景 B：iptables（无 firewalld/ufw）

```bash
# 新增一条手动转发后：
sudo iptables -L INPUT -n  | grep <lport>
sudo iptables -L FORWARD -n | grep <dest_ip>
# 删除后再次检查，规则应被回收

# 自动模式下批量增删的差集行为：
# 编辑 forward.json 同时增加 1 条 + 删除 1 条 + 改动 1 条目标，触发更新后
# 仅 1 个旧 INPUT 被删除、1 个新 INPUT 被新增，其余共享 FORWARD 不动
sudo grep "iptables 移除\|iptables 放行" /var/log/forward.log | tail -10
```

#### 场景 C：FORWARD 共享回收安全性

```bash
# 在 forward.json 中配置两条转发指向同一 (target_ip, target_port)：
#   name=a gateway_port=9001 ... target_port=80
#   name=b gateway_port=9002 ... target_port=80
# 自动更新后删除 a：FORWARD 规则应保留（b 仍在用）
# 再删除 b：FORWARD 规则应被回收
sudo iptables -L FORWARD -n | grep <target_ip>
```

### 8.10 状态/连通性显示

```bash
sudo ./forward.sh --status
# 预期输出片段：
#   节点模式: 前置 (gateway)        # 或 中转
#   运行模式: 自动 (auto)
#   中转节点 (共 2 个):
#     [0] relay1.example.com  (port=2222)
#     [1] 10.0.0.2            (port=22)
#   远端文件路径: root@<relay>:/root/.forward/forward.json
#   定时任务: 已安装 (/etc/cron.d/forward)
#   --- 当前运行的转发规则 ---
#   序号 本机端口 目标地址          连通性
#   1    9001     10.0.0.1:9001     通
```

### 8.11 配置损坏自愈

```bash
# 写入非法 JSON
echo "not a json" | sudo tee /root/.forward/config.json

# 启动脚本（会自动备份 + 重置）
sudo ./forward.sh --status
sudo ls /root/.forward/config.json.broken.*    # 应有备份
sudo cat /root/.forward/config.json             # 应为 {}
```

---

## 九、卸载与清理

### 9.1 内置卸载（推荐）

主菜单提供 `u) 卸载 forward.sh 管理项`，需要两次确认才会执行：

```bash
sudo ./forward.sh
# 选择 u
# 第一次确认: [y/N] 输入 y
# 第二次确认: 输入 'YES' (大写三字母)
```

执行内容：

| 步骤 | 操作 |
|---|---|
| 1 | 清空所有 nft 转发规则 + **回收已放行的防火墙规则**（firewalld/UFW/iptables 都覆盖） |
| 2 | 删除 `/etc/cron.d/forward` 并 reload cron 服务 |
| 3 | 删除 `/etc/nftables.d/forward.conf` 与备份目录 `backups/` |
| 4 | 递归删除本地配置目录 `/root/.forward`（含 config.json、forward.json、SSH 密钥、known_hosts、cron.lock） |
| 5 | 删除 sysctl 持久化文件 `/etc/sysctl.d/99-forward.conf` |
| 6 | 删除 logrotate 配置 `/etc/logrotate.d/forward` |
| 7 | 删除日志 `/var/log/forward.log*`（含轮转副本） |

**保留项**（不会删除）：

- 已安装的依赖程序：`nft / jq / rsync / openssh-client / cron / util-linux` 等
- `/etc/nftables.conf` 中的 `include "/etc/nftables.d/*.conf"` 指令（其他业务可能也用）
- 当前运行中的 `net.ipv4.ip_forward` 值（仅删持久化文件，不动 sysctl 当前值）

**卸载前的提示**：脚本会**列出本前置节点已配置的所有中转节点**，并为每个节点生成对应的清理命令，便于您逐一登录处理：

```text
[警告] 本节点为 gateway，已配置 2 个中转节点。
[警告] 卸载完成后请逐一登录以下节点，移除 forward_rsync 公钥授权：
    [0] ssh -p 2222 root@relay1.example.com \
          "sed -i '/forward_rsync/d' ~/.ssh/authorized_keys"
    [1] ssh -p 22 root@10.0.0.2 \
          "sed -i '/forward_rsync/d' ~/.ssh/authorized_keys"
```

**仍需手工处理**（脚本无法跨机操作）：

```bash
# A) 逐个到中转节点上移除 gateway 的公钥授权（命令由 §9.1 卸载流程自动生成）
ssh -p <port> root@<relay_addr> "sed -i '/forward_rsync/d' ~/.ssh/authorized_keys"

# B) 如确认其他业务不依赖，可彻底关闭 IPv4 转发
sudo sysctl -w net.ipv4.ip_forward=0
```

### 9.2 手工卸载（fallback）

若内置菜单不可用（如脚本本身已损坏），可按下列顺序手工执行：

```bash
# 1) 删除 cron 任务
sudo rm -f /etc/cron.d/forward

# 2) 清空所有转发规则
sudo nft delete table ip port_forward 2>/dev/null

# 3) 移除 nft 配置文件
sudo rm -f /etc/nftables.d/forward.conf
sudo rm -rf /etc/nftables.d/backups

# 4) 移除本地配置与密钥
sudo rm -rf /root/.forward

# 5) 关闭 IPv4 转发持久化（视需求）
sudo rm -f /etc/sysctl.d/99-forward.conf

# 6) 移除 logrotate 与日志
sudo rm -f /etc/logrotate.d/forward
sudo rm -f /var/log/forward.log*

# 7) 防火墙历史放行（手工卸载场景脚本无法回收，需自行处理）
#    UFW:       sudo ufw status numbered → sudo ufw delete <编号>
#    firewalld: sudo firewall-cmd --remove-port=<port>/tcp --permanent ; --reload
#    iptables:  按 §8.9 中查到的规则一一 -D
```

> 内置卸载（§9.1）会自动处理第 7 步的防火墙回收，建议优先使用。

---

## 十、常见问题

**Q1：rsync 拉取一直失败 (Permission denied)？**
确认中转节点 `/root/.ssh/authorized_keys` 中已含 gateway 的 `forward_rsync.pub`；
脚本固定以 `root` 用户连接（见 §10 Q10 修改方法）。
也请确认 `sshd_config` 允许 root 登录（`PermitRootLogin prohibit-password` 即可）。

**Q2：连通性显示「不通」但实际能连通？**
脚本只用 TCP 三次握手判断目标是否可达（`</dev/tcp/host/port` + `timeout`）。
如目标只响应 UDP，可用 `nc -uvz host port` 验证；本工具的 nft 规则同时下发 tcp+udp 两条，
不影响实际转发。

**Q3：切换节点模式后旧的防火墙放行如何处理？**
模式切换 → 二次确认 → `clear_all_rules` 调用 `firewall_close_port ... force` 自动回收。
但若是历史遗留（脚本管理之外手工添加）则不会被清。

**Q4：能否同一台机器既做前置节点又做中转节点？**
可以，但不推荐：脚本以全局 `node_mode` 决定规则语义，单机只能选一个角色。
若必须共存，可手动在 nftables 表里追加另一组规则，或拆为两台容器/虚机。

**Q5：cron 任务是否会重复执行？**
不会。cron 命令格式 `flock -n /root/.forward/cron.lock ... --cron`，`-n` 表示拿不到锁立即放弃，
保证任意时刻最多只有一个 `--cron` 实例在跑。

**Q6：如何查看历史变更？**
`/var/log/forward.log` 记录所有变更（菜单操作、cron 触发的更新、防火墙增删）。
`/etc/nftables.d/backups/` 保留最近 10 份 nft 配置快照，可用于人工回滚。

**Q7：`relay_host` 域名 TTL 很短，每次都触发全量更新岂不是很重？**
不会。`update_rules_from_config` 是把"实时解析结果"与 nft 中"上一轮已生效的目标 IP"
做比对，只有**真正发生变化**时才走全量；TTL 只影响 DNS 查询本身，不影响是否触发全量。
全量的额外开销主要在 firewalld reload / iptables -D&-I，规模 < 几十条时完全可控。

**Q8：如何强制下一次 cron 走全量更新？**
任意手段把 nft 中的目标 IP 改成与新解析结果不同的值即可。最简单：
`sudo sed -i 's/dnat to [0-9.]*/dnat to 9.9.9.9/g' /etc/nftables.d/forward.conf`，
下次 `--cron` 检测到目标 IP 变化触发全量。或者直接清空 nft 配置文件：
`sudo : > /etc/nftables.d/forward.conf`，下次 cron 把所有规则重新放行。

**Q9：可以临时改 SSH 端口吗？**
可以。直接修改 `/root/.forward/config.json` 的 `relay_ssh_port` 字段，
脚本下一次调用 rsync 时自动读取；非法端口或缺失字段都会安全回退到 22。

**Q10：能换 SSH 用户名 / 远端文件路径吗？**
不行（设计上故意不暴露）。脚本固定使用 `root` 用户与 `/root/.forward/forward.json`
路径，避免字符串解析歧义（IPv6 含 `:`、scp 风格 host:path 等）。如确需自定义，
请直接修改脚本顶部的 `REMOTE_SSH_USER` / `REMOTE_FORWARD_PATH` 常量。