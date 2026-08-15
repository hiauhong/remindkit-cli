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

## 当前列表结构（新增/归属路由先看这里，不必再跑 list）

> **新增/移动/归属判断前，只跑一次 `remindkit list --brief`**（~4KB：分组层级 + 列表名 + 备注 + 分区名），输出即权威结构，直接据此选列表+分区。**不要**再逐个 query 候选列表的条目对比——note + 分区已足够决策。只有真模糊（两个列表都说得通）才允许查条目。

!`remindkit list --brief`

> 结构会随用户整理变化（增删列表/改备注/调分区），**每次需要时重新跑上面的命令**，不要依赖记忆或旧输出。

## 用户的使用约定（先读这里，再路由意图）

> **约定文件 `~/.local/share/remindkit/conventions.md`（可用 `REMINDKIT_CONVENTIONS_FILE` 重定向，如放 iCloud Drive 跨设备同步）是可选的跨列表方法论侧车**（如旗标含义、inbox 列表）。它**不由 setup 生成**：需要时由 agent 在对话中向用户收集后写入，或用户手动编辑；普通用户不配置也能正常使用。

> 每个列表的用途以 `note` 备注为准。**agent 用 `list --brief` 拿归属决策结构（分组+备注+分区名）；`list --format json` 拿全量结构（含 UUID/icon/color/order）**，用 `note --set` 非交互写入，流程见下方「列表用途标注」。
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
| 按标题/备注/标签搜索 | `remindkit search "<词>"` | 多关键词空格分隔、任一命中（OR）；`--match-all` 全部命中（AND）；加 `--list` 限定列表 |
| 标签视角（列出所有标签+计数） | `remindkit tags` | 默认未完成；`--all` 含已完成 |
| 某个列表的提醒 | `remindkit query --list <名称或ID>` | 加 `--tag` / `--flagged` / `--urgent` 组合过滤 |
| 到期日期区间 | `remindkit query --due-after 2026-08-01 --due-before 2026-09-01` | |
| 数量统计（全局/按列表） | `remindkit count [--list X]` | 省 token 首选 |
| 每个列表的统计表 | `remindkit count --by-list` | 一次拿到全部列表统计，勿循环 count |
| 有哪些列表/群组/分区 | `remindkit list` / `remindkit list --groups` / `remindkit list --brief`（紧凑结构，含分区名+备注） | |
| **新增提醒（先看结构再写）** | `remindkit list --brief` 定列表+分区 → `remindkit add "…" --list <标题或--list-id UUID> --section <分区>` | **add 响应自带 `listTitle`+`section` 回显，无需再验证 query**；重名列表用 `--list-id` 精确定位 |
| 全量导出 | `remindkit dump > reminders.json` | 数据量大，谨慎；`dump.smartLists` 默认只含自定义（`type: custom`）；系统智能列表（今天/旗标/已完成/已分配）是虚拟视图、事项都在普通列表里，默认不输出，`dump --system-smartlists` 才包含；「计划」无实体，用 `scheduled` 命令 |
| 调整列表内任务顺序 | `remindkit reorder <id> --before <同级ID>` / `--after` / `--first`（置顶） / `--last`（置底） | 相对移动，锚点须在同一列表；子任务不支持（v1） |
| 权限诊断 | `remindkit doctor --for-agent --json` | 报错时最先跑 |

## 数据结构：五层层级模型（先建心智模型，再动手）

Apple Reminders 是严格的层级结构。**分组/分区/备注是用户精心设计的信息架构（领域模型）——分析前先读结构，别把列表当平铺数组逐条硬判**：

```
分组（Group，文件夹）              add-group / list --groups
└─ 列表（List，含图标+备注 note）   list --format json（一次拿全：parentTitle 分组归属 + note + sections）
   └─ 分区（Section，列表内分类）    query --list X --tree（或 --sections）
      └─ 任务（Reminder）           query --list X [--tree] / --fields
         └─ 子任务（Subtask）       同一列表内，parentId 指向父任务；query 输出 subtaskIds
```

- **分区 = 分类框架**：分区名（如视频/小红书/图文/运营）本身就是"什么条目属于此列表"的定义——判断某条目是否属于该列表，先看它落在哪个分区，再用分区语义定标准。
- **列表备注 note = 领域模型**：`list --format json` 的 note 字段说明列表用途；分析前先读（`note --all` 也可）。
- **杂项/兜底分区是重灾区**：无归属的分区（如「运营」「其他」）最容易混入不属于该列表的条目——分析时优先检查它们。
- **智能列表（今天/旗标/已完成/已分配 + 自定义）是虚拟视图**：事项引用自普通列表，无层级结构。

