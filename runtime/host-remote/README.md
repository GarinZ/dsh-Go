# ds-harness-remote 结果模式补丁

远程主机侧的 `ds-harness-remote` 补丁：在 0.6.5 上增加 `remote.result.only.v1` 能力，让手机在会话 follow、历史分页时只同步「状态 + 最终答复」，不同步工具调用、思考流、子代理和作业记录。

设计依据与效果样例见 [docs/design/remote-result-only.md](../../docs/design/remote-result-only.md)。

## 协议

- **能力**：`harness.transport.describe` 的 `capabilities` 里出现 `remote.result.only.v1`。
- **请求**：在 `session/follow`、`session/page`、`session/history`、`session/events`、`subagent/history` 的 payload 里带 `resultOnly: true`（可放在根、`request`、`args`、`args.request`、`args._request`）。插件在转发给引擎前把它摘掉，引擎看到的请求不变。
- **保留**：turn 起止、用户消息、assistant 的最终文本（只留非空 text 块，删 `data.stream`）、审批/权限/沙箱/模型、错误与结束原因；未知类型默认保留。
- **丢弃**：`tool/*`、`step/*`、`subagent/*`、`job/*`、`session-log-deepseek/*`、`request/*`、`assistant/attempt`、`todo/write`、`llm/retry`、`llm/retry-started`；`assistant-stream` 帧直接不发。瞬时重试属于过程，最终失败仍由 `turn/end` 和错误文本体现；这样重试不会把一段省略切成十几行。
- **`log/omitted`**：每一段连续丢弃的记录合并成一条 durable 记录，`seq` 等于最后一个被丢记录的 seq，在下一个保留记录之前发出。原始 seq 因此出现缺口；客户端把标记视为覆盖 `fromSeq..seq`，把 `_lastSeq` 推进到 `seq`，只有真实缺口才 resync。快照仍以 `cursor` 为准。
- **不改变**：审批、host request、turn 生命周期、seq/cursor、模型请求。只减少 Host→Client 的字节和帧数。

没有带 `resultOnly` 的请求完全走原逻辑，所以旧客户端、旧 App 的行为不变。

## 为什么是补丁而不是 fork

上游 `packages/plugin` 有 24k 行源码和提交过的 `dist`，整树复制会让每次上游变动都变成一次手工合并。这里只保留一个补丁，钉在 0.6.5 的 gitHead 上；`build.sh` 从 GitHub 源码归档重新构建（**不能用 npm tarball**：npm 包的 `files` 不含 `src/` 和 `tests/`）。

`upstream.json` 记录包名、版本、gitHead、源码归档 URL、SHA-256、pnpm 版本和补丁路径。构建脚本只信这个文件。

## 构建

前置：Node.js ≥ 20、`npm`/`npx`、`patch`、`tar`、`curl`。首次构建会下载源码和 pnpm 依赖，之后走缓存。

```bash
runtime/host-remote/build.sh
# 产物：runtime/host-remote/dist/ds-harness-remote-0.6.5-result-only.tgz
```

脚本依次做：

1. 从 `source` 下载源码归档到 `${DSH_HOST_REMOTE_CACHE:-~/.cache/dsh-go/host-remote}`，校验 SHA-256；
2. 解包到干净的构建目录，应用 `patches/0001-result-only.patch`；
3. `pnpm install --frozen-lockfile`，构建 `./packages/**`；
4. 在 `packages/plugin` 跑 `tsc -p tsconfig.test.json`（`pnpm check`）和全量 vitest；
5. `npm pack`，把产物改名为 `...-result-only.tgz`。

可用环境变量覆盖缓存和输出目录：`DSH_HOST_REMOTE_CACHE`、`DSH_HOST_REMOTE_OUT`。

测试串行跑（`vitest run --no-file-parallelism`）。上游 `tests/acp-workspace-controls.test.ts` 的 hermes 用例在并行跑全量时是已知 flake（与结果模式无关，未打补丁的树也能复现），串行稳定通过。

## 安装

```bash
runtime/host-remote/install.sh desktop
# 或显式指定 tgz：
runtime/host-remote/install.sh desktop ./runtime/host-remote/dist/ds-harness-remote-0.6.5-result-only.tgz
```

脚本只是转发给 `dsh plugin --profile <profile> add <tgz>`，用当前 `DSH_HOME` 下的 profile。默认 profile 是 `desktop`，可用第一个参数或 `DSH_PROFILE` 覆盖。

补丁不修改包版本号：`package.json` 仍是 `0.6.5`，这样上游的 `verify-version-sync` 才能通过。区分方式是 tgz 文件名的 `-result-only` 后缀；`dsh plugin add` 安装本地文件会替换同版本依赖。

