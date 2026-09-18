# 自循环任务（助手侧清单）

配合 `one-sentence.md` 第 3 节。用户说「自循环 / 一直循环直到没问题」或给了具体交付物时用。

**前置：第 1 节 git-sync 已装、第 2 节 PowerShell 已发给用户。** 否则不要进本文件。

## 什么不算「与本地打通」（禁止）

- 沙箱目录 `local/inbox/`、`local/status_receipts/`
- 自己写的 `local_bridge_skill.py` / `copy_to_local()`
- 用 python 复刻一套 `skills/docx_skill.py` 冒充「安装了 01a0a821 的 skills」
- 只在沙箱 `git commit` 就说「本机已接收」

真打通 = 用户机器上存在 `.\watch.ps1` 计划任务 `git-sync-watch-<文件夹>`，
`.\watch.ps1 -Status` 能看到 heartbeat。交付物经 **git 工作分支** 到那份克隆。

## 超时（不要写死 600）

`agent-wait.sh` / `agent-handsfree.sh` 默认 `--timeout auto`：

- **早结束**：handshake 变成 passed/failed 的那一次 poll 就返回（简单任务常见 30～120 秒）。
- **晚结束**：上限 = `check_timeout_min`（分钟，默认 30）× 60 + 180 秒；可用 `sync.config.json` 的 `wait_timeout_sec` 或命令行 `--timeout N` 覆盖。
- 死等 600 秒再看结果 = 错误用法。
- exit 3 = 值守不在。重贴 PowerShell，不要改口说沙箱已经是本机。

## 每一轮

1. 做任务（生成/修改文件）。任务以用户这句话为准，不默认 docx。放 `deliverable/`。
2. 更新 `results/status/success_criteria.json`，让「没问题」可机读。
3. `agent-handsfree.sh --sync "..." --request "verify: ..." --timeout auto`
4. 0 = 收尾；2 = 根据检查日志改代码再来一轮；3 = 本机值守不在，重贴 clone+bootstrap，不要 accept。

最多认真修 5 轮；第 5 轮仍失败就把日志和缺的标准列给用户，停止空转。

## 本机在自循环里做什么

值守 `hands_free=true` 时：

- 助手 push → 最多一个轮询间隔（默认 2 分钟）本机自动 `sync.ps1`
- 本机改文件 → 自动静默 push（`local: auto ...`）
- 助手 `--request` → 本机跑 `check_cmd`（含 success_criteria）并把 passed/failed push 回分支

用户**不必**每轮 `.\sync.ps1` / `.\push.ps1`。只要该克隆的值守还在跑。
