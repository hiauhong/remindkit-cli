# remindkit — Apple Reminders 数据管道 CLI

[English](README.en.md)

remindkit 是一个 macOS 命令行工具，从 Apple Reminders（提醒事项）导出结构化数据。统一了公共 EventKit API 和私有 ReminderKit 框架的数据提取。

> **⚠️ 免责声明**
> - remindkit 通过**苹果私有框架** `ReminderKit.framework` 提取数据（dlopen + Objective-C 运行时消息，不含苹果代码/头文件）。私有 API **不受苹果支持，可能随 macOS 更新失效**，请自行评估风险。
> - 本项目与 Apple Inc. 无任何关联；「Apple」「Reminders」等商标归苹果所有。
> - 仅供个人使用与学习研究。

> **🔒 隐私**
> - 所有数据**仅在本机处理**：CLI 不发起任何网络请求，不上传提醒内容（账单/健康/位置等敏感信息始终留在本机）。
> - 需要授予「提醒事项」访问权限（TCC）；权限归属于宿主进程，详见 [docs/macos-permissions.md](docs/macos-permissions.md)。

## 背景

Apple Reminders 的标签、分区、图标、列表群组、智能列表等数据**无法**通过公共 EventKit API 获取，只能通过私有框架 `ReminderKit.framework` 访问。由于 EventKit 和 ReminderKit 存在 XPC 冲突（不能同进程共存），本工具采用独立子进程架构：

```
ReminderKit 子进程 (ObjC, dlopen 私有框架)  ─┐  ← 主数据源（完整字段）
                                              ├─ 统一 JSON 输出
EventKit 主进程 (Swift, 公共 API)       ──────┘  ← 兜底（子进程不可用时）
```

**数据源策略：ReminderKit 优先，EventKit 兜底。** 子进程使用私有框架直接输出全部字段（含子任务、标签、分区、图标、颜色、智能列表等），是完整数据源；当子进程缺失/失败时，自动降级到 EventKit 公共 API 输出基础数据（无富字段），并在 stderr 提示。每次导出的 `source` 字段标明实际数据源。

## EventKit 拿不到的数据（仅 ReminderKit 提供）

remindkit 通过私有框架额外提供以下 EventKit 公共 API 无法导出的字段：

| 能力 | 对应字段 | 说明 |
|------|----------|------|
| 标签 | `reminders[].tags` | 提醒的标签（如「购物」），EventKit 不暴露 |
| 分区 | `reminders[].section` / `calendars[].sections` | 列表内的分区结构（macOS 26+） |
| 子任务 | `reminders[].parentId` / `.subtaskIds` | 提醒的子任务树结构 |
| 旗标 | `reminders[].flagged` | 星标/旗标状态 |
| 紧急 | `reminders[].urgent` | 是否标记为紧急 |
| 图标 | `calendars[].icon` | 列表 emoji 图标（badgeEmblem） |
| 颜色 | `calendars[].color` | 列表十六进制颜色（REMColor） |
| 群组 | `calendars[].isGroup` / `.parentUUID` | 列表群组（文件夹）结构 |
| 排序 | `calendars[].order` / `reminders[].order` | 列表与提醒在 UI 中的顺序 |
| 智能列表 | `smartLists[]` | 智能列表定义及过滤条件；默认只含**自定义列表**（`type: custom`）；系统智能列表（今天/旗标/已完成/已分配）是虚拟视图（事项都引用自普通列表），**默认不输出**，`dump --system-smartlists` 才包含 |
| 全局排序 | `listIDsOrdering` | 侧边栏所有列表的全局顺序 |
| 提前提醒 | `reminders[].alarms` | 绝对时间/间隔/截止前/位置四种提醒触发 |
| 位置提醒 | `reminders[].alarms[].location` | 到达/离开某地时提醒（含经纬度）|
| URL | `reminders[].url` | 存为附件（REMURLAttachment）|
| 全天 | `reminders[].allDay` | 是否全天提醒 |
| 时区 | `reminders[].timeZone` | 提醒所属时区 |
## 安装

```bash
# Homebrew
brew install hiauhong/tap/remindkit

# 或从 GitHub Releases 下载
curl -L https://github.com/hiauhong/remindkit-cli/releases/latest/download/remindkit \
  -o /usr/local/bin/remindkit && chmod +x /usr/local/bin/remindkit

# 或使用安装脚本（本地构建或 GitHub Release）
./scripts/install.sh

# 装完后让 agent 学会用
remindkit install-skill
```