同名构建也发布在 npm：`@garinz/ds-harness-remote`（当前 `0.6.5-resultonly.1`）。其他主机可以不传本地 tgz：

```bash
dsh plugin --profile desktop add @garinz/ds-harness-remote@0.6.5-resultonly.1
```

装完同样用 `reload.sh` 热加载（脚本会找到 scoped 包路径）。

安装后让主机加载新代码：启用了 HMR 的主机可以用 `reload.sh` 原地重载（见下节），否则**重启主机进程**（`dsh web` 或桌面 App），再让 DSH Go 重连。新的 `harness.transport.describe` 应带 `remote.result.only.v1`；主机没装补丁时，App 端的开关应不可用。

### 不重启热加载

主机进程启用了 HMR 时（桌面 App 默认如此；`dsh web` 由启动器提供 `profileContext` 时），可以用脚本原地换插件，不需要重启：

```bash
runtime/host-remote/reload.sh desktop
# 或显式指定 tgz：
runtime/host-remote/reload.sh desktop ./runtime/host-remote/dist/ds-harness-remote-0.6.5-result-only.tgz
```

它做三件事：

1. 用 `dsh plugin --profile <profile> add <tgz>` 把新包放进 profile；
2. `touch` 已安装的 `node_modules/ds-harness-remote/dist/index.js`，让 HMR 的重组合看到文件变了；
3. 改写 profile 的 `cordis.patch.yml`，删掉旧的 `# dsh-go hot reload trigger` 行，再追加一行新的触发注释。

只跑 `dsh plugin add` 不会通知 HMR；只 `touch` patch 文件也不会触发。必须让已加载的插件文件变化，并真正改动 profile 配置内容。成功时主机日志会先出现 `[ds-harness-remote] host runtime stopped`，随后再次 `host identity ready`；主机进程 PID 不变。

已在桌面 host 上验证：重载前后 PID 都是 90185，日志在 2026-11-18T13:28:59.617Z 出现 `host runtime stopped`，随后插件重新启动。HMR 关闭时脚本仍会安装并提示重启。

回滚：重新安装 npm 上的官方版本，或换回之前的 tgz，然后重启主机。

## 更新上游

1. 改 `upstream.json`：`version`、`gitHead`、`source`、`sha256`（`curl -L <source> | shasum -a 256`），必要时改 `pnpm`。
2. 在一个干净的上游树里应用旧补丁：

   ```bash
   mkdir -p /tmp/dshr-next && tar -xzf ds-harness-remote-<ver>.tar.gz --strip-components=1 -C /tmp/dshr-next
   (cd /tmp/dshr-next && patch -p1 < <repo>/runtime/host-remote/patches/0001-result-only.patch)
   ```

3. 解决冲突，重新生成补丁。只包含 `packages/plugin/src` 与 `tests`，**不要包含 `dist`**（构建会重新生成）：

   ```bash
   cd /tmp/dshr-next
   git init -q && git add -A && git commit -qm base
   # 把 result-only 的源码改动落到树上后：
   git add -N packages/plugin/src/result-only.ts packages/plugin/tests/result-only.test.ts
   git diff -- packages/plugin/src/harness-remote-bridge.ts \
     packages/plugin/src/rpc-router.ts \
     packages/plugin/src/result-only.ts \
     packages/plugin/tests/result-only.test.ts \
     > <repo>/runtime/host-remote/patches/0001-result-only.patch
   ```

4. 跑 `build.sh`，用临时 `DSH_HOME` 装一遍做 smoke test，再更新本文件里的版本号与数字。

## 兼容性与限制

- 主机没补丁：不广告能力，App 不显示开关；新客户端即使误带 flag，也会因为主机不认识而走原逻辑（旧主机忽略未知 payload 字段）。
- 旧客户端：不会带 flag，收到的事件与现在完全一致。
- 新客户端 + 旧主机：按能力隐藏开关；P2 的 `SessionOmittedEvent` 只在收到 `log/omitted` 时才会用到。
- 分页窗口整个都是一段被丢记录时，标记的 `seq` 会落在窗口尾部之前；客户端接受这个标记覆盖 `fromSeq..seq`，不要求窗口首尾对齐。正常会话里一段省略不会超过一页（500 条）。
- `log/omitted` 带工具名和参数摘要，仍属会话元数据；工具输出本身不再经过手机。

## 许可

补丁基于 MIT 许可的 [liguobao/ds-harness-remote](https://github.com/liguobao/ds-harness-remote)，保留上游版权与许可。
