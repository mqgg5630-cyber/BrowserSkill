# git-sync 在本仓库（BrowserSkill）的安装说明

> 这一页记录 **本仓库特有** 的适配。技能本身的说明书在 `skills/git-sync/README.md`。

## 1. 装了什么

| 项 | 值 |
|---|---|
| 技能来源 | `https://github.com/shaohuawen03-cyber/new.git` 分支 `arena/01a0aeb9-new` |
| 技能版本 | `skills/git-sync/VERSION` = **2.9.2** |
| 本会话工作分支 | `arena/01a0b352-browserskill`（= `skills/git-sync/sync.config.json` 的 `branch`） |
| 远端 | `origin` = `https://github.com/mqgg5630-cyber/BrowserSkill.git` |
| 闸门 | `bash code/check_all.sh`（`agent-sync.sh` 每次提交前跑；本机 `watch.ps1` 每轮也跑） |
| 本机检查 | `code/local_check.ps1`（`sync.config.json` 的 `check_cmd`） |
| 握手文件 | `results/status/handshake.json`，一轮一档日志 `results/status/check_rN_<时间>.txt` |
| 第一轮验收标准 | `results/status/success_criteria.json`（只验「打通」，不含任何业务任务） |

安装命令（沙箱侧，一条）：

```bash
git clone --quiet --depth 1 -b arena/01a0aeb9-new \
     https://github.com/shaohuawen03-cyber/new.git /tmp/git-sync-src \
  && bash /tmp/git-sync-src/skills/git-sync/scripts/agent-install.sh \
         --branch arena/01a0b352-browserskill
```

## 2. 与 BrowserSkill 原有文件的两处冲突（已处理）

技能默认往仓库根目录放 12 个 `.ps1`，其中两个名字/内容与本仓库自己的东西撞上：

### 2.1 根目录 `install.ps1` 是 BrowserSkill 自己的

本仓库根目录的 `install.ps1` 是 **bsk CLI 的 Windows 安装器**
（`irm https://raw.githubusercontent.com/Tencent/BrowserSkill/main/install.ps1 | iex`），
不能被技能的 `install.ps1` 覆盖 —— 已还原为仓库原版并保持原样。

* 技能那份仍在 `skills/git-sync/scripts/install.ps1`，用全路径调用即可：

  ```powershell
  .\skills\git-sync\scripts\install.ps1 -Target E:\0github\<目标仓库> -Branch <分支>
  ```

* `code/check_all.sh` 第 3 节（根目录副本 ↔ `skills/git-sync/scripts/` 逐字节一致）
  因此把 `install` 列入 `ROOT_SKIP`：不比较，但 **反向漂移会报错** ——
  一旦根目录 `install.ps1` 与技能那份逐字节相同，就说明安装器把它覆盖了，
  闸门直接 FAIL 并让你 `git checkout -- install.ps1`。其余 11 个脚本照旧严格比较。
* 根目录 `install.ps1` 同时进了第 1 节的 `ASCII_ALLOWLIST`：它的注释头里有一个 UTF-8 破折号 `—`，
  这是仓库原有内容，不归技能管（技能自带的 `.ps1` 一个都没放行）。
* **升级技能后要注意**：`agent-install.sh` 每次都会把技能的 `install.ps1` 拷到根目录，
  重跑安装器后请立刻 `git checkout -- install.ps1` 还原（忘了的话闸门会 FAIL 提醒你）。

### 2.2 `scripts/install-windows.test.ps1` 故意含非 ASCII

它是本仓库测试「Windows 安装器不丢 Unicode 路径」的 **测试固件**：带 UTF-8 BOM，
里面有 `张三`、`中文 space [x] & install` 这类字面量。改成 ASCII 就等于删掉它要测的东西。

* `code/check_all.sh` 第 1 节因此加了 `ASCII_ALLOWLIST`，**只放行这一个文件**（并打印 NOTE）。
* 技能自带的所有 `.ps1` 仍然 100% 受「只用 ASCII」铁律约束，一个都没放过。

## 3. 新增的 `.gitattributes`（只有两行规则）

```
*.sh  text eol=lf
*.ps1 text eol=lf
```

原因：本机是 Windows，`core.autocrlf=true` 时 `.sh` 检出成 CRLF 会让
`bash code/check_all.sh` 直接报 `$'\r': command not found`（闸门假失败），
也会让「根目录副本 ↔ skill 副本」的逐字节比较失败。PowerShell 5.1 读 LF 的 `.ps1` 没问题。
规则范围故意只限这两种扩展名，仓库其余文件不做任何重规范化。

## 4. 账号策略（v2.9.2）

**谁的仓库就用谁的账号**：本仓库属于 `mqgg5630-cyber`，所以本机那份克隆要钉到
`mqgg5630-cyber`（只写这个克隆的 local git config，机器默认账号与其他克隆不受影响）：

```powershell
.\auth.ps1 -Accounts                 # 先看本机有哪些 gh 登录、谁能推本仓库
.\auth.ps1 -Account mqgg5630-cyber   # 只钉这个克隆
.\auth.ps1 -Verify                   # push --dry-run PASSED 才算数
```

看到 `403 Permission to mqgg5630-cyber/BrowserSkill.git denied to <别的号>` 就是账号没钉对，
不是凭据坏了。

## 5. 本机（Windows）最短路径

克隆目录固定在 `E:\0github\`，**每个会话一个新文件夹，绝不覆盖已有目录**：

```powershell
cd E:\0github\
git clone -b arena/01a0b352-browserskill https://github.com/mqgg5630-cyber/BrowserSkill.git BrowserSkill-01a0b352
cd BrowserSkill-01a0b352
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\bootstrap.ps1 -Auto
.\auth.ps1 -Account mqgg5630-cyber
.\doctor.ps1
.\watch.ps1 -Status
```

日常：`.\sync.ps1`（取）/ `.\push.ps1 "说明"`（传）/ `.\download.ps1 -Set final`（下载交付物）/
`.\doctor.ps1`（体检，出问题先跑它，`-Fix` 一键修复）。
只保留本会话的值守：`.\watch.ps1 -Focus`；把被暂停的其他会话值守拉回来：`.\watch.ps1 -RestoreParked`。

## 6. 沙箱侧常用命令

```bash
bash skills/git-sync/scripts/agent-sync.sh "feat: ..."        # 守卫 + 闸门 + 回执 + commit + push
bash skills/git-sync/scripts/agent-handoff.sh                 # 生成本机粘贴块（不要手打）
bash skills/git-sync/scripts/agent-check.sh --request "验证X" # 请求本机检查
bash skills/git-sync/scripts/agent-wait.sh --read             # 等/读结果（0=过 2=败 3=还在等）
bash skills/git-sync/scripts/agent-criteria.sh                # 对第一轮验收标准
bash skills/git-sync/scripts/agent-handsfree.sh --request "..." --timeout auto   # 一条命令闭环
```
