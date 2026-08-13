# remindkit — Apple Reminders 数据管道 CLI

[![Vibe coded](https://img.shields.io/badge/vibe-coded-%23ff69b4?style=flat-square)](https://en.wikipedia.org/wiki/Vibe_coding)

[English](README.en.md)

remindkit 是一个 macOS 命令行工具，从 Apple Reminders（提醒事项）导出结构化数据，并支持**全层级读写**——从**列表文件夹 → 列表 → 分区 → 任务 → 子任务**，五层一路打通。**面向 AI agent 设计**：统一 JSON 输出、机器可解析的错误契约、内置 agent skill。


> 🎨 本项目由 **vibe coding**(AI 辅助开发)驱动——功能、测试与文档均在 AI agent 协作下迭代产出。

> **⚠️ 免责声明** — 通过苹果**私有框架** `ReminderKit.framework` 提取数据,不受苹果支持,可能随 macOS 更新失效;与 Apple Inc. 无任何关联,仅供个人使用与学习研究。

> **🔒 隐私**
> - 所有数据**仅在本机处理**：CLI 不发起任何网络请求，不上传提醒内容（账单/健康/位置等敏感信息始终留在本机）。
> - 需要授予「提醒事项」访问权限（TCC）；首次运行按系统提示授权即可，权限归属于宿主进程。

## 完整层级：列表文件夹 → 列表 → 分区 → 任务 → 子任务

Apple Reminders 的五级数据层级，remindkit **读、写全部支持**——这正是公共 EventKit API 做不到的部分：

```
列表文件夹（分组 / group）                  ← add-group
 └── 列表（list / calendar）                ← add-list --group
      ├── 分区（section，macOS 26+）        ← add-section
      └── 任务（task / reminder）           ← add --list / --section
           └── 子任务（subtask，仅一层，苹果原生限制）← add --parent <id> / update --parent <id>
```

- **读**：`dump` / `list --groups` / `list --format json` 全量输出层级关系，字段一一对应：`isGroup` / `parentUUID`（文件夹）、`sections`（分区）、`parentId` / `subtaskIds`（子任务树）
- **写**：从顶层一路建到叶子——`add-group` → `add-list --group` → `add-section` → `add --section` → `add --parent`；`move` 可在任意层级间调整归属；`update --parent/--no-parent` 把已有任务挂为/解除子任务

## 特性

- **结构化 JSON 导出**：列表、分组（文件夹）、分区、子任务、标签、旗标、紧急、智能列表——含公共 EventKit API **拿不到**的字段（见下文矩阵）
- **完整写路径**：列表文件夹 → 列表 → 分区 → 任务 → 子任务，五级全覆盖（增/改/完成/删除/移动），另含智能列表
- **双源架构**：ReminderKit 私有框架为主数据源，EventKit 公共 API 兜底，每次导出带 `source` 标注
- **agent 优先**：默认 JSON 输出、统一错误契约（stderr JSON + 退出码）、`--fields` 投影省 token、内置 skill 一键安装


## 安装

```bash
brew install hiauhong/tap/remindkit
# 每次运行自动同步 agent skill（含更新；终端可见提示；REMINDKIT_NO_AUTO_SKILL=1 关闭）；Claude Code 用户补：remindkit install-skill --claude
# 或
./Scripts/install.sh     # 装完自动注册 agent skill
```

## 首次使用:授权 + 备份

```bash
remindkit doctor                        # ① 检查权限(首次会弹授权框,点「允许」)
remindkit dump > ~/reminders-backup.json   # ② 先做全量基线备份
```

> 权限归属于宿主进程(终端/agent 宿主);之后进行写操作(完成/删除/移动/批量)前,可随时再 dump 对照,心里有底。

## 快速开始

```bash
remindkit                # 概览:今天/过期/未来/旗标/紧急
remindkit today          # 今日到期
remindkit overdue        # 已过期
remindkit search "牛奶"   # 搜索
remindkit search "牛奶 面包"   # 多关键词：任一命中（OR）；加 --match-all 全部命中（AND）
remindkit add "买牛奶" --list 待办 --due "2026-08-03 09:00"
remindkit complete <id>  # 完成
```

## 面向 AI agent

- 查询默认只返回**未完成**;`--all` / `--completed` 切换
- 默认 JSON 输出;错误为 stderr JSON `{"error":{...}}` + 退出码(1 运行时 / 64 用法)
- 完整层级写:列表文件夹→列表→分区→任务→子任务;含标签/旗标/紧急/智能列表/批量
- 内置 skill：`remindkit install-skill` 手动注册；**每次运行自动同步 `~/.agents/skills/` 副本**（缺失安装、内容不一致更新，agent 新会话生效）
- 全部命令与参数见 `remindkit <命令> --help`;agent 细则见 [.agents/skills/remindkit/SKILL.md](.agents/skills/remindkit/SKILL.md)
- 支持边界逐项评估(✅ 完整 / 🟡 受限 / ❌ 不支持,如日常采购列表、模板、图片附件等)见 [docs/apple-reminders-support.md](docs/apple-reminders-support.md)

## 安全约定

| 能力 | 字段 | 说明 |
|------|------|------|
| 标签 | `reminders[].tags` | EventKit 不暴露 |
| 分区 | `reminders[].section` / `calendars[].sections` | macOS 26+ |
| 子任务 | `reminders[].parentId` / `.subtaskIds` | 子任务树 |
| 旗标 / 紧急 | `flagged` / `urgent` | |
| 图标 / 颜色 | `calendars[].icon` / `.color` | 列表 emoji 与十六进制色 |
| 群组 | `calendars[].isGroup` / `.parentUUID` | 文件夹结构 |
| 智能列表 | `smartLists[]` | 系统（今天/旗标/已完成/已分配）与自定义；系统为虚拟视图默认不输出 |
| 提前/位置提醒 | `reminders[].alarms` | 四种触发（date/interval/dueDateDelta/location） |
| 全局排序 | `listIDsOrdering` | 侧边栏顺序 |

## 写操作

```bash
# 任务：增/改/完成/删/移（ReminderKit 私有框架写为主，EventKit 兜底）
remindkit add "买牛奶" --list 日常 --due "2026-08-03 09:00" --priority high \
  --repeat weekly --days mon,wed --tag 购物 --urgent --flagged \
  --notes "备注" --url "https://…" --alarm-before 30
remindkit update <id> --title "新标题" --due "2026-08-15 15:30" --priority medium --tag 生活
remindkit complete <id>          # 重复提醒完成后自动滚动到下一期，响应带 nextOccurrence
remindkit delete <id>            # 软删除 → 最近删除（30 天系统清除）
remindkit move <id> --to 日常

# 层级：列表文件夹 → 列表 → 分区 → 任务 → 子任务
remindkit add-group "工作"                              # ① 列表文件夹（分组）
remindkit add-list "项目A" --group "工作"                # ② 列表
remindkit add-section "项目A" "待办"                     # ③ 分区
remindkit add "写周报" --list "项目A" --section "待办"    # ④ 任务
remindkit add "整理大纲" --list "项目A" --parent <写周报的ID>   # ⑤ 子任务（可继续嵌套）

# 批量
remindkit bulk --op complete --list 日常 --due-before 2026-08-02   # 先 --dry-run 预览
```

> **安全约定**：同名列表（如两个「数码」「财务」）务必用 ID 定位；`delete-list` 永久删除需 `--yes`；测试写操作只在「测试冒烟*」列表上进行（自建自删、零残留）。

## 输出格式

统一 JSON Schema（`dump` 全量导出）：

```json
{
  "version": 1,
  "source": "reminderKit",        // reminderKit | eventKit
  "calendars": [{ "id": "…", "title": "工作", "isGroup": false, "icon": "💼",
                  "color": "#007aff", "sections": ["重要"], "parentUUID": null, "order": 0 }],
  "reminders": [{ "id": "…", "calendarId": "…", "title": "买牛奶", "completed": false,
                  "priority": 0, "dueDate": 1785859200, "dueDateText": "2026-08-05 00:00",
                  "tags": ["购物"], "flagged": true, "urgent": false,
                  "section": "待办", "parentId": null, "subtaskIds": [] }],
  "smartLists": [{ "uuid": "…", "name": "想买", "type": "custom", "filterData": "…" }],
  "listIDsOrdering": ["uuid1", "uuid2"]
}
```


## 开发

```bash
make build    # 编译(ObjC 子二进制 + Swift CLI)
make test     # 冒烟测试 + skill 契约测试
```

## License

MIT(含私有框架免责声明,见 [LICENSE](LICENSE))
