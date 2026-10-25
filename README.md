# remindkit — 在终端里管 Apple 提醒事项

[![Vibe coded](https://img.shields.io/badge/vibe-coded-%23ff69b4?style=flat-square)](https://en.wikipedia.org/wiki/Vibe_coding)

[English](README.en.md)

给用 Mac「提醒事项」的人：一条命令看清今天要做什么，也能直接新建、改期、完成、删除，不用在 App 里一层层点。
数据始终留在 Apple 提醒事项里 —— remindkit 只是在终端里读写它，不替代 App。

> ⚠️ 通过苹果**私有框架** `ReminderKit.framework` 读写数据，不受苹果支持，可能随 macOS 更新失效；与 Apple Inc. 无关联，仅供个人使用与学习研究。

> 🔒 所有数据只在本机处理：remindkit 不发起任何网络请求，提醒内容（账单 / 健康 / 位置等）不上传。

## 怎么用（3 步）

```bash
# ① 安装
brew install hiauhong/tap/remindkit

# ② 授权：第一次会弹系统框，点「允许」（同一个终端只需一次）
remindkit authorize --verify

# ③ 开始用
remindkit                                               # 今天 / 过期 / 未来 / 旗标 / 紧急，一屏看完
remindkit add "买牛奶" --list 待办 --due "2026-08-05 09:00"   # 列表名换成你自己的
```

不用 Homebrew：在仓库目录跑 `./Scripts/install.sh`（装到 `~/.local/bin`，不需要 sudo）。升级用 `brew upgrade remindkit`。

## 能做什么

- **看**：`remindkit` 一屏给出今天、过期、未来、旗标、紧急；`today` / `overdue` / `scheduled` / `flagged` / `urgent` 按需细看。
- **找和数**：`search` 搜标题 / 备注 / 标签，`count --by-list` 一次拿到每个列表的统计。
- **改**：新建、改期、改优先级、打标签、加提醒、重复任务、完成、移动、删除、批量操作。
- **管结构**：列表文件夹 → 列表 → 分区 → 任务 → 子任务，五层都能建、能改、能移。
- **导出**：`remindkit dump` 输出完整 JSON，方便备份或喂给别的工具。

## 常用命令

| 想做什么 | 命令 |
|---|---|
| 看今天该做什么 | `remindkit` |
| 今天到期 / 已过期 | `remindkit today` / `remindkit overdue` |
| 搜标题、备注、标签 | `remindkit search "牛奶"` |
| 看某个列表 | `remindkit query --list 工作` |
| 数一数（按列表） | `remindkit count --by-list` |
| 新建 / 完成 | `remindkit add "写周报" --list 工作 --due "2026-08-05 10:00"` / `remindkit complete <id>` |
| 全量导出 / 备份 | `remindkit dump > ~/reminders-backup.json` |
| 权限出问题 | `remindkit doctor` |
| 看全部命令 | `remindkit --help` |

> `<id>` 从任意查询结果里拿。删除是软删除，进「最近删除」，30 天后由系统清理。

## 已知限制

- **系统要求**：macOS 14 及以上；列表里的「分区」要 macOS 26 及以上。
- **权限**：需要「提醒事项」访问权限。权限记在**运行它的 App** 上（终端 / AI 工具的宿主），不是 remindkit 本身 —— 换一个 App 跑要重新授权。**不需要**「完全磁盘访问」。
- **第一次必须手动授权**：普通查询不会弹框，没授权时它只是安静地返回空数据，容易误以为「没有提醒」；跑一次 `remindkit authorize --verify` 才会弹框。
- **受限 / 沙盒模式的 AI 工具**可能报 `Mach error 4099`：把工具切到「完全访问」（Full Access）执行模式再授权；这和 macOS「完全磁盘访问」不是同一个权限。若该工具没有这个模式，需换一个能弹窗的终端来授权。
- **iCloud**：remindkit 不联网、不触发同步，读的是 Mac 本地当前数据（本地还没同步下来的改动读不到）；共享 / 协作列表不支持。
- **暂不支持**：图片附件、模板、「发信息时提醒」、日常采购列表的分类分组、写入时区；子任务只有一层（苹果原生限制）。
- **最近删除 / 恢复**只覆盖 remindkit 自己删的，在提醒事项 App 里删的看不到。
- 写操作前建议先备份：`remindkit dump > ~/reminders-backup.json`。

## 给开发者

- **双数据源**：ReminderKit 私有框架为主（字段最全），EventKit 公共 API 兜底；`dump` 的 `source` 标明来源，降级时响应带 `degraded: true`。
- **输出**：终端里默认纯文本，管道 / agent 调用自动 JSON；只要几个字段时用 `--fields id,title,dueDate` 省 token。
- **错误契约**：运行时错误 → stderr JSON + 退出码 1；用法错误 → 普通文本 + 退出码 64（不要假设所有错误都能 `jq` 解析）。
- **支持边界**（每项苹果功能 ✅ / 🟡 / ❌）：[docs/apple-reminders-support.md](docs/apple-reminders-support.md)
- **agent 命令契约**：[.agents/skills/remindkit/SKILL.md](.agents/skills/remindkit/SKILL.md)；每次运行自动同步到 `~/.agents/skills/`（`REMINDKIT_NO_AUTO_SKILL=1` 关闭），Claude Code 用 `remindkit install-skill --claude`。
- **只读模式**：`REMINDKIT_READ_ONLY=1` 拒绝一切写操作。重名列表用 ID 定位；`delete-list` 是永久删除，需 `--yes`。
- **构建 / 测试**：`make build`；日常 `make test-regressions`，发版前 `make test`（冒烟测试需本机提醒事项权限，只碰自建的「测试冒烟*」列表，自建自删）。

## License

MIT（含私有框架免责声明，见 [LICENSE](LICENSE)）。
