# Session Manager Daemon 设计

## 动机

当前 Armin 直接在移动端 app 进程中通过 SSH 执行 shell 脚本管理远端 tmux session。这种架构在移动场景下存在系统性缺陷：

| 痛点 | 根因 | 影响 |
|------|------|------|
| app 重启丢失所有活跃会话状态 | `_runningExecutions` 等映射仅存在于 app 内存 | 任务状态断裂、无法恢复监听 |
| `onDone` 不触发自动完成 | 移动端进程生命周期不可靠，流回调可能丢失 | 任务卡在非终端状态 |
| cleanup 不可靠 | `_cleanupTaskSession` 依赖 SSH 连通，网络中断时无法清理 | 残留 tmux session 堆积（一次测试就留下了 6 个） |
| `capture-pane` 轮询效率低 | 轮询模型是客户端主动拉取，而非服务端推送 | 网络开销大、延迟高 |
| 多设备无法共享 session | session 绑定在单设备内存中 | 无法用另一台设备接管同一任务 |

这些问题的根因一致：**移动端 app 不适合做 session 生命周期管理**。

## 方案

在远端机器上部署一个独立的后台 daemon 进程，专门管理 terminal session 生命周期。Armin 通过 SSH 通道调用 daemon，不再直接操作 tmux。

```
现在：                                Session Manager Daemon：

Phone (Armin)                         Phone (Armin)
   │ SSH + shell 脚本                     │ SSH 通道
   │ tmux 命令                            │ daemon RPC
   ▼                                     ▼
Remote tmux                          Session Manager Daemon (Go 常驻进程)
                                        │ goroutine 并发管理
                                        │ tmux 命令
                                        ▼
                                   Remote tmux sessions
```

### 为什么是 Go

- 编译为单一静态二进制，`scp` 上传即可运行，无运行时依赖
- goroutine 天然适合管理多个并发 session
- `golang.org/x/crypto/ssh` 可以直接复用现有 SSH 通道做认证
- 与 Node/Python 不同，不需要在远端安装运行时环境

## 功能边界

Session Manager **只管理 terminal session 生命周期**，不做以下事情：

- ✗ 不管理 agent 进程（那是 tmux 内部的事）
- ✗ 不做持久化（session 断了就没了，与 tmux 语义一致）
- ✗ 不做独立认证（复用 SSH 通道）
- ✗ 不解析 agent 输出（那是 Armin 的 NativeOutputObserver 职责）
- ✗ 不做事件归约（那是 Runtime reducer 职责）

### 核心操作

```
session.create(name, cwd, command)   → 创建 tmux session + 启动 agent
session.attach(name)                 → WebSocket 实时输出流（替代 pipe-pane + capture-pane 轮询）
session.send(name, text/keys)        → 发送输入、选择 terminal prompt 选项
session.list()                       → 列出当前所有活跃会话
session.probe(name)                  → 获取当前 pane 内容快照（替代 capture-pane 探测）
session.kill(name)                   → 清理会话 + 自动 GC
```

### 自动 GC

daemon 周期性扫描无客户端连接的 session，超时后自动清理（默认 1 小时），杜绝残留 session 堆积。

## 分阶段实施

### Phase A：最小可行 —— attach + kill（最高优先级）

只实现两个能力，验证架构可行性：

- **attach**：通过 WebSocket 实时推送 pane 输出，替代当前 `pipe-pane` + `capture-pane` 轮询模型。这是最大收益项——从轮询变为事件驱动。
- **kill**：可靠清理 session + 自动 GC 超时 session。彻底解决残留 tmux 堆积问题。

Armin 侧只改数据流：`SSHAgentSessionService.execute()` 内部连接 daemon attach 端点获取输出流，控制操作仍走原有 SSH 命令路径。

### Phase B：完整替换 —— create / send / probe / list

逐步替换 Armin 中的 shell 脚本生成逻辑：

- `_buildExecutionScript` 不再直接生成 tmux 命令
- 控制操作（sendFollowUp、selectTerminalOption、captureLog、cleanup）改为调用 daemon
- probe 替代 `_runControlCommand` 中的 capture-pane 探测

### Phase C：终极 —— 自建 PTY 管理（可选）

完全替代 tmux，daemon 直接管理 PTY 对。这是 tmux 选型替换的实现路径，不用改 Armin 上层代码。

## Armin 侧改动范围

| 改动 | 描述 |
|------|------|
| `SSHAgentSessionService` | `execute()` 内部 daemon attach 作为输出主通道，shell 脚本降级为 fallback |
| `AgentSessionService` 接口 | 无需变更——daemon 是实现细节，不暴露给上层 |
| `AgentExecutionRequest` / `AgentControlRequest` | 无需变更 |
| `armin_app_state.dart` | 无需变更——session 管理逻辑对上层透明 |
| `HostConfig` | 新增 `multiplexerDaemon` 可选字段（daemon 二进制路径） |

**核心原则**：daemon 是 `SSHAgentSessionService` 的内部实现细节，Armin 上层代码（AppState、UI、Bridge Runtime）无需感知。

## 与现有架构的关系

```
AgentSessionService (抽象接口，不变)
    │
    ├── SSHAgentSessionService (当前实现)
    │       └── 直接生成 tmux shell 脚本
    │
    └── SSHAgentSessionService (daemon 模式)
            └── 通过 SSH 通道调用 Session Manager daemon
                    └── daemon 管理 tmux session
```

