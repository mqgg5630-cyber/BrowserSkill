# 新会话：用户一句话，助手自动装技能、打通本机、按需自循环

> 用户**只发一句话**（可带 Arena 链接、可带具体任务）。完整动作清单在 `one-sentence.md`。
> **不要打开 arena.ai**（登录墙）。映射见仓库根目录 `01a0a821.md`：clone GitHub `shaohuawen03-cyber/new` 分支 `arena/01a0ae7a-new`（技能总部，v2.9.2 起）。
禁止向用户索要长提示词。账号策略：贴给用户的本机块里已带 `auth.ps1 -Account <仓库主>`。

---

## 用户发的（短的）

```text
安装 arena/01a0a821-git-pull-arena skills, 与本地打通
```

## 用户发的（带自循环任务，docx/pptx 可换成别的）

```text
安装https://arena.ai/agent/01a0a821-3f3c-7bbe-bf99-6e6793c45d81的skills。与本地打通
并实现自循环任务，将这个生成docx和pptx返回到本机，本机并把结果状态push到分支，一直自动循环知道你觉得结果没问题
```

## 助手自动做的

1. 从 `shaohuawen03-cyber/new` 分支 `arena/01a0ae7a-new` 把 `skills/git-sync` 装进**本仓库当前工作分支**（安装器会自己挑最新候选）。
2. `agent-sync.sh` 提交推送。
3. 回复一段**已经填好**的本机 PowerShell（新文件夹；禁止覆盖 `git-pull-arena` / `git-pull-arena-v268` / `git-pull-arena-s2`）。
4. 若有具体任务 / 「自循环」：立刻做任务、写 `success_criteria.json`、`agent-handsfree.sh --timeout auto` 直到 accept。值守一回传就停，不空等 600 秒。
5. **不要**让用户先去旧克隆 `.\sync.ps1`。新会话走自己的分支；本机只需对该新文件夹 `bootstrap -Auto` 一次。

命令与回复模板见 [`one-sentence.md`](one-sentence.md)，任务环见 [`task-loop.md`](task-loop.md)。