**分析结构化清单的流程（硬纪律）**：
1. **先输出结构地图**：`list --format json`（全部列表+备注+分组）→ `query --list X --tree`（目标列表内部分区→任务→子任务树）
2. **判断标准从结构里长出来**：用分区/备注定义的框架判断归属，不用通用业务逻辑硬套
3. **平铺 JSON 只用于查证细节**：结构建立后，需要字段时才 `query --fields` 定向取（省 token）
4. **杂项分区优先检查**（见上）

## 统一语义

- 所有查询命令**默认只返回未完成**；`--completed` 只查已完成；`--all` 查全部（`--completed` 与 `--all` 互斥）。
- **JSON 日期字段**：`dueDate` 是 epoch（Double），同时输出 `dueDateText`（本地时区 `yyyy-MM-dd HH:mm`，全天提醒为 `00:00`）——判断今天/过期/几天内直接用 `dueDateText`，勿手转 epoch。
- **分区（section）字段**：查询命令**显式 `--list` 时自动带** `section`（列表结构查询的核心诉求，如「OKR 列表 → 健康/个人成长/财务…」）；无 `--list` 默认不带（性能，section 查询慢）。需要时 `--sections` 强制带 / `--no-sections` 强制跳过。
- **结构视图 `--tree`**：`query --list X --tree`（`--list-id` 也可）直接渲染「分区 → 任务 → 子任务」层级树（含父子缩进）——查列表内部结构用它，别从平铺 JSON 自己拼。**要求列表解析唯一**：同名/前缀命中多个会报 `ambiguousList`，用 `--list-id <完整UUID>` 精确定位。
- **输出格式自动切换**：终端（TTY）默认 `plain`，管道/agent 调用自动 `json`——agent 无需每次带 `--format json`；也可显式 `--format json|plain|count` 覆盖。
- `count` 无完成态开关，始终显式输出 `{total, incomplete, completed, flagged, urgent, dueToday, overdue}`（默认 json，`--format plain` 给人看）。`count --by-list` 输出 `{total, incomplete, lists:[{id,title,icon,isGroup,parentTitle,total,…}]}`。
- `--list` 解析：**读侧**（query/search/scheduled/count/bulk/smart）完整 UUID → UUID 前缀（≥8 位）→ 精确标题（大小写不敏感）→ 子串；重名**全部匹配合并输出 + stderr 警告**（避免误当单列表）；匹配不到报 `noSuchList`。**写侧**（add/update/move 等）完整 UUID → UUID 前缀（≥8 位）→ 精确标题，**不支持子串**（防误写）；重名报错并列出候选（**带分组归属**，如 `数码（理财消费）[UUID]`），提示用 `--list-id` 精确定位。`--list-id`（写侧 add/move 等 + 读侧 query）按 ID 精确定位，同名列表场景的首选。
- **提醒字段语义（查询输出 JSON）**：输出是「固定核心 + 稀疏可选」混合——**固定字段永远在**（即使 false/0/[]），**可选字段有值才出现**（nil 直接省略 key，不输出 null）：
  - 固定（10）：`id`(UUID) `calendarId`(所属列表 UUID) `title` `completed` `priority` `allDay` `flagged` `urgent` `order`(列表内排序值) `subtaskIds`(`[]`=无子任务)
  - 可选（有值才出现）：`notes` `creationDate` `completionDate` `dueDate`(epoch) `dueDateText`(本地时区 yyyy-MM-dd HH:mm) `startDate` `timeZone` `recurrenceRules`(JSON 字符串) `tags` `url` `alarms` `section`(分区名) `parentId`(存在=是子任务，值=父提醒 UUID)
  - **`priority` 值域**：`0`=无，`1`=低，`5`=中，`9`=高（写端 `--priority high|medium|low|none` 对应 9/5/1/0，也接受 0-9）
  - **`alarms` 结构**：`[{type: date|interval|dueDateDelta|location, date?, interval?, delta?, proximity?(1=进入/2=离开), location?{title, latitude, longitude}}]`
  - **`recurrenceRules`**：JSON 字符串（frequency/interval/daysOfWeek 等）；读时勿当普通字符串拼接，简单判断可用，复杂场景用 `update --repeat`/`add --repeat` 重新生成

## Token 效率守则

- **优先 `count` / `search` / `today` 等定向查询**，全量 `dump` 一条提醒约 100~200 token，1000 条可达 10万+ token。
- **`--fields id,title,dueDate,…` 投影**：query/today/overdue/scheduled/search/flagged/urgent/dump 都支持只输出需要的字段（逗号分隔；不存在的字段忽略；dump 时只投影 reminders，calendars/smartLists 保留）。支持 `listTitle`/`list`（列表名投影，自动从日历表解析，省去本地 join）；`notes` 也在内。只要几个字段时务必用它，可省 80%+ token。
- 一次会话需要多个独立查询时，用 `;` 在**同一个 Bash 调用**里串起来，别拆成多次调用。
- 只要统计就 `count`，不要 `dump | jq length`。

