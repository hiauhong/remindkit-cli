---
name: remindkit
description: Read and manage Apple Reminders on macOS — lists, today/overdue, search, stats, permission diagnosis, and full write (create/edit/complete/delete reminders; groups, sections, subtasks, smart lists). Use when the user wants to know what's due, check/search/count reminders, list lists, export JSON, diagnose permissions, or create/update/complete/delete reminders and organize lists, groups, sections, smart lists.
allowed-tools:
  - Bash(remindkit *)
---

# remindkit — Apple Reminders 读写 CLI

面向 agent 的 macOS Reminders 读写 CLI。所有命令输出 JSON/纯文本/统计三种格式，无需 Full Disk Access，只需 Reminders 权限。读端覆盖全部字段（含分区/子任务/分组/智能列表）；写端覆盖完整层级：分组 → 列表 → 分区 → 任务 → 子任务。

## 当前时间（不要猜，用这些值）

- 今天 (ISO)：!`date +"%Y-%m-%d"`
- 现在 (本地)：!`date +"%H:%M %Z"`
- 明天 (ISO)：!`date -v+1d +"%Y-%m-%d"`

用户说"今天/明天/过期"时，先用上面的值确定日期，再决定用 `today` / `overdue` / `query --due-before`。不要从训练数据猜今天是几号。

## 用户的使用约定（先读这里，再路由意图）

> **约定文件 `~/.local/share/remindkit/conventions.md`（可用 `REMINDKIT_CONVENTIONS_FILE` 重定向，如放 iCloud Drive 跨设备同步）是可选的跨列表方法论侧车**（如旗标含义、inbox 列表）。它**不由 setup 生成**：需要时由 agent 在对话中向用户收集后写入，或用户手动编辑；普通用户不配置也能正常使用。

> 每个列表的用途以 `note` 备注为准。**agent 用 `list --format json` 拿全量结构（含分组归属 parentTitle + 备注 note），用 `note --set` 非交互写入**，流程见下方「列表用途标注」。
> ⚠️ **`setup` / `setup --deep` 是交互式确认向导，只有真人终端可用，agent 不运行**（非 TTY 直接报错退出）——agent 用 **`setup --accept`** 非交互保存候选备注（仅填空缺、不覆盖已有），或 `setup --status` 查状态。

## 意图路由

> **默认命令是 `overview`**（安全概览，不是全量导出）：无参数跑 `remindkit` = 今天/过期/未来 7 天/旗标焦点/紧急 摘要。全量数据必须显式 `remindkit dump`。

| 用户想要 | 命令 | 验证 |
|---|---|---|
| **先看该看什么（默认）** | `remindkit` / `remindkit overview [--within N]` | json 模式拿结构化摘要；plain 给人看 |
| 今天到期（未完成） | `remindkit today` | 加 `--format json` 拿结构化结果 |
| 今天到期 + 含过期 | `remindkit today --include-overdue` | 同上 |
| 已过期（未完成） | `remindkit overdue` | 同上 |
| 旗标（苹果一级入口「已标记」） | `remindkit flagged` | 对齐 App 侧边栏；支持 `--list`；agent 问"最近关注什么"用它 |
| 紧急（苹果一级入口） | `remindkit urgent` | 同上 |
| 计划（所有带日期的） | `remindkit scheduled [--within N] [--from D --to D]` | 对齐苹果「计划」视图：过期+今天+未来按日期排；`--within 7` = 未来 7 天；可与 `--flagged/--urgent/--list/--tag` 组合 |
| 按标题/备注/标签搜索 | `remindkit search "<词>"` | 加 `--list` 限定列表 |
| 标签视角（列出所有标签+计数） | `remindkit tags` | 默认未完成；`--all` 含已完成 |
| 某个列表的提醒 | `remindkit query --list <名称或ID>` | 加 `--tag` / `--flagged` / `--urgent` 组合过滤 |
| 到期日期区间 | `remindkit query --due-after 2026-08-01 --due-before 2026-09-01` | |
| 数量统计（全局/按列表） | `remindkit count [--list X]` | 省 token 首选 |
| 每个列表的统计表 | `remindkit count --by-list` | 一次拿到全部列表统计，勿循环 count |
| 有哪些列表/群组/分区 | `remindkit list` / `remindkit list --groups` | |
| 全量导出 | `remindkit dump > reminders.json` | 数据量大，谨慎；`dump.smartLists` 默认只含自定义（`type: custom`）；系统智能列表（今天/旗标/已完成/已分配）是虚拟视图、事项都在普通列表里，默认不输出，`dump --system-smartlists` 才包含；「计划」无实体，用 `scheduled` 命令 |
| 权限诊断 | `remindkit doctor --for-agent --json` | 报错时最先跑 |

