# 成功案例：新账号 + WSL/Windows 双链路 + 本机 conda ML

**对象**：`shaohuawen03-cyber/git-pull-arena`，分支 `arena/01a0ad15-git-pull-arena`
**用户机器**：`LAPTOP-R77M5D6M`（Windows 11 + WSL2，仓库父目录 `E:\0github\git-sync`）
**结果**：round 38–41（WSL 桥接/探针/ML + Windows 原生 deck）全过；round 46/47
Windows 原生探针 + 肽 ML 全过，验收标准 172/172，真 conda 环境出预测并推回。
**一句话**：以后这个账号 + 这台机器的新会话，先读 §1 三张卡 + §7 清单，5 分钟开工。

## 1. 三张卡（开工前先看这个）

**账号卡**：仓库主＝`shaohuawen03-cyber`；Windows 凭据库里存的是旧号
`mqgg5630-cyber`。旧号已被加为仓库 Collaborator——**两边各用各号，天然共存**：
沙箱/gh 走 shaohuawen03，Windows 值守走存好的 mqgg。push 报
`permission denied` 先查 Collaborators，**不是凭据坏了，别重登录**
（round 41 连跪 10 次，加完协作者第 11 次一次过）。

**Windows 卡**：仓库 `E:\0github\git-sync\git-pull-arena-01a0ad15`；conda base 在
**非标准路径 `E:\spider`**（`Scripts\conda.exe` 在，envs 分布在 `envs/`、
`Library\envs/`、`E:\conda-envs`），共 **22 个环境**，ML 达标 3 个——
**`NTxPred2`**（py3.10.7，numpy1.25/pandas1.5/sklearn1.5，另带 torch CPU）、DIP、
meta-analysis；venv `E:\0github\git-sync\ppt-master\.venv`（py3.11.9，
由 `E:\spider\python.exe -m venv` 生出，是仓库的**兄弟目录**，local_check 永远找得到）；
git 在 `E:\hermes\git`（自带 bash 专供门禁，**不在 PATH 里**）；真 Word/PowerPoint；
CPU 8 核，磁盘余 ~198GB，GPU 按 09-15 台账是 GTX 1650（本季未重测）。
值守＝计划任务 `git-sync-watch-git-pull-arena-01a0ad15`（2 分钟一轮），
状态在 `%LOCALAPPDATA%\git-sync\`。

**WSL 卡**：仓库 `~/projects/git-pull-arena-01a0ad15`；cron 值守（本季后半程已摘，
Windows 执勤中）。**铁律：同一分支只准一侧值守 live**，双 live 会抢答/重复 verdict。
WSL 的 conda 是另一套（13 环境，best=`AMPidentifier`），证据归档在
`machine_probe_linux.json` / `results/peptide_ml_linux/`，和 Windows 版永不混写。

## 2. 双账号共存（round 41）

现象：值守日志 10 次 `permission denied`（`103840–111020`），第 11 次
`b77d505..0a6e9d1` 一次推上。根因：仓库换主（shaohua 新库），Windows 存的还是
旧号 mqgg 凭据。修法：浏览器 → 仓库 Settings → Collaborators → 加回 mqgg。
附带坑：`push.ps1` 把认证拒绝误报成"branch moved, run sync first"——看到这句先看
exit 码是不是 4（认证失败），别真去 sync。

## 3. 值守交接（round 41 前）

同分支 Win+WSL 双值守会抢同一轮。开工先问用户哪侧执勤，另一侧摘掉
（Windows：`.\watch.ps1 -Unregister`；WSL：停 cron）。本季：用户摘了 WSL cron，
Windows 单侧执勤 rounds 41–47，零抢答。

## 4. runner 分流（round 42 起，`code/local_check.ps1` §4）

背景：ps1 原来只会 office-deck（读死 `pptmaster_local.txt`），`loop.json` 切配方它也照跑 deck。
修法（Option-2，小手术）：读 `code\loop.json` 的 recipe，`office-deck` 走原来 inline 路径
（逐字节不动），其他 recipe 走 `local_loop.py local --os windows`，收据判
`loop-ok` + `opened=`（判法与 `local_check.sh` 同构）。
教训：4b/4c 读到的可能是**上轮提交下来的旧收据**（本季就读到过 WSL 的 loop-ok）——
4a 的 exit code 才是真守卫，判轮时先看 4a。

## 5. 找 python 四连败（rounds 42–45，精华）

| 轮 | 现象 | 根因 | 修法 |
|---|---|---|---|
| 42 | PATH 里找不到 python | conda 默认不上 PATH；计划任务 PATH 极简；`python3` 只是 Store 桩（exit 9009），且本机没有 `py` 启动器 | 两阶段发现：**绝对路径先**（venv 兄弟目录 + conda 根），PATH 后，每个候选都 `-c` 实探 |
| 43 | 3 个候选全倒在探针上 | 看起来像"python 全坏了"，信息不足 | 逐候选打印 exists/exit/output，不猜 |
| 44 | venv 和 `E:\spider` 都存在，`import sys` 都 Traceback | 只截了输出**头** 120 字，错误行被砍了；同时确认 `E:\spider` 就是真 conda base | 截**尾** 300 字；加取证块（env 变量、`pyvenv.cfg`、`E:\` 目录、`Lib`/conda.exe 存在性） |
| 45 | 无投毒（PYTHONHOME 等全 unset）、Lib 完好 | **PS 5.1 调 native exe 会吞双引号**：`-c 'print("py-ok")'` 到达 python 时变成 `print(py-ok)` → NameError，每台解释器死法一模一样 | `-c` 里只准**单引号**：`print(''py-ok'')`；另补 `E:/spider`、`E:/` 进探针/包装器的根扫描 |

round 46 一次过（216 秒，venv runner，`envs=22 ml_ready=yes best=NTxPred2`）。
**以后任何从 PowerShell 拼 `-c` 的地方，复制这条铁律：单引号，无例外。**
（python 侧 `subprocess` 传参列表不受影响——只有 PS→native 这条边会吞引号。）

## 6. Windows 配方三件套（round 47）

1. 步骤禁 bash：git-bash 存在但不在 PATH，`{bash}` 占位符在 Windows 不可信——
   Windows 步骤一律 `["{python}", "code/xxx.py"]`（本季：`code/run_peptide_ml.py`，
   `run_peptide_ml.sh` 的纯 stdlib 双胞胎：探针报告 → 新鲜扫描（含 `E:/spider` 双布局）→ PATH，首个能 import numpy/pandas/sklearn 者胜，零安装、零硬编码环境名）。
2. 先 probe 轮，再干活轮：probe 便宜（2–4 分钟），一次验证分流＋发现链＋conda 清单；
   ML 轮直接吃 `machine_probe.json`（Windows 数据，由 verdict 推回覆盖）。
3. 确定性即证据：种子固定的 RF 在 Win/WSL 产出**字节一致**的 `predictions.csv`——
   verdict diff 里没有它**是正常的**（git 无变化），host/解释器/时间戳全在 `metrics.json` 里；
   活目录 `results/peptide_ml/` 给 verdict 覆盖，上个 OS 的版进 `results/peptide_ml_linux/` 归档。

round 47：`NTxPred2` 3.9 秒跑完，acc=0.97（P=1.00 R=0.70），104 秒 verdict passed。

## 7. 新会话 5 分钟清单（这个账号＋这台机器）

1. `git fetch origin` 对远端 tip；读 CONNECTIONS.md 最新两条 + 本案例。
2. 读 `results/status/machine_probe_windows.json`（conda 地图，ML 首选 NTxPred2）——
   环境没变就别重跑 probe 轮。
3. 确认**只有一侧值守 live**（问用户哪侧执勤）。
4. 新配方先跑 probe/冒烟轮验证分流；Windows 步骤必须无 bash；新 `-c` 探针单引号。
5. 新沙箱 push 用 gh（shaohuawen03）；Windows 侧 push 失败先看 Collaborators 和 exit 4。
6. 收尾：`loop.json` 切回 `office-deck`（＋payload 镜像），判轮只看 request→verdict→accept 链。
7. 沙箱 `.git` 被重置（`git log` 只剩基线）→ 先 `agent-recover.sh`，再 `cmp` 对工作区，
   不要急着重写文件。

## 8. 沙箱侧三坑（本季亲测）

* **`.git` 静默重置**：表现为 shallow 单分支 clone＋工作区快照覆盖。修：补 refspec
  → `fetch --unshallow` → `cmp` 确认快照＝远端 → `reset --hard origin/<branch>`
  （untracked 文件不受影响；未提交的改动先留 patch）。`agent-recover.sh` 一键版。
* **handsfree 退出码被吃了**：`cmd | tail; echo $?` 拿到的是 tail 的 0。
  等 verdict 必须 `> file 2>&1; echo $?` 或 `${PIPESTATUS[0]}`，再加 verdict 提交＋handshake 双确认。
* **`require_contains` 的值必须是字符串**：门禁按 `str(needle) not in body` 判，
  传 list 会变成 Python repr（`['a', 'b']`）永远匹配不上——一个文件只 pin 一个子串，
  要 pin 多个就选横跨两者的那一段原文。

## 9. 每克隆账号钉住（v2.9.0，2026-09-17，会话 `01a0ae7a`）

**现场**：仓库 `shaohuawen03-cyber/new`（本机克隆 `E:\0github\git-sync\new-01a0ae7a`），
Windows 侧 gh 默认账号 `mqgg5630-cyber`、凭据库 dpapi，`auth.ps1 -Verify` 报
`Permission to shaohuawen03-cyber/new.git denied to mqgg5630-cybe ... 403`——
**凭据是好的（40 字符 gho_ 令牌），403 是权限**。

**修法（用户选 B：不改仓库权限）**：
```powershell
gh auth login --git-protocol https     # 加一个 shaohuawen03-cyber 登录
gh auth switch -u mqgg5630-cyber       # ★ 默认账号切回 mqgg，否则 git-pull-arena / zhongqi 全部 403
.\auth.ps1 -Account shaohuawen03-cyber # 把【这个克隆】钉住
.\auth.ps1 -Verify                    # push --dry-run PASSED
```

**两条 shell 机制（实测，不是猜的）**：

1. **helper 列表是累加的**：机器级 `credential.helper`（GCM）与
   `credential.https://github.com.helper`（全局 gh = active 账号）都会排在前面先应答，
   只 `--add` 一条更具体的 helper **等于没设**。必须先写一条**空值** `credential.helper` 清空列表，再钉。
   实测（git 2.39，同一份 global 配置）：
   `只 add` → 应答者是机器级 helper；`先 add 空值再 add pin` → 应答者是 pin。