## 错误与权限

- 运行时错误（如权限被拒、找不到列表/提醒）输出到 **stderr** 的 JSON：`{"error":{"code":"…","message":"…"}}`，退出码 1；**用法错误（缺参数/互斥/格式错）是普通文本 + usage，退出码 64（非 JSON）**——agent 按退出码区分，别假设 stderr 永远可 `jq` 解析。**读侧与写侧同契约**。
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
remindkit query --completed --completed-after 2026-08-01 --fields id,title,completionDate \
  # 按完成日期过滤（月度/周报回顾）：--completed-after / --completed-before（YYYY-MM-DD [HH:MM]）
remindkit query --list <列表> --fields id,title,listTitle   # 列表归属投影，无需本地 join
remindkit dump --fields id,title,dueDate,completed > slim.json  # dump 也只投影 reminders
remindkit query --due-before 2026-08-01 --all --format json
remindkit count --list 工作
remindkit count --by-list                       # 每个列表的统计表
remindkit count --list 18713533                # UUID 前缀也能匹配
remindkit list --groups --format json

# 列表备注（sidecar 元数据，苹果没有列表描述字段）
remindkit note --all                              # 查看所有列表备注（含分组和智能列表）
remindkit note --list 购物                        # 读取某个列表备注
remindkit note --list <完整UUID> --set "购物清单"   # 设置（重名必须用 UUID）
remindkit note --list <完整UUID> --clear          # 清除
remindkit note --list 焦点 --set "重要事项"         # 智能列表也可读写备注（按名/UUID）
remindkit note --list <UUID前缀> --set "..."      # 智能列表 UUID 前缀
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
remindkit note --list <完整UUID> --set "每月账单缴费提醒"
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

> **只读保护**：环境变量 `REMINDKIT_READ_ONLY=1` 时所有写命令（add/update/complete/delete/move/reorder/bulk/add-list/add-group/add-section/add-smartlist/delete-list/update-list/restore）拒绝执行，报 `{"error":{"code":"readOnly"}}`——agent 在只读场景（如纯查询会话）可设置它防误写。
> **测试纪律（硬规则）**：写操作测试只能在**新建**的「测试冒烟*」列表/分组上做，自建自删（`make test` 的冒烟脚本会自建并自动删除，最后校验零残留）。**绝不直接对真实列表执行写测试**。
> **同名列表**：按名字操作遇到重名（如两个「工作」）会报歧义错误并列出候选 ID——此时必须改用 `--id`/`--list-id`/`--to-id` 精确定位。