> 安装会带上三个部分：`remindkit` 主 CLI、`fetch-remindkit` 子进程二进制（必须与主 CLI 同目录）、`.agents/skills/remindkit/` skill 源。打包命令：`./scripts/package.sh`。

## 使用

```bash
# 导出全部数据（统一 JSON）
remindkit dump > reminders.json

# 列表备注（sidecar 元数据，苹果没有列表描述字段）
remindkit note --all                                # 全部备注（含分组/智能列表，带 isGroup/isSmartList 标识）
remindkit note --list 数码                          # 读某个列表备注
remindkit note --list 旗标 --set "当前焦点"          # 写备注；系统/自定义智能列表同样支持（按名或 UUID）
remindkit note --list <完整UUID> --clear            # 清除（重名必须用 UUID）
# 存储：~/.local/share/remindkit/notes.json（REMINDKIT_NOTES_FILE 可改路径，如放 iCloud Drive 同步）

# 按需查询（agent 友好；默认只查未完成，--completed 查已完成，--all 查全部）
remindkit today                      # 今日到期（未完成）
remindkit today --include-overdue    # 含过期未完成
remindkit overdue                    # 已过期（未完成）
remindkit search "牛奶"              # 按标题/备注搜索（默认未完成）
remindkit search "牛奶" --all        # 搜索全部（含已完成）
remindkit show --tag 购物            # 按标签过滤
remindkit show --due-before 2026-08-01 --due-after 2026-07-01
remindkit show --flagged --urgent --completed   # 已完成+已标旗+紧急
remindkit count --list 工作           # 列表统计（未完成/已完成显式标注）

# 所有查询命令支持 --format json|plain|count
remindkit today --format json
remindkit show --list 工作 --format count   # 某个列表的统计
remindkit count                             # 全局统计
remindkit count --list 工作

# 列表用途备注（sidecar）：列表/分组/智能列表均可读写
remindkit note --all                          # 全部备注
remindkit note --list 旗标 --set "当前焦点"    # 智能列表备注（按名或 UUID）
remindkit note --list <完整UUID> --clear      # 清除（重名必须用 UUID）

# 列表备注初始化：setup 交互式（真人终端），setup --accept 非交互（agent 用，仅填空缺不覆盖）
remindkit setup --status                      # 查配置状态
remindkit setup --accept                      # 非交互保存候选备注

# 权限诊断（agent 场景必用）
remindkit doctor                       # 权限/宿主/子进程状态
remindkit doctor --for-agent --json    # agent 宿主上下文 + JSON

# 让 AI agent 学会用 remindkit
remindkit install-skill                # 安装到 ~/.claude/skills + ~/.agents/skills
remindkit install-skill --force        # 覆盖已存在的 skill

# 查看子命令帮助
remindkit --help
remindkit dump --help
```

## 字段与列表支持矩阵

### 提醒字段（读写状态，均经实测验证）

| 字段 | 读（dump/查询） | 写（add） | 说明 |
|------|:---:|:---:|------|
| 名称 | ✅ | ✅ | |
| 备注 | ✅ | ✅ `--notes` | |
| URL | ✅ | ✅ `--url` | 存为附件（REMURLAttachment）|
| 日期 | ✅ | ✅ `--due YYYY-MM-DD` | 无时间 = 全天 |
| 时间 | ✅ | ✅ `--due YYYY-MM-DD HH:MM` | |
| 紧急 | ✅ | ✅ `--urgent` | |
| 重复规则 | ✅ | ✅ `--repeat/--every/--days/--until` + 复杂选项（见下）| 含结束日期；`daysOfTheMonth`/`setPositions`/`monthsOfTheYear`/`weekNumber` 均已验证 |
| 发信息时 | ❌ | ❌ | 暂不支持 |
| 提前提醒 | ✅ | ✅ `--alarm-at`（绝对时间）/ `--alarm-before N`（截止前 N 分钟）| 读支持 4 种触发（date/interval/dueDateDelta/location）|
| 所属列表 | ✅ | ✅ `--list` | |
| 标签 | ✅ | ✅ `--tag`（可重复）| |
| 旗标 | ✅ | ✅ `--flagged` | |
| 优先级 | ✅ | ✅ `--priority high\|medium\|low` | |
| 位置提醒 | ✅ | ✅ `--location <地名> --latitude X --longitude Y [--proximity arrive\|leave]` | 到达=1 / 离开=2 |
| 子任务 | ✅ | ✅ `--parent <id>` | 单层（Apple 限制，不可嵌套）|
| 发信息时 | ❌ | ❌ | 暂不支持 |
| 添加图像 | ❌ | ❌ | 暂不支持（读可识别附件类型）|

