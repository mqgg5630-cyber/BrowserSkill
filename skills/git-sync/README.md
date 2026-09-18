> 当前版本 **v2.9.2**（技能总部迁至 `shaohuawen03-cyber/new` 分支 `arena/01a0ae7a-new`；安装器多候选探测取最新、旧仓库降为后备；**账号策略**：谁仓库的会话就用谁账号，`agent-handoff.sh` 自动在粘贴块里带上 `auth.ps1 -Account <仓库主>`。见「二·六」。）
>
> v2.9.1（修多账号钉账号：helper 必须是被调用的函数 `!f() { ...; }; f`（git 会追加 `"$@"`，`if…fi` 会 syntax error）；空值复位改为三层兜底 + 读回验证；钉住后不加后备 helper（失败关闭）。见「二·六」与 `CASE_STUDY.md` §9。）
> 当前版本 **v2.9.0**（多账号）：`auth.ps1` 新增 `-Accounts` / `-Account <login>` / `-Unpin`——一台机器多个 GitHub 登录时，把**单个克隆**钉到有权推它的账号，其他克隆不受影响；403 `Permission to ... denied to OTHER-USER` 归位为「权限问题」；`doctor` 与 `local_check.ps1` 会报当前账号/pin。见「二·六」。
> 当前版本 **v2.8.1**（放开沙箱工具链限制：`pip`/`.venv`/python-docx 随便用，只禁「冒充本机」；安装器不再降级 + 取最新分支；值守每行带时间戳；轮询自适应提速；`.gitattributes` 统一 LF 修 CRLF 假失败）。成功案例 `deliverable/CASE_STUDY_v2.8.0.md`。`main` 上是 **v2.6.7**。

# 本地 ↔ Agent 同步 skill —— 使用说明