## 统一语义

- 所有查询命令**默认只返回未完成**；`--completed` 只查已完成；`--all` 查全部（`--completed` 与 `--all` 互斥）。
- **JSON 日期字段**：`dueDate` 是 epoch（Double），同时输出 `dueDateText`（本地时区 `yyyy-MM-dd HH:mm`，全天提醒为 `00:00`）——判断今天/过期/几天内直接用 `dueDateText`，勿手转 epoch。
- **分区（section）字段**：查询命令**显式 `--list` 时自动带** `section`（列表结构查询的核心诉求，如「OKR 列表 → 健康/个人成长/财务…」）；无 `--list` 默认不带（性能，section 查询慢）。需要时 `--sections` 强制带 / `--no-sections` 强制跳过。
- **结构视图 `--tree`**：`query --list X --tree` 直接渲染「分区 → 任务 → 子任务」层级树（含父子缩进）——查列表内部结构用它，别从平铺 JSON 自己拼。
- **输出格式自动切换**：终端（TTY）默认 `plain`，管道/agent 调用自动 `json`——agent 无需每次带 `--format json`；也可显式 `--format json|plain|count` 覆盖。
- `count` 无完成态开关，始终显式输出 `{total, incomplete, completed, flagged, urgent, dueToday, overdue}`（默认 json，`--format plain` 给人看）。`count --by-list` 输出 `{total, incomplete, lists:[{id,title,icon,isGroup,parentTitle,total,…}]}`。
- `--list` 解析顺序：完整 UUID → UUID 前缀（≥8 位）→ 精确标题（大小写不敏感）→ 子串；**匹配不到时报错退出**（见下），重名列表全部匹配并在 stderr 提示。

## Token 效率守则

- **优先 `count` / `search` / `today` 等定向查询**，全量 `dump` 一条提醒约 100~200 token，1000 条可达 10万+ token。
- **`--fields id,title,dueDate,…` 投影**：query/today/overdue/scheduled/search/flagged/urgent/dump 都支持只输出需要的字段（逗号分隔；不存在的字段忽略；dump 时只投影 reminders，calendars/smartLists 保留）。只要几个字段时务必用它，可省 80%+ token。
- 一次会话需要多个独立查询时，用 `;` 在**同一个 Bash 调用**里串起来，别拆成多次调用。
- 只要统计就 `count`，不要 `dump | jq length`。

## 错误与权限

- 运行时错误（如权限被拒、找不到列表/提醒）输出到 **stderr** 的 JSON：`{"error":{"code":"…","message":"…"}}`，退出码 1；用法错误（缺参数/互斥/格式错）退出码 64。**读侧与写侧同契约**。
- **列表不存在**：`--list`/`--list-id`/`--to-id`/`--group-id` 匹配不到时退出码 1，stderr：`{"error":{"code":"noSuchList","message":"…"}}`（有近似候选时 message 附带 Did you mean 提示）。写侧业务码：noSuchList / noSuchReminder / noSuchGroup / noSuchAccount / noSuchDeletedRecord / noSuchSection / reminderKitError / unsupportedByEventKit / readOnly。
- macOS 权限归属于**宿主进程**（终端 App 或 agent 宿主），不是 remindkit 二进制。
- 权限问题先跑 `remindkit doctor --for-agent --json`，按 `fix` 提示操作（给宿主授权）。
- 若 `doctor` 显示 `access: granted` 但命令仍失败，检查是否有 `--format`/参数拼写问题。

## 命令示例