> `--alarm-before` 通过绝对时间提醒实现（due − N 分钟）；Reminders.app 的"提前提醒"读回可能是 `dueDateDelta` 类型（读取已支持）。写 `dueDateDelta` 会被 remindd 拒绝（私有框架限制），故用绝对时间替代，功能等价。

### 列表类型

| 类型 | 读取 | 创建 | 说明 |
|------|:---:|:---:|------|
| 普通列表 | ✅ | 增：✅ `add-list` / 改：✅ `update-list`（改名/图标/12 色板颜色）/ 删：✅ `delete-list` | |
| 智能列表 | ✅（`dump.smartLists`，默认只含自定义）| ❌ 创建；✅ `delete-list` 可删 | 虚拟视图；含 filterData；系统智能列表默认不输出，`dump --system-smartlists` 才包含 |
| 分组（文件夹）| ✅ | ❌ | `list --groups` |
| 日常采购（购物清单）| ✅（按普通列表读）| ❌ | Reminders.app 特殊列表类型（grocery 自动分类），暂不支持创建 |

### 写操作

写路径与读对称：**ReminderKit 私有框架写为主，EventKit 写兜底**。标签、紧急、旗标、子任务等 EventKit 写不了的字段，ReminderKit 写都能创建。所有写操作直接可用（无写保护）：

```bash
remindkit add "买牛奶" --list 测试列表 --due "2026-08-03 09:00" --priority high \
  --repeat weekly --days mon,wed --until 2026-12-31 --notes "备注" \
  --tag 购物 --tag 生活 --urgent --flagged --parent <父提醒ID> \
  --url "https://example.com" --alarm-before 30 \
  --location "深圳湾" --latitude 22.52 --longitude 113.94 [--proximity arrive|leave]
remindkit complete <id>            # 完成（--reopen 重开）；重复提醒完成后自动滚动到下一期，响应带 nextOccurrence/nextOccurrenceText
remindkit delete <id>              # 删除（软删除 → 最近删除）
remindkit move <id> --to 测试列表2
remindkit add-list "新列表"      # 新建列表
remindkit update-list "列表" --new-name "新名" --icon 🚀 --color red  # 改名/图标/颜色（12 色板）
# 同名列表（如两个「财务」）务必用 ID 定位：
remindkit add "买牛奶" --list-id <列表ID>        # add 目标列表
remindkit move <提醒ID> --to-id <目标列表ID>      # move 目标列表
remindkit update-list --id <列表ID> --color green  # update-list 按 ID
remindkit delete-list --id <列表ID>               # delete-list 按 ID
remindkit delete-list "测试列表2"   # 删除列表（普通/智能列表）
remindkit recently-deleted         # 查询最近删除（remindkit 删的，仍可恢复的）
remindkit restore <id>             # 从最近删除恢复到原列表（--list / --list-id 指定目标）
```

> `add` 参数：`--notes` / `--due`（`YYYY-MM-DD` 全天 | `YYYY-MM-DD HH:MM`）/ `--start` / `--priority high|medium|low` / `--repeat daily|weekly|monthly|yearly` / `--every N` / `--days mon,tue,…` / `--until` / `--tag`（可重复）/ `--urgent` / `--flagged` / `--parent <id>`（子任务）/ `--url` / `--alarm-at "YYYY-MM-DD HH:MM"`（可重复，绝对时间提醒）/ `--alarm-before N`（截止前 N 分钟）/ `--location <地名> --latitude X --longitude Y [--proximity arrive|leave]`（位置提醒）。
> 查询命令（`show` / `search` / `count`）的 `--list` 支持精确名/ID 匹配（`财务` 只匹配「财务」，不会误匹配「财务选题」）。
> 重复频率：`hourly`（每小时）/ `daily`（每天）/ `weekdays`（工作日）/ `weekends`（周末）/ `weekly`（每周，配 `--days` 选周几）/ `monthly`（每月）/ `yearly`（每年）。
> 复杂重复：`--repeat monthly --on-day 15`（每月 15 日）/ `--repeat monthly --last-workday`（每月最后一个工作日）/ `--repeat yearly --months 3,8 --on-weekday sun:1`（每年 3、8 月第一个周日，`sun:1`=第1个周日，`mon`=每周一）。
> 间隔与结束：`--every N`（如 `--repeat monthly --every 3` = 每 3 个月）/ `--until YYYY-MM-DD`。
> **`--repeat` 未给 `--due` 时，会自动计算"下一个符合规则的日期"作为首期到期日**（与 Reminders.app 一致——重复提醒必须锚定到期日才能正常显示）。
> 提前提醒通过绝对时间 alarm 实现（`--alarm-before` = due − N 分钟）；Reminders.app 的"提前提醒"读回可能是 `dueDateDelta` 类型（子进程已支持读取）。
> 写响应含 `source` 字段：`reminderKit`（主路径）或 `eventKit`（兜底，`degraded: true` 表示标签/紧急/子任务未写）。
> 注意：ReminderKit 的 `move` 是复制+删除，提醒 ID 会变化（响应返回新 `id` 与 `movedFromId`）。

