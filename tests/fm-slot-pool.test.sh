#!/usr/bin/env bash
# Behavioral coverage for bin/fm-slot-pool.sh: the pool census counts (held,
# finished, stuck, reusable free, headroom), the low-room warning, and the
# opt-in idle reserve, which removes only surplus reusable slots and only with
# a plain `treehouse destroy <path> --yes`. Real git clones and slot worktrees
# in a real pool layout; Treehouse is faked from a JSON status fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-slot-pool)
SLOT_POOL="$ROOT/bin/fm-slot-pool.sh"

# make_case <name> <max-trees>: a home whose projects/app clone owns a pool
# with slots 1-6, plus slot 9 of another clone that only occupies room.
#   1 2 3  available, idle, on origin/main         -> reusable free
#   4      dirty, idle                              -> stuck
#   5      available, idle, HEAD not on origin/main -> stuck
#   6      in use, named by task t-done whose merge is recorded -> finished
make_case() {
  local name=$1 max=$2 case_dir clone pool slot
  case_dir="$TMP_ROOT/$name"
  clone="$case_dir/home/projects/app"
  pool="$case_dir/pool"
  mkdir -p "$case_dir/home/state" "$case_dir/home/config" "$pool/9/other" "$case_dir/fakebin"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$clone" 2>/dev/null
  git -C "$clone" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$clone" push -q origin HEAD:main
  git -C "$clone" fetch -q origin
  git -C "$clone" remote set-head origin main
  printf 'max_trees = %s\n' "$max" > "$clone/treehouse.toml"
  : > "$pool/treehouse-state.json"
  for slot in 1 2 3 4 5 6; do
    mkdir -p "$pool/$slot"
    git -C "$clone" worktree add -q --detach "$pool/$slot/app" origin/main
  done
  git -C "$pool/5/app" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "squashed away"
  fm_write_meta "$case_dir/home/state/t-done.meta" "kind=ship" "worktree=$pool/6/app" \
    "pr=https://github.com/example/app/pull/7"
  (
    STATE="$case_dir/home/state"
    # shellcheck source=bin/fm-pr-lib.sh
    . "$ROOT/bin/fm-pr-lib.sh"
    fm_pr_url_parse "https://github.com/example/app/pull/7"
    fm_pr_poll_merge_mark_notified "$case_dir/home/state" t-done \
      "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"
  ) || fail "$name: could not record the merge fixture"
  pool=$(cd "$pool" && pwd -P)
  cat > "$case_dir/status.json" <<JSON
[
 {"name":"1","path":"$pool/1/app","status":"available","processes":[],"lease_id":""},
 {"name":"2","path":"$pool/2/app","status":"available","processes":[],"lease_id":""},
 {"name":"3","path":"$pool/3/app","status":"available","processes":[],"lease_id":""},
 {"name":"4","path":"$pool/4/app","status":"dirty","processes":[],"lease_id":""},
 {"name":"5","path":"$pool/5/app","status":"available","processes":[],"lease_id":""},
 {"name":"6","path":"$pool/6/app","status":"in-use","processes":[{"pid":1,"name":"zsh"}],"lease_id":""}
]
JSON
  : > "$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
case "\${1:-}" in
  status) cat "$case_dir/status.json" ;;
  destroy) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/treehouse"
  printf '%s\n' "$case_dir"
}

run_pool() {  # <case-dir> <args...>
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" PATH="$case_dir/fakebin:$PATH" "$SLOT_POOL" "$@"
}

test_census_counts_each_slot_condition() {
  local case_dir out
  case_dir=$(make_case census 10)
  out=$(run_pool "$case_dir" census --json) || fail "census: exited non-zero"
  [ "$(printf '%s' "$out" | jq -c '.clones[0] | [.held, .finished, .stuck, .reusable_free, .pool_slots, .headroom, .low_room]')" \
    = '[1,1,2,3,7,3,false]' ] || fail "census: wrong counts: $(printf '%s' "$out" | jq -c '.clones[0] | del(.slots)')"
  [ "$(printf '%s' "$out" | jq -r '.clones[0].slots[] | select(.name == "6") | .task')" = t-done ] \
    || fail "census: slot 6 not attributed to its task"
  [ "$(printf '%s' "$out" | jq '.warnings | length')" = 0 ] || fail "census: warned with room to spare"
  pass "census counts held, finished, stuck, reusable free and headroom per clone"
}

