# remindkit × Apple Reminders 支持度评估

> 评估 remindkit 对苹果「提醒事项」功能的支持程度。状态标注：
> ✅ 完整支持 ｜ 🟡 部分/受限 ｜ ❌ 暂不支持
>
> 最后更新：2026-08-02（对应 commit `bee1878` 之后的层级写支持）

## 一、列表层

| 苹果功能 | 状态 | 说明 |
|---------|------|------|
| 普通列表 | ✅ | 读（`list`）、建（`add-list`）、改名/图标/颜色（`update-list`）、删（`delete-list --yes`） |
| 列表图标（emoji） | ✅ | 读取 + `update-list --icon` |
| 列表颜色 | ✅ | 读取 + `update-list --color`（12 色板） |
| 分组（智能文件夹） | ✅ | **读**完整（`list --groups`、parentUUID 归属）；**写**：`add-group` 建、`add-list --group` 放入、`delete-list` 删（探索确认：分组=REMAccountGroupContext，无 REMGroup 类；苹果文件夹不支持嵌套，单层） |
| 智能列表 | ✅ | **读**（smartLists 字段）；**写**：`add-smartlist [--color]`；删除可用 `delete-list` |
| 列表分区（sections） | ✅ | **读**（`[N sections]`）；**写**：`add-section <list> <name>` 建分区；`add --section` / `update --section` 把提醒归入分区（REMMembership 路径） |
| 列表排序 | 🟡 | 读取保持 display order；**写排序不支持** |

## 二、提醒字段层

| 字段 | 状态 | 说明 |
|------|------|------|
| 标题 / 备注 | ✅ | 读写（`add`/`update --title/--notes`） |
| 到期日期（due） | ✅ | `--due "YYYY-MM-DD"`（全天）或 `"YYYY-MM-DD HH:MM"` |
| 开始日期（start） | ✅ | `--start` |
| 全天（all-day） | 🟡 | 读完整；写靠日期格式推断（不带时间=全天） |
| 时区 | 🟡 | 读完整；**写不支持**（尝试设置会触发 remindd 崩溃——私有框架坑，已探索确认） |
| 重复规则 | ✅ | `--repeat daily/weekly/monthly/yearly` + `--every/--days/--until`；复杂规则：`--on-day`、`--last-workday`、`--months + --on-weekday`（年/月首周） |
| 标签 | ✅ | 读写（`--tag` 可重复）；`tags` 命令统计、`search` 可搜标签 |
| 优先级 | ✅ | `--priority high/medium/low`（映射 9/5/0） |
| 旗标（已标记） | ✅ | 读写（`update --flag/--no-flag`）；`flagged` 命令一级入口 |
| 紧急 | ✅ | 读写（`update --urgent/--no-urgent`）；`urgent` 命令一级入口 |
| URL | ✅ | 读写（URL 附件形式） |
| 提醒（alarm）— 绝对时间 | ✅ | `--alarm-at "YYYY-MM-DD HH:MM"`（可重复） |
| 提醒 — 截止前 N 分钟 | ✅ | `--alarm-before N`（基于 due 或当前 dueDate） |
| 提醒 — 位置触发 | ✅ | `--location + --latitude/--longitude [--proximity arrive/leave]` |
| 子任务 | 🟡 | 读完整（parentId/subtaskIds）；写 `add --parent`；**嵌套是苹果原生不支持**（会报 `Nested subtasks is unsupported`，仅一层父→子） |
| 完成态 | ✅ | `complete <id>` / `complete <id> --reopen` |
| 顺序（order） | 🟡 | 读完整；**写不支持** |
| 图片附件 | ❌ | 暂不支持（需求评估过：低频） |
| 发信息时提醒 | ❌ | 暂不支持（低频） |

## 三、操作层

