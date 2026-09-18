---
name: git-local-arena-sync
description: "TRIGGER: user says 安装https://arena.ai/agent/01a0a821 的skills 与本地打通 (or 安装 arena/01a0a821-git-pull-arena skills). Do NOT open arena.ai (login wall). Immediately: git clone --quiet --depth 1 -b arena/01a0a821-git-pull-arena https://github.com/shaohuawen03-cyber/new.git /tmp/git-sync-src && bash /tmp/git-sync-src/skills/git-sync/scripts/agent-install.sh && bash skills/git-sync/scripts/agent-sync.sh. Root must have watch.ps1. First user-visible reply MUST be filled Windows PowerShell: git clone -b BRANCH URL NEW_FOLDER then .\bootstrap.ps1 -Auto. Forbidden: faking the local side (local/inbox, hand-made stand-in skill). Sandbox may pip install / use .venv freely (v2.8.0). Then do the user task (docx/pptx) and agent-handsfree.sh --timeout auto. Also Windows PowerShell <-> Arena git-sync (sync/push/watch/doctor/auth silent push, zero-window watcher)."
---

> 当前版本 **v2.9.2**（**技能总部搬到这里**：源改为 `shaohuawen03-cyber/new` 分支 `arena/01a0ae7a-new`，安装器会探测全部候选并**装最新版**，旧仓库仅作后备；**账号策略**写进技能：**谁仓库的会话就用谁账号**——生成的本机命令块自动带 `auth.ps1 -Account <仓库主>`，每个克隆钉到仓库主账号、机器默认账号不受影响。详见第 11 节。）
>
> v2.9.1（修 v2.9.0 的多账号钉账号：① helper 必须写成**被调用的函数** `!f() { ...; }; f`——git 会在命令后追加 `"$@"`，`if ...; fi` 形式会直接 `syntax error near unexpected token 'get'`；② 「空值复位」这一条在 Windows 上可能被 cmd/MSYS 吞掉，改成**三层兜底 + 读回验证**（argv → `--stdin` → 直接写 `.git/config`）；③ 钉住后**不再追加后备 helper**：账号令牌失效就明确失败，绝不回落机器默认账号。实测记录见 `CASE_STUDY.md` §9。）
> 当前版本 **v2.9.0**（**多账号**：`-Accounts` 列出本机所有 gh 登录并逐个实测「能不能推本仓库」，`-Account <login>` 把**当前克隆**钉到某个账号（只写本克隆的本地 git config，其他克隆照旧），`-Unpin` 还原；403 从此被识别为**权限问题**而不是「凭据坏了」；`doctor` / `local_check.ps1` 都会报出当前账号与 pin。详见第 10 节。）
> 当前版本 **v2.8.1**（沙箱可自由装库；安装器取最新分支且拒绝降级；值守日志带时间戳；轮询自适应；LF 统一）。一句话触发装技能+自循环；`--timeout auto` 值守一回传就停。`main` 上仍是 v2.6.7。
> 用户侧升级三步：`.\sync.ps1` → `.\watch.ps1 -Unregister ; .\watch.ps1 -Register` → `.\watch.ps1 -Status`（应看到 `hands-free: master=True`）。切回本会话：`.\watch.ps1 -Focus`。


# 本地 ↔ Agent 双向同步（skill）

一个仓库、两条链路：**你在本机按一个命令，Agent 在远端按一个命令**，中间只有 git。
所有脚本都是幂等的、配置驱动的，`agent-install.sh` 一条命令就能装进任何新仓库。

## 0. 一句话流程

```
本机                                          远端（Agent 沙箱 / Arena）
  .\sync.ps1            <---- push ----       agent-sync.sh "feat: ..."   （守卫→自检→回执→提交推送）
  .\upload.ps1          ---- pull ---->       （附件按扩展名归位 -> sources/ code/ results/）
  .\download.ps1        <---- pull ----       （把 deliverable/ 等镜像到本机；-Since 只取增量）
  .\push.ps1 "msg"      ---- push ---->       （你侧提交；两轮 agent-sync 都会把"纳入了哪些提交"写进回执）
  .\hardware.ps1        ---- push ---->       （本机硬件/环境报告；agent 开工前用 agent-hardware.sh 读）
  .\pr.ps1              ---- PR ----->        main（agent-pr.sh 同款；GitHub Actions 会跑 gate）
  .\doctor.ps1 (-Fix)   体检 / 一键修复
```

## 1. 脚本清单

### 本机侧（仓库根目录，PowerShell）