2. **`test -n $(...)` 是陷阱**：POSIX `test` 收到单个参数 `-n` 时**恒为真**，于是
   `!test -n $(gh auth token -u X) && GH_TOKEN=$(...) gh auth git-credential` 在
   账号不可用时仍会执行——而且 `GH_TOKEN` 为空时 gh 会**回落 active 账号**，
   等于静默用错身份。最终写成失败关闭、且**不含双引号**（cmd 传递安全）：
   `!if T=$(Q auth token -u NAME); then GH_TOKEN=$T Q auth git-credential; else exit 1; fi`。

**附带**：`-Auto` 的零窗口启动器在杀软下报 `%1 不是有效的 Win32 应用程序`，自动回退 flash 模式
（每次登录闪一次，功能不变）；想零闪就给 `C:\ProgramData\git-sync\` 加排除，或管理员跑
`.\watch.ps1 -Register -Headless`（需 gh 令牌可用）。

## 10. v2.9.0 钉账号的两连坑（2026-09-17 下午，会话 `01a0ae7a` 实测）

**症状**：`E:\0github\git-sync\new-01a0ae7a` 执行 `auth.ps1 -Account shaohuawen03-cyber` →
`[FAIL] could not write the local pin:`（详情为空）；随后 `-Verify` 里 push 直接报
``if T=$(...); then ...; else exit 1; fi get: -c: line 1: syntax error near unexpected token `get'``。

