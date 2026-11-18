# 远程会话「只看结果」同步

你在 Android 的 DSH Go 里连远程主机跑任务时，手机现在会收到**全过程**：每个工具调用和它的完整输出、每一步的起止、思考流（`assistantStream` 的 token 分片）、子代理事件，逐条推过来。手机要解密、解析、更新状态、重绘——即使你正在看别的 App。结果是发烫、耗电，而其中绝大部分内容你根本不会看。

这份设计把同步改成「结果模式」：**手机只同步任务跑到哪、什么时候结束、最后说了什么、有没有要你批的；过程默认不传、不渲染，需要时再按需取。**

| 项 | 位置 |
|---|---|
| 主机插件补丁 | `runtime/host-remote/`（新增；上游 `ds-harness-remote` 0.6.5 的补丁集 + 构建/安装脚本） |
| 协议 | capability `remote.result.only.v1`、请求字段 `resultOnly`、省略记录 `log/omitted` |
| 客户端 | `packages/dsh_client/lib/src/session_api.dart`、`models.dart`、`transcript.dart` |
| App | `app/lib/state/chat_state.dart`、`app/lib/ui/remote/remote_screen.dart`、l10n |
| 状态 | P0–P3 已实现；桌面检查与 Android 真机主流程、最终图片、审批与提问已验证；长时温度/电流、生产签名包待补；P4（按需看过程、上游 PR）待做 |

## 1. 目标（重新描述）

要的最终效果，一句话：

> 会话在手机上呈现为「状态 + 最终答复 + 一行过程省略标记」，不是滚动的工具日志和思考流；审批照常弹，历史里也一样。

具体到你会看到的东西：

- **执行中**：一行状态（第几步、跑了多久、是否在等审批）。没有工具行，没有思考流，没有 token 逐字出现。
- **结束时**：最终答复全文（该有的 Markdown、代码块都在），加一行「过程已省略：N 步 / M 次工具调用 / 约 X MB」。
- **审批/提问**：照常弹出并可回答，绝不省略——省了它们任务会静默卡住。
- **历史**：重开会话看到的是同样的「答复 + 省略行」，不会重新灌一遍全过程。
- **过程可取**：点省略行按需从主机读那一段（第二阶段，单独页面，不混进当前时间线）。

不是目标：

- 不改本地（PRoot）引擎——本地是同进程共享内存，不走隧道。
- 不改其他远程客户端（Web / ACP）的默认行为：它们不带 `resultOnly` 就还是全量。
- 不做「只留最后一条消息」的极端模式。中间的文字进度（每次 step 一两句，通常几 KB）保留；工具、步骤、思考流、子代理才丢。

硬约束：

