#!/usr/bin/env bash
# remindkit smoke test — run against the built binary.
#
# Test discipline (hard rule): the script
# ONLY ever touches lists/groups/smart lists whose name starts with
# 「测试冒烟」(test smoke), which it creates itself and removes at the end.
# It NEVER writes to real lists — real user data must be identical before
# and after a run (verified by the final LEFT check). A failure anywhere
# exits non-zero.
#
# Usage:  make test   (or)   bash Scripts/smoke-test.sh

set -euo pipefail

BIN="${REMINDKIT_BIN:-$(cd "$(dirname "$0")/.." && pwd)/.build/release/remindkit}"

if [[ ! -x "$BIN" ]]; then
    echo "error: binary not found at $BIN (run 'make build' first)" >&2
    exit 1
fi

PASS=0
FAIL=0
TAG="$(date +%s)"
LIST_A="测试冒烟A$TAG"
LIST_B="测试冒烟B$TAG"
REMINDER="冒烟提醒$TAG"
# Isolated deleted-cache file for this run — the test's delete/restore
# round-trip must never touch the user's real recently-deleted cache.
CACHE="$(mktemp -t remindkit-deleted.XXXXXX 2>/dev/null || echo "/tmp/remindkit-deleted.$$")"
export REMINDKIT_DELETED_CACHE="$CACHE"
KEEP_CACHE=0

cleanup() {
    # Best-effort removal of everything the test created, with retries
    # (remindd sync can briefly delay a delete from being visible, and a
    # freshly-restored reminder can race a list delete).
    for attempt in 1 2 3 4 5; do
        local ids
        ids=$("$BIN" list --format json 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c['title'].startswith('测试冒烟'):
        print(c['id'])")
        if [[ -z "$ids" ]]; then break; fi
        for id in $ids; do
            if ! "$BIN" delete-list --id "$id" --yes >/dev/null 2>&1; then
                echo "  cleanup: delete-list $id failed (attempt $attempt)" >&2
            fi
        done
        sleep 2
    done
    # Smart lists live outside list output; remove them separately.
    local sls
    sls=$("$BIN" dump 2>/dev/null | python3 -c "
import json,sys
for s in json.load(sys.stdin).get('smartLists', []):
    if s.get('name', '').startswith('测试冒烟'):
        print(s['uuid'])")
    for id in $sls; do
        "$BIN" delete-list --id "$id" --yes >/dev/null 2>&1 || true
    done
    if [[ "$KEEP_CACHE" != "1" ]]; then
        rm -f "$CACHE" 2>/dev/null || true
    fi
}
trap cleanup EXIT

check() { # check <description> <expected> <actual>
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1))
        echo "  ok: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc — expected [$expected], got [$actual]" >&2
    fi
}

echo "== remindkit smoke test (binary: $BIN) =="

# ── Read path ────────────────────────────────────────────────────────────────
echo "-- read path --"
OUT=$("$BIN" doctor --json)
check "doctor json parse" "ok" "$(echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print('ok' if d['subprocess'].startswith('ok') else d['subprocess'])")"
check "doctor primary=reminderKit" "reminderKit" "$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['primary'])")"

OUT=$("$BIN" count)
check "count totals consistent" "ok" "$(echo "$OUT" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d['total'] == d['incomplete'] + d['completed'] else 'bad')")"

OUT=$("$BIN" dump)
check "dump source=reminderKit" "reminderKit" "$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['source'])")"
check "dump reminders non-empty" "ok" "$(echo "$OUT" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if len(d['reminders']) > 0 else 'empty')")"
check "query --fields projects keys" "ok" "$("$BIN" query --all --fields id,title --format json 2>/dev/null | python3 -c "
import json,sys
rows=json.load(sys.stdin)
print('ok' if rows and 'completed' in rows[0] and 'id' in rows[0] and 'title' in rows[0] and 'notes' not in rows[0] else 'bad')")" 
check "dump --fields keeps top-level shape" "ok" "$("$BIN" dump --fields id,title 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('ok' if set(['version','reminders','calendars']) <= set(d.keys()) and d['reminders'] and 'completed' in d['reminders'][0] and 'id' in d['reminders'][0] and 'title' in d['reminders'][0] and 'notes' not in d['reminders'][0] else 'bad')")" 

# ── Hierarchy integrity (folder → list → section → reminder → subtask) ──────
# Consistency checks on the full dump. They pass vacuously on an empty
# dataset and under the EventKit fallback (which carries none of these
# fields), so they only fail on a genuine data-integrity regression.
check "hierarchy: list parentUUID points to a real group" "ok" "$(echo "$OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
groups={c['id'] for c in d['calendars'] if c.get('isGroup')}
bad=[c['title'] for c in d['calendars'] if not c.get('isGroup') and c.get('parentUUID') and c['parentUUID'] not in groups]
print('ok' if not bad else 'orphans: ' + ', '.join(bad[:3]))")"
check "hierarchy: reminder section belongs to its list's sections" "ok" "$(echo "$OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sections={c['id']: c.get('sections') or [] for c in d['calendars']}
bad=[r['title'] for r in d['reminders'] if r.get('section') and r['section'] not in sections.get(r['calendarId'], [])]
print('ok' if not bad else 'orphans: ' + ', '.join(bad[:3]))")"
check "hierarchy: subtask tree consistent (no dangling, subtaskIds match)" "ok" "$(echo "$OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ids={r['id'] for r in d['reminders']}
children={}
for r in d['reminders']:
    if r.get('parentId'):
        children.setdefault(r['parentId'], []).append(r['id'])