长期目标链路（与 ARCHITECTURE.md 一致）：

```text
Session Manager Daemon (常驻，管理 session)
    ↓
RuntimeEventBus + SQLite Store (事件归约与持久化)
    ↓
Armin App UI (纯查看与控制客户端)
```

Session Manager Daemon 是向"远端 Runtime daemon"架构演进的第一步，也是 Phase 3 断线续传和 Phase 4 安全远端执行器的基础设施前置条件。

## 内网穿透方案

Armin 的核心用户在国内，Session Manager 通常部署在家庭/办公室内网，手机端需要通过互联网访问。本节分析主流方案并给出设计决策。

### 核心设计原则

**Session Manager 不做穿透**。它只监听一个 TCP 端口，提供 session 管理能力。穿透是部署层的事：

```
Armin (Phone) ──TCP──→ {host}:{port} ──→ Session Manager
                        ↑
                   穿透层把内网的 host:port
                   映射成手机可达的地址
               ├── 有公网 IP → 直接暴露
               ├── 有 IPv6 → 防火墙放行
               ├── 有云服务器 → frp 映射
               └── 什么都没有 → ZeroTier mesh
```

Armin 看到的永远是一个 `host:port`，无论背后是什么穿透方案。

### 方案对比

| 方案 | 服务器端复杂度 | 手机端依赖 | 国内稳定性 | 适合用户 |
|------|-------------|-----------|-----------|---------|
| frp | frps 部署在云服务器 | **零依赖** | ★★★★★ | 有国内云服务器的用户 |
| IPv6 直连 | 路由器放行防火墙 | **零依赖** | ★★★★ | 宽带支持 IPv6 的用户 |
| ZeroTier + 自建 Moon | 部署 Moon 节点 | 装 ZeroTier App | ★★★★ | 无公网 IP 且无云服务器的用户 |
| 公网 IP + DDNS | 路由器端口转发 | **零依赖** | ★★★ | 电信/联通宽带有公网 IPv4 的用户 |
| Tailscale + tsnet | 编译进 daemon 二进制 | 装 Tailscale App | ★★ (国内) | 海外用户 |
| Cloudflare Tunnel | 装 cloudflared | **零依赖** | ★★ (国内慢) | 有域名 + CF 账户的用户 |

### 首选方案：frp

frp 是国内开发者社区事实标准（GitHub 83k star），生态最成熟：

```
Phone ──TCP──→ 公网 frps ──TCP──→ 家里/公司内网 Session Manager
              (99元/年云服务器)        (frpc 内嵌在 daemon 中)
```

- **手机零依赖**：不需要额外 App，frp 做的是服务端端口映射
- **性能好**：纯 TCP 转发，SSH 层已加密，转发层不需要额外加密
- **部署简单**：云服务器跑 frps（一条 docker 命令），daemon 侧可选内嵌 frpc

Session Manager 可选集成：启动时通过参数指定 frp 服务端信息，daemon 自动建立端口映射：

```bash
# 不带 frp —— 需要外部手动做端口映射：
./session-manager serve --port 2222

# 带 frp —— daemon 自动注册到云服务器的 frps：
./session-manager serve --port 2222 \
  --frp-server=124.70.x.x \
  --frp-server-port=7000 \
  --frp-token=xxx
```

### 理想方案：IPv6 直连

三大运营商宽带均已支持 IPv6，手机 4G/5G 也全面支持 IPv6。零依赖、零成本。

唯一门槛是路由器放行 IPv6 防火墙的 daemon 端口。未来 Armin Host 配置应支持 IPv6 地址输入，并在连接失败时给出"请检查路由器 IPv6 防火墙"的诊断提示。

### 后备方案：ZeroTier + 自建 Moon

不适合用 frp 的场景（没有云服务器、没有公网 IP 也没有 IPv6），ZeroTier 是 Tailscale 的国内平替。关键步骤是**自建 Moon 节点**：

- 用最低配国内云服务器（99 元/年）搭建 Moon 节点
- ZeroTier 客户端配置 Moon 后，打洞延迟从 200ms+ 降至 < 10ms
- 手机端仍需安装 ZeroTier App（受限于零信任网络模型的必要性）

### 海外用户：Tailscale tsnet

Session Manager 可以内嵌 `tailscale.com/tsnet`，一个 auth key 即可将 daemon 加入 tailnet：

```bash
./session-manager serve --tailscale-auth-key=tskey-xxx
```

服务器侧部署从"装 Tailscale + 装 daemon"简化为"一个二进制一条命令"。手机端保持 Tailscale App（最成熟的移动端 WireGuard 实现）。

Tailscale 在国内不可靠（DERP 中继常被墙、UDP 易被 QoS），不推荐国内用户使用。

### 部署推荐矩阵

| 用户画像 | 推荐方案 | 最小配置 |
|----------|----------|---------|
| 有国内云服务器（阿里/腾讯/华为云） | **frp** | 云服务器跑 frps docker，daemon 指定 `--frp-server` |
| 家庭宽带支持 IPv6 | **IPv6 直连** | 路由器放行防火墙 + Armin 填 IPv6 地址 |
| 电信/联通宽带有公网 IPv4 | **公网 IP + DDNS** | 路由器端口转发 |
| 以上都没有 | **ZeroTier + 自建 Moon** | 最低配云服务器搭 Moon + 手机装 ZeroTier |
| 海外用户 | **Tailscale tsnet** | daemon 指定 `--tailscale-auth-key` + 手机装 Tailscale |