| 操作 | 状态 | 说明 |
|------|------|------|
| 新建 / 编辑 | ✅ | `add` 全字段；`update` 字段 + 旗标/紧急 + 提醒 |
| 完成 / 重开 | ✅ | `complete [--reopen]` |
| 删除 | ✅ | 软删除 → 最近删除（30 天后系统清除） |
| 最近删除查询 | 🟡 | `recently-deleted` 仅能列出 **remindkit 删的**（本地缓存）；App 里删的不可见 |
| 恢复 | 🟡 | `restore` 同上，仅 remindkit 删的 |
| 移动 | 🟡 | `move` = ReminderKit 复制+删除，**ID 会变**（响应给新 id） |
| 批量 | ✅ | `bulk --op complete/delete/move/update` + 条件选择 + `--dry-run` + `--limit` |

## 四、视图层（对齐 App 一级入口）

| 苹果入口 | 命令 | 说明 |
|---------|------|------|
| 今日 | `today` | `--include-overdue` 含过期 |
| 计划 | `scheduled` | `--within N` / `--from/--to` 区间 |
| 已标记 | `flagged` | 未完成旗标（你的"当前焦点"） |
| 紧急 | `urgent` | 未完成紧急 |
| 全部 | `dump` / `query --all` | dump 全量导出 JSON |
| 已完成 | `query --completed` | 各查询命令统一支持 |
| 概览（本工具特色） | `overview` | 今日/过期/未来/旗标/紧急一站式摘要，默认命令 |

## 五、系统/扩展层

| 能力 | 状态 | 说明 |
|------|------|------|
| 权限诊断 | ✅ | `doctor`（access 状态 + 修复指引） |
| 只读保护 | ✅ | `REMINDKIT_READ_ONLY=1` 拒绝全部写操作 |
| 数据导出 | ✅ | `dump`（unified JSON，含全部字段） |
| 用户画像（本工具特色） | ✅ | `setup`（仅结构）/ `setup --deep`（含内容）逐列表备注 + 可选 `conventions.md` 侧车 |
| 标签视角 | ✅ | `tags` 命令（标签+计数） |
| 全库搜索 | ✅ | `search` 标题/备注/标签 |
| 模糊列表解析 | ✅ | UUID 前缀/精确标题/子串 + `noSuchList` 报错 |
| 输出格式 | ✅ | 按 TTY 自动 json/plain；`count --format plain` |
| 测试纪律 | ✅ | 冒烟测试仅碰自建的「测试冒烟*」列表/分组/智能列表（自建自删 + 零残留校验），绝不写真实列表 |
| 跨设备同步 | — | 数据在 iCloud 天然同步；本工具只读本机 |
| 协作/共享列表 | ❌ | 不支持 |
| 模板（iOS 17+） | ❌ | 不支持 |

## 六、已知局限（按影响排序）

1. **最近删除恢复不完整**：只能恢复 remindkit 删的（本地 `deleted.json` 缓存）；App 里删的无法恢复。ReminderKit 无法枚举 marked-for-delete 对象所致。
2. **EventKit 兜底降级**：子进程不可用时，tags/重复/旗标/紧急/分区/分组/智能列表不可写（响应标记 `degraded: true`）。
3. **move ID 变化**：复制+删除实现，移动后引用需用返回的新 id。
4. **子任务嵌套**：一层父子可用；更深嵌套未验证/不支持。
5. **写端缺**：时区（触发 remindd 崩溃）、顺序、图片、消息提醒、模板、协作。
6. **子任务嵌套**：苹果框架原生报 `Nested subtasks is unsupported`，仅支持一层。

## 七、结论

**读端 ≈ 100%**：苹果提醒事项的字段几乎全部可读（含子任务、位置、重复、时区、智能列表）。

**写端覆盖全层级**：文件夹（`add-group`）→ 列表（`add-list [--group]`）→ 分区（`add-section` + `add/update --section`）→ 任务（`add`/`update`/`complete`）→ 子任务（`add --parent`）的完整层级写链路均已打通；日常使用（增删改查、完成、移动、批量、标签、旗标、紧急、提醒、位置、重复、智能列表创建）完整；缺口集中在低频/系统级功能（图片、模板、协作）和两个工程限制（最近删除、move ID）。
