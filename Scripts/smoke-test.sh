#!/usr/bin/env bash
# remindkit smoke test — run against the built binary.
#
# Test discipline (hard rule): the script records the exact IDs of every
# list/group/smart list it creates and cleanup only ever deletes those IDs.
# It NEVER writes to or deletes real lists. A failure anywhere exits non-zero.
#
# Usage:
#   make test                                  # full smoke + contract suite
#   make test-regressions                      # focused checks for recent fixes
#   bash Scripts/smoke-test.sh --regressions   # focused checks directly

set -euo pipefail

BIN="${REMINDKIT_BIN:-$(cd "$(dirname "$0")/.." && pwd)/.build/release/remindkit}"
SUITE="${1:-full}"

case "$SUITE" in
    full|--regressions) ;;
    *)
        echo "error: unknown smoke suite '$SUITE' (use --regressions or omit it for full)" >&2
        exit 2
        ;;
esac

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
BASELINE_FILE="$(mktemp -t remindkit-baseline.XXXXXX 2>/dev/null || echo "/tmp/remindkit-baseline.$$")"
AFTER_FILE="$(mktemp -t remindkit-after.XXXXXX 2>/dev/null || echo "/tmp/remindkit-after.$$")"
export REMINDKIT_DELETED_CACHE="$CACHE"
printf '[]' > "$CACHE"
KEEP_CACHE=0
CREATED_ENTITY_IDS=()
CLEANUP_DONE=0

register_entity_id() {
    local id="$1"
    if [[ -n "$id" ]]; then
        CREATED_ENTITY_IDS+=("$id")
    fi
}

current_entity_ids() {
    "$BIN" dump 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for c in d.get('calendars', []): print(c['id'])
for s in d.get('smartLists', []): print(s.get('uuid', ''))
"
}

entity_exists_in() {
    local ids="$1" id="$2"
    grep -Fqx -- "$id" <<<"$ids"
}

cleanup() {
    if [[ "$CLEANUP_DONE" == "1" ]]; then return; fi
    # Best-effort removal of exactly the entities created by this run, with retries
    # (remindd sync can briefly delay a delete from being visible, and a
    # freshly-restored reminder can race a list delete).
    for attempt in 1 2 3 4 5; do
        local remaining=0
        local id existing_ids
        if ! existing_ids=$(current_entity_ids); then
            echo "  cleanup: entity snapshot failed (attempt $attempt)" >&2
            sleep 2
            continue
        fi
        for id in "${CREATED_ENTITY_IDS[@]}"; do
            if entity_exists_in "$existing_ids" "$id"; then
                remaining=$((remaining + 1))
                if ! "$BIN" delete-list --id "$id" --yes >/dev/null 2>&1; then
                    echo "  cleanup: delete-list $id failed (attempt $attempt)" >&2
                fi
            fi
        done
        if [[ "$remaining" -eq 0 ]]; then break; fi
        sleep 2
    done
    if [[ "$KEEP_CACHE" != "1" ]]; then
        rm -f "$CACHE" 2>/dev/null || true
    fi
    CLEANUP_DONE=1
}

finish() {
    cleanup
    rm -f "$BASELINE_FILE" "$AFTER_FILE" 2>/dev/null || true
}
trap finish EXIT

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

ids_are_distinct() {
    python3 -c 'import sys
ids=sys.argv[1:]
print("ok" if len(ids)==len(set(ids)) and all(ids) else "bad")' "$@"
}

created_ids_match_dump() {
    "$BIN" dump | python3 -c 'import json,sys
d=json.load(sys.stdin)
name=sys.argv[1]
returned=sys.argv[2:]
actual=[c["id"] for c in d.get("calendars",[]) if c.get("title")==name]
actual += [s["uuid"] for s in d.get("smartLists",[]) if s.get("name")==name]
print("ok" if set(returned)==set(actual) and len(actual)==len(returned) else "bad")' "$@"
}