**坑 1：git 会往 helper 命令后面追加 `"$@"`**。git 执行 `!` 开头的 helper 等价于
`sh -c '<value> "$@"' '<value>' get`，所以值必须是**被调用的函数**：
`!f() { ...; }; f` → 变成 `f get` ✅；而 `!if ...; then ...; fi` → 变成 `if ...; fi get` → 语法错误 ❌。
写成 `test -n $(...) && ...` 还有第二个坑：POSIX `test` 收到单个参数 `-n` 时**恒为真**，
且 `GH_TOKEN` 为空时 gh 会**回落 active 账号**（= 静默用错身份）。最终形态（无引号、可经 cmd）：

```
!f() { T=$('C:/Program Files/GitHub CLI/gh.exe' auth token -u NAME) || exit 1; GH_TOKEN=$T 'C:/Program Files/GitHub CLI/gh.exe' auth git-credential $@; }; f
```

**坑 2：空值复位必须写在本地列表最前面，而且写进去不可靠**。实测（git 2.39，global 层有一个
能正常应答的 generic helper）：
* 只写本地 `credential.https://github.com.helper` → **机器级 generic 抢先应答**（所以用户手打那条无效）；
* 本地先写一条**空值** `credential.helper` 再 pin → pin 生效 ✅；
* 没有空值复位时的对照实验 → 又回到机器级账号 ❌。