> 目标是：**取、传、下载、打包、排障各一个命令**，不需要 git 知识；
> 一份配置（`sync.config.json`）驱动全部脚本，`agent-install.sh` 一条命令装进任何新仓库
> （新会话引导提示词在 `templates/new-session-prompt.md`，整段复制即用）。
> 仓库根目录放着同款脚本（`sync.ps1 / push.ps1 / upload.ps1 / download.ps1 / doctor.ps1 / pack.ps1 / bootstrap.ps1 / pr.ps1 / hardware.ps1 / watch.ps1 / auth.ps1 / install.ps1`），
> 这份 skill 是**通用版 + 说明书**；根目录副本必须与 `scripts\` 下的**逐字节相同**（`code/check_all.sh` 第 3 节会卡）。
>
> **v2.8.1（三处「本机侧假 SKIP / 硬编码」根治 + CI 兜底）**：① `local_check.ps1` 的 3h 开档测试不再写死文件名，改读 `deliverable/OFFICE_HASHES.json`（换交付物自动覆盖，没声明就 SKIP 并说明）② 闸门解析 python 时逐个**验证可用**并补 `py -3`（本机 conda python 被 Store 存根挡住 → 三项检查一直 SKIP）③ `.github/workflows/gate.yml` 随包安装：本机不在线也有独立核验 ④ `agent-handoff.sh` 在没有 remote 的克隆里给出可照抄的修复命令。
>
> **v2.7.5（交接块生成化 + 分支一致性闸门）**：三个真实事故（2026-09-16：`01a0a95e` 请求在 `pending` 挂 2 小时、`01a0a98d` 配置分支停在上个会话、把 `/home/user/...` 写进 Windows PowerShell 块）都源于**手打交接命令**。现在：① `scripts/agent-handoff.sh` 从 `git remote get-url` + 配置 branch 生成可粘的 PowerShell（`--json` 给真值），配置分支 ≠ HEAD 时 exit 3 拒绝；② `code/check_all.sh` 新增 2b 段「`sync.config.json` 的 branch 必须等于 HEAD」，不一致直接 exit 1（值守轮询的是配置分支，不一致 = 本机永远收不到请求）；③ `agent-check.sh --read` 报告本轮 pending 了多少分钟，≥10 分钟就提示重发交接块而不是继续轮询；④ `agent-install.sh` 本来就会用 HEAD 写 branch（v2.7.5 起由闸门兜底）。
>
> **v2.7.4（短句仍用 arena.ai，助手自己展开）**：用户不改提示词。`arena.ai/agent/01a0a821` → clone 本仓库；根目录 `01a0a821.md`。禁止向用户索要长命令。
>
> **v2.7.3（曾要求用户粘带 GitHub clone 的长提示词）**：沙箱打不开 arena.ai。v2.7.4 起改回：用户继续短句，助手自己 clone GitHub。（注意：`.venv` 不是本机，但装库本身从 v2.8.0 起不再禁止。）
>
> **v2.7.2（先打通本机，禁止假 local/）**：给用户的第一条回复必须是 `git clone` + `.\bootstrap.ps1 -Auto`；沙箱 `local/inbox` / 自制 python skills **不算**打通；自循环只准 `agent-handsfree.sh`。`agent-install.sh` 补拷 `install.ps1`。
>
> **v2.7.1（一句话自循环 + 自适应超时）**：新会话 `安装 ... skills，与本地打通`（可带 arena.ai 链接和具体任务）即装技能并 `agent-handsfree.sh --timeout auto`——值守一回传就停，上限随 `check_timeout_min`，不再死等 600s。协议 `templates/one-sentence.md` / `templates/task-loop.md`。
>
> **v2.7.0（解放双手）**：值守每轮 `auto_pull`（`sync.ps1`）+ `auto_push`（静默 `push.ps1`，排除密钥与 handshake）；Agent 一条 `agent-handsfree.sh`：wait 本机检查 → `agent-criteria.sh` → 全过 `--accept`。配置键 `hands_free` / `success_criteria`。先例：`new`/`arena/01a0a90b-new` round 1 accepted。必须重注册值守。说明 `deliverable/HANDS_FREE_v2.7.0.md`。
>
> **v2.6.9（新会话暂停其他值守 / 切回本会话）**：`-Register` 默认把其他 `git-sync-watch-*` **暂停**（Stop + Disable + 杀掉循环 PID，**不 Unregister**）；台账 `%LOCALAPPDATA%\git-sync\parked.json`。新对话装完即只留这一份值守。继续原来的对话：在 HQ 克隆里 `.\watch.ps1 -Focus`（本克隆恢复、其他再暂停）。一次全恢复：`.\watch.ps1 -RestoreParked`。不想动别人：`-Register -KeepOthers`。`-Status` / `doctor.ps1` 列出 other tasks 与 parked 行。last-check 日志按 UTF-8 读（修中文乱码）。说明 `deliverable/FIX_v2.6.9.md`。
>
> **v2.6.8（值守"每轮都要有收尾行"）**：`watch.ps1` 的 `Invoke-PollRound`（6 个出口）与
> `Invoke-PollOnce`（锁被占 / 崩溃，2 个出口）现在**每个出口都设置 `$script:PollSummary`**，
> 循环与手动单轮都把它打印出来（手动单轮再补一行 `== finished at ...`），所以窗口不会再停在
> 上一轮的旧行上看着像卡死。这条规则由 `code/check_loop_summary.py`（闸门 §3c）与
> `code/check_loop_summary.ps1`（本机检查项 2c）**静态盯住**：删掉任意一条赋值，闸门 exit 1。
> 另外 `Get-PowerShellExe` 优先 64 位（32 位进程走 `SysNative`）；`-Status` 的 host log 尾部按
> UTF-8 读（修中文乱码），并给计划任务结果码加人话注释（`0 / 267009 / 267011 / 267014 /
> 2147946720=0x800710E0` 都是正常码，`doctor.ps1` 同步不再误报），代理提示改成可直接照抄的
> `setx HTTPS_PROXY "..."`；安装/升级的两块照抄命令见 `templates/install-one-liner.md`。
>
> **v2.6.1（网络/代理）**：`auth.ps1` 自动读取 `git config http.proxy` 并套用给 gh
> （实测常见病：git 走代理能通、gh 只认 `HTTPS_PROXY` 于是超时），新增 `-HttpProxy`；
> PAT 入库改为**离线优先**（先写凭据助手，不需要任何 API 调用，网络不通也能先存好）；
> `sync.ps1` 不再把值守产物（`results/status/`）堆成 stash（改为本地提交，并在分叉时自动对齐远端）；
> 值守把 push 失败原因记进心跳 `last_push_detail`，`-Register`/`-Status` 会记录并提醒 git 代理与
> `HTTPS_PROXY` 不一致的问题。
>
> **v2.6.0（值守改成"一次登录一个常驻进程"）**：注册的任务跑 `watch.ps1 -Loop`，
> 一个进程内部每 N 分钟轮询到底——所以 **flash 模式下也只在你登录系统时闪一次**
> （以前是每 2 分钟一次，720 次/天）；默认仍优先用零窗口启动器，且**注册前先对启动器做冒烟测试**
> （失败的诊断会直接打印任务结果 + host 日志）；新增 keeper 心跳触发器（每 30 分钟，
> 进程死了才拉起，活着不动）；`-Status` 增加"循环是否活着 / 心跳年龄"；`auth.ps1` 新增
> **`-GhLogin`**（一条命令完成那唯一一次交互登录，并自动 setup-git）与"公开仓库的 ls-remote
> 不能证明鉴权"的明确提示；`push.ps1 -Prompt` 会显式打开交互（对付机器级
> `credential.interactive=false`）。**升级技能后要重注册值守**，常驻进程才会用上新代码。
>
> **v2.5.1**：`auth.ps1 -Setup` 改为**先探测、只在必要时才改配置**（v2.5.0 会在有好凭据的机器上把
> `credentialStore` 改成 dpapi，等于把原来 Windows 凭据管理器里的登录"藏起来"——实测踩到）；
> 新增 `-MigrateStore`（把凭据**复制**一份到 dpapi，给 S4U/-Headless 用）；
> `watch.ps1` 修了一个会**整份脚本解析失败**的写法（`"$round:"` → `"${round}:"`，PowerShell 会把它当盘符变量），
> gate 新增 `code/scan_ps_var_colon.py` 专扫这类陷阱；`watch.ps1 -Register` 增加 git/bash/powershell 环境预检；
> `local_check.ps1` 不允许 gate "空转通过"；gate 的 python 解释器按 `python3` → `python` 探测（Windows/conda 常常只有 `python`）。
>
> **v2.5.0 起（默认行为变了）**：推送**默认静默**（任何 git 调用都不许弹窗/等点击，拿不到凭据就快速失败并告诉你怎么修）；
> 值守**默认零窗口**（编译一个 GUI 子系统启动器，Task Scheduler 不再有 console 闪窗）；
> `auth.ps1` 一次配好免点击凭据并**用实跑证明**；`watch.ps1 -Register` 注册后**自检真的跑没跑**。
> 多会话协作（模式 B/C）**暂时搁置**，先按"一会话一仓库"（模式 A）走通单会话闭环。

## 一、最短用法（在仓库目录里）

```powershell
.\sync.ps1                                # 取：拉最新（本地有改动会自动 stash）
.\upload.ps1                              # 传：附件归位到 sources\ code\ results\ 后 commit + push
.\push.ps1 "说明"                          # 传：直接提交推送（拒绝推 main）
.\push.ps1 -Gate "说明"                    # 同上，但提交前本机也跑一遍自检（需 bash，装 Git 就有）
.\download.ps1 -Set final                 # 下载：把 deliverable\ 等目录镜像到本机
.\download.ps1 -Set final -Since 2026-09-14   # 只复制该日期之后变过的文件（先 .\sync.ps1）
.\download.ps1 -Folders deliverable,examples\x # 临时指定目录下载（不用改配置）
.\download.ps1 -List                      # 看有哪些集合
.\pack.ps1 -Set final                     # 打包：生成 _export\20260914_2030_final.zip
.\doctor.ps1                              # 体检：环境 / 分支 / 远端 / 未提交 / stash / 大文件 / 版本
.\doctor.ps1 -Fix                         # 一键修复：重建 refspec + stash + 切回分支 + 拉取
.\hardware.ps1 -Deep                      # 采集本机硬件/conda环境报告并推送（每台机器一次；变化后重跑）
.\auth.ps1 -Setup -Verify                 # 一次性：把推送配成免点击，并用实跑证明（不弹窗）
.\auth.ps1 -Accounts                     # 多账号：本机 gh 登录 + 各自能否推本仓库
.\auth.ps1 -Account shaohuawen03-cyber    # 只把本克隆钉到这个账号（其他克隆不动）
.\auth.ps1 -Unpin                       # 去掉本克隆的 pin，回到机器默认账号
.\auth.ps1                                # 看现在推送会用哪套凭据、能不能静默完成
.\watch.ps1 -Register                     # 自动验证循环：注册本机值守（每2分钟；默认零窗口）
.\watch.ps1 -Status                       # 值守活着吗：模式 / 上次运行 / 心跳 / 最近一轮结果
.\watch.ps1 -Test                         # 立刻跑一次计划任务，验证"真的会跑"（而不是只注册成功）
.\pr.ps1                                  # 开 PR：工作分支 -> main（需 GitHub CLI）
```

助手那一侧（本仓库的 `skills/git-sync/scripts/`）：

```bash
bash skills/git-sync/scripts/agent-sync.sh "feat: xxx"     # 守卫 + fetch + 自检 + 回执 + commit + push
bash skills/git-sync/scripts/agent-sync.sh --status        # 只看状态，不动文件
bash skills/git-sync/scripts/agent-hardware.sh             # 读本机硬件报告（超 30 天提醒重跑）
bash skills/git-sync/scripts/agent-check.sh --request "验证X"  # 请求本机自动检查（自动验证循环）
bash skills/git-sync/scripts/agent-wait.sh --request "验证X"   # 请求 + 原地等结果（一轮对话内闭环）
bash skills/git-sync/scripts/agent-wait.sh --request "X" --auto-accept   # 通过即自动收尾
bash skills/git-sync/scripts/agent-check.sh --read         # 读本机检查结果（0=过/2=败/3=等）
bash skills/git-sync/scripts/agent-check.sh --accept       # 通过且满意 → 收尾，循环不再触发
bash skills/git-sync/scripts/agent-recover.sh              # 沙箱 .git 被重置后的恢复
bash skills/git-sync/scripts/agent-pr.sh --dry-run         # 开 PR（--dry-run 只打印）
bash skills/git-sync/scripts/agent-pr.sh --checks          # 看 PR 的 CI 状态
```

## 二、脚本与配置

| 文件 | 说明 |
|---|---|
| `sync.config.json` | **唯一的配置**：`branch` / `remote` / `download_dir` / `download_sets` / `upload_map` / `gate` / `receipt` / `handshake` / `check_cmd` / `check_timeout_min` / `lock_stale_min` |
| `VERSION` | 技能版本号；`doctor.ps1` 和安装器都会显示，升级对账用 |
| `scripts/sync.ps1` | 拉取；配置查找：`-Config` 参数 > `sync.config.<GIT_SYNC_PROFILE>.json` > 仓库内 `skills\git-sync\` > 脚本旁边 |
| `scripts/push.ps1` | 提交推送；**拒绝推 `main` / `master`**；`-Gate` 提交前本机也跑一遍自检；**默认静默模式**（prompts 关闭：拿不到凭据就 exit 4 并让你跑 `auth.ps1 -Setup`，绝不弹窗等待），要交互用 `-Prompt` |
| `scripts/upload.ps1` | 附件归位：扩展名 → 目录映射取自 `upload_map`，也可 `-Ext`/`-Dest` 临时指定 |
| `scripts/download.ps1` | robocopy 镜像下载；`-Set` 选集合，`-Mirror` 完全镜像，`-Since <日期>` 增量，`-Folders a,b` 临时指定目录 |
| `scripts/pack.ps1` | 压缩包交付；输出到 `_export\`（已在 `.gitignore` 里，不会被推送） |
| `scripts/doctor.ps1` | 体检报告 + 技能版本 + LFS/大文件检查 + **值守/心跳/凭据三行**（watcher / heartbeat / auth）；`-Fix` 一键修复；ahead/behind 对比的是 `origin/<分支>`（修复了老版本永远显示 0 的 bug） |
| `scripts/hardware.ps1` | **本机硬件/环境上报**：OS、CPU、内存、GPU（nvidia-smi 优先，含显存/算力/CUDA 驱动）、磁盘、conda/mamba 环境列表与各环境 python，`-Deep` 再探测每个环境的 torch + CUDA；写入 `hardware_dir`（latest.md/latest.json + 历史快照）并推送 |
| `scripts/watch.ps1` | **自动验证循环本机侧**：`-Register` 常驻循环；**v2.7.0 每轮 auto_pull + auto_push**；请求检查时 sync → `check_cmd` → 推回结论；`-Status`/`-Test`/`-Focus`/`-RestoreParked`/`-KeepOthers` |
| `scripts/bootstrap.ps1` | 首次准备：执行策略、git 身份、fetch、切分支、首拉 |
| `scripts/pr.ps1` | GitHub CLI 开 PR / 查 CI；`-Base` 换目标分支，`-Checks` 看检查状态 |
| `scripts/auth.ps1` | **免点击推送**：`-Setup`（**先探测现有配置，能静默拿到凭据就什么都不改**；否则 gh CLI 优先，再退到 GCM，并逐个 store 找已有凭据）/ `-Verify`（prompts 关闭下实跑 `ls-remote` + `push --dry-run`）/ `-MigrateStore`（复制凭据到 dpapi，给 S4U/-Headless 用）/ `-Token`·`-TokenFile`·`-PromptToken`（无浏览器播种令牌，永不回显）/ `-Json`（给 doctor、gate、agent 读）/ `-Unset` |
| `scripts/install.ps1` | 装到另一个仓库：`.\install.ps1 -Target C:\MyProject -Branch main`（目标已有配置时只动 branch，其余保留） |
| `scripts/agent-sync.sh` | 助手侧一键：分支守卫 → fetch → 发散自愈 → gate → **写同步回执（并按日期归档）** → commit + push |
| `scripts/agent-hardware.sh` | 助手侧读本机硬件报告；缺失/超 30 天会提示让用户跑 `.\hardware.ps1 -Deep` |
| `scripts/agent-check.sh` | **自动验证循环助手侧**：`--request` 请求本机检查（round+1）/ `--read` 读结果（exit 0=过 2=败 3=等）/ `--accept` 通过收尾 |
| `scripts/agent-pr.sh` | 助手侧开 PR / 看 CI |
| `scripts/agent-recover.sh` | 助手侧修复：`.git` 被重置回基线提交时，保住工作区把 HEAD 挪回分支 |
| `scripts/agent-install.sh` | **一条命令装进任何仓库**（见第六节） |
| `templates/check_all.sh` | 通用 gate 模板（ASCII + 分支守卫 + 根目录/skill 脚本一致性） |
| `templates/gate.yml` | GitHub Actions 模板：push 后自动跑 gate |
| `templates/new-session-prompt.md` | **新会话引导提示词模板**：整段复制到新 Arena 对话即完成安装与验收 |
| `templates/local_check.ps1` | **本机自检模板**（装到 `code\local_check.ps1`，只建不覆盖）：默认跑 gate + 扩展点，`watch.ps1` 请求检查时执行的就是它 |
| `templates/local-runner.md` | **本机即 Runner 配方**：自动验证循环的推广用法——任务在真实本机环境执行、产物自动回传（AgentArena 整合的理论基础） |
| `templates/health.yml` | GitHub Actions **每日体检**：握手卡死 / 硬件报告过期自动开 issue；定时只跑默认分支，从本机复制到 main 并改 `BRANCH` 启用 |

同步回执：助手每轮 `agent-sync.sh` 会把"纳入了你哪些提交、这轮改了哪些文件"写进配置里
`receipt` 指定的文件（默认 `results/sync/last_sync.md`），同时把带时间戳的副本归档到
`receipt_history` 目录（默认 `results/sync/history/`，自动保留最近 50 份），你 `.\sync.ps1`
之后打开就能看到。

硬件报告：你跑一次 `.\hardware.ps1 -Deep`，agent 之后用 `agent-hardware.sh` 就能看到
本机 CPU/内存/GPU（型号/显存/算力/CUDA 驱动）/磁盘/conda 与 mamba 环境列表、每个环境的
python 版本、哪个环境的 torch 能用 CUDA——计算类工作开工前先对表。

自动验证循环（v2.3）：本机 `.\watch.ps1 -Register` 一次（计划任务，每 2 分钟轮询）；
之后 agent 每轮完工 `agent-check.sh --request "验证X"` → 你本机**自动** sync → 跑
`check_cmd`（默认 `code\local_check.ps1`，可改）→ 日志落 `results\status\check_rN_<时间>.txt`
→ 把 passed/failed 推回分支；agent `--read` 读结果（0=过/2=败/3=等），败了修了再来一轮，
过了且满意 `--accept` 收尾——**循环由 handshake 文件驱动，收尾后值守静默待命**。
详见 SKILL.md 第 8 节。

## 二·五、零弹窗值守 + 免点击推送（v2.5.0）

两件事各自都有"看着成了其实没成"的坑，所以都配了**可验证的自检**：

| 目标 | 做法 | 怎么证明 |
|---|---|---|
| 值守**不闪窗** | `watch.ps1 -Register` 默认编译一个 GUI 子系统启动器（`%LOCALAPPDATA%\git-sync\watchhost-<仓库>.exe`），由它用 `CreateNoWindow` 拉起 powershell——Task Scheduler 不再创建任何 console 窗口；不需要管理员、不碰已弃用的 VBScript | 注册后自动**自检**：立刻跑一次任务并等心跳文件；自检失败会自动回退 `-Flash` 并如实告知 |
| 推送**不点确认** | `auth.ps1 -Setup`：有 gh 就 `gh auth setup-git`（令牌存在 gh 自己配置里，session 0 也能用）；否则 GCM + `credential.credentialStore=dpapi`（Windows 凭据管理器在 session 0/SSH 下读不到，dpapi 文件可以）。`push.ps1` 默认静默：prompts 全关 | `auth.ps1 -Verify`：在 prompts 关闭的情况下实跑 `git ls-remote` 与 `git push --dry-run`，退出码 0 才算过 |

值守的心跳、日志、启动器都在 `%LOCALAPPDATA%\git-sync\`（**不进 git**）：
`watch-<仓库>.json`（上次运行时间/动作/round/结论/推送结果）、`watch-<仓库>.log`（每次轮询一行，含每次 git 调用的结果）。
出问题就看这两样，或直接 `.\watch.ps1 -Status` / `.\doctor.ps1`。

长任务（本机即 Runner）记得**同步调大**两个值：`check_timeout_min`（单轮硬超时，默认 30）与
`lock_stale_min`（锁过期，默认 45，必须大于超时）；`watch.ps1 -Register -CheckTimeoutMin 120` 也能临时覆盖。

## 二·六、多账号共存 / 切换（v2.9.0）

一台机器多个 GitHub 登录是常态（本机：默认 `mqgg5630-cyber`，仓库主 `shaohuawen03-cyber`）。
克隆默认用 gh 的 **active** 账号——号不对时凭据有效、push 仍 403：

```powershell
.\auth.ps1 -Accounts                      # 每个登录一行 + 实测 permissions.push
.\auth.ps1 -Account shaohuawen03-cyber     # 只钉这个克隆（local git config）
.\auth.ps1 -Unpin                         # 还原
```

| 机制 | 说明 |
|---|---|
| 作用域 | 只写本克隆 `git config --local`；其他克隆照旧用机器默认（`gh auth switch -u X` 才是改全局默认） |
| helper 写法 | git 会执行 `!f() { ...; }; f "$@"`——必须是**被调用的函数**；`if ...; fi` → `fi get` = syntax error，等于没设。值里不含双引号，路径用正斜杠 |
| 空值怎么写成 | Windows 上往 cmd 传空参数不可靠：argv → `--stdin`（git≥2.45）→ 直接改 `.git/config` 三层兜底，**每层读回验证**，并报出实际生效的那层 |
| 先清空再钉 | `credential.helper` 是累加列表，机器级 helper（GCM / 全局 gh = active 账号）会先应答；`-Account` 先写一条**空值**清空列表再钉（git 2.39 / 2.54 实测） |
| 后备 | 原机器级 helper 会被追加为后备；值中含双引号时跳过（避免 cmd 引号二次转义写出坏配置） |
| 不加后备 | 钉住后**不再追加**机器级 helper 作后备：账号令牌失效就明确失败，绝不静默用别的账号推送 |
| 失败关闭 | pin 命令 `!if T=$(gh auth token -u NAME); then GH_TOKEN=$T gh auth git-credential; else exit 1; fi`——账号登出/令牌失效直接非零退出，绝不悄悄用 active 账号 |
| 可视化 | `doctor.ps1` 打 `auth account` 行；`code/local_check.ps1` 每轮把 pin 写进日志；`push.ps1` 遇 403 直接给出这两条命令 |


### 账号策略（v2.9.2）

| 会话 / 仓库 | 钉住的账号 |
|---|---|
| `shaohuawen03-cyber` 的会话与仓库 | `shaohuawen03-cyber` |
| `mqgg5630-cyber` 的会话与仓库 | `mqgg5630-cyber` |

`agent-handoff.sh` 生成的粘贴块里已经带好 `.\auth.ps1 -Account <仓库主>`（owner 从 remote URL 解析）。
**机器默认账号不动**，所以同机其他克隆照旧；`gh auth switch -u X` 才是改机器默认（会连累所有克隆，不要拿它当切换器）。


## 三、为什么 `.ps1` 里绝对不能写中文

Windows PowerShell 5.1 读**没有 BOM** 的 `.ps1` 时按 **ANSI/GBK** 解码；UTF-8 的中文注释会变成乱码，
乱码里一旦出现引号就会把后面的字符串吞掉，报 `字符串缺少终止符` / `InvalidArgument`。
约定：**`.ps1` 只用 ASCII，中文只出现在 `.md` / `.json`**；
gate（`code/check_all.sh`）提交前自动扫描全部 `.ps1`，非 ASCII 直接 FAIL（本机侧 `.\push.ps1 -Gate` 也跑同一套）。

中文目录名（如 `中间版`）因此**只写在 `sync.config.json` 里**，脚本用 `Get-Content -Encoding UTF8` 读取，
再拼路径——这样既有中文目录，又不会有 GBK 问题。

所有 `.ps1` 从脚本位置**自动上溯找仓库根**（有 `.git` 的目录），所以放在根目录或
`skills\git-sync\scripts\` 里都能直接运行。

## 四、三道安全阀

1. **分支守卫**
   * `push.ps1` / `pr.ps1` / `agent-pr.sh`：分支是 `main` / `master` 直接拒绝；
   * `agent-sync.sh`：HEAD 与配置里的分支不一致就退出（不会误推到别处），并且只 `git push origin <配置分支>`。
2. **提交前自检（gate）**
   `sync.config.json` 的 `gate`（默认 `bash code/check_all.sh`）失败时 `agent-sync.sh` **不提交**，
   因此远端历史里的每个提交都是自检通过的；本机侧想同样把关就 `.\push.ps1 -Gate`。
3. **远端 CI（可选）**
   `templates/gate.yml` 装到 `.github\workflows\` 后，每次 push 在 GitHub 上自动跑同一套 gate。
   注意：GitHub App 类的 agent 令牌往往**没有 workflows 权限**，推不动这个目录——
   这时由本机侧启用（你的凭据可以）：

   ```powershell
   New-Item -ItemType Directory -Force .github\workflows | Out-Null
   Copy-Item skills\git-sync\templates\gate.yml .github\workflows\gate.yml
   .\push.ps1 "ci: enable gate workflow"
   ```

## 五、故障对照表

| 现象 | 处理 |
|---|---|
| `running scripts is disabled` | 跑一次 `.\bootstrap.ps1` |
| `gh auth login` 超时 / `dial tcp ...:443 did not properly respond` | 网络路径问题，不是脚本：git 可能走了 `git config http.proxy`，而 gh 只认 `HTTPS_PROXY`。用 `.\auth.ps1 -GhLogin -HttpProxy http://127.0.0.1:7890`，或 `setx HTTPS_PROXY ...` 后重开窗口；不想折腾 gh 就 `.\auth.ps1 -Setup -PromptToken`（离线入库） |
| `git stash list` 越积越多 | v2.6.1 起值守产物改为本地提交；历史堆积用 `git stash list` 检查后 `git stash clear`（确认没有你要的改动） |
| 要密码 / 认证失败 / 推送卡着等确认 | `.\auth.ps1 -Setup` → `.\auth.ps1 -Verify`（一次配好免点击；两者都支持 `-Json`）。**如果 `-Setup` 之后反而开始要登录**：`.\auth.ps1 -MigrateStore` 或 `.\auth.ps1 -Unset`（把 `credentialStore` 改回默认，原来的凭据立刻可见） |
| `403 ... Permission to OWNER/REPO denied to OTHER-USER` | 凭据没问题，**账号没权限**：`.\auth.ps1 -Accounts` → `.\auth.ps1 -Account <login>`（只钉本克隆）；或浏览器把该号加为仓库 Collaborator |
| 设了 `credential.https://github.com.helper` 却没生效 | helper 列表是累加的，机器级先应答；用 `.\auth.ps1 -Account <login>`（先清空再钉） |
| 值守注册时直接抛 ParserError（脚本一行都没跑） | 检查有没有 `"$var:"` 这种写法：`$round:` 会被当成盘符变量，**整份脚本解析失败**。gate 的 `code/scan_ps_var_colon.py` 会替你先扫出来 |
| 计划任务报 `Disabled` / 心跳文件不存在 | 任务被 `-Pause` / `-Focus` 过或从未成功注册：本克隆 `.\watch.ps1 -Focus` 或 `.\watch.ps1 -Resume`；一次全恢复 `.\watch.ps1 -RestoreParked`；真要重来才 `-Unregister` → `-Register` |
| 值守推送一直不成功（agent 说"还在等"） | `.\watch.ps1 -Status` 看心跳与 `last_push`；`auth: no silent credential` 就是没配凭据，跑 `.\auth.ps1 -Setup` |
| 值守好像没在跑（计划任务显示正常） | `.\watch.ps1 -Test`（立刻跑一次并等心跳）；`Get-ScheduledTaskInfo <任务名>` 的 LastTaskResult 不可信（v2.4.4 就是这么被骗的） |
| 新会话装完，旧会话值守不跑了 | 这是 v2.6.9 的默认：`-Register` 暂停其他 `git-sync-watch-*`（任务还在）。回原会话：`cd <原克隆> ; .\watch.ps1 -Focus`。全恢复：`.\watch.ps1 -RestoreParked`。新会话不想动别人：`-Register -KeepOthers` |
| 值守闪黑窗 | v2.6.0 起是常驻循环：`-Register` 首选零窗口启动器（0 闪），回退 `-Flash` 也只是**每次登录闪一次**。升级后务必重注册：`.\watch.ps1 -Unregister` → `.\watch.ps1 -Register` |
| 启动器自检失败（`no heartbeat`） | 现在会直接打印任务结果 + `%LOCALAPPDATA%\git-sync\watch-*.log` 尾部；把这段发我即可定位。临时用 `-Register -Flash`（每次登录一次闪窗）或管理员 `-Register -Headless`（零窗口，但需要 gh 助手） |
| 单轮检查被判 failed 且写了 `TIMEOUT` | 检查超过 `check_timeout_min`（默认 30 分钟）被强杀；长任务请调大它并把 `lock_stale_min` 一起调大 |
| `Updates were rejected`（远端有新提交） | 先 `.\sync.ps1`，再 `.\push.ps1` |
| `pull --ff-only` 失败（本地有分叉提交） | `.\doctor.ps1` 看状态；或 `.\doctor.ps1 -Fix` |
| 本地改动"消失"了 | 多半在 stash：`git stash list` → `git stash pop` |
| 下载后文件是旧的 | 先 `.\sync.ps1` 再 `.\download.ps1`；只要增量加 `-Since <日期>` |
| 想下的目录不在集合里 | `.\download.ps1 -Folders <目录1>,<目录2>`，或改进 `download_sets` |
| robocopy 返回 1—7 | 正常（有文件被复制 / 无变化 / 有额外文件），只有 ≥8 才算失败 |
| 想看这轮助手到底改了什么 | `.\sync.ps1` 后打开 `results\sync\last_sync.md`（历史回执在 `results\sync\history\`） |
| Agent 不知道本机算力/该用哪个环境 | 本机 `.\hardware.ps1 -Deep`；agent 侧 `agent-hardware.sh` 读取（超 30 天自动提醒） |
| **助手侧**工作区正常但历史回到基线提交 | `bash skills/git-sync/scripts/agent-recover.sh` → `agent-sync.sh` |

## 六、装到别的项目 / 给已装过的仓库升级

**新 Arena 会话**：用户只用短句 `安装 arena.ai/agent/01a0a821 的skills，与本地打通`。助手自己按 `templates/one-sentence.md` / 根目录 `01a0a821.md` 装技能（不要打开 arena.ai，不要向用户要长命令）。

**助手侧 / 手动（一条命令）**：

```bash
git clone --quiet --depth 1 -b arena/01a0ae7a-new \
     https://github.com/shaohuawen03-cyber/new.git /tmp/git-sync-src \
  && bash /tmp/git-sync-src/skills/git-sync/scripts/agent-install.sh --branch <工作分支>
