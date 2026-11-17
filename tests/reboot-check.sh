#!/usr/bin/env bash
# The reboot script a server with a reboot_check runs at reboot_time, with the
# check and systemctl replaced by stubs.
#
#   bash tests/reboot-check.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/reboot-check-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
printf '#!/bin/sh\necho "systemctl $*" >> "%s/calls"\n' "$work" > "$work/bin/systemctl"
chmod +x "$work/bin/systemctl"
sed -e "s#{{ reboot_check }}#sh -c 'exit \$CHECK_EXIT'#" \
  -e "s#/var/run/reboot-required#$work/reboot-required#" \
  "$REPO/ansible/roles/base/templates/dotfiles-reboot.j2" > "$work/reboot"
# run <check exit>: the script's output, with the check exiting that.
run() { rm -f "$work/calls"; CHECK_EXIT=$1 PATH="$work/bin:$PATH" sh "$work/reboot" 2>&1; }
rebooted() { grep -qx "systemctl reboot" "$work/calls" 2>/dev/null; }

section "the reboot script"
grep -q '{{' "$work/reboot" && fail "the test fills in every template value" "$(grep '{{' "$work/reboot")"

run 0 >/dev/null
rebooted && fail "no new kernel: no reboot" || pass "no new kernel: no reboot"

touch "$work/reboot-required"
run 0 >/dev/null
rebooted && pass "a new kernel and an idle server: reboots" || fail "a new kernel and an idle server: reboots"

out="$(run 1)"
if ! rebooted && grep -q "Trying again tomorrow" <<< "$out"; then
  pass "busy: waits a day"
else
  fail "busy: waits a day" "$out"
fi

out="$(run 2)"
if rebooted && grep -q "exit 2" <<< "$out"; then
  pass "a check that fails otherwise: reboots anyway"
else
  fail "a check that fails otherwise: reboots anyway" "$out"
fi

summary
