#!/usr/bin/env bash
# fm-slot-pool.sh - Treehouse pool census and idle-slot reserve for this home.
#
# Usage:
#   fm-slot-pool.sh census [--json]   count this home's pool slots by condition
#   fm-slot-pool.sh reserve           remove idle reusable slots beyond the reserve
#
# Scope: the clones under this home's projects/ directory, and for each only
# the slots `treehouse status --json` lists for it (Treehouse lists a clone's
# own slots; a shared pool's other clones are counted only as occupied room).
# Another home's or another clone's slots are never read as candidates.
#
# census --json prints one fm-slot-pool.v1 object:
#   {schema, low_room_threshold, clones[], warnings[]}
# Each clones[] row is
#   {project, pool_root, max_trees, pool_slots, headroom, reusable_free, stuck,
#    held, finished, low_room, slots[]}
# where each slots[] row is
#   {name, path, status, busy, leased, merged, task, merge_recorded}.
#   busy      Treehouse reports a process under the slot.
#   leased    the slot carries a Treehouse lease.
#   merged    HEAD is on origin's default branch (null when unknown).
#   task      the id of this home's task record naming the slot, else the
#             claimant in the slot's Firstmate owner claim, else null.
#   merge_recorded  that task's PR merge outcome is recorded in this home.
# Counts: held is slots with a task; finished is held slots whose merge is
# recorded (finished but not cleaned up); reusable_free is available, idle,
# unleased, unclaimed slots on the default branch; stuck is idle, unleased,
# unclaimed slots Treehouse will not reuse (dirty, damaged, or not on the
# default branch). pool_slots counts every slot directory in the pool root,
# across clones, and headroom is max_trees (treehouse.toml) minus that, null
# when max_trees is unknown. low_room is reusable_free + headroom below the
# threshold (FM_SLOT_LOW_ROOM, default 4), and each low-room clone adds one
# captain-facing warnings[] line. Plain census prints the same counts as text.
# Working and waiting splits of held slots need current task state, so
# bin/fm-fleet-snapshot.sh derives them from its own task rows.
#
# reserve acts only when config/slot-idle-reserve exists. Its first line is the
# number of idle reusable slots to keep per clone (empty means 2; anything but
# a non-negative integer is reported and changes nothing). Under the project's
# Treehouse lock (bin/fm-wake-lib.sh fm_treehouse_project_lock_path, the lock
# spawn and teardown hold), it re-reads the census and removes the surplus
# reusable_free slots, highest slot name first, each with a plain
# `treehouse destroy <path> --yes`: no --include-* flag, so Treehouse removes
# only its own disposable class (merged, clean, idle, unleased) and skips
# anything else. A held lock skips that clone until the next run. It prints one
# line per removal or skip. bin/fm-watch.sh starts it in the background on each
# heartbeat when config/slot-idle-reserve exists.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, and
# FM_PROJECTS_OVERRIDE resolve the home as the other bin/ scripts do.
# FM_SLOT_POOL_TIMEOUT bounds each treehouse call (default 30 seconds).
# Exit status: 0 on success, 1 on an invalid config/slot-idle-reserve or a
# failed destroy, 2 on a usage error or missing jq.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
LOW_ROOM=${FM_SLOT_LOW_ROOM:-4}
case "$LOW_ROOM" in ''|*[!0-9]*) LOW_ROOM=4 ;; esac
TH_TIMEOUT=${FM_SLOT_POOL_TIMEOUT:-30}
case "$TH_TIMEOUT" in ''|*[!0-9]*|0) TH_TIMEOUT=30 ;; esac

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '3,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

