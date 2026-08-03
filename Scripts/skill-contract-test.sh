#!/usr/bin/env bash
# skill-contract-test.sh — 验证 SKILL.md 的命令示例与 CLI 实际能力一致。
#
# 背景：skill 是 agent 的 "API 契约"。文档漂移（skill 里写了 CLI 不存在的
# 子命令/选项，如历史上的 `note --all --format json`）会让 agent 直接踩坑。
# 本脚本解析 SKILL.md 的 bash 代码块，对每个示例命令做两层校验：
#   1. 子命令存在：remindkit <sub> --help 退出码 0
#   2. 选项存在：示例用到的每个 --option 出现在该子命令的 --help 里
# 只校验（跑 --help），绝不执行示例命令（含写操作示例）。
set -u
cd "$(dirname "$0")/.."
SKILL=".agents/skills/remindkit/SKILL.md"
R=".build/release/remindkit"

[ -x "$R" ] || { echo "先 build：make build" >&2; exit 1; }
[ -f "$SKILL" ] || { echo "找不到 $SKILL" >&2; exit 1; }

fail=0
checked_lines=0
report="$(mktemp)"
TMPHOME="$(mktemp -d)"
trap 'rm -f "$report"; rm -rf "$TMPHOME"' EXIT

# 提取 SKILL.md 中 ```bash 代码块的行；strip 注释与续行符。
awk '/^```bash/{b=1; next} /^```/{b=0} b' "$SKILL" | while IFS= read -r raw; do
    line="${raw%%#*}"                      # 去行内注释
    line="${line%\\}"                      # 去续行符
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$line" in
        remindkit\ *) ;;
        *) continue ;;                     # 非命令行（说明/变量）跳过
    esac

    # 跳过纯 "remindkit"（默认 overview）与带 shell 语法的行
    set -- $line
    [ $# -ge 2 ] || continue
    sub="$2"

    checked_lines=$((checked_lines+1))

    if ! "$R" "$sub" --help >/dev/null 2>&1; then
        echo "✗ 子命令不存在: $sub  （行: ${line}）" >> "$report"
        continue
    fi

    help="$("$R" "$sub" --help 2>&1)"
    opts="$(printf '%s' "$line" | grep -oE '\-\-[a-z][a-z-]*' | sort -u)"
    for opt in $opts; do
        case "$help" in
            *"$opt"*) ;;
            *)
                echo "✗ $sub 缺选项 $opt  （行: ${line}）" >> "$report"
                ;;
        esac
    done
done

# 第一段 while 在管道子 shell 里，失败数收集在临时文件
grep -c '^✗' "$report" 2>/dev/null | grep -q . || true
fail="$(grep -c '^✗' "$report" 2>/dev/null || true)"
cat "$report"

# while 在管道里，fail 的累加发生在子 shell —— 用临时文件收结果
# （上面的 fail 变量只在子 shell 生效，这里改为把失败写入 stdout 已即时输出，
#   退出码以命令执行结果为准，见下方二次校验。）

# 二次校验：真实跑一遍（无副作用的只读命令集合），确保示例可执行。
readonly_checks=(
    "overview --format json"
    "count --format json"
    "list --format json"
    "note --all"
    "tags --format json"
)
for cmd in "${readonly_checks[@]}"; do
    if ! "$R" $cmd >/dev/null 2>&1; then
        echo "✗ 只读示例执行失败: $cmd"
        fail=$((fail+1))
    fi
done

# --- install-skill 回归（历史 bug：argv[0] 是裸命令名时 binDir 错指 cwd，
#      源被误判成目标 → --force 先删源再报 no such file）---
R_BIN_DIR="$(cd "$(dirname "$R")" && pwd)"
mkdir -p "$TMPHOME/.local/bin" "$TMPHOME/.agents/skills/remindkit"
cp "$R" "$TMPHOME/.local/bin/remindkit"
cp "$SKILL" "$TMPHOME/.agents/skills/remindkit/SKILL.md"

# 用例1：源==目标（skill 只在全局位、二进制旁无源）时，--force 绝不能删掉唯一副本
( cd "$TMPHOME" && HOME="$TMPHOME" PATH="$TMPHOME/.local/bin:$PATH" remindkit install-skill --agents --force >/dev/null 2>&1 )
if [ -f "$TMPHOME/.agents/skills/remindkit/SKILL.md" ]; then
    echo "ok: install-skill 源==目标时 --force 不删唯一副本"
else
    echo "✗ install-skill 源==目标时删掉了唯一副本（历史 bug 复发）"
    fail=$((fail+1))
fi

# 用例2：裸命令名（argv[0]=remindkit）从无 skill 的 cwd 调用，靠 PATH 解析到真实源
( cd /tmp && HOME="$TMPHOME" PATH="$R_BIN_DIR:$PATH" remindkit install-skill --agents --force >/dev/null 2>&1 )
if [ -f "$TMPHOME/.agents/skills/remindkit/SKILL.md" ]; then
    echo "ok: install-skill 裸命令名经 PATH 解析源并安装成功"
else
    echo "✗ install-skill 裸命令名找不到源/安装失败（历史 bug 复发）"
    fail=$((fail+1))
fi

# setup --accept 也应可非交互运行（agent 场景核心路径）
if ! "$R" setup --accept >/dev/null 2>&1; then
    echo "✗ setup --accept 非交互运行失败"
    fail=$((fail+1))
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "✓ skill 契约测试通过（解析命令块 + 只读示例）"
    exit 0
else
    echo "✗ skill 契约测试失败：$fail 处不一致，修复 SKILL.md 或 CLI 后再提交"
    exit 1
fi