1. **seq 身份必须保持，原始 seq 不再连续**。`_SessionWatch` 原本对 follow 的 durable 事件要求 seq 连续；结果模式下主机把一段被丢记录压成一条 `log/omitted`，`seq` 是最后一条被丢记录。客户端必须把标记视为覆盖 `fromSeq..seq`，把 `_lastSeq` 直接推进到 `seq`；只有标记的 `fromSeq` 仍大于 `_lastSeq + 1`（真实缺口）才 `_Resync`，不做逐页补洞。
2. **审批/提问、`turn/end`、错误必须保留**。
3. **主机插件不能由手机远程升级**。bridge 的 `checkRemoteBundleUpdate` 对远程插件自身更新返回 `PERMISSION_DENIED`：「The Remote plugin can only be updated locally on the Host.」所以功能前提是主机本地装了带补丁的插件；旧主机上开关不可用，App 必须优雅降级。
4. 主机插件 MIT（[liguobao/ds-harness-remote](https://github.com/liguobao/ds-harness-remote)）。以补丁集 + 构建脚本进仓，不整树复制（理由见 §5.1）。

## 2. 现在为什么烫

不是轮询。链路是：

```text
远程 DSH 引擎 → 主机插件 pump() → harness.remote.frame（一条事件一帧）
  → Noise 加密 → WebRTC / Relay → 手机 tunnel_carrier._onEvent
  → 一条 mux item → _SessionWatch → ChatState → 32ms 合批重绘
```

每个 `harness.remote.frame` 都要解密、JSON 解析、分配对象、过 mux 队列、更新 Riverpod、触发重绘；App 退到后台也一样（`MainActivity.shouldDestroyEngineWithHost()` 返回 false，Dart 和订阅都活着）。心跳只有 25s 一次（`tunnel_carrier.dart` 的 `healthInterval`、relay 的 `_heartbeatMs`），不是耗电主因；主因是**帧的数量和体积**。

实测（本机 6 个最大会话的回放，2026-11；不是估算）：

- 原样 **225.67 MB / 107,955 帧**；按结果模式过滤后 **8.37 MB / 8,766 帧**，字节 **-96.3%**，帧数 **-91.9%**。
- 只删 `data.stream` 就省 **-46.1%**（225.67 → 121.68 MB）。现有「精简历史」不碰它，所以整窗口只省 **10.4%**。
- 500 条消息窗口里，`stream` 占 **37.9%**、工具记录占 **12.4%**；只删 `stream` 并截断工具载荷是 **-40.8%**。整会话回放说明结果模式的收益远高于这个保守目标。
- 窄集合（只丢工具/步骤类，保留 job 与 delivery）是 **-88.4%**；把 `job/registered`、`job/settled`、`session-log-deepseek/delivery-accepted` 也丢后到 **-96.3%**。省略标记 3,390 条、701.5 KB，占结果字节 8.4%。
- 最大单会话 51.82 MB → 1.91 MB，23,055 → 2,319 帧。

按记录结构，一次 40 次工具调用的 turn 约 200 帧；结果模式下只剩 turn/文本/审批，约 5–10 帧。回放的整体帧数降幅是 **12.3×**。

## 3. 最终效果样例

### 3.1 执行中

```text
┌──────────────────────────────────────────┐
│ ‹  dsh-go · 远程主机          MacBook Pro │
│                                   ● 在线  │
├──────────────────────────────────────────┤
│                                          │
│            ┌───────────────────────────┐ │
│            │ 把 remote 层的同步改成     │ │
│            │ 只看结果                   │ │
│            └───────────────────────────┘ │
│                                  你 10:41 │
│                                          │
│  ◐ 正在执行 · 第 14 步 · 03:12            │
│                                          │
└──────────────────────────────────────────┘
```

没有工具行、没有思考流、没有逐字输出。状态来自 `turn/start` / `$events` 的 `api-session/status` / 本地计时。

### 3.2 完成

```text
┌──────────────────────────────────────────┐
│ 你 10:41                                  │
│ 把 remote 层的同步改成只看结果             │
│                                          │
│ 已省略 37 条过程记录                      │
│                                          │
│ DSH 10:52                                │
│ 完成。改了 6 个文件：                      │
│                                          │
│ 1. session_api.dart：WatchOptions 增加…   │
│ 2. models.dart：新增 SessionOmittedEvent… │
│ 3. …                                     │
│                                          │
│ ✓ 已完成 · 11 分 03 秒                    │
└──────────────────────────────────────────┘
```

省略行是独立的 `OmittedRow`（`chat_rows.dart` / `chat_list.dart`），一行弱化文字，不参与「已完成 turn 折叠」：结果模式下本地本来就没有过程可折叠。连续出现的省略行会合并计数；被模型插话文字隔开的分段仍各占一行（真机上一次 20 次工具调用被保留记录切成多段，原来会出现十几行，合并后只剩几行）。

### 3.3 审批照样弹

```text
│ ⚠ 需要你确认                              │
│ 运行 rm -rf build/ ？                      │
│ [允许一次]  [本会话允许]  [拒绝]           │
```

审批走 `$events` 的 waterfall，不走 follow 的 durable 记录；过滤只碰会话日志，审批链路本来就在。

### 3.4 会话列表

```text
│ dsh-go                                    │
│ 重构 remote 同步 · 已完成 10:52            │
│ dsh-remote / 修复断线重连 · 运行中 02:11   │
```

会话列表本身走 `watchSessionControl` 的投影（标题、运行状态、模型），不含会话日志，所以列表刷新本来就不传工具输出；这次没有改它。团队页的一次性成员日志读取（`agents_state._recentEvents`）仍发全量，列入 P4。

### 3.5 点开过程（第二阶段）

```text
┌──────────────────────────────────────────┐
│ ‹  过程 · 第 14 步                         │
├──────────────────────────────────────────┤
│ 10:41  bash   ls packages/dsh_client      │
│ 10:41  read   session_api.dart            │
│ 10:42  grep   resultOnly                  │
│ …                                          │
│ [加载更多]                                 │
└──────────────────────────────────────────┘
```

按 `fromSeq..toSeq` 用**全量**请求读一页，渲染在单独页面；不合并回主时间线，避免「已省略」和「完整记录」互相覆盖。

## 4. 数据通信

### 4.1 能力与开关

主机在 `harness.transport.describe` 的 capabilities 里增加 `remote.result.only.v1`。

- App 连上后读到它，才在「设置 › 远程主机 › 只看结果」显示开关；没有就置灰，提示「主机插件需升级」。
- 旧主机：不发 `resultOnly`，行为完全不变。
- **不新增 configure RPC**：开关是每个请求携带的，不是连接级状态。切换后下一次 follow/page 立即生效（App 会 `_relisten()` 拿一份新快照，避免两种基线混读）；也不需要像「精简历史」那样重建客户端。

### 4.2 请求

`session/follow` 的 open payload：

```json
{
  "request": {
    "address": {"workspace": "dsh-go", "sessionId": "…"},
    "maxMessages": 500,
    "turnWindow": {"turns": 50, "steps": 2},
    "resultOnly": true
  }
}
```

`session/page`（历史/补洞）：

```json
{
  "request": {
    "address": {"workspace": "dsh-go", "sessionId": "…"},
    "throughSeq": 8447,
    "beforeSeq": 8000,
    "maxMessages": 500,
    "resultOnly": true
  }
}
```

主机插件在**转发给引擎之前**把 `resultOnly` 摘掉，而且只对认识这个 flag 的端点做：`openStream` 只处理 `session/follow`，`call` 只处理四个 history 端点，其余端点的 payload 原样转发。摘除时克隆 payload，改根/`request`/`args`/`args.request`/`args._request` 里的副本，不污染原对象。引擎的 zod schema 永远看不到这个字段，旧引擎也不会因为未知字段报错。同样地，主机只在请求带 flag、且自己支持时才过滤。

同一份 flag 用于：`session/follow`、`session/page`、`session/history`、`session/events`、`subagent/history`。

### 4.3 保留 / 丢弃

| 记录类型 | 结果模式 |
|---|---|
| `turn/start`、`turn/end` | 保留（含结束原因、错误） |
| `user/message` | 保留 |
| `assistant/message` | **裁剪后保留**：只留 `content` 里的 text 块，删 `data.stream`；没有 text 块就整条丢 |
| `approval/asked`、`approval/decided`、`approval/policy` | 保留 |
| `permission/preset`、`sandbox/mode`、`model/selection` | 保留（都很小） |
| `llm/retry`、`llm/retry-started` | 丢（瞬时重试属于过程；最终失败仍由 `turn/end` 和错误文本体现，保留会把一次省略切成十几行） |
| `agent/inbox/spliced` | 保留（运行中塞进来的用户消息） |
| `step/start`、`step/end` | 丢 |
| `tool/call`、`tool/result`、`tool/ptc-dispatch`、`tool/ptc-dispatch-start` | 丢 |
| `request/header`、`request/context` | 丢（每回合重复的大块上下文） |
| `job/registered`、`job/settled`、`session-log-deepseek/delivery-accepted` | 丢（高频账本记录，P0 实测占省略标记的大头） |
| `assistant/attempt` | 丢 |
| `todo/write` | 丢 |
| `subagent/*` | 丢（子代理自己的会话不在手机时间线里） |
| 其他未知类型 | 默认保留（宁可多发一条，不静默吞新语义）；出现新的高频类型再补进丢表 |

被丢的连续记录合并成**一条** `log/omitted`，见 §4.4。中间夹着模型可见文字时仍分成多条，这是对话流水的真实顺序，不做跨文字合并。

### 4.4 省略记录 `log/omitted`

```json
{
  "type": "log/omitted",
  "seq": 8447,
  "time": 1792712157588,
  "data": {
    "fromSeq": 8420,
    "count": 28,
    "bytes": 4382210,
    "kinds": ["tool/call", "tool/result"],
    "tools": ["bash", "read", "grep"],
    "turn": 3,
    "step": 7
  }
}
```

规则：

- `seq` = 这段里最后一条被丢记录的 seq；`fromSeq` 到 `seq` 之间**全部**是被丢记录，所以整段恰好被一条记录覆盖。客户端看到的是原始 seq 缺口，但把标记当作覆盖 `fromSeq..seq` 的权威记录，`_lastSeq` 直接推进到 `seq`；这不是需要补洞的缺口。
- 只在「下一条保留记录」之前发出，或在流关闭/页尾结算。**不在一次被丢记录串的中间结算**：标记的 `seq` 必须等于紧邻前一条被丢记录，否则标记覆盖的区间不完整。一个 turn 里可能有多条省略行（工具串被一段文字答复隔开），属正常。
- `count` 是记录条数，`bytes` 是被丢记录的 JSON 字节数（近似值），`kinds` 是去重后的记录类型（最多 8 个），`tools`/`turn`/`step` 用于 UI 文案。
- 快照与分页里也插入同样的记录（窗口首尾不足一段时，`fromSeq` 取窗口内第一条被丢记录），这样冷启动、历史往回翻都能得到同一个视图。快照末尾若仍是丢记录，**不补尾标记**：客户端把快照的 `cursor` 当作权威上界，不要求 `records` 末尾对齐。

### 4.5 帧样例（前后对比）

现在，一次工具调用产生两帧，其中 result 带完整输出：

```json
{"streamId":"s-1","hasValue":true,"value":{"type":"tool/call","seq":8421,"time":1792712010000,"data":{"callId":"call_7","name":"bash","arguments":{"command":"…"}}}}
{"streamId":"s-1","hasValue":true,"value":{"type":"tool/result","seq":8422,"time":1792712012345,"data":{"callId":"call_7","output":"…48 KB…"}}}
```

结果模式，28 条这类记录变成一帧：

```json
{"streamId":"s-1","hasValue":true,"value":{"type":"log/omitted","seq":8447,"time":1792712157588,"data":{"fromSeq":8420,"count":28,"bytes":4382210,"kinds":{"tool/call":14,"tool/result":14},"tools":["bash","read","grep"],"turn":3,"step":7}}}
```

`assistant/message` 也一样：带 620 KB `stream` 的记录裁剪成约 2 KB 的纯文本消息：

```json
{"type":"assistant/message","seq":8419,"data":{"turn":3,"step":2,"message":{"role":"assistant","content":[{"type":"text","text":"先看 remote 层的帧路径。"}]},"usage":{…}}}
```

一个 40 次工具调用、约 11 分钟的 turn（估算）：

| | 现在 | 结果模式 |
|---|---|---|
| follow 帧数 | ~200 | ~8 |
| 字节 | ~6 MB | ~40 KB |
| 手机侧解析/重绘 | 每帧一次 | 每 turn 几次 |

### 4.6 快照、分页与补洞

- 快照：主机对 `records` 走同一个过滤器并插入 `log/omitted`，`projections` / `header` 原样；不返回 `assistantStream` 的活跃 attempt。
- 分页：同样过滤。`session/page` 的 `throughSeq` 在主机会 `Math.min(request.throughSeq ?? lastSeq, lastSeq)`，所以补洞时即使不知道头游标也能取尾部。
- 补洞：客户端 `_fill` 要求页覆盖到自己的 `_lastSeq + 1`；省略记录让每一段都「有记录」，因此现有连续性检查不需要放宽。
- 重新打开：`SessionSnapshotEvent`（非 resync）会 `_log.clear()` 后用快照重建，所以切开关后 `_relisten()` 不会把两种基线混在一起。

### 4.7 兼容与降级

| 组合 | 行为 |
|---|---|
| 新 App + 旧主机 | 没有 capability，开关不可用；不带 `resultOnly`，全量，和现在一样 |
| 旧 App + 新主机 | 不带 flag，全量；`log/omitted` 不会出现 |
| 新 App + 新主机，关开关 | 全量 |
| 新 App + 新主机，开开关 | 结果模式；审批、错误、结束原因照常 |

### 4.8 为什么不用现有做法

- **扩 `remote.history.configure`**：它的 schema 是 `z.object({compact}).strict()`，加字段会让旧主机直接 400；而且它是连接级、只作用于历史接口，管不到 live follow。
- **客户端收到再丢**：带宽、解密、解析、重绘都已经发生，省不了电；快照仍会把全过程灌进来。
- **只做压缩/精简历史**：现有实现不碰 `data.stream`，实测窗口只省 10.4%；压缩只换带宽，帧数和重绘成本不变。
- **只轮询结果**：引入延迟和额外请求，审批还会漏。

## 5. 改动点

### 5.1 主机插件：`runtime/host-remote/`

上游 `packages/plugin` 有 24k 行源码 + 提交过的 dist，整树复制进仓会让每次上游变动都变成一次手工合并。这里沿用仓库对引擎的做法：**钉版本 + 补丁 + 构建脚本**。

```text
runtime/host-remote/
  upstream.json            # name/version(0.6.5)/gitHead/source sha256、pnpm、许可证说明
  patches/0001-result-only.patch
  build.sh                 # 取 GitHub 源码归档 → 校验 → 打补丁 → tsc + vitest → npm pack
  install.sh               # dsh plugin --profile <p> add <打包出的 tgz>
  reload.sh                # 安装后触发 HMR 重组合；HMR 关闭时仍要重启
```

`build.sh` 从 `upstream.json` 的 GitHub 源码归档拉取（**不是 npm tarball**：npm 包不含 `src/` 与 `tests/`），校验 SHA-256，应用补丁，跑 `pnpm check` 与串行 vitest，产出 `ds-harness-remote-0.6.5-result-only.tgz`。`install.sh` 转发给 `dsh plugin add`（本质是 profile 里的 pnpm）：

```bash
dsh plugin --profile desktop add ./dist/ds-harness-remote-0.6.5-result-only.tgz
```

包版本号保持 `0.6.5`（上游 `verify-version-sync` 会检查），用产物文件名的 `-result-only` 后缀区分；安装本地 tgz 会替换同版本依赖。

启用了 HMR 的主机不必重启：`reload.sh` 安装后 `touch` 已装包的 `dist/index.js`，再改写 profile 的 `cordis.patch.yml` 触发重组合。桌面 host 实测插件先 `host runtime stopped` 再重新 ready，PID 不变。只跑 `dsh plugin add` 或只 `touch` patch 都不会触发；HMR 关闭时仍需重启主机。

补丁内容：

1. 新增 `src/result-only.ts`：
   - `takeResultOnly(payload)`：从根/`request`/`args`/`args.request`/`args._request` 摘掉 flag，克隆后再改，不污染原 payload；
   - `ResultOnlyFilter`：逐条 `push(record)`，返回「省略标记 + 保留记录」或空；`flush()` 结算；`snapshot()`/`entries()`/`events()` 处理快照与分页；
   - `filterResultOnly(endpoint, result)`：只对 `session/page`、`session/events`、`session/history`、`subagent/history` 生效；
   - `resultOnlyStream(source, signal)`：丢掉 `assistant-stream` 帧，过滤快照/事件，流关闭时先 flush。
2. `src/harness-remote-bridge.ts`：
   - `call` 只对 `session/page`/`session/history`/`session/events`/`subagent/history` 调 `takeResultOnly`，`openStream` 只对 `session/follow` 调；其他端点 payload 原样转发，后续 `gateway.dispatch`/`gateway.open` 只看到摘掉 flag 的请求；
   - `wireResult` 在 compactHistory 之前先 `filterResultOnly`；
   - `pump(..., resultOnly)`：`for await` 的 source 换成 `resultOnlyStream`；`session/follow` 仍按原顺序发 `harness.remote.frame`，关闭时先 flush 再发 `harness.remote.stream.closed`。
3. `src/rpc-router.ts`：describe 的 capabilities 里加 `remote.result.only.v1`，只在有 bridge 时广告（codex/acp-only 主机不广告）。
4. 测试：过滤表逐类断言；省略标记的 seq 连续性；`turn/end` 前必然 flush；审批/错误不被丢；快照/分页同规则；`session/follow` 带 flag 时 gateway 收到的 payload 不再有 `resultOnly`，wire 上不出现工具内容。

上游不动 `session-format-compat.ts`：`log/omitted` 是普通 durable 记录，原样透传。

### 5.2 Dart 客户端：`packages/dsh_client`

1. `WatchOptions`（`session_api.dart:62`）加 `resultOnly`（默认 false）；`_followRequest()` 加 `'resultOnly': true`，并省略 `assistantStream`。
2. `DshClient.history()` 加 `resultOnly`。**`_fill` 不传**：结果模式下 `_onFrame` 把 `SessionOmittedEvent` 当作覆盖 `fromSeq..seq` 的标记，推进 `_lastSeq`；真实缺口才 `_Resync`，不做逐页补洞。
3. `models.dart`：`SessionOmittedEvent`（`fromSeq`、`count`、`bytes`、`kinds`、`tools`、`turn`、`step`）并加进 `SessionLogEvent.fromJson` 的 switch。
4. `transcript.dart`：
   - `apply` 收到 `SessionOmittedEvent` 时，先删 `_log` 里 `fromSeq..seq` 的条目，再存标记（防止先有全量、后切结果模式时残留旧记录）；
   - `_DurableFold` 产出 `OmittedChatItem`（或复用 `NoticeChatItem` 的样式），渲染「过程已省略」行；
   - `conversation_export.dart` 导出时把标记渲染成一行文字，别丢。**尚未实现**：当前导出走到 `default`，省略段直接消失（见 §6 P4）。
5. 测试：请求体含 flag；标记解析；`fromSeq..seq` 清理（含快照重载与 `prependHistory`）。

### 5.3 App

1. `RemoteAccount` 暴露 `hostCapabilities`；`DshRemoteRelayBackend` 实现 `ResultOnlyRelayBackend.supportsResultOnly(client)`（能力探测，不是 setter：flag 随每次 follow/page 请求走，没有连接级 configure）。`HostConnection.resultOnlySupported` 只在 Relay 连接且能力存在时为 true；本机/SSH 恒为 false。
2. `RemoteResultOnlyController`（SharedPreferences `remote_result_only`），默认关。设置页开关在 `app/lib/ui/remote/remote_screen.dart`，与「精简历史」并排；主机不支持时禁用并给提示。
3. `chat_state.dart`：`assistantStream: !_quiet && !_resultOnly`、`resultOnly: _resultOnly`；开关变化时重建 watch（下一次 follow 生效）。开着结果模式时 `_quiet` 不再需要，逻辑上等价于恒 quiet。
4. 列表/预览：`agents_state.dart` 的 `_recentEvents`（团队消息，一次性 200 条）**未接入**；`sessions_state` 的列表走 `watchSessionControl` 投影，不含会话日志，无需过滤。
5. UI：独立的 `OmittedRow` 一行显示「已省略 N 条过程记录」，不依赖 `foldCompletedTurns`。
6. l10n：`remote_zh.arb` / `remote_en.arb` 新增 `remoteResultOnly`、`remoteResultOnlyHint`、`remoteResultOnlyUnsupported`、`searchKwRemoteResultOnly`、`remoteOmittedProcess`，跑过 `python3 app/tool/l10n_merge.py`。
7. 指南：`docs/guide/{zh,en,harmony/{zh,en}}/03-engine-hosts.md` 各加一段，跑过 `python3 app/tool/guide_sync.py`。

### 5.4 文档

`docs/architecture.md` §5.1 已补「只看结果」一句；本文件作为设计依据。发布说明里需写清「主机需安装本仓库产出的 `0.6.5-result-only` 补丁包，手机不能替你升级」。`docs/changelog.md` 只记录已发布版本，本次改动待发版时补。

## 6. 分期

| 阶段 | 内容 | 产出 / 验证 |
|---|---|---|
| P0（已完成） | 用真实会话 JSONL 回放过滤规则，确认省下的字节/帧数；冻结记录分类表 | 6 个最大会话 225.67 MB→8.37 MB（-96.3%），107,955→8,766 帧（-91.9%）；只读脚本 + 数字 |
| P1（已完成） | 主机插件补丁：能力、请求摘字段、follow/pump 过滤、`log/omitted`、单测 | `build.sh` 绿；打包产物含能力与标记；旧客户端不带 flag 不触发过滤 |
| P2（已完成） | 客户端：`resultOnly`、`SessionOmittedEvent`、transcript 清理与省略行；`history` 透传 | `dart analyze` 干净；`dart test` 911 通过（唯一失败是基线也复现的 heartbeat 用例）；fake host 请求体测试 |
| P3（已完成） | App 开关 + 省略行 + l10n/指南 | App analyze 无 error；目标测试通过；l10n/guide 检查通过；Android 真机连补丁主机跑通 20 次工具调用，开/关对比见 §7 |
| P4（待做） | 按需看过程（单独页面，全量读一页）；导出省略行；团队消息预览；上游 PR | 真机；上游 issue/PR 链接 |

真机验证是硬性的：远程/配对/隧道相关改动不能只靠桌面测试（AGENTS.md）。P3 结束前至少在 Android 真机上连一次真实主机，跑一个 ≥10 分钟、≥20 次工具调用的任务。

## 7. 验证与验收

单测：

- 主机（vitest）：分类表逐条；标记 seq 连续；flush 时机；审批/错误不丢；快照/分页与 live 一致；带 flag 的 wire 上搜不到工具输出。
- 客户端（`dart test`）：请求体、事件解析、transcript 清理。导出未实现，未测。
- App：设置开关的持久化与能力门控；l10n/guide 检查。尚无 fake host 播 resultOnly 流的 widget 测试。

真实会话回放（已完成，P0）：对 `~/.dsh/sessions/**/session.v4.jsonl.zstd` 的大会话跑同一过滤器，统计「保留记录 / 丢弃记录 / 标记数 / 字节」：

- 6 个最大会话：**225.67 MB → 8.37 MB（-96.3%）**，**107,955 → 8,766 帧（-91.9%）**，超过 ≥90% 帧数、≥50% 字节的目标；
- 500 条消息窗口的保守样本：stream 37.9% + 工具 12.4%，只删 stream 并截断工具是 -40.8%；
- 冷启动快照字节同比例下降（真机尚未复核）。

真机（P3，2026-11-18，Android vivo V2303A + 补丁主机 0.6.5）：

- 环境：独立 `DSH_HOME` 里装 `runtime/host-remote/build.sh` 产物，手机 debug 包（最终 1.1.0+11181457）扫码配对，P2P/TURN 自动切换；桌面主机与本会话未重启。
- 结果模式：20 次 `bash`（每次 `date; sleep 2`，约 77 s）和 6 次/4 次短任务都只显示「已省略 N 条过程记录」与最终答复，没有工具卡片，没有逐 token 流；turn 正常结束，未进 resync 循环。真机上原先把 `llm/retry` 当保留记录，一次 20 次调用被切成十几行；改成丢弃瞬时重试、并由客户端合并连续省略行后，同一个回合只剩 3 行（4 / 23 / 171 条），4 次调用只剩 1 行（37 条）。
- 关闭结果模式后重连：同一会话显示「已完成 · 4 次工具调用」，历史完整；证明开关只影响传输，不改变主机会话。
- 同一会话冷启动快照：开 = **81,452 B / 1 帧**，关 = **360,240 B / 1 帧**，**-77.4%**。这是历史快照，不含 live turn 的帧；live 回合本身在结果模式下只剩文本/标记，桌面回放预计再少一个数量级。
- 最终输出完整性（2026-11-18，同一真机/补丁主机，结果模式开）：用真实 Passport 会话验证，最终答复里的 Markdown 图片（hero_front / hero_back）直接在手机上渲染，点开可看全图；「交付了 4 个文件」卡片保留 4 个文件与两张缩略图，文档、图片都能打开。中间步骤的图片（工具结果里的截图）按设计仍被丢弃，只有当最终答复引用它或通过 `present` 交付时才看得到。
- 同一轮发现并修掉一个预览路径 bug：从最终答复点开 `docs/hardware/enclosure-v4-gamelearn.md` 后，文档内 `../../hardware/...` 的图片全部显示「无法显示」，主机日志是 `workspaceFiles/stat` → `WORKSPACE_PATH_DENIED` / `outside-root`。原因是预览把相对目录 `docs/hardware` 直接当 baseDir，`resolveSessionPath` 在 cwd 非绝对时不折叠 `..`。修复：`_MarkdownDocument` 用 `workspaceRootProvider` 把 baseDir 落到绝对工作区根；补了 widget 回归测试；真机复验文档图片正常、文档内 `model.py` 相对链接也能打开。
- 真机首轮发现并修掉一个补丁 bug：请求摘字段时给原生 args 注入了不存在的 `_request: undefined`，网关报 `unexpected "_request"`，`session/follow` 直接 INTERNAL_ERROR。修复后补了回归单测，重新打包并跑通真机。
- 审批/提问真机（2026-11-18，结果模式开）：在 `工作区内修改` 下写工作区外的 `/Users/garin/Project/llm/dsh-approval-outside.txt`，审批卡出现「允许运行这条命令？」；点「允许本次」后命令执行、最终答复返回文件内容，过程只剩 1 条省略标记。`ask_user_question` 也正常弹出 red/blue 选项，选 red 提交后最终答复为 “You chose red.”；两次都没有 resync 循环。
- 审批首轮暴露一个 App 崩溃：省略标记打断 `deriveRows` 的 fold 边界，`chat_rows.dart` 抛 RangeError，界面卡在 2%。已修 fold 起点/终点保护并加回归测试；同时修客户端把 `log/omitted` 的 seq 当缺口、每段都强制 resync 的问题，跟随流现在接受 `fromSeq <= last+1` 的标记。修后重跑 20 次工具调用、审批、提问均正常。
- 未覆盖：最终答复里原生 `image` content block（当前主机只保留 text block）——本会话没有这种消息，未实测；≥10 分钟长任务；电池温度/电流前后对比；生产签名包。验收仍以「不丢结果、不丢审批、标记覆盖其丢段、真实缺口仍能 resync、旧主机/旧客户端不变」为准，不把省字节当唯一目标。

验收口径：**不丢结果、不丢审批、标记覆盖其丢段、真实缺口仍能 resync、旧主机/旧客户端行为不变**；省字节和帧数是收益，不是唯一目标。

## 8. 风险与取舍

- **上游演进**：补丁钉在 0.6.5 的 gitHead；上游改 `pump`/`call` 结构时补丁要重做。缓解：补丁尽量小、只碰两个现有文件 + 新增一个文件；`upstream.json` 记录源码归档 SHA-256；上游 PR 合入后删补丁。
- **能力探测失败**：主机没装补丁时开关不可用；UI 必须说清「需要主机本地升级」，不能让用户以为 App 坏了。
- **中间文字进度**：结果模式保留每次 step 的文本（几 KB）。如果你连这个也不想看，再加「只留最后一条」的严格档（见 §9）。
- **未知记录类型**：默认保留，可能漏掉未来新增的高频类型；版本钉死 + 回放脚本能提前发现。
- **字节统计成本**：对被丢记录做 `JSON.stringify` 只为算 `bytes`；相对省下的传输可以忽略，但大输出时在主机会多一次序列化。必要时只统计长度、跳过内容。
- **隐私**：结果模式让工具输出不再经过手机，是减少暴露面；但 `log/omitted` 会带工具名与参数摘要，仍属会话元数据，按现有会话数据处理。

## 9. 待定

1. 开关默认值：建议默认关（结果模式改变历史呈现，先让用户主动开）；你的手机会话可以一键打开。
2. 是否要「只留最后一条答复」的严格档：默认不做；文字进度很小，保留更像正常对话。
3. 省略行是否显示工具名：建议只显示次数与字节，点开详情再看；避免又变成日志。
4. 上游 PR 的形态：能力 + 请求字段 + 记录类型三件套一次提，还是先提能力与过滤、按需详情放后续。
5. 主机插件版本号：已定保持 `0.6.5`，产物名加 `-result-only` 后缀；不升 semver，避免和上游 `verify-version-sync` 冲突。
