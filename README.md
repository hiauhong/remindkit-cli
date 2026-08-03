# remindkit — Apple Reminders 数据管道 CLI

[![Vibe coded](https://img.shields.io/badge/vibe-coded-%23ff69b4?style=flat-square)](https://en.wikipedia.org/wiki/Vibe_coding)

[English](README.en.md)

remindkit 是一个 macOS 命令行工具，从 Apple Reminders（提醒事项）导出结构化数据，并支持完整的层级写操作（列表 / 分组 / 分区 / 任务 / 子任务）。**面向 AI agent 设计**：统一 JSON 输出、机器可解析的错误契约、内置 agent skill。

> 🎨 本项目由 **vibe coding**（AI 辅助开发）驱动——功能、测试与文档均在 AI agent 协作下迭代产出。

> **⚠️ 免责声明**
> - remindkit 通过**苹果私有框架** `ReminderKit.framework` 提取数据（dlopen + Objective-C 运行时消息，不含苹果代码/头文件）。私有 API **不受苹果支持，可能随 macOS 更新失效**，请自行评估风险。
> - 本项目与 Apple Inc. 无任何关联；「Apple」「Reminders」等商标归苹果所有。
> - 仅供个人使用与学习研究。

> **🔒 隐私**
> - 所有数据**仅在本机处理**：CLI 不发起任何网络请求，不上传提醒内容（账单/健康/位置等敏感信息始终留在本机）。
> - 需要授予「提醒事项」访问权限（TCC）；首次运行按系统提示授权即可，权限归属于宿主进程。

## 特性

- **结构化 JSON 导出**：列表、分组（文件夹）、分区、子任务、标签、旗标、紧急、智能列表——含公共 EventKit API **拿不到**的字段（见下文矩阵）
- **完整写路径**：任务（增/改/完成/删除/移动）、列表、分组、分区、智能列表
- **双源架构**：ReminderKit 私有框架为主数据源，EventKit 公共 API 兜底，每次导出带 `source` 标注
- **agent 优先**：默认 JSON 输出、统一错误契约（stderr JSON + 退出码）、`--fields` 投影省 token、内置 skill 一键安装

## 安装

```bash
# Homebrew（目前发布 Apple Silicon / arm64）
brew install hiauhong/tap/remindkit

# 或从 GitHub Releases 下载（arm64）
curl -L https://github.com/hiauhong/remindkit-cli/releases/latest/download/remindkit \
  -o /usr/local/bin/remindkit && chmod +x /usr/local/bin/remindkit

# 或使用安装脚本
./scripts/install.sh

# 装完让 AI agent 学会用
remindkit install-skill
```

> Intel（x86_64）用户暂请从源码构建（`make build`）；arm64 二进制已通过 Homebrew 与 GitHub Releases 发布。

> 安装包含三个部分：`remindkit` 主 CLI、`fetch-remindkit` 子进程二进制（必须与主 CLI 同目录）、`.agents/skills/remindkit/` skill 源。

## 首次运行：授权

remindkit 需要「提醒事项」访问权限（TCC）。首次运行会弹出系统授权框，点击「允许」即可：

```bash
remindkit doctor        # 先检查权限状态（未授权时按提示操作）
remindkit               # 或直接跑任意命令，首次会触发授权弹窗
```

> 权限归属于**宿主进程**（终端 App 或 agent 宿主），不是 remindkit 二进制本身。在 agent 环境里授权失败时，用 `remindkit doctor --for-agent --json` 看责任进程并给它授权。

## 快速开始

```bash
remindkit                  # 概览：今天/过期/未来/旗标/紧急（默认命令）
remindkit today            # 今日到期
remindkit overdue          # 已过期
remindkit search "牛奶"     # 搜索
remindkit complete <id>    # 完成
remindkit count            # 统计
```

所有查询命令默认**只返回未完成**；`--completed` 只查已完成，`--all` 查全部。输出格式按终端自动切换（终端 plain / 管道 json），也可 `--format json|plain|count` 显式指定。

## 常用命令

| 用途 | 命令 |
|---|---|
| 概览（agent 默认入口） | `remindkit overview [--within N]` |
| 今日 / 过期 / 计划 / 旗标 / 紧急 | `today` `overdue` `scheduled` `flagged` `urgent` |
| 搜索 / 过滤 / 统计 | `search "<词>"` `query --list X --tag Y` `count [--by-list]` |
| 列表结构（含分组/分区/备注） | `list --format json` `list --groups` |
| 标签视角 | `tags` |
| 全量导出 | `dump > reminders.json`（数据量大，配合 `--fields` 投影） |
| 完成 / 重开 / 删除 / 移动 | `complete <id>` `delete <id>` `move <id> --to 列表` |
| 列表备注（列表/分组/智能列表） | `note --all` `note --list 旗标 --set "当前焦点"` |
| 备注初始化（agent 非交互） | `setup --accept` / `setup --status` |
| 权限诊断 | `doctor --for-agent --json` |

> 完整参数见 `remindkit <命令> --help`；agent 使用细节见 [.agents/skills/remindkit/SKILL.md](.agents/skills/remindkit/SKILL.md)。

## 面向 AI agent

- **默认入口 `overview`**：一次拿到 今天/过期/未来 7 天/旗标焦点/紧急 摘要，无需全量导出
- **JSON 日期字段**：`dueDate` 为 epoch，同时输出 `dueDateText`（本地时区 `yyyy-MM-dd HH:mm`）
- **错误契约**：运行时错误输出 stderr JSON `{"error":{"code":"…","message":"…"}}`，退出码 1；用法错误退出码 64
- **列表备注**：每个列表/分组/智能列表可用 `note` 记录用途描述（苹果无描述字段），agent 查询前用它理解列表语义；`setup --accept` 非交互生成候选
- **skill**：`remindkit install-skill` 安装到 `~/.claude/skills` + `~/.agents/skills`，agent 自动发现

## EventKit 拿不到的数据（仅 ReminderKit 提供）

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

# 层级：分组 → 列表 → 分区 → 任务
remindkit add-group "工作"
remindkit add-list "项目A" --group "工作"
remindkit add-section "项目A" "待办"
remindkit add "写周报" --list "项目A" --section "待办"

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
make build         # 全部编译（ObjC 子二进制 + Swift CLI）
make test          # 冒烟测试（真实权限，本地跑）+ skill 契约测试
./scripts/package.sh   # 打包发布 tarball
```

- 架构说明见下文
- **测试纪律**：任何写操作测试只能在新建的「测试冒烟*」列表/分组上进行，自建自删，结束时零残留

## 架构

```
ReminderKit 子进程 (ObjC, dlopen 私有框架)  ─┐  ← 主数据源（完整字段）
                                              ├─ 统一 JSON 输出
EventKit 主进程 (Swift, 公共 API)       ──────┘  ← 兜底（子进程不可用时）
```

EventKit 与 ReminderKit 存在 XPC 冲突（不能同进程共存），故采用独立子进程架构：ReminderKit 子进程输出全部字段，EventKit 主进程兜底输出基础数据。每次导出的 `source` 字段标明实际数据源。

## 许可证

MIT（含私有框架使用免责声明，见 [LICENSE](LICENSE)）
