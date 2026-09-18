# 用户一句话 —— 助手必须自动跑完全套（先打通本机，再自循环）

用户**只用短句**（下面「触发句」）。助手必须自己展开成本文件第 1～3 节，**禁止**把长命令回贴让用户再发一遍，**禁止**打开 arena.ai。

## 铁律（违反 = 没打通，不许说完成）

1. **「与本地打通」= 用户 Windows 上的 git 克隆 + `.\watch.ps1` 计划任务。**
   不是沙箱里建 `local/inbox/`，不是 python `local_bridge`，不是 `copy_to_local()`，
   不是自己写一套 `skills/docx_skill.py`。那些都是假本机。
   **沙箱里的工具链不受限（v2.8.0 起）**：`pip install` / `.venv` / python-docx / python-pptx
   随便用——它们只是生成工具。唯一要求是产物**经 git 到本机**、并由**本机值守**回传判定。
   以前的「禁止 .venv」是把「别拿沙箱冒充本机」错写成了「别装库」，现已改正。
2. **必须安装的 skills** 只有这一份：
   `https://github.com/shaohuawen03-cyber/new` 分支 `arena/01a0ae7a-new`（技能总部，v2.9.2 起）
   里的 `skills/git-sync`（第 1 节那条 clone 命令）。
   `arena.ai/agent/01a0a821-...` **不要去打开**（要登录）。技能只在 GitHub。**禁止**用 python 复刻这套同步技能来冒充它。
3. **给用户的第一条可见回复必须是第 2 节填好的 PowerShell**（clone 新文件夹 + `bootstrap -Auto`）。
   那段由 `bash skills/git-sync/scripts/agent-handoff.sh` **生成**，助手不得手打（仓库/分支/路径填错
   = 本机永远收不到请求）。在用户还没拿到这段命令之前：不许生成 docx/pptx、不许自循环、
   不许写 LOOP_COMPLETED、不许说「已返回本机」。
4. 自循环只准走 `agent-handsfree.sh --timeout auto`（git 握手 + 本机值守回传）。
   exit 3 = 本机值守没起来 → **停**，再贴一次 PowerShell，**不要**假装成功。
5. 禁止覆盖文件夹：`git-pull-arena` / `git-pull-arena-v268` / `git-pull-arena-s2`。

## 触发句（用户只发这个，助手自己知道后面怎么做）

```text
安装https://arena.ai/agent/01a0a821-3f3c-7bbe-bf99-6e6793c45d81的skills。与本地打通
并实现自循环任务，将这个生成docx和pptx返回到本机，本机并把结果状态push到分支，一直自动循环知道你觉得结果没问题
```

短句也算同一套：`安装 arena/01a0a821-git-pull-arena skills, 与本地打通`

映射：`arena.ai/agent/01a0a821-*` → GitHub `shaohuawen03-cyber/new` 分支 `arena/01a0ae7a-new`（技能总部；见仓库根目录 `01a0a821.md`）。
旧 `mqgg5630-cyber/git-pull-arena` 仍可作后备；安装器会自己挑最新版。不要打开 arena.ai。
账号策略：**谁仓库的会话就用谁账号** —— 贴给用户的本机块里已带 `auth.ps1 -Account <仓库主>`。

---

## 0. 要不要先去旧克隆 sync？

**不用。** 新会话装技能、做任务、都推到**本会话工作分支**。

本机要对**这个新仓库**粘贴一次第 2 节（沙箱不能注册 Windows 计划任务）。
跑完不用回「好了」，也不用再 `sync`/`push`。假的 `local/inbox` 不算。

| 时机 | 你要不要动手 |
|---|---|
| 这句话发出去 | 助手先装 git-sync，**先把 PowerShell 发给你** |
| 这个新会话还没有值守 | 粘贴一次第 2 节 |
| 值守已在跑（同一文件夹重开） | 不用再粘，助手可以直接 `agent-handsfree` |
| 简单任务 | 值守一回传，`agent-handsfree` 立刻停（不是死等 600 秒） |

---

## 1. 助手必须先做（不要问、不要改命令）

```bash
git clone --quiet --depth 1 -b arena/01a0ae7a-new \
  https://github.com/shaohuawen03-cyber/new.git /tmp/git-sync-src \
  && bash /tmp/git-sync-src/skills/git-sync/scripts/agent-install.sh

bash skills/git-sync/scripts/agent-sync.sh "feat: install git-sync skill"
```

然后读：

```bash
git remote get-url origin
git rev-parse --abbrev-ref HEAD
test -f watch.ps1 && test -f skills/git-sync/VERSION && echo "git-sync OK"
```

HEAD 若是 `main` / `master`：**停**，先切到本会话工作分支再装。
若 `watch.ps1` 不存在：**没装上，不许进入第 3 节。**

---

## 2. 助手必须立刻回复的本机代码（填好，可直接粘）——第一条回复就是这个

**不要手打这段。** 让脚本生成，然后原样贴给用户（v2.7.5）：

```bash
bash skills/git-sync/scripts/agent-handoff.sh        # 打印填好的 PowerShell 块
bash skills/git-sync/scripts/agent-handoff.sh --json # 需要真值时用这个
```

它自己读 `git remote get-url` + `sync.config.json` 的 branch，仓库/分支/文件夹名不可能填错；
配置分支与 HEAD 不一致时直接 **exit 3 拒绝**（那正是「本机永远收不到请求」的根因）。

手写时的三个真实事故（2026-09-16）：写成另一个仓库（`zhongqi` vs `git-pull-arena`，
请求在 `pending` 挂了 2 小时）、写成上一个会话的分支、把沙箱路径 `/home/user/...` 写进
Windows PowerShell 块。生成器就是为了杜绝这三条。

生成结果长这样（占位符已被真值替换）：

```powershell
cd E:\0github\git-sync
git clone -b <BRANCH> <ORIGIN_URL> <NEW_FOLDER>
cd <NEW_FOLDER>
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\bootstrap.ps1 -Auto
.\doctor.ps1
.\watch.ps1 -Status
```

成功标志：`doctor.ps1` 的 branch 是工作分支、ahead/behind = 0/0、末尾 watcher / heartbeat / auth / **hands-free master=True**。

`bootstrap -Auto` 会暂停其他会话的 `git-sync-watch-*`（任务保留）。回 HQ：

```powershell
cd E:\0github\git-sync\git-pull-arena-s2
.\watch.ps1 -Focus
```

---

## 3. 本机命令已经发出去之后，若用户还说了具体任务 / 自循环

任务从提示词里抽（docx/pptx 只是例子）。交付物放 `deliverable/`，用 git 到用户机器，
**禁止** `local/inbox`。

1. 写 `results/status/success_criteria.json`。
2. `agent-sync.sh` 推上**本会话分支**。
3. 自循环：

```bash
bash skills/git-sync/scripts/agent-handsfree.sh \
     --sync "feat: <本轮改动>" \
     --request "verify: <用户的任务一句话>" \
     --timeout auto \
     --interval 15
```

- exit 0：本机检查过 + 标准过 + 已 accept → 停。
- exit 2：看 `results/status/check_r*_*.txt` → 修 → 再跑（round+1）。
- exit 3：本机没通。**不要继续轮询**——`agent-check.sh --read` 会告诉你这轮已经 pending 了多少分钟；
  超过 10 分钟就重跑 `agent-handoff.sh` 把第 2 节再贴一次。**禁止**改口说「沙箱 local/ 已打通」。

`--timeout auto`：结论一到就返回。细节：`templates/task-loop.md`。
