# BrowserSkill 自循环 — 证据目录

这个目录里的文件**只能由你本机产生**。Arena 沙箱里没有 `bsk` 守护进程，也没有浏览器扩展，
所以沙箱永远无法伪造它们 —— 这正是「打通」的判定依据。

每一轮由你机器上的 git-sync 值守（计划任务 `git-sync-watch-*`）执行：

```
watch.ps1  ->  code\local_check.ps1  ->  code\bsk_arena_chat.ps1  ->  bsk CLI  ->  你的浏览器
```

产生：

| 文件 | 内容 |
| --- | --- |
| `result.json` | 机读结论：`ok`、`session_id`、`message_sent`、`reply_detected`、每一步状态 |
| `transcript.md` | 人读回合纪要（发了什么、页面回了什么） |
| `observe_before.txt` | 发送前 `bsk observe` 的语义快照 |
| `observe_after.txt` | 回复稳定后的语义快照 |
| `page.png` | `bsk screenshot` 的视觉证据 |

判定标准写在 `results/status/success_criteria.json`，由本机 `local_check.ps1` 核对，
结论通过 git 推回分支，沙箱侧 `agent-handsfree.sh` 读到 passed 才收尾。

任务参数在 `results/status/browser_task.json`（URL、要发的话、超时、是否借用已打开的标签页）。
改那个 JSON 就能换一轮任务，不需要动任何 `.ps1`（`.ps1` 必须保持纯 ASCII，
Windows PowerShell 5.1 会按 ANSI/GBK 解码，中文会直接让脚本解析失败）。
