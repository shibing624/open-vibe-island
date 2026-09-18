# 更新日志

本文件记录 Open Island 的所有重要变更。格式遵循
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/spec/v2.0.0.html)。

已发布版本的内容转录自
[GitHub Releases](https://github.com/shibing624/open-vibe-island/releases)，
release 页面始终是发布说明、安装方式与贡献者致谢的权威来源。

`Unreleased` 段收集的是最新 tag 之后合并进 `main` 的改动。

## [Unreleased]

- **Feature**：支持 agentica CLI。为其 wire 安装了托管 hook，适配它命名的多消费者出口；
  `delegate` 调用产生的委托 worker 运行会被丢弃，而不再为每次调用生成一条幽灵岛记录 ——
  委托 worker 是父会话的实现细节，通过 `AGENTICA_DELEGATE_DEPTH` 识别而非猜测。
- **Feature**：把 agentica 的工具名与回答文本带入会话元数据。`AgenticaSessionMetadata`
  为 hook 的 `tool.started` / `tool.completed` 事实提供了落点，因此 agentica 记录行能显示
  正在运行的工具与最终回答，而不再只有光秃秃的 `Running` / `Ready` 标签。
- **Feature**：用内容而非状态词来描述已完成的运行。已完成的记录行优先显示助手消息，
  其次显示 hook 自带的摘要（回答预览或 `Finished: <prompt>`），最后才回退到 `Done`。
- **Feature**：新增 CESP 事件音效主题，支持逐事件提示音与音效包下载器，并内置了已买断的
  Orc Peon 音效包，因此全新安装无需下载即可获得逐事件音效。
- **Feature**：在两次 reconcile 之间通过「已确认的 pid 存活检查」结束会话。此前 CLI 在
  发出最后一个 hook 事件后立即退出时，会在岛上多停留最多两个轮询周期；现在会每 2 秒用
  `kill(pid, 0)` 复核被跟踪的 pid，并带有 pid 复用与歧义保护。
- **Feature**：在 hook 阶段采集 tmux pane 身份。`tmuxTarget` 过去只由进程轮询路径填充，
  导致所有 hook 驱动的会话都跳过精确跳转分支，退化成仅激活 app。该采集现已落入共享的
  `HookTerminalContext`，覆盖到达 Swift hook 二进制的全部五种 payload 类型。
- **Feature**：为 Claude 系分支新增 setup CLI 的 `--source` 参数。
- **Fix**：不再把跳到别处的 tmux 跳转报告为成功。`switch-client` 与 `select-window` 的
  退出码此前被 `_ =` 丢弃，因此一次从未离开原会话的跳转仍会报告成功；`list-clients`
  此前按「首行获胜」读取，在 server 有多个 client 时会切换到任意一个。
- **Fix**：tmux pane 匹配改为按信号强度排序，而非按 pane 顺序。原循环以 pane 为主序，
  导致靠前 pane 上一次较弱的标题匹配就能抢走 TTY 精确属于靠后 pane 的会话。TTY 与
  pane id 属于身份标识，不再输给子串标题匹配。
- **Fix**：按所有消费方都要求的 `session:window.pane` 形式存储 tmux target，而不再存
  `TMUX_PANE` 原始值。
- **Fix**：为每个终端自动化子进程设置超时，并在其运行期间持续读取输出。此前
  `waitUntilExit()` 在读取输出管道之前就被调用，导致写入超过管道缓冲区的子进程与父进程
  互相死锁；多数 spawn 也缺少截止时间，而一次会话中的首个 `osascript` 可能无限期阻塞在
  自动化（TCC）授权弹窗上。
- **Fix**：避免已结束的会话被再次报告为运行中。该保护现已置于 reducer 中，覆盖了此前
  需要手写绕行逻辑的路径；迟到的 `.completed` 仍会生效，因此终端摘要不会被丢弃。
- **Fix**：跳转到 cmux 会话时聚焦 cmux 标签页。hook 二进制此前从未采集
  `CMUX_SURFACE_ID`，导致跳转只能把 cmux 带到前台。
- **Fix**：无论完成卡片以何种方式打开，都自动收起。
- **Fix**：仅在启动型会话上重新触发首条 prompt 的提示音。Claude Code 会把同一会话重新
  注册为 `resume`、`clear` 或 `compact`，因此 `taskAcknowledge` 过去会为用户已经确认过的
  工作再次响铃。
- **Fix**：使 Open Island 的 hook 与商业版 Vibe Island 互不干扰。
- **Fix**：恢复被 patch 修改过的脚本的可执行位，并移除一处仅 zsh 支持的 glob 限定符，
  使 `sh scripts/fetch-sound-packs.sh` 能跑到最终汇总，而不是在音效包已安装完成后中止。
- **Tests**：端到端钉住一个 agentica 轮次以覆盖三处元数据修复；为 tmux/Ghostty resolver
  补上首批测试；并把此前已漂移过的终端注册不变量固定下来。
- **Docs**：在文档索引中链接 agentica hooks 升级方案。
- **Chore**：新增带启动存活校验的 clean-and-run 脚本，并忽略 superpowers 计划输出。
  v1.2.1 的发布后收尾（appcast 条目、贡献者图片缓存）也已在打 tag 后落地。

## [v1.2.1] - 2026-09-15 — 点击处理、面板形变与跳回修复

- **Fix**：修复关闭状态的岛持续吞掉点击的问题。当鼠标按下落在已关闭且位于胶囊之外的 panel 上时，panel 现在会记录这次漂移点击、重新应用 click-through、重新排序窗口以使 WindowServer 采纳该设置，并把点击转发给下方的内容（限流为每 0.5 秒一次修复）(#689)。
- **Fix**：不再重复转发已经到达其他 app 的外部点击。全局与本地鼠标监视器现在会告知 panel 该点击是否被投递给了 Open Island 自身；已被其他 app 接收的外部点击只关闭岛、不再被二次合成，从而消除了关闭已打开的岛时的双击残影 (#682 by @hnrobert)。
- **Fix**：让关闭到展开的面板形变更顺滑。岛表面现在在稳定的 panel frame 内对其尺寸与圆角做动画，起始宽度取自关闭态胶囊的实际渲染宽度，并把内容裁剪到过渡中的形状，使动画过程中不会有任何内容画到表面之外。Harness 场景默认禁用 overlay 事件监听；设置 `OPEN_ISLAND_HARNESS_INTERACTIVE=1` 可保留指针交互以便手动验证 (#662 by @CommitTheKermit)。
- **Fix**：当 client 已在目标会话上时跳过多余的 tmux `switch-client`。跳回逻辑现在连同 client tty 一起读取 `#{client_session}`，仅在需要时才切换会话，因此 iTerm2 的 tmux 集成（`tmux -CC`）不再在每次跳转时拆毁并重建窗口 (#700 by @Buer2333)。
- **Fix**：映射 Qoder 的真实 bundle ID 以支持跳回。Qoder 0.1.6 上报的是 `com.qoder.app` 而非 `com.qoder.qoder`，导致 workspace 跳转永远匹配不上并落到第一个已安装的终端。Qoder 现在拥有自己的 app 描述符（含两个标识符），跳回会直接激活 Qoder workspace (#692 by @jerryyon-eng)。
- **Tests**：放宽 `CodexAppServerTimeoutTests` 中的 CI 时间上限。用于防止在 app-server 卡死时挂起的耗时检查，因并行测试套件阻塞在 osascript 超时上而在 CI runner 上以 2.0–2.4 秒误触发；现在下限改为 5 秒，意图不变 (#702)。

## [v1.2.0] - 2026-09-03 — Grok Build、Pi 与 Oh My Pi

- **Feature**：支持 Grok Build / Grok CLI。Open Island 会在 `~/.grok/hooks/open-island.json` 安装 hook 文件，覆盖完整会话生命周期 —— 会话开始与结束、prompt、工具调用、子 agent、`Stop`、`StopCancelled` 与 `StopFailure` —— 因此 Grok 会话及其活动与完成状态都会显示在岛中，并能跳回正确的终端。被中断的轮次会立即结算；max turns 之类的运行时退出会以完成态呈现。事件目前为 fire-and-forget（无权限往返）。可在设置 → 安装中启用 (#630 by @neighborLing)。
- **Feature**：支持 Pi coding agent 与 Oh My Pi。会向 `~/.pi/agent/extensions` 与 `~/.omp/agent/extensions` 安装 TypeScript 扩展，直接与桥接 socket 通信，上报会话开始、轮次、工具执行与关闭，并通过心跳保活使被杀的 agent 自行老化退出。Pi 与 Oh My Pi 拥有各自的配色与设置 → 安装行，且该扩展无需 hooks 二进制 (#639 by @UNICKCHENG)。

[Unreleased]: https://github.com/shibing624/open-vibe-island/compare/v1.2.1...HEAD
[v1.2.1]: https://github.com/shibing624/open-vibe-island/compare/v1.2.0...v1.2.1
[v1.2.0]: https://github.com/shibing624/open-vibe-island/compare/v1.1.9...v1.2.0
