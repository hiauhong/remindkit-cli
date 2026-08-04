# remindkit — Apple Reminders 数据管道 CLI

[![Vibe coded](https://img.shields.io/badge/vibe-coded-%23ff69b4?style=flat-square)](https://en.wikipedia.org/wiki/Vibe_coding)

[English](README.en.md)

remindkit 是 macOS 命令行工具,从 Apple Reminders(提醒事项)导出结构化数据,并支持完整读写(文件夹→列表→分区→任务→子任务)。**面向 AI agent**:统一 JSON 输出、机器可解析错误契约、内置 skill。

> 🎨 本项目由 **vibe coding**(AI 辅助开发)驱动——功能、测试与文档均在 AI agent 协作下迭代产出。

> **⚠️ 免责声明** — 通过苹果**私有框架** `ReminderKit.framework` 提取数据,不受苹果支持,可能随 macOS 更新失效;与 Apple Inc. 无任何关联,仅供个人使用与学习研究。

> **🔒 隐私** — 数据仅本机处理,不发任何网络请求;需要「提醒事项」访问权限(TCC),首次运行按提示授权。

## 安装

```bash
brew install hiauhong/tap/remindkit
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
remindkit add "买牛奶" --list 日常 --due "2026-08-03 09:00"
remindkit complete <id>  # 完成
```

## 面向 AI agent

- 查询默认只返回**未完成**;`--all` / `--completed` 切换
- 默认 JSON 输出;错误为 stderr JSON `{"error":{...}}` + 退出码(1 运行时 / 64 用法)
- 完整层级写:列表文件夹→列表→分区→任务→子任务;含标签/旗标/紧急/智能列表/批量
- 内置 skill:install 后自动注册,agent 扫描 `~/.agents/skills/` 自动发现
- 全部命令与参数见 `remindkit <命令> --help`;agent 细则见 [.agents/skills/remindkit/SKILL.md](.agents/skills/remindkit/SKILL.md)

## 安全约定

- 同名列表(如两个「财务」)用 ID 定位;`delete-list` 永久删除需 `--yes`
- 测试写操作只在「测试冒烟*」列表,自建自删、零残留

## 开发

```bash
make build    # 编译(ObjC 子二进制 + Swift CLI)
make test     # 冒烟测试 + skill 契约测试
```

## License

MIT(含私有框架免责声明,见 [LICENSE](LICENSE))
