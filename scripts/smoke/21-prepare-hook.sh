#!/usr/bin/env bash
# The prepare hook in config.json gets the UDID of each new and erased device; one that fails removes the device and fails the command.
source "$(dirname "$0")/lib.sh"

config="$SIMCTLHOUSE_HOME/config.json"
err="$SMOKE_WORK/prepare.err"
# The tests share one home; leave no hook behind for the next one.
trap 'rm -f "$config"' EXIT
mkdir -p "$SIMCTLHOUSE_HOME"
cat >"$config" <<'EOF'
{ "hooks": { "prepare": { "command": "echo \"prepared [$SIMCTLHOUSE_UDID] $SIMCTLHOUSE_PREPARE_REASON\"" } } }
EOF

"$bin" delete --all --force >/dev/null 2>&1
udid="$("$bin" acquire --skip-boot --holder smoke-prepare 2>"$err")"
# The hook's output goes to stderr, so stdout is still the UDID alone.
[[ "$udid" =~ ^[0-9A-F-]{36}$ ]] || fail "acquire printed more than the UDID: $udid"
/usr/bin/grep -qxF "prepared [$udid] create" "$err" || fail "the hook did not print the new device's UDID $udid:"$'\n'"$(cat "$err")"
"$bin" release "$udid"

"$bin" erase "$udid" >/dev/null 2>"$err"
/usr/bin/grep -qxF "prepared [$udid] erase" "$err" || fail "the hook did not print the erased device's UDID $udid:"$'\n'"$(cat "$err")"

status=0
held="$("$bin" acquire --skip-boot --holder smoke-hold 2>/dev/null)"
out="$(SIMCTLHOUSE_PREPARE='exit 7' "$bin" acquire --skip-boot --holder smoke-prepare-fails 2>/dev/null)" || status=$?
"$bin" release "$held"
[[ "$status" -eq 1 ]] || fail "acquire with a failing hook exited with $status, expected 1."
[[ -z "$out" ]] || fail "acquire with a failing hook printed $out."
[[ "$(pool_size)" -eq 1 ]] || fail "the device the hook failed on is still in the pool:"$'\n'"$("$bin" list 2>&1)"

echo '{ "hook": {} }' >"$config"
status=0
"$bin" list >/dev/null 2>&1 || status=$?
[[ "$status" -eq 64 ]] || fail "list with an unknown key in config.json exited with $status, expected 64."