```bash
# 查询
remindkit                                  # 默认 overview：今天/过期/未来/旗标/紧急摘要
remindkit overview --format json           # agent 首选：结构化摘要
remindkit today --format json
remindkit today --include-overdue --format json
remindkit overdue --format json
remindkit scheduled --within 7 --format json   # 未来 7 天的计划（含今天）
remindkit scheduled --flagged --format json   # 带日期的旗标事项
remindkit search "牛奶" --format json
remindkit query --list 工作 --tag 紧急 --format json
remindkit query --all --fields id,title,dueDate --format json   # 只取需要的字段（token 优化）
remindkit dump --fields id,title,dueDate,completed > slim.json  # dump 也只投影 reminders
remindkit query --due-before 2026-08-01 --all --format json
remindkit count --list 工作
remindkit count --by-list                       # 每个列表的统计表
remindkit count --list 18713533                # UUID 前缀也能匹配
remindkit list --groups --format json

# 列表备注（sidecar 元数据，苹果没有列表描述字段）
remindkit note --all                              # 查看所有列表备注（含分组和智能列表）
remindkit note --list 数码                        # 读取某个列表备注
remindkit note --list <完整UUID> --set "想买的数码产品"   # 设置（重名必须用 UUID）
remindkit note --list <完整UUID> --clear          # 清除
remindkit note --list 旗标 --set "当前焦点"         # 智能列表也可读写备注（按名/UUID）
remindkit note --list BE0D0E6D --set "..."        # 智能列表 UUID 前缀（旗标）
# 智能列表：系统（今天/旗标/已完成/已分配）+ 自定义均可读可写；note --all 输出带 isSmartList/smartListType 标识
# 存储：~/.local/share/remindkit/notes.json（可用 REMINDKIT_NOTES_FILE 改路径，如放 iCloud Drive 自动同步）
# list --format json 输出携带 id/title/icon/color/sections/parentTitle/note/order（一次拿全结构）
# list --format plain（树形）和 count --by-list 的输出也会自动携带每个列表的 note 字段

# 列表用途标注（agent 非交互流程，不跑 setup）
# 1. 拿全量结构：
remindkit list --format json
# 2. 识别待标注列表：note 为空、或仍是机械结构复述（形如「分区[支出/收入] ｜ 图标💵」）
# 3. 读内容推断用途（投影省 token）：
remindkit count --by-list                                      # 统计视角
remindkit query --list <完整UUID> --fields title,dueDate --all # 内容视角（必须 UUID）
remindkit query --list <完整UUID> --tree                      # 结构视图：分区→任务→子任务层级树
# 4. 写回：
remindkit note --list <完整UUID> --set "每月账单缴费提醒：电费/水费/房贷/五险一金/燃气费"
# 5. 复查：
remindkit list --format plain    # 树形含备注
# 幂等：已有合理备注的列表不要覆盖；只补空的/机械的。setup 是交互式向导（需真人终端），agent 禁用。

# 全量导出（token 昂贵，只在需要完整上下文时用）
remindkit dump > reminders.json
remindkit dump --pretty > reminders-pretty.json   # 人读用

# 诊断
remindkit doctor --for-agent --json
```

## 写操作（谨慎使用）

> **只读保护**：环境变量 `REMINDKIT_READ_ONLY=1` 时所有写命令（add/update/complete/delete/move/bulk/add-list/add-group/add-section/add-smartlist/delete-list/update-list/restore）拒绝执行，报 `{"error":{"code":"readOnly"}}`——agent 在只读场景（如纯查询会话）可设置它防误写。
> **测试纪律（硬规则）**：写操作测试只能在**新建**的「测试冒烟*」列表/分组上做，自建自删（`make test` 的冒烟脚本会自建并自动删除，最后校验零残留）。**绝不直接对真实列表执行写测试**。
> **同名列表**：按名字操作遇到重名（如两个「财务」）会报歧义错误并列出候选 ID——此时必须改用 `--id`/`--list-id`/`--to-id` 精确定位。