dangling=[p for p in children if p not in ids]
mismatch=[r['id'] for r in d['reminders'] if sorted(r.get('subtaskIds', [])) != sorted(children.get(r['id'], []))]
print('ok' if not dangling and not mismatch else 'dangling=%d mismatch=%d' % (len(dangling), len(mismatch)))")"

for cmd in "list --format count" "today --format count" "overdue --format count" "search 的 --format count" "query --all --format count"; do
    if "$BIN" $cmd >/dev/null 2>&1; then
        PASS=$((PASS + 1)); echo "  ok: $cmd runs"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: $cmd failed" >&2
    fi
done

# ── Write path (protected sandbox) ───────────────────────────────────────────
echo "-- write path (smoke lists only) --"

LIST_A_ID=$("$BIN" add-list "$LIST_A" | python3 -c "import json,sys; print(json.load(sys.stdin)['calendar']['id'])")
check "add-list returns id" "ok" "$(test -n "$LIST_A_ID" && echo ok || echo no)"

REM_ID=$("$BIN" add "$REMINDER" --list-id "$LIST_A_ID" --due 2099-01-01 --priority high --tag smoke --notes "smoke test" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
check "add returns id" "ok" "$(test -n "$REM_ID" && echo ok || echo no)"

# ── Hierarchy write path (group → list-in-group → section → filed reminder) ──
GROUP_ID=$("$BIN" add-group "测试冒烟分组$TAG" | python3 -c "import json,sys; print(json.load(sys.stdin)['group']['id'])")
check "add-group returns id" "ok" "$(test -n "$GROUP_ID" && echo ok || echo no)"

LIST_IN_GROUP_ID=$("$BIN" add-list "测试冒烟组内$TAG" --group-id "$GROUP_ID" | python3 -c "import json,sys; print(json.load(sys.stdin)['calendar']['id'])")
check "add-list --group returns id" "ok" "$(test -n "$LIST_IN_GROUP_ID" && echo ok || echo no)"

check "add-section ok" "ok" "$("$BIN" add-section "测试冒烟组内$TAG" "测试冒烟分区$TAG" | python3 -c "import json,sys; print('ok' if json.load(sys.stdin).get('ok') else 'bad')")"

REM_IN_SECTION=$("$BIN" add "测试冒烟分区任务$TAG" --list-id "$LIST_IN_GROUP_ID" --section "测试冒烟分区$TAG" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
check "add --section returns id" "ok" "$(test -n "$REM_IN_SECTION" && echo ok || echo no)"

"$BIN" add-section "测试冒烟组内$TAG" "测试冒烟分区2$TAG" >/dev/null 2>&1
check "update --section moves" "测试冒烟分区2$TAG" "$("$BIN" update "$REM_IN_SECTION" --section "测试冒烟分区2$TAG" | python3 -c "import json,sys; print(json.load(sys.stdin).get('changes', {}).get('section', ''))")"

SL_ID=$("$BIN" add-smartlist "测试冒烟智能$TAG" --color "#FF3B30" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
check "add-smartlist returns id" "ok" "$(test -n "$SL_ID" && echo ok || echo no)"

OUT=$("$BIN" dump)
check "hierarchy: reminder filed into section" "ok" "$(echo "$OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
rs=[r for r in d['reminders'] if r['title']=='测试冒烟分区任务$TAG']
print('ok' if rs and rs[0].get('section')=='测试冒烟分区2$TAG' else 'bad')")"
check "hierarchy: list parentUUID points to created group" "ok" "$(echo "$OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ls=[c for c in d['calendars'] if c['id']=='$LIST_IN_GROUP_ID']
print('ok' if ls and ls[0].get('parentUUID')=='$GROUP_ID' else 'bad')")"

# move-list: 把顶层测试列表移入分组再移出（用响应断言，避免 remindd 同步延迟）
check "move-list into group" "ok" "$("$BIN" move-list "$LIST_A" --to-group-id "$GROUP_ID" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('ok' if d.get('groupID')=='$GROUP_ID' else 'bad')")"
check "move-list out of group" "ok" "$("$BIN" move-list "$LIST_A" --out-of-group | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('ok' if d.get('groupID') is None else 'bad')")"

# Duplicate-name list must be ambiguous (two 财务 lists exist in real data,
# but this must hold generally — use the smoke lists to check no false positive).
"$BIN" complete "$REM_ID" >/dev/null 2>&1
OUT=$("$BIN" query --all --list "$LIST_A" --format json)
check "complete + query reflects completion" "ok" "$(echo "$OUT" | python3 -c "
import json,sys
rs=[r for r in json.load(sys.stdin) if r['title']=='$REMINDER']
print('ok' if any(r['completed'] for r in rs) else 'not-completed')")"

"$BIN" complete "$REM_ID" --reopen >/dev/null 2>&1
OUT=$("$BIN" query --list "$LIST_A" --format json)
check "reopen shows incomplete" "ok" "$(echo "$OUT" | python3 -c "
import json,sys
rs=[r for r in json.load(sys.stdin) if r['title']=='$REMINDER']
print('ok' if any(not r['completed'] for r in rs) else 'bad')")"

"$BIN" update-list --id "$LIST_A_ID" --new-name "$LIST_B" --color red >/dev/null 2>&1
OUT=$("$BIN" list --format json)
check "update-list rename+color" "ok" "$(echo "$OUT" | python3 -c "
import json,sys
c=[c for c in json.load(sys.stdin) if c['id']=='$LIST_A_ID'][0]
print('ok' if c['title']=='$LIST_B' and c.get('color') else 'bad')")"

# move within test lists (same list, forced through the move op)
# True move re-parents the existing reminder — the identifier is preserved
# (no copy/delete, no recently-deleted entry).
MOVED=$("$BIN" move "$REM_ID" --to-id "$LIST_A_ID" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['id'])")
check "move preserves id (no copy/delete)" "$REM_ID" "$MOVED"

# delete → recently-deleted → restore round-trip
"$BIN" delete "$MOVED" >/dev/null 2>&1
OUT=$("$BIN" recently-deleted)
check "recently-deleted lists the record" "ok" "$(echo "$OUT" | python3 -c "
import json,sys
items=json.load(sys.stdin)['items']
print('ok' if any(i['id']=='$MOVED' for i in items) else 'missing')")"
"$BIN" restore "$MOVED" --list-id "$LIST_A_ID" >/dev/null 2>&1
OUT=$("$BIN" search "$REMINDER" --all --format count)
check "restore brings the reminder back" "ok" "$(echo "$OUT" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d['total'] >= 1 else 'missing')")"
check "restore removes the record from cache" "ok" "$("$BIN" recently-deleted | python3 -c "
import json,sys
items=json.load(sys.stdin)['items']
print('ok' if not any(i['id']=='$MOVED' for i in items) else 'still-present')")"