snapshot_real_data() {
    local output_file="$1"
    shift
    "$BIN" dump | python3 -c 'import json,sys
excluded=set(sys.argv[2:])
d=json.load(sys.stdin)
d.pop("exportedAt", None)

d["calendars"]=sorted(
    (x for x in d.get("calendars", []) if x.get("id") not in excluded),
    key=lambda x:x.get("id", ""))
d["smartLists"]=sorted(
    (x for x in d.get("smartLists", []) if x.get("uuid") not in excluded),
    key=lambda x:x.get("uuid", ""))
d["reminders"]=sorted(
    (x for x in d.get("reminders", []) if x.get("calendarId") not in excluded),
    key=lambda x:x.get("id", ""))
d["listIDsOrdering"]=[x for x in d.get("listIDsOrdering", []) if x not in excluded]

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, sort_keys=True, separators=(",", ":"))' \
        "$output_file" "$@"
}

real_data_unchanged() {
    snapshot_real_data "$AFTER_FILE" "${CREATED_ENTITY_IDS[@]}"
    if cmp -s "$BASELINE_FILE" "$AFTER_FILE"; then
        echo ok
        return
    fi
    python3 -c 'import json,sys
before=json.load(open(sys.argv[1], encoding="utf-8"))
after=json.load(open(sys.argv[2], encoding="utf-8"))
changed=[k for k in sorted(set(before)|set(after)) if before.get(k)!=after.get(k)]
print("  baseline mismatch in: " + ", ".join(changed), file=sys.stderr)' \
        "$BASELINE_FILE" "$AFTER_FILE"
    echo changed
}

# Capture before the first test command performs any write. The after snapshot
# filters only IDs recorded by this run; every other object must be identical.
snapshot_real_data "$BASELINE_FILE"

recurrence_rule_count() {
    local list_id="$1" reminder_id="$2"
    "$BIN" query --list-id "$list_id" --all --fields id,recurrenceRules --format json | \
        python3 -c 'import json,sys
rows=json.load(sys.stdin)
target=sys.argv[1]
row=next(r for r in rows if r["id"]==target)
rules=row.get("recurrenceRules", "[]")
if isinstance(rules, str): rules=json.loads(rules)
print(len(rules))' "$reminder_id"
}

recurrence_due_date() {
    local list_id="$1" reminder_id="$2"
    "$BIN" query --list-id "$list_id" --all --fields id,dueDateText --format json | \
        python3 -c 'import json,sys
rows=json.load(sys.stdin)
target=sys.argv[1]
row=next(r for r in rows if r["id"]==target)
print(row.get("dueDateText", "").split()[0])' "$reminder_id"
}

reminder_field() {
    local list_id="$1" reminder_id="$2" field="$3"
    "$BIN" query --list-id "$list_id" --all --fields "id,$field" --format json | \
        python3 -c 'import json,sys
rows=json.load(sys.stdin)
target,field=sys.argv[1:]
row=next(r for r in rows if r["id"]==target)
print(row.get(field, ""))' "$reminder_id" "$field"
}