```bash
# 新建提醒（写走 ReminderKit 私有框架，EventKit 兜底；输出 JSON 含 source）
remindkit add "买牛奶" --list 测试列表 --due "2026-08-03 09:00" --priority high \
  --repeat weekly --days mon,wed --until 2026-12-31 --notes "备注" \
  --tag 购物 --tag 生活 --urgent --flagged --parent <父提醒ID> \
  --url "https://example.com" --alarm-before 30 \
  --location "深圳湾" --latitude 22.52 --longitude 113.94

# 常用参数：--notes / --due (YYYY-MM-DD 全天 | YYYY-MM-DD HH:MM) / --start / --priority high|medium|low \
#   --repeat hourly|daily|weekdays|weekends|weekly|monthly|yearly / --every N / --days mon,tue,... / --until YYYY-MM-DD \
#   --tag (可重复) / --urgent / --flagged / --parent <id>（子任务）/ --section <分区名>（归入已有分区，先 add-section）\
#   --url / --alarm-at "YYYY-MM-DD HH:MM"（绝对时间提醒，可重复）/ --alarm-before N（截止前 N 分钟）\
#   --location <地名> --latitude X --longitude Y [--proximity arrive|leave]（位置提醒）\
#   复杂重复：--repeat monthly --on-day 15 / --repeat monthly --last-workday \
#     --repeat yearly --months 3,8 --on-weekday sun:1（每年3、8月第一个周日）\
#   注意：--repeat 未给 --due 时自动算下一个符合规则的日期作为到期日

# 批量操作（先条件选择，再统一执行）
remindkit bulk --op complete --list 日常 --due-before 2026-08-02   # 完成日常里过期的
remindkit bulk --op delete --list 测试列表 --all --dry-run         # 先预览再删
remindkit bulk --op move --list 收集 --to 想去                      # 收集的移到想去
remindkit bulk --op update --list 数码 --flag                       # 批量加旗标
# 选择器：--list/--tag/--flagged/--urgent/--due-after/--due-before（至少一个）
# 安全：--dry-run 预览；--limit N 上限（默认 50，超出拒绝）

# 完成 / 重开 / 删除 / 移动 / 旗标紧急
remindkit complete <id>          # 完成；重复提醒完成后自动滚动到下一期，响应带 nextOccurrence/nextOccurrenceText
remindkit complete <id> --reopen  # 重开
remindkit update <id> --flag          # 给已有提醒加旗标（当前焦点）
remindkit update <id> --no-flag --urgent   # 去旗标 + 标紧急（可组合）
remindkit update <id> --title "新标题" --due "2026-08-15 15:30" --notes "备注" \\
  --priority high --tag 购物 --url "https://…" --repeat weekly --days mon,wed --until 2026-09-01
  # 更新字段：--title/--notes/--due/--start/--priority/--tag(可重复)/--url/--repeat/--days/--until/--section(移入分区)
  # 提醒：--alarm-at "YYYY-MM-DD HH:MM"(可重复)/--alarm-before N(--due 或当前 dueDate 为基准)/--location+经纬度
  # 至少指定一个字段或旗标；EventKit 兜底时 tags/repeat/flag/urgent/section 标记 degraded
remindkit delete <id>          # 软删除 → 最近删除（30 天后系统清除）
remindkit move <id> --to 测试列表2   # ReminderKit move=复制+删除，ID 会变（响应给新 id）
remindkit recently-deleted     # 查询最近删除（remindkit 删的，仍可恢复的）
remindkit restore <id>         # 从最近删除恢复到原列表（ID 不变）

# 新建 / 修改 / 删除测试列表
remindkit add-list "测试列表2"
remindkit update-list "测试列表2" --new-name "测试列表3" --icon 🚀 --color red  # 12色板: red/orange/yellow/green/lightblue/blue/indigo/pink/purple/brown/gray/rose
remindkit delete-list "测试列表2" --yes   # 永久删除，必须 --yes 确认（不可撤销！）

# 层级写：分组（文件夹）→ 列表 → 分区 → 任务（苹果完整层级）
remindkit add-group "工作"                  # 创建分组（文件夹）
remindkit add-list "项目A" --group "工作"    # 在分组内建列表（--group-id 也可）
remindkit add-section "项目A" "待办"            # 给列表加分区
remindkit add "写周报" --list "项目A" --section "待办"   # 新建提醒时直接归入分区
remindkit update <id> --section "进行中"         # 把已有提醒移入另一分区（先 add-section 创建）
remindkit add-smartlist "重要" --color "#FF3B30" [--display-name "重要事项"]   # 智能列表（颜色/显示名）
remindkit move-list "项目A" --to-group "工作"      # 已有列表移入分组（--to-group-id 也可）
remindkit move-list "项目A" --out-of-group         # 移出分组到顶层（也可 --order N 调显示顺序）
# 分组也能删除：remindkit delete-list "工作" --yes（组内列表随之删除）
# 注意：苹果文件夹不支持嵌套（单层）；子任务只支持一层父子（苹果原生限制）
```

> 写响应含 `source`：`reminderKit`（主）或 `eventKit`（兜底，`degraded: true` 表示标签/紧急/子任务未写）。
> 写后可用查询命令验证（读走 ReminderKit 子进程）。