| 脚本 | 作用 | 典型用法 |
|---|---|---|
| `sync.ps1` | fetch + 切分支 + `pull --ff-only`；本地有改动先自动 stash | `.\sync.ps1` |
| `upload.ps1` | 附件按 `upload_map` 归位到 `sources/ code/ results/`，再调用 `push.ps1` | `.\upload.ps1 -Src "E:\附件"` |
| `push.ps1` | `pull --ff-only` → `add -A` → commit → push；**拒绝推 main/master**；`-Gate` 提交前本机也跑一遍自检；**默认静默**（prompts 全关，拿不到凭据 exit 4 并提示跑 `auth.ps1`，绝不弹窗等待；`-Prompt` 才允许交互） | `.\push.ps1 -Gate "add files"` |
| `auth.ps1` | **免点击推送**（`-GhLogin` 一条命令完成那唯一一次交互登录）：`-Setup`（**先探测，能静默拿到凭据就不动配置**；否则 gh 优先 / GCM，并在 dpapi·wincredman 里找已有凭据，命中 wincredman 就 unset 回默认）/ `-Verify`（prompts 关闭实跑 ls-remote + push --dry-run）/ `-MigrateStore`（复制凭据到 dpapi）/ `-Token`·`-TokenFile`·`-PromptToken`（播种令牌，永不回显）/ `-Json` / `-Unset` | `.\auth.ps1 -Setup -Verify` |
| `download.ps1` | 按 `download_sets` 用 robocopy 镜像到本机；**`-Since` 只复制某日期后变过的文件**；**`-Folders a,b` 临时指定目录** | `.\download.ps1 -Folders deliverable,examples\x` |
| `pack.ps1` | 把某个集合压成一个 zip（默认 `_export\<日期>_<集合>.zip`，不进 git） | `.\pack.ps1 -Set final` |
| `doctor.ps1` | 体检：环境/分支/远端/落后领先/未提交/stash/LFS/大文件/**技能版本** + **值守/心跳/凭据**（watcher / heartbeat / auth 三行）；**`-Fix` 一键修复** | `.\doctor.ps1 -Fix` |
| `bootstrap.ps1` | 首次准备：执行策略、git 身份、fetch、切分支、首拉；`-Auto` 追加"免点击凭据 + 注册值守" | `.\bootstrap.ps1 -Auto` |
| `hardware.ps1` | **采集本机硬件与环境**（OS/CPU/内存/GPU 显存/磁盘/conda/mamba 环境列表，`-Deep` 探测每个环境的 torch+CUDA）写入 `hardware_dir` 并推送 | `.\hardware.ps1 -Deep` |
| `watch.ps1` | **自动验证循环的本机侧**：`-Register` 注册常驻循环；**v2.7.0 每轮 auto_pull + auto_push**（hands_free）；请求检查时 sync → `check_cmd` → 推回 passed/failed；`-Status`（含 hands-free 行）、`-Test`、`-Pause`/`-Resume`/`-Unregister`、**`-Focus` / `-RestoreParked` / `-KeepOthers`** | `.\watch.ps1 -Register` |
| `pr.ps1` | 用 GitHub CLI 开 PR（工作分支 → main），`-Checks` 看 CI | `.\pr.ps1` |
| `install.ps1` | 把整套技能装到另一个仓库（升级时**保留**对方已有配置） | `.\install.ps1 -Target C:\MyProject -Branch arena/xxx` |

### 多账号（v2.9.0，`auth.ps1`）

| 用法 | 作用 |
|---|---|
| `.\auth.ps1 -Accounts` | 列出本机所有 gh 登录 + 各自能否推**本仓库**（`repos/OWNER/REPO` 的 `permissions.push`） |
| `.\auth.ps1 -Account <login>` | 只把**当前克隆**钉到该账号（写本克隆 local git config；先清空 helper 列表再钉，否则机器级 helper 会先应答） |
| `.\auth.ps1 -Unpin` | 去掉本克隆的 pin，回到机器默认账号 |

同一台机器多个仓库各用各号时**只动这一个文件夹**；`gh auth switch -u X` 才是改机器默认（影响所有克隆）。
### 助手侧（`skills/git-sync/scripts/`，bash）

| 脚本 | 作用 | 典型用法 |
|---|---|---|
| `agent-sync.sh` | 分支守卫 → fetch → 发散自愈 → gate → **写同步回执并按日期归档** → commit + push | `bash skills/git-sync/scripts/agent-sync.sh "feat: ..."` |
| `agent-check.sh` | **自动验证循环的助手侧**：`--request` 请求本机检查（round+1）/ `--read` 读结果（exit 0=过 2=败 3=等）/ `--accept` 通过收尾 | `bash skills/git-sync/scripts/agent-check.sh --request "verify X"` |
| `agent-wait.sh` | **一条命令闭环**：`--request` 后原地轮询直到值守推回（**一到就停**，默认 `--timeout auto` = 检查时限+3 分钟，不是死等 600s）；`--auto-accept` 通过即收尾 | `bash skills/git-sync/scripts/agent-wait.sh --request "verify X" --timeout auto` |
| `agent-hardware.sh` | **读取本机硬件报告**（缺失或过期会提醒让用户跑 `hardware.ps1`） | `bash skills/git-sync/scripts/agent-hardware.sh` |
| `agent-recover.sh` | 沙箱 `.git` 被重置回基线提交后，保住工作区恢复历史 | `bash skills/git-sync/scripts/agent-recover.sh` |
| `agent-pr.sh` | 助手侧开 PR / 看 CI（`--dry-run` 只打印） | `bash skills/git-sync/scripts/agent-pr.sh --checks` |
| `agent-install.sh` | **把这套技能一条命令装进任何仓库**（新会话复用的入口） | 见第 7 节 |
| `agent-criteria.sh` | **成功标准**：读 `success_criteria.json`（文件/子串/大小/正则/禁止项；`require_files` 支持 glob） | `bash skills/git-sync/scripts/agent-criteria.sh` |
| `agent-handsfree.sh` | **解放双手闭环**：sync → request → wait（`--timeout auto`）→ criteria → 全过 `--accept` | `bash skills/git-sync/scripts/agent-handsfree.sh --request "..." --timeout auto` |

### 模板与标识（`skills/git-sync/templates/` 等）

| 文件 | 作用 |
|---|---|
| `check_all.sh` | 通用 gate：.ps1 全 ASCII + 配置分支守卫 + 根目录与 skill 脚本一致性（含 auth.ps1；缺根目录副本也算失败）+ **每个 .ps1 语法可解析**（PATH 上有 powershell/pwsh 时用 PowerShell 自己的解析器，没有就显式 SKIP）；典型坑扫描器 `scan_ps_var_colon.py` 找 `"$var:"`（盘符变量陷阱，会让整份脚本一行都不跑）；python 解释器按 python3 → python 依次探测（Windows/conda 常常只有 python）；`agent-install.sh` 会装到 `code/check_all.sh` |
| `gate.yml` | GitHub Actions：push 后自动跑 gate（`agent-install.sh --gha` 安装；agent 令牌若没有 workflows 权限，就由本机侧复制后 push） |
| `new-session-prompt.md` | **新会话引导提示词模板**：整段复制到任何新 Arena 对话，一条命令装好本技能，并附本机步骤与双向验收清单 |
| `local_check.ps1` | **本机自检模板**（装到 `code\local_check.ps1`，只建不覆盖）：默认跑 gate + 留好扩展点（文件存在性/Office COM/GPU 冒烟测试等），是 `watch.ps1` 在 agent 请求检查时实际执行的东西 |
| `local-runner.md` | **本机即 Runner 配方**：把自动验证循环当远程任务执行器用（任务在真实本机环境跑、产物自动回传、`--auto-accept` 自动收尾），含两个实战案例 |
| `health.yml` | GitHub Actions **每日体检**：握手卡死 / 硬件报告过期自动开 issue 提醒（注意：定时任务只跑默认分支，启用时把文件放 main 并改 `BRANCH`；agent 令牌无 workflows 权限时由本机复制启用） |
| `../VERSION` | 技能版本号；`doctor.ps1` 与安装器会显示，升级对账用 |

## 2. 配置：`sync.config.json`

脚本里**不写中文、不写死分支**；一切可变的都在这个 UTF-8 JSON 里：

```json
{
  "branch": "arena/01a0a821-git-pull-arena",
  "remote": "origin",
  "download_dir": "",
  "download_sets": { "final": ["deliverable"], "all": ["deliverable", "code", "skills"] },
  "upload_map":    { ".docx": "sources", ".py": "code", ".xlsx": "results" },
  "gate": "bash code/check_all.sh",
  "receipt": "results/sync/last_sync.md",
  "receipt_history": "results/sync/history",
  "hardware_dir": "results/hardware",
  "handshake": "results/status/handshake.json",
  "check_cmd": "powershell -NoProfile -ExecutionPolicy Bypass -File code/local_check.ps1",
  "check_timeout_min": 30,
  "lock_stale_min": 45,
  "hands_free": true,
  "auto_pull": true,
  "auto_push": true,
  "success_criteria": "results/status/success_criteria.json"
}
```

* `download_dir` 留空 → 下载到仓库上一级的 `<仓库名>_out`；
* `receipt` 是助手侧每轮 `agent-sync.sh` 落盘的**同步回执**（留空关闭）；`receipt_history` 是**按日期归档**目录（留空不归档；自动只保留最近 50 份，文件名 `YYYYMMDD-HHMMSS.md`）；
* `hardware_dir` 是**本机硬件报告**目录：`hardware.ps1` 写入 `latest.md`/`latest.json` + `history/<时间戳>.md`（保留 30 份），`agent-hardware.sh` 读取；
* **多环境 profile**：每台机器 `setx GIT_SYNC_PROFILE lab` 一次，脚本就会优先找 `sync.config.lab.json`；单次也可 `-Config <路径>` 指定。查找顺序：`-Config` > profile > `sync.config.json`；
* `gate` 是助手侧提交前运行的检查命令，失败就**不提交**；本机侧想跑同一套检查用 `.\push.ps1 -Gate`；
* `check_timeout_min` 是单轮本机检查的硬超时（分钟，默认 30，超时判 `failed` 并在日志头写 `TIMEOUT`）；
  `lock_stale_min` 是值守锁的过期分钟数（默认 45，脚本保证它 ≥ 超时 + 15，否则长任务会被并发轮询打断）。

## 3. 铁律（踩过的坑）

1. **`.ps1` 只用 ASCII**。Windows PowerShell 5.1 读无 BOM 的 `.ps1` 时按 GBK 解码，中文注释会把引号吃掉。中文放在 `.md` 与 `.json` 里（`hardware.ps1` 生成的报告里出现中文系统名是运行时数据，不受影响）。gate 提交前自动扫全部 `.ps1`。
2. **只在自己的工作分支上动**。脚本默认从配置读分支；`push.ps1`/`pr.ps1`/`agent-pr.sh` 直接拒绝 `main`/`master`；`agent-sync.sh` 发现 HEAD 不是配置里的分支就退出。
3. **不要 `git init` 再推同一分支**（历史不一致会被拒），也不要在冲突时 `--force`。
4. **推送前先 `pull --ff-only`**（两个方向的脚本都内建），避免 non-fast-forward。
5. **大文件不进 git**。放 `build/` 之类被 ignore 的目录，或本地 `pack.ps1` 外发；`doctor.ps1` 会列出超过 50 MB 的被跟踪文件提醒上 Git LFS。
6. **「与本地打通」不是沙箱 `local/` 目录。** 必须是用户 Windows 上的 `watch.ps1` 计划任务。禁止用 python 复刻 skills、禁止 `local_bridge` / `local/inbox` 冒充本机。给用户的第一条回复必须是填好的 `git clone` + `.\bootstrap.ps1 -Auto`。自循环只准 `agent-handsfree.sh`；exit 3 就是没打通。
7. **用户只用短句。** `安装https://arena.ai/agent/01a0a821-...的skills。与本地打通` 就是完整入口。禁止打开 arena.ai（登录墙），禁止向用户索要 `USER_PROMPT.md`。映射：clone **`https://github.com/shaohuawen03-cyber/new.git` 分支 `arena/01a0ae7a-new`**（技能总部，v2.9.2 起；根目录 `01a0a821.md`）。旧 `mqgg5630-cyber/git-pull-arena` 只作后备候选。

## 4. 故障对照表

| 现象 | 处理 |
|---|---|
| `cannot be loaded because running scripts is disabled` | `.\bootstrap.ps1`（内部设 CurrentUser RemoteSigned） |
| 提示输入密码 | GitHub 不接受密码 → `gh auth login` / GitHub Desktop |
| `rejected - non-fast-forward` | 先 `.\sync.ps1` 再推；助手侧 `agent-sync.sh` 会自动对齐远端 |
| `pull --ff-only` 失败 | 本机有分叉提交：`.\doctor.ps1` 看清状态，或直接 `.\doctor.ps1 -Fix` |
| 你的改动进了 stash | `git stash list` → `git stash pop`（`doctor -Fix` 的 stash 也在里面） |
| robocopy 报 8 以上错误码 | 目标目录被占用/权限不足；`download.ps1` 只在 ≥8 时报失败，0—7 都正常 |
| 下载后文件是旧的 | 先 `.\sync.ps1` 再 `.\download.ps1`；只要最近变过的文件加 `-Since <日期>` |
| 想下的目录不在任何集合里 | `.\download.ps1 -Folders <目录1>,<目录2>`，或加进 `download_sets` |
| Agent 不知道本机算力/该用哪个环境 | 本机跑 `.\hardware.ps1 -Deep`（GPU/conda/torch+CUDA 全量上报）；agent 侧 `agent-hardware.sh` 读取，超 30 天会提醒重跑 |
| **助手侧**：`git log` 只剩 `Initial commit`，`git status` 全是新文件 | `.git` 被静默重置：`agent-recover.sh`（工作区不动），然后 `agent-sync.sh` 提交（它内部也会自动自愈） |
| 助手侧 fetch 拉不到远端分支 | `agent-sync.sh` / `agent-recover.sh` 现已自动补全 refspec（`+refs/heads/*:...`）再 fetch |
| 分支对不上 / 一团乱 | `.\doctor.ps1 -Fix`：重建 refspec + stash + 切回配置分支 + 拉取 |
| 删掉跟踪文件后提交里没有这次删除 | 分叉自愈会 `ls-files -d` 还原：再跑一次 `agent-sync.sh`，或直接 `git rm` + `git commit` + `git push`（`CASE_STUDY.md` §11） |
| 本机 push 报 `permission denied`（存的是旧号凭据） | 别重登录：浏览器把旧号加为仓库 Collaborator，两边各用各号共存（`CASE_STUDY.md` §2）；或 `.uth.ps1 -Account <login>` 只钉本克隆（§10）；`push.ps1` 的"branch moved"遇 exit 4 是误报 |
| 本机 push 报 `403 ... Permission to OWNER/REPO denied to OTHER-USER` | 凭据没问题、**账号没权限**：`.uth.ps1 -Accounts` 看谁能推 → `.uth.ps1 -Account <login>` 只钉本克隆（§10） |
| 设了 `credential.https://github.com.helper` 却「没生效」 | helper 列表是**累加**的，机器级先应答：用 `.uth.ps1 -Account <login>`（先写空值清空列表再钉） |
| 本机 `-c` 探针在每台 python 上都 Traceback | PS 5.1 调 native 会吞双引号：`-c` 里只准单引号（`CASE_STUDY.md` §5） |
| 同一分支 Win＋WSL 双值守 | 会抢答/重复 verdict：只准一侧 live（`CASE_STUDY.md` §3） |

## 5. 首次使用

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned      # 只做一次
.\bootstrap.ps1                                          # 身份 / 分支 / 首拉
.\doctor.ps1                                             # 确认状态（含技能版本）
.\hardware.ps1 -Deep                                     # 上报本机硬件与环境（每台机器一次）
```

## 6. 与 Agent 协作的约定

1. Agent 每轮 `agent-sync.sh` 提交推送（**只推约定分支**），回执落在 `receipt` 路径并按日期归档，你 `.\sync.ps1` 后可读；
2. 你这边只记两条：`.\sync.ps1`（取）和 `.\upload.ps1`（传）；要交材料用 `.\pack.ps1`；
3. 交付物落地 `.\download.ps1 -Set final`；增量加 `-Since <日期>`，目录不在集合里用 `-Folders`；
4. **计算/训练类工作**：agent 开工前先 `agent-hardware.sh` 看本机报告（GPU 型号显存、哪个 conda 环境有可用 CUDA 的 torch），据此选环境、选设备、定 batch size；硬件或环境变化后重跑 `.\hardware.ps1 -Deep`；
5. **单会话优先（2026-09-15 决定）**：只走"一会话一仓库"，把单会话闭环做扎实——agent 请求检查 → 本机值守**零窗口**跑完 → **免点击**推回 → `agent-wait --auto-accept` 一次拿到 exit 0。多会话并行/汇总会话（模式 B/C）**暂时搁置**（调度、合并、冲突仲裁成本高于收益），需要时按技能 README.md 第七节重启；
6. 任何"不对劲"先 `.\doctor.ps1`（或 `-Fix`），把输出贴给 Agent。

## 7. 装进新仓库（用户只发一句话）

用户在任何新 Arena 会话里只说（带 Arena 链接、带「自循环 / 生成 docx」也算同一套）：

```text
安装 arena/01a0a821-git-pull-arena skills, 与本地打通
```

或：

```text
安装https://arena.ai/agent/01a0a821-3f3c-7bbe-bf99-6e6793c45d81的skills。与本地打通
并实现自循环任务，将这个生成docx和pptx返回到本机，本机并把结果状态push到分支，一直自动循环知道你觉得结果没问题
```

助手必须立刻按 `templates/one-sentence.md` 执行（装技能 → 回复本机 PowerShell → **若有任务则立刻做并 `agent-handsfree.sh --timeout auto` 直到 accept**）。不要向用户要长提示词，也不要让用户先去旧克隆 `.\sync.ps1`。协议：`templates/one-sentence.md`、`templates/task-loop.md`、`templates/new-session-prompt.md`、`templates/connect-local.ps1`。

Agent 实际执行的命令（沙箱里 git clone 可用、raw.githubusercontent.com 可能被墙）：

```bash
git clone --quiet --depth 1 -b arena/01a0ae7a-new \
     https://github.com/shaohuawen03-cyber/new.git /tmp/git-sync-src \
  && bash /tmp/git-sync-src/skills/git-sync/scripts/agent-install.sh \
         --branch <本会话工作分支>
```

（技能合并进 main 之后把 `-b` 换成 `main`。）

安装器行为：装 `skills/git-sync/` 全套 + 根目录 10 个 `.ps1`（含 `hardware.ps1`、`watch.ps1`）+ gate 与 `local_check.ps1`（都是只建不覆盖）；
**目标仓库已有 `sync.config.json` 时只更新 branch/补缺失键，其余配置全部保留**
（所以给已装过的仓库升级也是同一条命令）。`--gha` 额外装 CI；`--source` 可指定别的来源。
升级后用 `.\doctor.ps1` 看技能版本对账。

## 8. 自动验证循环（agent 干完 → 本机自动检查 → 结果回传 → 直到满意）

平时是"你按命令同步"；这个循环让**本机变成自动验证机**：Arena 每轮完工时请求检查，
你本机的值守任务自动拉取、跑 `check_cmd`（默认 `code\local_check.ps1`，可改）、
把 passed/failed 和完整日志推回分支；Agent 读到结果，要么收尾要么修复再来一轮——
**直到 Agent 觉得可以为止，就 `--accept`，循环不再触发**。状态全部记在
`handshake` 文件里（`results/status/handshake.json`），一轮一档日志（`results/status/check_rN_<时间>.txt`）。

```
Arena（agent）                                本机（watch.ps1 计划任务，每 2 分钟）
  agent-sync.sh "feat: ..."
  agent-check.sh --request "验证X"   ──推送──>  轮询发现 awaiting_check/pending
                                                自动 .\sync.ps1 拉取
                                                跑 check_cmd，日志落盘
  agent-check.sh --read             <──推送──   handshake: local_state=passed/failed
    exit 0=过 / 2=败 / 3=还在等
  过了且满意 → --accept（循环收尾）
  败了 → 修复 → agent-sync.sh → --request（round+1，再来一轮）
```

最快的一条命令版（工作 → 验证 → 自动收尾）：

```bash
bash skills/git-sync/scripts/agent-wait.sh --request "验证X" --auto-accept
```

把这个循环**当远程任务执行器用**（任务在你真实机器上跑、产物自动回传）的完整配方
见 `templates/local-runner.md`——AgentArena 的"真实本机环境 runner"整合就是这个模式。

启用（每台机器一次，两步都不能省）：

```powershell
.\auth.ps1 -Setup -Verify          # 1) 凭据：让推送不弹窗、不等点击（实跑证明）
.\watch.ps1 -Register              # 2) 注册计划任务（默认 2 分钟；默认零窗口 + 注册后自检；暂停其他会话值守）
.\watch.ps1 -Status                # 值守活着吗（模式 / 上次运行 / 心跳 / last_push / other tasks）
.\watch.ps1 -Focus                 # 只留这一会话：暂停其他 git-sync-watch-*（不删任务）
.\watch.ps1 -RestoreParked         # 把暂停的值守全部拉回来
.\watch.ps1 -Test                  # 立刻跑一次任务，验证"真的会跑"
.\watch.ps1                        # 手动跑一次轮询（立即处理当前请求）
.\watch.ps1 -Unregister            # 不用了就摘掉
```

窗口与凭据（v2.5.0 的两条硬要求）：

* **不闪窗（v2.6.0 两层保障）**：① 注册的任务是**一个常驻进程**（`watch.ps1 -Loop`），
  它自己每 N 分钟轮询——所以窗口最多"每次登录一次"，而不是每次轮询一次；
  ② 默认用 GUI 子系统启动器（`%LOCALAPPDATA%\git-sync\watchhost-<仓库>.exe`，`CreateNoWindow`）
  启动这个进程，于是**一次都不闪**；注册前对该启动器做**冒烟测试**（临时小脚本 + 标记文件），
  失败就自动回退 `-Flash` 并把任务结果与 host 日志打印出来。
  `-Headless`（S4U/session 0）仍是零窗口的另一条路，但需要管理员控制台 +
  一个 session 0 可读的凭据（`gh auth setup-git` 最省事）。
  **升级技能后重注册**，常驻进程才会跑新代码。
* **不点确认**：值守推送用 `push.ps1 -NoPrompt`（`GIT_TERMINAL_PROMPT=0` / `GCM_INTERACTIVE=never` /
  `credential.interactive=false`）。**没有可静默使用的凭据就直接失败**（exit 4），并把 `auth: no silent credential`
  写进心跳，绝不挂在那里等点击——`auth.ps1 -Setup` 是修它的唯一命令。
* 状态全在 `%LOCALAPPDATA%\git-sync\`：`watch-<仓库>.json`（心跳）、`watch-<仓库>.log`（每次轮询一行，
  含每次 git 调用的结果）、`parked.json`（被 `-Focus`/`-Register` 暂停的其他会话值守），**不进 git**；
  `-Status` 与 `doctor.ps1` 都会读。
* **一会话一份值守（v2.6.9）**：新会话 `.\watch.ps1 -Register`（或 `bootstrap -Auto`）默认暂停其他
  `git-sync-watch-*`（Stop+Disable+杀循环，**不删任务**）。继续原来的对话：在 HQ 克隆
  `cd E:\0github\git-sync\git-pull-arena-s2 ; .\watch.ps1 -Focus`。一次全恢复：`.\watch.ps1 -RestoreParked`。
  不想动别人：`-Register -KeepOthers`。

要点：

* 值守任务用**本机已有的 git 凭据**推送（`auth.ps1` 探到的、或配好的那套）；
* **`"$var:"` 是禁用写法**：`"$round: x"` 会被 PowerShell 当作盘符变量 → ParserError →
  整份脚本**一行都不会执行**（实测把 watch.ps1 全废掉）。写 `"${round}: x"`，gate 会替你扫；
* `check_cmd` 在 `sync.config.json` 里改；默认的 `code\local_check.ps1` 跑 gate +
  你在模板里加的仓库专属检查（文件存在性、Office 能否打开、GPU 冒烟测试……），
  并顺带打一行 `== auth: ...` 告诉你免点击推送是否就绪（软提示，不影响 verdict）；
  单轮检查有硬超时（`check_timeout_min`，默认 30 分钟），超时判 failed 并在日志头记 `TIMEOUT`；
* 同一时刻只有一个轮询在跑（文件锁防重叠）；agent 没 `--request` 时值守完全静默；
* `--accept` 之后值守继续静默待命，直到下一次 `--request`。

## 9. Hands-Free（v2.7.0）—— 解放双手

配置 `hands_free` / `auto_pull` / `auto_push`（见 `sync.config.json`）。值守每轮：

1. `auto_pull` → `sync.ps1`（你不用再手动拉）
2. `auto_push` → 工作区有非排除脏文件则 `push.ps1 -NoPrompt`（你不用再手动推）
3. 若 handshake 为 `awaiting_check` → 照旧跑 `check_cmd` 并推回 verdict

Agent 侧一条命令闭环：

```bash
bash skills/git-sync/scripts/agent-handsfree.sh \
     --sync "feat: ..." \
     --request "verify ..." \
     --timeout auto
```

它会：sync → request → wait 本机值守 → `agent-criteria.sh` 读 `success_criteria` → 全过则 `--accept` 停下。

成功标准文件默认 `results/status/success_criteria.json`。本机 `code/local_check.ps1` 也会跑同一份。
案例与安全边界：`deliverable/HANDS_FREE_v2.7.0.md`。

用户侧升级：`.\sync.ps1` → `.\watch.ps1 -Unregister ; .\watch.ps1 -Register` → `.\watch.ps1 -Status`
（应显示 `hands-free: master=True auto_pull=True auto_push=True`）。

## 10. 多账号共存与切换（v2.9.0 / v2.9.1）

一台机器常有**多个 GitHub 登录**（gh 可以存很多个，只有一个是 active）。克隆用的是 active 那个——仓库属于另一个号时，凭据完全有效，push 仍然 403
`Permission to OWNER/REPO.git denied to OTHER-USER`。心跳/日志里看到 403 时，先把「凭据问题」和「权限问题」分开：

```powershell
.\auth.ps1 -Accounts                  # 每个 gh 登录一行 + 实测能否推本仓库
.\auth.ps1 -Account shaohuawen03-cyber # 只把【这个克隆】钉到该账号
.\auth.ps1 -Unpin                     # 还原（本克隆回到机器默认）
.\auth.ps1 -Verify                    # 钉完立刻证明：push --dry-run PASSED
```

* **helper 必须是"被调用的函数"**：git 执行 `!` 开头的 helper 时会在命令末尾**追加 `"$@"`**（`f() { ...; }; f get`）。写成 `if ...; then ...; fi` 会变成 `fi get` → `syntax error near unexpected token 'get'`，helper **一次都不会执行**（v2.9.0 真实事故，v2.9.1 修复）；值里不要出现双引号（要经过 cmd），路径用正斜杠；
* **只动本文件夹**：pin 写在 `git config --local`，其他克隆（如 `git-pull-arena`）继续用机器默认账号，互不影响；
* **空值复位是硬前提**：机器级 generic helper（GCM / 全局 gh = active 账号）**排在前面先应答**，只在本地写 host-specific helper（`credential.https://github.com.helper`）**完全无效**（实测：谁先应答由列表顺序决定，而 system→global→local）。必须在本地列表**最前面**放一条**空值** `credential.helper`，它会把此前收集到的 helper 全部丢弃，之后的 pin 才轮得到；
* **空值写入要三层兜底**：Windows 上把空参数送进 cmd/MSYS 不可靠（会被吞掉，`git config key ""` 退化成"读"并 exit 1——v2.9.0 现场就是这个）。`-Account` 依次尝试 argv → `git config --stdin`（git ≥ 2.45）→ 直接编辑 `.git/config`，**每次都读回验证**，并打印实际生效的那一层；
* **为什么先清空**：`credential.helper` 是**累加**的，机器级 helper（GCM / 全局 gh）会排在前面先应答，只 `--add` 一条新 helper 等于没设。`-Account` 会先写一条空值**清空列表**再钉（git 2.39 / 2.54 实测），并把原机器级 helper 作为**后备**（值里含双引号时跳过，避免引号二次转义写成坏配置）；
* **钉住后不加后备 helper**：账号令牌失效时 helper 直接非零退出（明确报错），不会回落到机器默认账号——否则"失败关闭"就形同虚设，还可能以错误身份推送；
* **钉住后不加后备 helper**：账号令牌失效时 helper 直接非零退出（明确报错），不会回落到机器默认账号——否则"失败关闭"形同虚设，还可能以错误身份推送；
* **失败关闭**：pin 的命令形如
  `!if T=$(... 'gh.exe' auth token -u NAME); then GH_TOKEN=$T ... git-credential; else exit 1; fi`——
  账号被登出/令牌失效时**退出非零**，绝不悄悄改用 active 账号（空 `GH_TOKEN` 会让 gh 回落，那样会以错误身份推送）；
* 想看机器默认是谁：`gh auth status`；要改机器默认（影响所有克隆）：`gh auth switch -u <login>`；

## 11. 账号策略（v2.9.2）—— 谁仓库的会话，就用谁账号

一条规则，别再靠记忆：

| 会话 / 仓库 | 钉住的账号 |
|---|---|
| `shaohuawen03-cyber` 的会话、`shaohuawen03-cyber/*` 仓库 | `shaohuawen03-cyber` |
| `mqgg5630-cyber` 的会话、`mqgg5630-cyber/*` 仓库 | `mqgg5630-cyber` |

做法（每次新建克隆一次，或升级后重跑一次）：

```powershell
.\auth.ps1 -Account <仓库主>   # 从 remote URL 里取 owner；只钉这个克隆
.\auth.ps1 -Verify            # push --dry-run PASSED 才算数
```

* `agent-handoff.sh` 生成的粘贴块**已经带好这行**（owner 由 remote URL 解析，AI 不用手打）；
* **机器默认账号不动**：`gh auth switch -u X` 是"改机器默认"，会连累同机其他克隆，只在你确实要换默认账号时才用；
* 每个仓库一个克隆、每个克隆一个 pin —— 一台机器上 mqgg 的仓库走 mqgg、shaohua 的仓库走 shaohua，互不干扰（这是 2026-09-17 现场验证过的形态）；
* `doctor.ps1` 的 `auth account` 行会显示本克隆钉到谁；`code/local_check.ps1` 每轮也会把 pin 写进检查日志。

## 12. 技能总部（v2.9.2）

* **canonical**：`https://github.com/shaohuawen03-cyber/new.git` 分支 `arena/01a0ae7a-new`，技能在 `skills/git-sync/`；
* 安装器自带候选列表（新源 → 旧 `mqgg5630-cyber/git-pull-arena`），**探测全部、装最新版、拒绝降级**；旧源只保证"还能装上一份能跑的"；
* 新会话的短句不变（`安装 ... 的 skills，与本地打通`），助手照样自己 clone + 安装，不要打开 arena.ai。

* `doctor.ps1` 现在会打一行 `auth account`（本克隆 pin / gh active / 可选账号列表），`code/local_check.ps1` 也会把「本克隆 pin 到谁」写进每轮检查日志——agent 一眼就能分辨 403 的性质。