```

（技能合并进 main 后把 `-b` 换成 `main`；也可以 `--gha` 顺带装 CI。）

**本机侧**（比如升级另一个已有配置的仓库）：

```powershell
.\skills\git-sync\scripts\install.ps1 -Target E:\0github\git-sync\<目标仓库> -Branch <它的分支>
cd E:\0github\git-sync\<目标仓库>
.\push.ps1 "chore: upgrade git-sync skill"
```

三种方式**都保留目标仓库已有的 `sync.config.json`**（只更新分支、补缺失的键），
所以**升级已装过的仓库 = 再跑一遍安装命令**；装完 `.\doctor.ps1` 看 `skill` 一行即可对账版本。

## 七、多会话协作模式（多个 Arena 会话 × 本地）

> **现状（2026-09-15 用户决定）：模式 B / C 暂时搁置。** 多会话并行的调度、合并、
> 冲突仲裁成本明显高于收益，先只走"一会话一仓库"（模式 A）把单会话闭环做扎实；
> 本节内容保留备查，需要时随时可以重启。
>
> 单会话闭环的验收标准（唯一要满足的）：agent 请求检查 → 本机值守**零窗口**自动跑完 →
> **免点击**推回结果 → agent 一个 `agent-wait --request ... --auto-accept` 内拿到 exit 0。

铁律先行：**一个会话一个分支**（Arena 给每个会话自动建 `arena/<id>-仓库名>` 分支，这是天然隔离边界）；
会话之间不能直接对话，**git 是唯一的总线**（提交 / 文件 / PR）。

| 模式 | 结构 | 冲突风险 | 适用 |
|---|---|---|---|
| **A 一会话一仓库**（默认） | 每个会话一个仓库；本机一仓库一个克隆文件夹 + 一个值守 | 无 | 彼此独立的项目（现状：技能总部 / PPT 项目 / AgentArena） |
| **B 同仓库多分支分任务** | 同一仓库开多个会话（各占一个分支）；本机**每个分支一个克隆文件夹**（`<repo>-a`、`<repo>-b`），各注册值守 | 只在 merge 时可能出现内容冲突（正常解决） | 同一项目的多任务并行 |
| **C 汇总会话**（release-manager） | 一个专职会话守集成分支（main / integration）：fetch 其他会话的分支 → merge → gate → `agent-wait --auto-accept` 让本机真机回归 | 由汇总会话统一处理 | 3 个以上会话，或任务间有依赖 |

关键事实：

* **同一条分支被两个会话同时推 = 必冲突**，不要这么用（Arena 自动分会支已天然避免）；
* 同仓库不同分支互不干扰：gate / 回执 / 握手全是分支内文件，值守任务名按文件夹命名不会撞；
* **一个本地文件夹不能同时检出两个分支**——模式 B 就一分支一个克隆（想省磁盘可用 git worktree，但脚本按"文件夹=仓库"设计，不推荐混用）；
* `hardware.ps1` 每个克隆各跑一次即可（或用 `GIT_SYNC_PROFILE` 共享一份配置）；
* 模式 C 的汇总会话自己会 fetch 同仓库的其他分支，**你不需要当传声筒**；合并质量由"本机真机回归"把关——这正是自动验证循环的第二种用法。

## 八、扩展清单

已实现：

- [x] 取 / 传 / 下载 / 打包 / 体检 / 首次准备 / 复用安装 / 开 PR 八类命令
- [x] 配置化：分支、远端、下载集合、扩展名归位、gate、回执路径
- [x] 分支守卫 + 提交前自检（gate）+ 可选 GitHub Actions 远端 CI
- [x] 助手侧 `agent-sync.sh`（含发散自愈、**同步回执**）与 `agent-recover.sh`（沙箱重置恢复）
- [x] `doctor.ps1 -Fix` 一键修复；ahead/behind 改为对比 `origin/<分支>`
- [x] `download.ps1 -Since <日期>` 增量下载；`-Folders` 临时指定目录
- [x] 多环境 profile（`GIT_SYNC_PROFILE` / `-Config`）
- [x] `agent-install.sh`：任何仓库一条命令安装/升级（保留配置）
- [x] 新会话引导提示词模板（`templates/new-session-prompt.md`）
- [x] `push.ps1 -Gate`：本机侧提交前也跑同一套自检
- [x] 版本标识（`VERSION`）+ `doctor.ps1` / 安装器显示版本
- [x] 回执按日期归档（`receipt_history`，自动保留最近 50 份）
- [x] 本机硬件/环境上报（`hardware.ps1` / `agent-hardware.sh`：GPU/CPU/内存/磁盘/conda/mamba/torch+CUDA）
- [x] **自动验证循环**（`agent-check.sh --request/--read/--accept` + `watch.ps1` 值守 + `local_check.ps1` 模板）：agent 干完 → 本机自动检查回传 → 直到 agent 满意收尾
- [x] `agent-wait.sh --auto-accept`：通过即自动收尾（"干完→验证→关闭"一条命令）
- [x] 本机即 Runner 配方（`templates/local-runner.md`）+ GitHub Actions 每日体检（`templates/health.yml`：握手卡死/硬件过期自动开 issue）
- [x] 安装器：根目录精简安装（无 skills 夹）的 `sync.config.json` 升级时同样保留（AgentArena 场景）
- [x] 安装器补漏：`hardware.ps1` / `watch.ps1` 进根目录复制清单（v2.2 漏 hardware，由另一 Arena 会话实战发现）
- [x] LFS / 大文件体检（>50 MB 提醒）
- [x] 安装器补齐 `code/check_loop_summary.ps1` / `.py`（v2.9.0；此前只有 `install.ps1` 会拷，bash 安装器缺，导致本机检查 2c 每轮都 WARN）
- [x] **多账号**（v2.9.0）：`auth.ps1 -Accounts` / `-Account <login>` / `-Unpin`，按克隆钉账号、失败关闭；`doctor`、`local_check.ps1`、`push.ps1` 三处联动

还想加的（按需）：

- [ ] 实验环境快照：`hardware.ps1 -Deep` 顺带把各环境 `pip freeze` / `conda env export` 存进 `results\hardware\envs\`（复现实验用）
- [ ] `agent-sync.sh` 自动 `git lfs install` + push 前 `lfs status` 检查（真有大文件时）
- [ ] 数据集清单与校验和：`dataset-manifest`（目录 + md5 + 大小），换机器核对数据没变
- [ ] 定时同步：`schedule.ps1` 注册 Windows 计划任务，每小时自动 `.\sync.ps1`
- [ ] 增量清单进回执（`-Since` 语义写进 `last_sync.md`）
