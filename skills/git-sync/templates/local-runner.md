# 本机即 Runner —— 把自动验证循环当"远程任务执行器"用（配方）

> 适用场景：任务**必须在你这台真实机器上跑**（真 GPU、真 conda 环境、真 Office、真数据），
> Agent 在沙箱只负责设计 / 编码 / 发起。v2.3 的自动验证循环天然就是这个模式：
> `check_cmd` 不只能"检查"，也能"执行任务并回传产物"。

## 核心思想

| 循环部件 | 当作任务系统理解 |
|---|---|
| `handshake.json` | 任务队列（单槽，round 递增，状态机可审计） |
| `check_cmd`（默认 `code\local_check.ps1`） | 任务本体——任意命令 |
| `results\` 目录 | 产物回传区（值守 push 自动带回） |
| `agent-wait.sh --request "任务" --auto-accept` | 派活 → 等结果 → 通过即自动收尾，一条命令 |

## 步骤（任何装了 git-sync 的仓库）

0. 本机一次：`.\auth.ps1 -Setup -Verify`（值守在后台推产物，没人能点登录窗，必须免点击）
1. 本机一次：`.\watch.ps1 -Register -Interval 2`（默认零窗口；注册后自检"真的跑了一次"）
2. 把要跑的命令写进 `code\local_check.ps1`（或改 `sync.config.json` 的 `check_cmd`）：
   产物写到 `results\jobs\` 下，进程退出码 0/非0 = 成功/失败
3. Agent：`bash skills/git-sync/scripts/agent-wait.sh --request "任务说明" --auto-accept`
4. Agent 读取 `results\status\check_rN_*.txt`（日志）与回传的产物，继续下一步工作

## 实战案例

- **image-to-editable-pptx**：`local_check.ps1` 里审计 PPTX——Office 包打开、
  227 原生形状 / 0 贴图 / 1139 可编辑字符、SVG 校验（"真可编辑"的核心承诺在本机验证）
- **AgentArena**：`docs/local-runner-brief.md` 把本模式设计为 benchmark 的
  "真实本机环境 runner"（`agentarena run` 的 job JSON + `local-runs/`，该仓库下一阶段）

## 注意事项

- **长任务**：把 `agent-wait --timeout` 调大（如 3600）；同时把 `sync.config.json` 的
  `check_timeout_min`（单轮硬超时，默认 30 分钟）和 `lock_stale_min`（锁过期，默认 45 分钟，必须大于超时）
  一起调大——否则任务会被判 `TIMEOUT` 强杀，或锁过期后第二个轮询插进来
- **大产物别进 git**：写到 `build\`（ignored）或 `pack.ps1` 打包后只回传清单/校验和
- **一次一个任务**（握手文件是单槽队列）；要并行就多仓库/多分支
- 任务里的输出用 `Write-Output`（不用 `Write-Host`），否则计划任务里捕获不到
