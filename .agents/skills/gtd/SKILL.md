---
name: gtd
description: GTD(Getting Things Done)方法论工作流,基于 remindkit 提醒事项落地——捕获→厘清→组织→回顾→执行五步,外加每周回顾。当用户要实践 GTD、清理收件箱、做每周回顾、问"这条待办该放哪/接下来该做什么",或要把想法整理进提醒事项系统时使用。依赖 remindkit(工具层)读写提醒事项。
---

# GTD 工作流(提醒事项版)

GTD 的核心:清空大脑,让提醒事项系统承载所有承诺(open loops)。用户是决策者,agent 是记忆与处理层。

## 系统地图(用户列表结构)

```
收集            ← 唯一 inbox(待办收集箱,定期清理分流)
├─ OKR          ← 项目与年度目标(分区:工作/财务/个人成长/健康/社交/5年计划)
├─ 日常 / 健康 / 财务 / 人际 / 数码 / 尝试 / 想去   ← 领域待办
├─ 理财消费(组) ← 想买:日用品 / 数码 / 服饰 / 老家 / 账单 / 零售(闲鱼)
├─ 学习输入(组) ← 书单学习:互联网 / 商业 / 社科 / 艺术 / 其它
└─ 创造输出(组) ← 内容创作:个人项目 / 账号运营 / 城市/数码/产品/生活/潮流/摄影选题
```

规则:`remindkit list --format json` 拿全量结构(含 note 备注),列表用途以 note 为准,拿不准就问用户。

## 五步流程

### 1. 捕获 Capture(零摩擦,不判断)
用户说"提醒我 XX / 记一下 XX / 加个事项" → 直接 `remindkit add "XX" --list 收集`。
**不归类、不设时间、不打断**——除非用户明确指定。目标是让"说出想法"成为唯一动作。

### 2. 厘清 Clarify(处理收集箱)
对「收集」里的每条,agent 先做第一轮分析,用户做最终判断:

| 情况 | 动作 |
|---|---|
| 可行动,2 分钟内能做完 | 建议立即做(agent 不代做) |
| 可行动,需更多时间 | 进入组织:归列表 + 定下一步 + 设时间 |
| 不可行动,但有用信息 | 建议转备忘录(notekit)或书单列表 |
| 不可行动,无价值 | 建议删除 |

### 3. 组织 Organize(归类 + 定属性)
归类规则(拿不准就问一句,不要擅自):
- 目标 / 跨月项目 → `OKR`(按分区,如 --section 个人成长)
- 生活琐事→日常;体检就医→健康;钱/投资→财务;人情送礼→人际;数码折腾→数码;新鲜体验→尝试;地点→想去
- 想买→理财消费组对应列表;书单→学习输入组;内容选题→创造输出组对应选题列表
- 未分类杂项→留在收集

定属性:到期时间(用户给,或 agent 建议后确认)、`--priority`、`--tag`、`--notes`、重复规则(`--repeat`)。

### 4. 回顾 Reflect(每周回顾,agent 出报告用户审批)
用户说"周回顾/本周回顾"或按约定触发,依次:
1. `remindkit today --include-overdue` —— 过期 + 今天
2. `remindkit scheduled --within 7` —— 未来 7 天
3. `remindkit query --list 收集 --all` —— 清 inbox,分流(走厘清→组织)
4. `remindkit query --list OKR --tree` —— 项目进展
5. `remindkit overdue` + `remindkit flagged` —— 扫尾

输出结构化报告:**完成 / 卡住 / 过期 / 下周重点 / 需要用户决策的事项**。用户只做决定,agent 执行对应写入。

### 5. 执行 Engage(决定 + 去做)
用户问"今天做什么" → 组合 `today` + `overdue` + `flagged`,agent 按时间/精力/优先级给出候选,用户选。执行本身是用户的(agent 可代做纯执行型任务)。

## 决策边界(硬规则)

- **agent 做**:记录、归类建议、设时间建议、生成回顾、提醒、搜索、批量整理
- **用户做**:判断"做不做 / 做什么 / 何时做",以及实际执行
- agent 永远不替用户判断"这条重不重要"——只能给出依据(过期、频次、与 OKR 的关联)

## 常用命令速查

```bash
remindkit add "事项" --list 收集                              # 捕获
remindkit add "事项" --list 日常 --due "2026-08-05 20:00" --priority high --notes "..." --tag 生活
remindkit query --list 收集 --all --fields title,dueDate     # 厘清时扫 inbox(投影省 token)
remindkit query --list OKR --tree                            # 项目树
remindkit today --include-overdue                            # 过期+今天
remindkit scheduled --within 7                               # 未来 7 天
remindkit move <id> --to 健康                                 # 归类
remindkit update <id> --due "2026-08-06 09:00" --priority high
remindkit complete <id>                                      # 完成
remindkit bulk --op complete --list 日常 --due-before <昨天>  # 批量清理过期
```

## 注意事项

- 测试纪律:写操作测试只在 `测试冒烟*` 列表做,绝不碰真实列表(见 remindkit 仓库文档)
- 同名列表(两个"财务"/两个"数码")用完整 UUID 精确定位
- 删除用软删除;批量操作用 `--dry-run` 预览