```bash
# 新建提醒（写走 ReminderKit 私有框架，EventKit 兜底；输出 JSON 含 source + listTitle/section 回显，无需再验证）
remindkit add "买牛奶" --list 测试列表 --due "2026-08-03 09:00" --priority high \
  --repeat weekly --days mon,wed --until 2026-12-31 --notes "备注" \
  --tag 购物 --tag 生活 --urgent --flagged --parent <父提醒ID> \
  --url "https://example.com" --alarm-before 30 \
  --location "<地点>" --latitude <纬度> --longitude <经度>

# 常用参数：--notes / --due (YYYY-MM-DD 全天 | YYYY-MM-DD HH:MM) / --start / --priority high|medium|low \
#   --repeat hourly|daily|weekdays|weekends|weekly|monthly|yearly / --every N / --days mon,tue,... / --until YYYY-MM-DD \
#   --tag (可重复) / --urgent / --flagged / --parent <id>（子任务）/ --section <分区名>（归入已有分区，先 add-section）\
#   --url / --alarm-at "YYYY-MM-DD HH:MM"（绝对时间提醒，可重复）/ --alarm-before N（截止前 N 分钟）\
#   --location <地名> --latitude X --longitude Y [--proximity arrive|leave]（位置提醒）\
#   复杂重复：--repeat monthly --on-day 15 / --repeat monthly --last-workday \
#     --repeat yearly --months 3,8 --on-weekday sun:1（每年3、8月第一个周日）\
#   注意：--repeat 未给 --due 时自动算下一个符合规则的日期作为到期日

# 批量操作（先条件选择，再统一执行）
remindkit bulk --op complete --list 待办 --due-before 2026-08-02   # 完成待办里过期的
remindkit bulk --op delete --list 测试列表 --all --dry-run         # 先预览再删
remindkit bulk --op delete --list 测试列表 --all --yes             # 预览确认后批量删除（--yes 必需）
remindkit bulk --op move --list 收集箱 --to 目的地 --yes             # 收集箱的移到目的地（--yes 必需）
remindkit bulk --op update --list 购物 --flag                       # 批量加旗标
remindkit bulk --op update --list 收集箱 --notes-append "统一标注"   # 批量备注追加（40+ 次循环的替代）
remindkit bulk --op update --list 收集箱 --notes "覆盖全部备注"       # 批量覆盖备注
# 选择器：--list/--tag/--flagged/--urgent/--due-after/--due-before（至少一个）
# 安全：--dry-run 预览；--limit N 上限（默认 50，超出拒绝）；delete/move 是破坏性写，必须 --yes
#       update 至少带一个更新字段（--flag/--no-flag/--urgent/--no-urgent/--notes/--notes-append）

# 完成 / 重开 / 删除 / 移动 / 旗标紧急
remindkit complete <id>          # 完成；重复提醒完成后自动滚动到下一期，响应带 nextOccurrence/nextOccurrenceText
remindkit complete <id> --reopen  # 重开
remindkit update <id> --flag          # 给已有提醒加旗标（--flag/--flagged 互为别名）
remindkit update <id> --notes-append "补充信息"   # 备注追加（省一次读+拼接）
remindkit update <id> --no-flag --urgent   # 去旗标 + 标紧急（可组合）
remindkit update <id> --title "新标题" --due "2026-08-15 15:30" --notes "备注" \\
  --priority high --tag 购物 --url "https://…" --repeat weekly --days mon,wed --until 2026-09-01
  # 更新字段：--title/--notes/--due/--start/--priority/--tag(可重复)/--url/--repeat/--days/--until/--section(移入分区)
  # 提醒：--alarm-at "YYYY-MM-DD HH:MM"(可重复)/--alarm-before N(--due 或当前 dueDate 为基准)/--location+经纬度
  # 至少指定一个字段或旗标；EventKit 兜底时 tags/repeat/flag/urgent/section/url/alarm/location 标记 degraded
remindkit update <id> --parent <父提醒ID>   # 把普通任务挂为父任务的子任务（父须同列表、本身非子任务、无孙任务）
remindkit update <id> --no-parent           # 解除父子关系（子任务变回普通任务，留在原列表）
remindkit delete <id>          # 软删除 → 最近删除（30 天后系统清除）；无 EventKit 兜底（需 ReminderKit 子进程，避免硬删）
remindkit move <id> --to 测试列表2   # 真移动：ID 保留、子树完整迁移（不复制不删、不进最近删除）
remindkit reorder <id> --first          # 移到列表顶部
remindkit reorder <id> --last           # 移到列表底部
remindkit reorder <id> --before <同级提醒ID>   # 移到某提醒前面（锚点须同一列表）
remindkit reorder <id> --after <同级提醒ID>    # 移到某提醒后面（锚点须同一列表）
remindkit recently-deleted     # 查询最近删除（remindkit 删的，仍可恢复的）
remindkit restore <id>         # 从最近删除恢复到原列表（ID 不变）

# 新建 / 修改 / 删除列表族（列表 / 分组 / 智能列表）
remindkit add-list "测试列表2"
remindkit update-list "测试列表2" --new-name "测试列表3" --icon 🚀 --color red  # 12色板: red/orange/yellow/green/lightblue/blue/indigo/pink/purple/brown/gray/rose
# update-list 统一派发列表族（#15）：列表/分组/智能列表同名同名冲突时报错列候选（带 list/smartList/group 类型标注），用 --id 或 --type 精确
remindkit update-list 理财消费 --new-name 收入支出            # 分组改名（文件夹）
remindkit update-list "重要" --new-name "重要事项" --type smartlist  # 智能列表改名（--type 逃生门，脚本场景）
remindkit update-list B1D35ED8 --new-name "数码购物"          # UUID 前缀定位（位置参数也按 ID 匹配）
# 分组/智能列表仅支持 --new-name（无 icon/color，传入报错）；响应带 type 字段（list/smartList/group）
remindkit delete-list "测试列表2" --yes   # 永久删除，必须 --yes 确认（不可撤销！）；列表/分组/智能列表通用

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

> 写响应含 `source`：`reminderKit`（主）或 `eventKit`（兜底，`degraded: true` 表示标签/紧急/子任务/url/提醒/位置等字段未写）。
> 写前子进程超时/无输出会报 `writeResultUnknown`（结果未知，不盲目走兜底，避免重复写入）。
> 写后可用查询命令验证（读走 ReminderKit 子进程）。