# Let the restore settle in remindd before cleanup — deleting a list whose
# reminder was just restored can race (delete reports success but the list
# lingers).
sleep 2

# ── reorder: 列表内相对移动（--before/--after/--first/--last）──────────
# 锚点：新建一个同级提醒，让列表至少两个任务可排序。
SIB=$("$BIN" add "冒烟排序锚点$TAG" --list-id "$LIST_A_ID" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
check "reorder anchor add ok" "ok" "$(test -n "$SIB" && echo ok || echo no)"

check "reorder --first ok" "ok" "$("$BIN" reorder "$REM_ID" --first | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d.get('ok') and d.get('relation')=='before' else 'bad')")"
check "reorder --before sibling ok" "ok" "$("$BIN" reorder "$REM_ID" --before "$SIB" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d.get('ok') and d.get('relation')=='before' and d.get('sibling')=='冒烟排序锚点$TAG' else 'bad')")"
check "reorder --after sibling ok" "ok" "$("$BIN" reorder "$REM_ID" --after "$SIB" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d.get('ok') and d.get('relation')=='after' else 'bad')")"
check "reorder --last ok" "ok" "$("$BIN" reorder "$REM_ID" --last | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d.get('ok') and d.get('relation')=='after' else 'bad')")"

# 顺序验证：--last 后 REMINDER 应排列表末尾（query 枚举顺序 = 显示顺序）
OUT=$("$BIN" query --list-id "$LIST_A_ID" --fields title --format json)
check "reorder --last moves reminder to bottom" "ok" "$(echo "$OUT" | python3 -c "
import json,sys
rows=[r['title'] for r in json.load(sys.stdin)]
print('ok' if rows and rows[-1]=='$REMINDER' else 'bad: ' + ','.join(rows[-3:]))")"

# 单任务 no-op：把锚点删掉，剩唯一任务，--first 应 unchanged
"$BIN" delete "$SIB" >/dev/null 2>&1
check "reorder single-task no-op (unchanged)" "ok" "$("$BIN" reorder "$REM_ID" --first | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d.get('ok') and d.get('unchanged') else 'bad')")"

# subprocess stderr must stay silent on success (no internal-log pollution)
STDERR=$("$BIN" count 2>&1 >/dev/null)
check "successful run leaves stderr clean" "" "$STDERR"

# ── Final hygiene: nothing we created may remain ────────────────────────────
# cleanup runs explicitly here (and again via trap on exit; it is idempotent).
cleanup
LEFT=$("$BIN" dump 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
left=[c['title'] for c in d['calendars'] if c['title'].startswith('测试冒烟')]
left += [s['name'] for s in d.get('smartLists', []) if s.get('name', '').startswith('测试冒烟')]
print(len(left))
")
if [[ "$LEFT" != "0" ]]; then
    echo "FAIL: $LEFT test list(s) left behind after cleanup" >&2
    FAIL=$((FAIL + LEFT))
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