而"写一条空值"在 Windows 上会失败：空参数经 cmd/MSYS 可能被吞掉，`git config key ""` 退化成读操作并 exit 1
（这正是 `could not write the local pin:` 的来源）。v2.9.1 起三层兜底并逐层读回验证：
argv（`--replace-all credential.helper ""`）→ `git config --stdin`（git ≥ 2.45，空值走 stdin，不经过 argv）→
直接编辑 `.git/config`（在 `[credential]` 段首插入 `helper = `）。

**坑 3（设计决定）：钉住后不加后备 helper**。若把机器级 helper 追加在后面当后备，账号令牌失效时
git 会拿机器默认账号（错误身份）继续推——"失败关闭"就没意义了。宁可明确失败，让人看见。

**怎么快速自检**：`auth.ps1 -Account <login>` 成功时会打印实际生效的那一层（argv/stdin/file）与
`probe: the credential now comes from ...`；`-Accounts` 会显示 PINNED 与"谁能推本仓库"。

## 11. 删掉一个被跟踪的文件，会被"分叉自愈"还原（2026-09-17 实测）

**现场**：把跑完的临时脚本 `.patch_291.py` 从分支上删掉——
`git rm --cached` + `rm` 后再跑 `agent-sync.sh`，提交里**看不到这次删除**，文件随后又出现在工作区。

**原因**：`agent-sync.sh` / `agent-check.sh` 的分叉自愈里有两步连着走：
`git reset --mixed origin/<branch>`（把索引退回远端 = 文件回到索引）紧接着
`git ls-files -d | xargs -r git checkout --`（"索引里有、工作区没了"的文件一律**还原**）。
这两步是为了在沙箱 `.git` 被静默重置后把文件抢救回来，但副作用是：**你刚删掉的跟踪文件会被"救"回来**。

**正确做法**（删跟踪文件时）：
* 走完 `agent-sync.sh` 后 `git status` 确认删除已进提交；没有就再来一次，或
* 直接 `git rm <file>` → `git commit` → `git push origin <branch>`（跳过自愈路径）；
* 删完用 `git ls-tree -r origin/<branch> --name-only | grep <file>` 在**远端**核对，别只看本地。

## 12. 账号策略 + 技能总部（v2.9.2，2026-09-17）

**用户决定**：① 技能**只更新在 `arena/01a0ae7a-new`**（不开 PR 到 main）；② **以后都从这个分支装 skills**；
③ 账号规则：**mqgg 的对话用 mqgg、shaohua 的对话用 shaohua**。

**落地**：
* `agent-install.sh` 的源改成候选列表（新源 `shaohuawen03-cyber/new@arena/01a0ae7a-new` 优先，
  旧 `mqgg5630-cyber/git-pull-arena` 兜底），**探测全部候选、装最新版**（沙箱实测：探测 5 个候选后选中 v2.9.1，而不是旧源的 v2.8.1）；
* `agent-handoff.sh` 从 remote URL 解析 owner，粘贴块里自动加
  `.\auth.ps1 -Account shaohuawen03-cyber    # policy: push as the REPO OWNER's account`，
  并在末尾打印 `account : <owner> (the repo owner - this clone is pinned to it)`；
* 机器默认账号**保持用户常用的那个**（`gh auth switch` 只用于改默认，不用于切仓库）。

**为什么按"仓库主"钉**：一台机器上 mqgg 与 shaohua 的克隆并存，谁都不能把对方的凭据顶掉；
pin 只写本克隆的 local config，`-Unpin` 一键还原。合并两账号权限（Collaborator）是另一条路，
用户明确选了"不动仓库权限、各用各号"。