canon() {  # <dir>
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Prints "<canonical-worktree>\t<task-id>" for this home's task records.
home_task_slots() {
  local meta wt
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    wt=$(meta_value "$meta" worktree)
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    wt=$(canon "$wt") || continue
    printf '%s\t%s\n' "$wt" "$(basename "$meta" .meta)"
  done
}

merge_recorded() {  # <task-id>
  local id=$1 pr
  [ -f "$STATE/$id.meta" ] || return 1
  pr=$(meta_value "$STATE/$id.meta" pr)
  [ -n "$pr" ] && fm_pr_url_parse "$pr" || return 1
  fm_pr_poll_merge_already_notified "$STATE" "$id" \
    "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"
}

default_ref() {  # <clone>
  local ref
  ref=$(git -C "$1" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) || ref=
  [ -n "$ref" ] || ref=refs/remotes/origin/main
  git -C "$1" rev-parse --quiet --verify "$ref^{commit}" >/dev/null 2>&1 || return 1
  printf '%s\n' "$ref"
}

max_trees() {  # <clone>
  [ -f "$1/treehouse.toml" ] || return 1
  sed -n 's/^[[:space:]]*max_trees[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1/treehouse.toml" | head -1
}

# One clone's census row as JSON, or nothing when the clone has no pool.
clone_census() {  # <clone> <task-slots-file>
  local clone=$1 tasks=$2 status ref pool_root='' pool_slots=0 max path real
  local name st busy leased merged task recorded dir
  local -a rows=()
  command -v treehouse >/dev/null 2>&1 || return 0
  status=$(cd "$clone" && fm_run_timed "$TH_TIMEOUT" treehouse status --json 2>/dev/null) || return 0
  printf '%s' "$status" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 || return 0
  ref=$(default_ref "$clone") || ref=
  while IFS=$'\t' read -r name path st busy leased; do
    real=$(canon "$path") || continue
    [ -n "$pool_root" ] || pool_root=$(dirname "$(dirname "$real")")
    merged=null
    if [ -n "$ref" ]; then
      if git -C "$real" merge-base --is-ancestor HEAD "$ref" 2>/dev/null; then merged=true; else merged=false; fi
    fi
    task=$(awk -F'\t' -v p="$real" '$1 == p { print $2; exit }' "$tasks")
    if [ -z "$task" ]; then
      fm_treehouse_slot_owner_state "$real" ""
      case "$FM_TREEHOUSE_SLOT_OWNER" in
        other) task=$FM_TREEHOUSE_SLOT_OWNER_ID ;;
        unsafe) task="unreadable-claim" ;;
      esac
    fi
    recorded=false
    [ -z "$task" ] || ! merge_recorded "$task" || recorded=true
    rows+=("$(jq -cn --arg name "$name" --arg path "$real" --arg status "$st" \
      --argjson busy "$busy" --argjson leased "$leased" --argjson merged "$merged" \
      --arg task "$task" --argjson recorded "$recorded" \
      '{name:$name,path:$path,status:$status,busy:$busy,leased:$leased,merged:$merged,
        task:(if $task == "" then null else $task end),merge_recorded:$recorded}')")
  done < <(printf '%s' "$status" | jq -r '.[] | [.name, .path, .status,
      ((.processes // []) | length > 0 | tostring),
      ((.lease_id // "") != "" | tostring)] | @tsv')
  [ "${#rows[@]}" -gt 0 ] || return 0
  for dir in "$pool_root"/*/; do
    [ -d "$dir" ] && pool_slots=$((pool_slots + 1))
  done
  max=$(max_trees "$clone") || max=
  printf '%s\n' "${rows[@]}" | jq -cs --arg project "$clone" --arg pool_root "$pool_root" \
    --argjson pool_slots "$pool_slots" --arg max "$max" --argjson low "$LOW_ROOM" '
    def idle: (.busy | not) and (.leased | not) and .task == null;
    . as $slots
    | ($max | if . == "" then null else tonumber end) as $max_trees
    | ($slots | map(select(idle and .status == "available" and .merged == true)) | length) as $free
    | ($slots | map(select(idle and (.status == "dirty" or .status == "damaged" or .merged == false))) | length) as $stuck
    | (if $max_trees == null then null else ([$max_trees - $pool_slots, 0] | max) end) as $headroom
    | {project:$project, pool_root:$pool_root, max_trees:$max_trees, pool_slots:$pool_slots,
       headroom:$headroom, reusable_free:$free, stuck:$stuck,
       held:($slots | map(select(.task != null)) | length),
       finished:($slots | map(select(.merge_recorded)) | length),
       low_room:($headroom != null and ($free + $headroom) < $low),
       slots:$slots}'
}

census_json() {
  local tasks clone row
  local -a rows=()
  tasks=$(mktemp "${TMPDIR:-/tmp}/fm-slot-pool.XXXXXX") || return 1
  home_task_slots > "$tasks"
  for clone in "$PROJECTS"/*/; do
    clone=${clone%/}
    [ -d "$clone/.git" ] || [ -f "$clone/.git" ] || continue
    row=$(clone_census "$clone" "$tasks") || row=
    [ -z "$row" ] || rows+=("$row")
  done
  rm -f "$tasks"
  printf '%s\n' ${rows[@]+"${rows[@]}"} | jq -cs --argjson low "$LOW_ROOM" '
    {schema:"fm-slot-pool.v1", low_room_threshold:$low, clones:.,
     warnings:[.[] | select(.low_room) |
       "Slot pool for \(.project | split("/") | last) is nearly full: \(.reusable_free) reusable free + \(.headroom) unused room (under \($low)); \(.stuck) stuck idle, \(.finished) finished but not cleaned up."]}'
}

cmd_census() {
  local json
  json=$(census_json) || exit 1
  if [ "${1:-}" = --json ]; then
    printf '%s\n' "$json"
    return 0
  fi
  printf '%s\n' "$json" | jq -r '
    if (.clones | length) == 0 then "slot pool: no Treehouse pool under this home" else
    (.clones[] | "slot pool \(.project): held=\(.held) finished=\(.finished) stuck=\(.stuck) reusable_free=\(.reusable_free) headroom=\(.headroom // "unknown") max_trees=\(.max_trees // "unknown")"),
    (.warnings[] | "warning: \(.)") end'
}

reserve_target() {
  local file="$CONFIG/slot-idle-reserve" first
  [ -e "$file" ] || return 3
  first=$(head -n 1 "$file" 2>/dev/null | tr -d '[:space:]') || first=
  [ -n "$first" ] || first=2
  case "$first" in
    *[!0-9]*) echo "fm-slot-pool: config/slot-idle-reserve must be a non-negative integer, got '$first'; nothing removed" >&2; return 1 ;;
  esac
  printf '%s\n' "$first"
}

cmd_reserve() {
  local keep rc=0 clone lock tasks row path surplus
  keep=$(reserve_target) || { rc=$?; [ "$rc" -eq 3 ] && return 0; return 1; }
  rc=0
  for clone in "$PROJECTS"/*/; do
    clone=${clone%/}
    [ -d "$clone/.git" ] || [ -f "$clone/.git" ] || continue
    lock=$(fm_treehouse_project_lock_path "$clone") || continue
    fm_lock_try_acquire "$lock" || { printf 'skipped %s: slot allocation lock is held\n' "$clone"; continue; }
    tasks=$(mktemp "${TMPDIR:-/tmp}/fm-slot-pool.XXXXXX") || { fm_lock_release "$lock"; return 1; }
    home_task_slots > "$tasks"
    row=$(clone_census "$clone" "$tasks") || row=
    rm -f "$tasks"
    if [ -n "$row" ]; then
      surplus=$(printf '%s' "$row" | jq -r --argjson keep "$keep" '
        [.slots[] | select((.busy | not) and (.leased | not) and .task == null
          and .status == "available" and .merged == true)]
        | sort_by(.name | (tonumber? // .)) | .[$keep:] | .[].path')
      while IFS= read -r path; do
        [ -n "$path" ] || continue
        if (cd "$clone" && fm_run_timed "$TH_TIMEOUT" treehouse destroy "$path" --yes) >/dev/null 2>&1; then
          printf 'removed idle slot %s (keeping %s idle in %s)\n' "$path" "$keep" "$clone"
        else
          printf 'skipped %s: treehouse destroy refused or failed\n' "$path"
          rc=1
        fi
      done <<< "$surplus"
    fi
    fm_lock_release "$lock" || true
  done
  return "$rc"
}

command -v jq >/dev/null 2>&1 || { echo "fm-slot-pool: jq not found" >&2; exit 2; }
case "${1:-}" in
  census) shift; cmd_census "${1:-}" ;;
  reserve) cmd_reserve ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