test_census_warns_when_free_room_is_low() {
  local case_dir out
  case_dir=$(make_case low-room 7)
  out=$(run_pool "$case_dir" census --json) || fail "low-room: exited non-zero"
  [ "$(printf '%s' "$out" | jq -c '.clones[0] | [.reusable_free, .headroom, .low_room]')" = '[3,0,true]' ] \
    || fail "low-room: wrong verdict: $(printf '%s' "$out" | jq -c '.clones[0] | del(.slots)')"
  printf '%s' "$out" | jq -r '.warnings[0]' | grep -q "3 reusable free + 0 unused room" \
    || fail "low-room: warning missing: $(printf '%s' "$out" | jq -c .warnings)"
  run_pool "$case_dir" census | grep -q '^warning: Slot pool for app is nearly full' \
    || fail "low-room: text census omitted the warning"
  pass "census warns when reusable free slots plus unused room drop under four"
}

test_reserve_is_off_without_config() {
  local case_dir
  case_dir=$(make_case reserve-off 10)
  run_pool "$case_dir" reserve >/dev/null || fail "reserve-off: exited non-zero"
  ! grep -q '^destroy' "$case_dir/treehouse.log" || fail "reserve-off: destroyed without config/slot-idle-reserve"
  pass "reserve does nothing unless config/slot-idle-reserve exists"
}

test_reserve_removes_only_surplus_reusable_slots_safely() {
  local case_dir pool out
  case_dir=$(make_case reserve 10)
  pool=$(cd "$case_dir/pool" && pwd -P)
  : > "$case_dir/home/config/slot-idle-reserve"
  out=$(run_pool "$case_dir" reserve) || fail "reserve: exited non-zero: $out"
  [ "$(grep -c '^destroy' "$case_dir/treehouse.log")" = 1 ] \
    || fail "reserve: expected one removal: $(cat "$case_dir/treehouse.log")"
  grep -Fxq "destroy $pool/3/app --yes" "$case_dir/treehouse.log" \
    || fail "reserve: did not remove the highest surplus slot with a plain destroy: $(cat "$case_dir/treehouse.log")"
  printf '%s\n' "$out" | grep -q "removed idle slot $pool/3/app" || fail "reserve: removal not reported: $out"
  pass "reserve keeps two idle reusable slots and removes the rest with a plain treehouse destroy"
}

test_reserve_zero_never_touches_held_or_stuck_slots() {
  local case_dir
  case_dir=$(make_case reserve-zero 10)
  printf '0\n' > "$case_dir/home/config/slot-idle-reserve"
  run_pool "$case_dir" reserve >/dev/null || fail "reserve-zero: exited non-zero"
  [ "$(grep -c '^destroy' "$case_dir/treehouse.log")" = 3 ] \
    || fail "reserve-zero: expected the three reusable slots only: $(cat "$case_dir/treehouse.log")"
  ! grep -Eq '^destroy .*/(4|5|6)/app' "$case_dir/treehouse.log" \
    || fail "reserve-zero: touched a stuck or held slot: $(cat "$case_dir/treehouse.log")"
  ! grep -q -- '--include' "$case_dir/treehouse.log" || fail "reserve-zero: passed an --include flag"
  pass "reserve never removes held, dirty, or unmerged slots"
}

test_reserve_rejects_invalid_config() {
  local case_dir rc=0
  case_dir=$(make_case reserve-bad 10)
  printf 'two\n' > "$case_dir/home/config/slot-idle-reserve"
  run_pool "$case_dir" reserve >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "reserve-bad: invalid config should exit 1"
  grep -q "non-negative integer" "$case_dir/stderr" || fail "reserve-bad: no diagnostic"
  ! grep -q '^destroy' "$case_dir/treehouse.log" || fail "reserve-bad: destroyed on invalid config"
  pass "reserve reports an invalid config/slot-idle-reserve and removes nothing"
}

test_census_counts_each_slot_condition
test_census_warns_when_free_room_is_low
test_reserve_is_off_without_config
test_reserve_removes_only_surplus_reusable_slots_safely
test_reserve_zero_never_touches_held_or_stuck_slots
test_reserve_rejects_invalid_config
