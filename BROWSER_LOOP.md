# BrowserSkill × git-sync 自循环

目标：**Arena 里的我不碰你的浏览器，而是让你机器上的值守去碰**，然后把证据经 git 推回来，
我读到 `passed` 才收尾。整条链路不需要你每轮点任何东西。

```
[Arena 沙箱]  改 results/status/browser_task.json  ->  agent-handsfree.sh  ->  push
                                                                              |
                                                                              v
[你的 Windows]  git-sync-watch-* 计划任务  ->  sync.ps1  ->  code\local_check.ps1
                                                                |
                                                                v
                                        code\bsk_arena_chat.ps1  ->  bsk CLI  ->  你的浏览器
                                                                |
                                       deliverable/browser-loop/{result.json,transcript.md,page.png}
                                                                |
                                                                v
                                        success_criteria 核对 -> 判定 push 回分支 -> 沙箱读到 passed
```

## 组成

| 文件 | 跑在哪 | 作用 |
| --- | --- | --- |
| `results/status/browser_task.json` | — | 一轮任务的全部参数（URL / 要发的话 / 超时 / 借标签页规则）。沙箱只改这个。 |
| `code/bsk_arena_chat.ps1` | 本机 | 真正操控浏览器：`bsk status` → `session start` → 导航或借标签页 → `observe` → 找输入框 → `fill` → `press Enter` → 轮询等回复 → `screenshot` → `session stop`。写出证据。 |
| `code/local_check.ps1` (第 3 节) | 本机 | 值守每轮调用上面的脚本，失败则整轮 failed。 |
| `results/status/success_criteria.json` | 本机核对 | 五个证据文件必须存在，且 `result.json` 里 `"ok": true`、含目标 URL、`page.png` ≥ 5 KB。 |
| `deliverable/browser-loop/` | 本机产出 | 证据。沙箱造不出来（没有 bsk / 没有扩展）。 |

## 为什么沙箱伪造不了

`result.json` 里写着 `host`（你的计算机名）、`daemon_version`、`protocol_version`、
`session_id`、真实截图字节数。这些只有 `bsk` 守护进程在你机器上真的跑了一轮才拿得到。
沙箱里 `bsk status` 根本没有 socket 可连。

## 一轮怎么走

1. 沙箱改 `browser_task.json`（换 URL 或换要发的话）。
2. 沙箱跑：
   ```bash
   bash skills/git-sync/scripts/agent-handsfree.sh \
     --sync "browser loop: round N" --request "verify browser round N" --timeout auto
   ```
3. 本机值守下一次轮询（默认 2 分钟内）自动 `sync.ps1` → 跑 `local_check.ps1` → 浏览器动起来
   → 写证据 → 推回判定。
4. 沙箱侧 exit 0 = 通过并已收尾；exit 2 = 看 `results/status/check_rN_*.txt` 修一轮再来；
   exit 3 = 值守没起来（这时不许说"已打通"）。

## 边界（脚本自己会说清楚，不会假装成功）

- **登录墙**：目标站点要登录时，脚本在 `transcript.md` 里标 `login check: WARN`，并让这轮 failed。
  你在那个浏览器配置里登录一次就行，下一轮自动过。
- **借用标签页**：`borrow_tab_match` 命中一个你已经打开的标签页时会先请求借用；
  你在扩展里开了"借用前确认"，那就需要你点一次同意（这是扩展的安全设定，命令行覆盖不了）。
  借不到就自动退回"开新标签页导航"，不会卡死。
- **回复判定**：对比发送前后的 `observe` 文本，扣掉自己发的那句，剩下的新增行才算回复；
  并要求页面连续 `settle_sec` 秒不再变化，避免把"正在输入"当成答案。
- 每轮结束一定 `session stop`（借的标签页归还、Agent 窗口关闭），失败也一样。

## 换一轮任务只需要改这几个键

```json
{
  "url": "https://...",
  "message": "要发的话",
  "composer_hint": "只在多输入框页面需要：匹配 observe 里那一行的正则",
  "reply_timeout_sec": 240,
  "require_reply": true,
  "borrow_tab_match": "只在想借已打开标签页时填",
  "login_pattern": "(?i)\\b(sign in|log in)\\b"
}
```

把 `"enabled": false` 写进去就跳过浏览器这一节（其余 git-sync 检查照跑）。
