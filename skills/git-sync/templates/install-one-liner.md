# install-one-liner.md（模板）—— 四行装好 / 三行升级

> 这两块是给用户**直接照抄**的。`<...>` 处按自己的机器改；其余一个字都不用动。
> 安装器对已存在的文件是 **create-only**（只新建、不覆盖），所以升级不会冲掉你改过的
> `code\local_check.ps1` / `sync.config.json`。

---

## 一、新机器：四行安装块

```powershell
cd E:\0github\git-sync                                                            # 1) 放仓库的父目录
git clone -b <工作分支> https://github.com/<owner>/<repo>.git                      # 2) 克隆工作分支（不是 main）
.\bootstrap.ps1 -Auto                                                              # 3) 策略/身份/切分支 + 免点击推送 + 注册值守
.\doctor.ps1                                                                       # 4) 体检：三行都应是好消息
```

- 第 2 行的分支就是 `sync.config.json` 里的 `branch`（技能总部当前是 `arena/01a0ae7a-new`；你自己仓库用你自己的分支）。
  `push.ps1` 会直接拒绝 main/master，所以克隆错分支会立刻暴露，不会静默推坏东西。
- 第 3 行 `-Auto` 等价于 `bootstrap.ps1` + `auth.ps1 -Setup -Verify` + `watch.ps1 -Register` 三步。
- `-Register`（v2.6.9）会**暂停其他会话**的 `git-sync-watch-*`（任务保留、循环停掉）。切回本会话 HQ：`cd E:\0github\git-sync\git-pull-arena-s2 ; .\watch.ps1 -Focus`。不想动别人：`.\watch.ps1 -Register -KeepOthers`。
- 第 4 行期望：`branch` 是工作分支、`ahead/behind = 0/0`、末尾 `watcher / heartbeat / auth` 三行都正常。
  前置只有一个：本机装好 Git（`git --version` 出版本号；没有就到 <https://git-scm.com/download/win>）。

## 二、已装过：三命令升级块

```powershell
cd <repo>                                                                          # 1) 进仓库目录
.\sync.ps1                                                                         # 2) 拉最新
.\watch.ps1 -Unregister ; .\watch.ps1 -Register                                     # 3) 重注册值守（顺手清掉旧循环）
.\watch.ps1 -Status                                                                 #    确认：other loops 为空、last_push: ok
```

**为什么第 3 步必须重注册**：计划任务里写死的是启动命令行，不重注册就还在跑旧版本的启动方式
（v2.6.0 之前的旧循环没有 pid 文件，`-Unregister` 停不掉它，`-Register` 会顺手清理）。

## 三、升级后自检（`-Status` 该看到什么）

| 行 | 期望 |
|---|---|
| `loop process` | `pid ... (running)`，且只有一个 |
| `other loops` | 不出现（出现就说明还有旧版本循环，`-Unregister` 再 `-Register` 一次） |
| `heartbeat age` | 小于轮询间隔的 2 倍，标 `fresh` |
| `last run / schedule result` | 带人话注释；`0 / 267009 / 267011 / 267014 / 2147946720(0x800710E0)` 都是**正常**码 |
| `host log (tail)` | 每轮都有一行 `== ...` 收尾行 + 一行 `== next poll at HH:MM:SS (Ctrl+C stops this loop)` |
| `other tasks` / `parked` | 其他会话的 `git-sync-watch-*`；被暂停的会标 Disabled。切回：`.\watch.ps1 -Focus`；全恢复：`.\watch.ps1 -RestoreParked` |

> `2147946720` 看着吓人，其实是 `0x800710E0`「已有实例在跑，本次启动被拒」——常驻循环 + 10 分钟
> keeper 触发器的**正常**结果，v2.6.8 起 `doctor.ps1` 也不再把它当异常提示。

## 四、代理机器额外一步

`gh` 不读 git 的 `http.proxy`，只认环境变量。`-Status` 检测到不一致时会直接把命令打出来，照抄即可：

```cmd
setx HTTPS_PROXY "http://127.0.0.1:10808"
```

（`setx` 只对**之后新开的**窗口生效，当前窗口要手动 `$env:HTTPS_PROXY = '...'`。）

## 五、装到别的项目（技能复用）

```powershell
.\skills\git-sync\scripts\install.ps1 -Target C:\MyProject -Branch <该项目的工作分支>
```

装完在目标仓库里跑 `.\doctor.ps1`。根目录的 `watch.ps1` / `doctor.ps1` / `install.ps1` 是
`skills\git-sync\scripts\` 的**逐字节镜像**（`code/check_all.sh` 第 3 节会卡这件事）——改了 skill 里的
副本记得 `cp` 回根目录，否则闸门会红。