run_command_contract_suite() {
    local list_name="测试冒烟命令契约$TAG"
    local list_id
    local priority_id url_id bulk_delete_id bulk_tag
    local preview section_error query_error tree_error bulk_result

    list_id=$("$BIN" add-list "$list_name" | python3 -c "import json,sys; print(json.load(sys.stdin)['calendar']['id'])")
    register_entity_id "$list_id"
    priority_id=$("$BIN" add "priority none regression" --list-id "$list_id" --priority high | \
        python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")

    preview=$("$BIN" bulk --op delete --list "$list_id" --all --dry-run)
    check "bulk destructive dry-run does not require --yes" "ok" "$(echo "$preview" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("ok" if d.get("dryRun") is True and d.get("selected", 0) > 0 else "bad")')"

    "$BIN" update "$priority_id" --priority none >/dev/null
    check "update --priority none clears priority" "0" \
        "$(reminder_field "$list_id" "$priority_id" priority)"

    url_id=$("$BIN" add "url replacement regression" --list-id "$list_id" \
        --url "https://example.com/old" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    "$BIN" update "$url_id" --url "https://example.com/new" >/dev/null
    check "update --url replaces the old URL" "https://example.com/new" \
        "$(reminder_field "$list_id" "$url_id" url)"

    section_error=$("$BIN" update "$priority_id" --section "missing-$TAG" 2>&1 || true)
    check "missing section returns explicit noSuchSection" "noSuchSection" "$(echo "$section_error" | python3 -c '
import json,sys
print(json.load(sys.stdin).get("error", {}).get("code", ""))')"

    query_error=$("$BIN" query --list-id "$list_id" --section "missing-$TAG" --no-sections 2>&1 || true)
    check "query rejects --section with --no-sections" "ok" \
        "$(echo "$query_error" | grep -q 'mutually exclusive' && echo ok || echo bad)"

    tree_error=$("$BIN" query --smart-list "missing-$TAG" --tree 2>&1 || true)
    check "query rejects smart-list tree explicitly" "ok" \
        "$(echo "$tree_error" | grep -q 'does not support --smart-list' && echo ok || echo bad)"

    bulk_tag="bulk-delete-$TAG"
    bulk_delete_id=$("$BIN" add "bulk delete restore regression" --list-id "$list_id" --tag "$bulk_tag" | \
        python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    bulk_result=$("$BIN" bulk --op delete --list "$list_id" --tag "$bulk_tag" --all --yes)
    check "bulk delete succeeds once" "1" "$(echo "$bulk_result" | python3 -c '
import json,sys
print(json.load(sys.stdin).get("succeeded", 0))')"
    check "bulk delete is recorded for restore" "ok" "$("$BIN" recently-deleted | python3 -c '
import json,sys
target=sys.argv[1]
print("ok" if any(i.get("id")==target for i in json.load(sys.stdin).get("items", [])) else "missing")' "$bulk_delete_id")"
    "$BIN" restore "$bulk_delete_id" --list-id "$list_id" >/dev/null
    check "bulk-deleted reminder restores through CLI" "$bulk_delete_id" \
        "$(reminder_field "$list_id" "$bulk_delete_id" id)"
}

run_regression_suite() {
    local target_list="测试冒烟回归日期$TAG"
    local collision_name="测试冒烟回归同名$TAG"
    local target_list_id recurrence_id collision_list_id smart_a_id smart_b_id
    local mixed_error collision_error left=0 id existing_ids

    echo "== remindkit focused regression smoke (binary: $BIN) =="

    OUT=$("$BIN" doctor --json)
    check "read outcome is explicit success" "ok" "$(echo "$OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('ok' if d.get('subprocess','').startswith('ok') else 'bad')")"

    target_list_id=$("$BIN" add-list "$target_list" | python3 -c "import json,sys; print(json.load(sys.stdin)['calendar']['id'])")
    register_entity_id "$target_list_id"
    mixed_error=$("$BIN" add "mixed date regression" --list-id "$target_list_id" \
        --due 2099-04-04 --start '2099-04-04 09:00' 2>&1 || true)
    check "mixed due/start granularity rejected" "ok" \
        "$(echo "$mixed_error" | grep -q '必须同为全天日期' && echo ok || echo bad)"
    check "mixed date rejection writes nothing" "0" \
        "$("$BIN" query --list-id "$target_list_id" --all --format count | python3 -c \
            'import json,sys; print(json.load(sys.stdin)["total"])')"

    recurrence_id=$("$BIN" add "repeat replacement regression" --list-id "$target_list_id" \
        --due 2099-09-20 --repeat monthly | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    "$BIN" update "$recurrence_id" --due 2099-09-19 --repeat monthly >/dev/null
    check "update --repeat moves recurrence anchor from 20th to 19th" "2099-09-19" \
        "$(recurrence_due_date "$target_list_id" "$recurrence_id")"
    check "update --repeat replaces existing rules" "1" \
        "$(recurrence_rule_count "$target_list_id" "$recurrence_id")"
    "$BIN" update "$recurrence_id" --no-repeat >/dev/null
    check "update --no-repeat clears rules" "0" \
        "$(recurrence_rule_count "$target_list_id" "$recurrence_id")"

    run_command_contract_suite

    collision_list_id=$("$BIN" add-list "$collision_name" | python3 -c "import json,sys; print(json.load(sys.stdin)['calendar']['id'])")
    register_entity_id "$collision_list_id"
    smart_a_id=$("$BIN" add-smartlist "$collision_name" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    register_entity_id "$smart_a_id"
    smart_b_id=$("$BIN" add-smartlist "$collision_name" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    register_entity_id "$smart_b_id"

    check "duplicate smart-list ids are distinct" "ok" \
        "$(ids_are_distinct "$collision_list_id" "$smart_a_id" "$smart_b_id")"
    check "created ids match dump exactly" "ok" \
        "$(created_ids_match_dump "$collision_name" "$collision_list_id" "$smart_a_id" "$smart_b_id")"

    collision_error=$("$BIN" delete-list "$collision_name" --yes 2>&1 || true)
    check "delete-list rejects cross-family ambiguity" "ok" "$(echo "$collision_error" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('ok' if '跨列表/智能列表/分组' in d.get('error',{}).get('message','') else 'bad')")"

    cleanup
    if existing_ids=$(current_entity_ids); then
        for id in "${CREATED_ENTITY_IDS[@]}"; do
            if entity_exists_in "$existing_ids" "$id"; then left=$((left + 1)); fi
        done
    else
        left="snapshot-failed"
    fi
    check "focused smoke leaves no created entities" "0" "$left"
    check "focused smoke preserves all pre-existing data" "ok" "$(real_data_unchanged)"

    echo ""
    echo "passed: $PASS  failed: $FAIL"
    [[ "$FAIL" -eq 0 ]]
}

if [[ "$SUITE" == "--regressions" ]]; then
    run_regression_suite
    exit $?
fi

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
register_entity_id "$LIST_A_ID"
check "add-list returns id" "ok" "$(test -n "$LIST_A_ID" && echo ok || echo no)"

REM_ID=$("$BIN" add "$REMINDER" --list-id "$LIST_A_ID" --due 2099-01-01 --priority high --tag smoke --notes "smoke test" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
check "add returns id" "ok" "$(test -n "$REM_ID" && echo ok || echo no)"

# all-day semantics (regression for the allDay write-path fix): a pure
# YYYY-MM-DD --due must produce allDay=true; with a time part it must not.
ALLDAY_ID=$("$BIN" add "smoke allday" --list-id "$LIST_A_ID" --due 2099-02-02 | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
check "add pure-date is allDay" "True" "$("$BIN" query --list-id "$LIST_A_ID" --fields id,allDay --format json | python3 -c "
import json,sys
rows=json.load(sys.stdin)
print([r['allDay'] for r in rows if r['id']=='$ALLDAY_ID'][0])")"
check "update to all-day keeps allDay" "True" "$("$BIN" update "$REM_ID" --due 2099-03-03 | python3 -c "import json,sys; print(json.load(sys.stdin)['changes'].get('allDay'))")"
check "update to timed date clears allDay" "False" "$("$BIN" update "$ALLDAY_ID" --due '2099-02-02 10:30' | python3 -c "import json,sys; print(json.load(sys.stdin)['changes'].get('allDay'))")"
MIXED_DATE_ERR=$("$BIN" add "smoke mixed date" --list-id "$LIST_A_ID" --due 2099-04-04 --start '2099-04-04 09:00' 2>&1 || true)
check "mixed due/start granularity rejected" "ok" "$(echo "$MIXED_DATE_ERR" | grep -q '必须同为全天日期' && echo ok || echo bad)"

REPEAT_ID=$("$BIN" add "smoke repeat replacement" --list-id "$LIST_A_ID" --due 2099-09-20 --repeat monthly | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
"$BIN" update "$REPEAT_ID" --due 2099-09-19 --repeat monthly >/dev/null
check "update --repeat moves recurrence anchor from 20th to 19th" "2099-09-19" "$(recurrence_due_date "$LIST_A_ID" "$REPEAT_ID")"
check "update --repeat replaces existing rules" "1" "$(recurrence_rule_count "$LIST_A_ID" "$REPEAT_ID")"
"$BIN" update "$REPEAT_ID" --no-repeat >/dev/null
check "update --no-repeat clears rules" "0" "$(recurrence_rule_count "$LIST_A_ID" "$REPEAT_ID")"

run_command_contract_suite

# ── Hierarchy write path (group → list-in-group → section → filed reminder) ──
GROUP_ID=$("$BIN" add-group "测试冒烟分组$TAG" | python3 -c "import json,sys; print(json.load(sys.stdin)['group']['id'])")
register_entity_id "$GROUP_ID"
check "add-group returns id" "ok" "$(test -n "$GROUP_ID" && echo ok || echo no)"

# update-list unified dispatch (feature pool #15): group rename by name + verify
# via list output; renamed group still matches the 测试冒烟 cleanup prefix.
GROUP_RENAMED="测试冒烟分组改名$TAG"
check "update-list renames group (type)" "group" "$("$BIN" update-list "测试冒烟分组$TAG" --new-name "$GROUP_RENAMED" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type',''))")"
check "update-list group rename visible" "ok" "$("$BIN" list --format json | python3 -c "
import json,sys
gs=[g for g in json.load(sys.stdin) if g.get('isGroup') and g['title']=='$GROUP_RENAMED']
print('ok' if gs else 'missing')")"
# group rename by UUID (prefix) must also work and return the same type
check "update-list group rename by id" "group" "$("$BIN" update-list "$GROUP_ID" --new-name "测试冒烟分组$TAG" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type',''))")"

LIST_IN_GROUP_ID=$("$BIN" add-list "测试冒烟组内$TAG" --group-id "$GROUP_ID" | python3 -c "import json,sys; print(json.load(sys.stdin)['calendar']['id'])")
register_entity_id "$LIST_IN_GROUP_ID"
check "add-list --group returns id" "ok" "$(test -n "$LIST_IN_GROUP_ID" && echo ok || echo no)"

check "add-section ok" "ok" "$("$BIN" add-section "测试冒烟组内$TAG" "测试冒烟分区$TAG" | python3 -c "import json,sys; print('ok' if json.load(sys.stdin).get('ok') else 'bad')")"

REM_IN_SECTION=$("$BIN" add "测试冒烟分区任务$TAG" --list-id "$LIST_IN_GROUP_ID" --section "测试冒烟分区$TAG" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
check "add --section returns id" "ok" "$(test -n "$REM_IN_SECTION" && echo ok || echo no)"

"$BIN" add-section "测试冒烟组内$TAG" "测试冒烟分区2$TAG" >/dev/null 2>&1
check "update --section moves" "测试冒烟分区2$TAG" "$("$BIN" update "$REM_IN_SECTION" --section "测试冒烟分区2$TAG" | python3 -c "import json,sys; print(json.load(sys.stdin).get('changes', {}).get('section', ''))")"

SL_ID=$("$BIN" add-smartlist "测试冒烟智能$TAG" --color "#FF3B30" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
register_entity_id "$SL_ID"
check "add-smartlist returns id" "ok" "$(test -n "$SL_ID" && echo ok || echo no)"

# Duplicate names are legal. Creation must return each newly-created UUID,
# and delete-list by name must refuse a cross-family ambiguous match.
COLLISION_NAME="测试冒烟同名$TAG"
COLLISION_LIST_ID=$("$BIN" add-list "$COLLISION_NAME" | python3 -c "import json,sys; print(json.load(sys.stdin)['calendar']['id'])")
register_entity_id "$COLLISION_LIST_ID"
COLLISION_SMART_A_ID=$("$BIN" add-smartlist "$COLLISION_NAME" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
register_entity_id "$COLLISION_SMART_A_ID"
COLLISION_SMART_B_ID=$("$BIN" add-smartlist "$COLLISION_NAME" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
register_entity_id "$COLLISION_SMART_B_ID"
check "duplicate smart-list creation returns distinct ids" "ok" \
    "$(ids_are_distinct "$COLLISION_LIST_ID" "$COLLISION_SMART_A_ID" "$COLLISION_SMART_B_ID")"
check "created ids match dump exactly" "ok" \
    "$(created_ids_match_dump "$COLLISION_NAME" "$COLLISION_LIST_ID" "$COLLISION_SMART_A_ID" "$COLLISION_SMART_B_ID")"
COLLISION_ERR=$("$BIN" delete-list "$COLLISION_NAME" --yes 2>&1 || true)
check "delete-list rejects cross-family ambiguity" "ok" "$(echo "$COLLISION_ERR" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('ok' if '跨列表/智能列表/分组' in d.get('error', {}).get('message', '') else 'bad')")"

# update-list unified dispatch: smart list rename by name + verify via dump
SL_RENAMED="测试冒烟智能改名$TAG"
check "update-list renames smart list (type)" "smartList" "$("$BIN" update-list "测试冒烟智能$TAG" --new-name "$SL_RENAMED" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type',''))")"
check "update-list smart list rename visible" "ok" "$("$BIN" dump | python3 -c "
import json,sys
sls=[s for s in json.load(sys.stdin).get('smartLists',[]) if s.get('name')=='$SL_RENAMED']
print('ok' if sls else 'missing')")"
# icon/color must be rejected for non-list entities
check "update-list group rejects --icon" "ok" "$(test -n "$("$BIN" update-list "测试冒烟分组$TAG" --new-name "测试冒烟分组$TAG" --icon 🚀 2>&1 | python3 -c "import json,sys; print(json.load(sys.stdin).get('error',{}).get('code',''))")" && echo ok || echo no)"

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
# 独立的两任务列表：避免前面回归新增的提醒破坏 --last 与单任务前提。
REORDER_LIST="测试冒烟排序$TAG"
REORDER_LIST_ID=$("$BIN" add-list "$REORDER_LIST" | python3 -c "import json,sys; print(json.load(sys.stdin)['calendar']['id'])")
register_entity_id "$REORDER_LIST_ID"
REORDER_TITLE="冒烟排序目标$TAG"
REORDER_ID=$("$BIN" add "$REORDER_TITLE" --list-id "$REORDER_LIST_ID" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
SIB=$("$BIN" add "冒烟排序锚点$TAG" --list-id "$REORDER_LIST_ID" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
check "reorder anchor add ok" "ok" "$(test -n "$SIB" && echo ok || echo no)"

check "reorder --first ok" "ok" "$("$BIN" reorder "$REORDER_ID" --first | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d.get('ok') and d.get('relation')=='before' else 'bad')")"
check "reorder --before sibling ok" "ok" "$("$BIN" reorder "$REORDER_ID" --before "$SIB" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d.get('ok') and d.get('relation')=='before' and d.get('sibling')=='冒烟排序锚点$TAG' else 'bad')")"
check "reorder --after sibling ok" "ok" "$("$BIN" reorder "$REORDER_ID" --after "$SIB" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d.get('ok') and d.get('relation')=='after' else 'bad')")"
check "reorder --last ok" "ok" "$("$BIN" reorder "$REORDER_ID" --last | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d.get('ok') and d.get('relation')=='after' else 'bad')")"

# 顺序验证：--last 后目标应排列表末尾（query 枚举顺序 = 显示顺序）
OUT=$("$BIN" query --list-id "$REORDER_LIST_ID" --fields title --format json)
check "reorder --last moves reminder to bottom" "ok" "$(echo "$OUT" | python3 -c "
import json,sys
rows=[r['title'] for r in json.load(sys.stdin)]
print('ok' if rows and rows[-1]=='$REORDER_TITLE' else 'bad: ' + ','.join(rows[-3:]))")"

# 单任务 no-op：把锚点删掉，剩唯一任务，--first 应 unchanged
"$BIN" delete "$SIB" >/dev/null 2>&1
check "reorder single-task no-op (unchanged)" "ok" "$("$BIN" reorder "$REORDER_ID" --first | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d.get('ok') and d.get('unchanged') else 'bad')")"

# ── subtask: update --parent / --no-parent（普通任务 ↔ 子任务）─────
# 全部在测试列表 LIST_A 内：REM_ID 为父任务，SUB 为普通任务；
# 校验：自挂 / 父是子任务 / 已有子任务 / 跨列表（ReminderKit 强制同列表）。
SUB=$("$BIN" add "冒烟子任务$TAG" --list-id "$LIST_A_ID" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
check "subtask: add sub ok" "ok" "$(test -n "$SUB" && echo ok || echo no)"

check "update --parent attaches subtask" "$REM_ID" "$("$BIN" update "$SUB" --parent "$REM_ID" | python3 -c "
import json,sys; print(json.load(sys.stdin).get('changes', {}).get('parentId', ''))")"

check "update --no-parent detaches" "null" "$("$BIN" update "$SUB" --no-parent | python3 -c "
import json,sys
v=json.load(sys.stdin).get('changes', {}).get('parentId')
print('null' if v is None else v)")"

SUB_ERR=$("$BIN" update "$SUB" --parent "$SUB" 2>&1 || true)
check "subtask: self-attach rejected" "不能把提醒挂到自己下面" "$(echo "$SUB_ERR" | python3 -c "
import json,sys; print(json.load(sys.stdin).get('error', {}).get('message', 'no-error'))")"

"$BIN" update "$SUB" --parent "$REM_ID" >/dev/null 2>&1
PAR_ERR=$("$BIN" update "$REM_ID" --parent "$SUB" 2>&1 || true)
check "subtask: parent-is-subtask rejected" "父提醒本身是子任务——苹果不支持嵌套子任务，无法再挂" "$(echo "$PAR_ERR" | python3 -c "
import json,sys; print(json.load(sys.stdin).get('error', {}).get('message', 'no-error'))")"

# REM_ID 已有子任务 SUB → 不能再挂到其他父任务下（防 3 层嵌套）
TOP=$("$BIN" add "冒烟顶层$TAG" --list-id "$LIST_A_ID" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
CH_ERR=$("$BIN" update "$REM_ID" --parent "$TOP" 2>&1 || true)
check "subtask: has-children rejected" "该提醒已有子任务——苹果不支持嵌套子任务（父→子→孙），无法再挂到父任务下" "$(echo "$CH_ERR" | python3 -c "
import json,sys; print(json.load(sys.stdin).get('error', {}).get('message', 'no-error'))")"

# 跨列表：父任务在另一个测试列表（组内列表），ReminderKit 强制同列表
XL_ERR=$("$BIN" update "$SUB" --parent "$REM_IN_SECTION" 2>&1 || true)
check "subtask: cross-list rejected" "父提醒在不同列表——请先 move 到同一列表再挂（ReminderKit 强制子任务与父同列表）" "$(echo "$XL_ERR" | python3 -c "
import json,sys; print(json.load(sys.stdin).get('error', {}).get('message', 'no-error'))")"

# subprocess stderr must stay silent on success (no internal-log pollution)
STDERR=$("$BIN" count 2>&1 >/dev/null)
check "successful run leaves stderr clean" "" "$STDERR"

# ── move --section / query --section（跨列表迁移一步归位）──────────────
# 独立流程：自建列表 C + 分区，把 LIST_A 里的提醒一步迁入分区；
# 校验响应回显（toList+section）、query --section 归位验证、未建分区引导、
# query --section 缺 --list 报错。列表 C 由 cleanup 统一清除。
SEC_LIST="测试冒烟C$TAG"
SEC_NAME="测试冒烟分区$TAG"
SEC_LIST_ID=$("$BIN" add-list "$SEC_LIST" | python3 -c "import json,sys; print(json.load(sys.stdin)['calendar']['id'])")
register_entity_id "$SEC_LIST_ID"
check "move-section: target list created" "ok" "$(test -n "$SEC_LIST_ID" && echo ok || echo no)"
"$BIN" add-section "$SEC_LIST" "$SEC_NAME" >/dev/null 2>&1
MVREM=$("$BIN" add "冒烟迁移$TAG" --list-id "$LIST_A_ID" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
check "move-section: source reminder added" "ok" "$(test -n "$MVREM" && echo ok || echo no)"

check "move --section files into target section (echo)" "ok" "$("$BIN" move "$MVREM" --to "$SEC_LIST" --section "$SEC_NAME" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d.get('ok') and d.get('section')=='$SEC_NAME' and d.get('toList')=='$SEC_LIST' else 'bad:'+json.dumps(d))")"

OUT=$("$BIN" query --list "$SEC_LIST" --section "$SEC_NAME" --format json)
check "query --section shows moved reminder" "ok" "$(echo "$OUT" | python3 -c "
import json,sys
rs=[r for r in json.load(sys.stdin) if r['id']=='$MVREM']
print('ok' if len(rs)==1 and rs[0].get('section')=='$SEC_NAME' else 'bad')")"

BAD=$("$BIN" move "$MVREM" --to "$SEC_LIST" --section "不存在分区$TAG" 2>&1 || true)
check "move --section missing section guides add-section" "ok" "$(echo "$BAD" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if '先用 add-section' in d.get('error', {}).get('message', '') else 'bad')")"

ERR=$("$BIN" query --section "$SEC_NAME" 2>&1 || true)
check "query --section requires --list" "ok" "$(echo "$ERR" | grep -q 'requires --list' && echo ok || echo bad)"

# bulk --op move --section：批量迁移一步归位（同一 opMove 路径，选择器=列表+标签）
BULKREM=$("$BIN" add "冒烟批量$TAG" --list-id "$LIST_A_ID" --tag bulksec | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
check "bulk-section: source added" "ok" "$(test -n "$BULKREM" && echo ok || echo no)"
BRES=$("$BIN" bulk --op move --to "$SEC_LIST" --section "$SEC_NAME" --list "$LIST_B" --tag bulksec --yes | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d.get('ok') and d.get('succeeded')==1 else 'bad:'+json.dumps(d))")
check "bulk --op move --section files into target section" "ok" "$BRES"
OUT=$("$BIN" query --list "$SEC_LIST" --section "$SEC_NAME" --format json)
check "bulk-section: query verifies placement" "ok" "$(echo "$OUT" | python3 -c "
import json,sys
rs=[r for r in json.load(sys.stdin) if r['id']=='$BULKREM']
print('ok' if len(rs)==1 and rs[0].get('section')=='$SEC_NAME' else 'bad')")"

# ── Final hygiene: nothing we created may remain ────────────────────────────
# cleanup runs explicitly here (and again via trap on exit; it is idempotent).
cleanup
LEFT=$("$BIN" dump 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
targets=set(sys.argv[1:])
ids={c['id'] for c in d.get('calendars', [])}
ids.update(s.get('uuid') for s in d.get('smartLists', []))
print(len(targets & ids))
" "${CREATED_ENTITY_IDS[@]}")
if [[ "$LEFT" != "0" ]]; then
    echo "FAIL: $LEFT entity ID(s) from this run left behind after cleanup" >&2
    FAIL=$((FAIL + LEFT))
fi
check "full smoke preserves all pre-existing data" "ok" "$(real_data_unchanged)"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