### 删除与最近删除

`delete` 是**软删除**（与 Reminders.app 一致，进"最近删除"，30 天后由系统清除，可在 app 里手动恢复）。CLI 记录自己删除的提醒到 `~/.local/share/remindkit/deleted.json`，提供：

- `recently-deleted`：列出仍处于删除状态的提醒（每次查询会向 ReminderKit 验证状态，app 里手动恢复或清除的会自动过滤）
- `restore <id> [--list <目标列表>]`：恢复到原列表（默认）或指定列表，恢复后 ID 不变

> 局限：ReminderKit 无"枚举最近删除"API，只能记录 remindkit 自己删除的；在 Reminders.app 里删的提醒不在此列（app 里可查看）。

### 查询语义（统一约定）

所有查询命令（`today` / `overdue` / `search` / `show`）默认**只返回未完成**提醒；三个完成态开关三选一（`--completed` 与 `--all` 互斥）：

| 参数 | 行为 |
|------|------|
| （默认） | 只返回未完成 |
| `--completed` | 只返回已完成 |
| `--all` | 全部（未完成 + 已完成） |

`count` 不设这些开关——它始终同时显式标注 `incomplete` 与 `completed` 两个数：

```json
{"total": 12, "incomplete": 8, "completed": 4, "flagged": 1, "urgent": 0, "dueToday": 3, "overdue": 2}
```

### 错误契约

运行时错误（如权限被拒）输出到 **stderr** 的结构化 JSON（stdout 只承载数据），退出码 `1`；用法错误（参数缺失/互斥/日期非法）退出码 `64`：

```json
{"error": {"code": "accessDenied", "message": "Apple Reminders access denied (host: zsh). ..."}}
```

`doctor` 用非提示式 API 检查权限状态并报告**责任进程（宿主）**——TCC 授权属于宿主 App，不属于 remindkit 二进制。详见 `docs/macos-permissions.md`。

## 输出格式

```json
{
  "version": 1,
  "exportedAt": "2026-07-30T12:00:00Z",
  "source": "reminderKit",   // "reminderKit"（默认）| "eventKit"（兜底）

  "calendars": [
    {
      "id": "EKCalendar.calendarIdentifier",
      "title": "工作",
      "isGroup": false,
      "icon": "💼",
      "color": "#007aff",
      "sections": ["重要", "待办"],
      "parentUUID": null,
      "order": 0
    }
  ],

  "reminders": [
    {
      "id": "EKReminder.calendarItemIdentifier",
      "calendarId": "关联的 calendar.id",
      "title": "买牛奶",
      "notes": "",
      "completed": false,
      "priority": 0,
      "dueDate": null,
      "dueDateText": "2026-08-05 00:00",   // 本地时区可读日期（yyyy-MM-dd HH:mm），全天为 00:00
      "tags": ["购物"],
      "flagged": true,
      "urgent": false,
      "order": 0,
      "section": "待办",
      "parentId": null,
      "subtaskIds": []
    }
  ],

  "smartLists": [
    {
      "uuid": "REMCDSmartList.objectID UUID",
      "name": "旗标",
      "type": "com.apple.reminders.smartlist.flagged",  // custom=自定义；否则为系统类型全名
      "sortingStyle": "displayDate_asc",
      "filterData": "JSON 字符串",
      "icon": "📅",
      "color": null
    }
  ],

  "listIDsOrdering": ["uuid1", "uuid2"]
}
```

## 开发

```bash
# 编译 ObjC 子二进制
make build-cbinary

# 编译 Swift CLI
make build-cli

# 全部编译
make build
```

## 架构

```
Sources/
├── remindkit/               # Swift CLI 入口（主进程）
│   ├── main.swift           # ArgumentParser 入口
│   ├── DumpCommand.swift    # dump 子命令：子进程优先，EventKit 兜底
│   ├── Merging.swift        # 数据源选择与统一 Schema 映射
│   └── Models.swift         # 统一 JSON Schema 类型
└── CReminderKit/            # ObjC 源码（私有框架，独立编译）
    └── fetch-remindkit.m
```

## 许可证

MIT
