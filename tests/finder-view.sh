#!/usr/bin/env bash
# Finder's view settings: the merger writes the wanted values into a made-up
# Finder plist and leaves the rest alone, and the saved settings hold nothing
# tied to one Mac. Never reads or writes this Mac's Finder.
#
#   bash tests/finder-view.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

merge=$REPO/home/.chezmoitemplates/defaults-merge.py
saved=$REPO/home/.chezmoitemplates/finder-view.plist
T=$(mktemp -d "${TMPDIR:-/tmp}/finder-view-test.XXXXXX")

python3 -I - "$T/now.plist" "$T/want.plist" <<'PY'
import plistlib, sys
now = {'FXRecentFolders': ['kept'], 'FXPreferredViewStyle': 'icnv',
       'StandardViewSettings': {'ListViewSettings': {'textSize': 13.0, 'scrollPositionX': -1.0},
                                'IconViewSettings': {'iconSize': 64.0}}}
want = {'FXPreferredViewStyle': 'clmv', 'ShowStatusBar': True,
        'StandardViewSettings': {'ListViewSettings': {'textSize': 11.0}}}
plistlib.dump(now, open(sys.argv[1], 'wb'))
plistlib.dump(want, open(sys.argv[2], 'wb'))
PY

section "defaults-merge.py"
python3 -I "$merge" "$(cat "$T/want.plist")" < "$T/now.plist" > "$T/after.plist"
python3 -I - "$T/after.plist" <<'PY' && pass "writes the wanted values, nested ones too" || fail "writes the wanted values, nested ones too"
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
sys.exit(not (d['FXPreferredViewStyle'] == 'clmv' and d['ShowStatusBar'] is True
              and d['StandardViewSettings']['ListViewSettings']['textSize'] == 11.0))
PY
python3 -I - "$T/after.plist" <<'PY' && pass "leaves every other key alone" || fail "leaves every other key alone"
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
s = d['StandardViewSettings']
sys.exit(not (d['FXRecentFolders'] == ['kept'] and s['ListViewSettings']['scrollPositionX'] == -1.0
              and s['IconViewSettings']['iconSize'] == 64.0))
PY
out=$(python3 -I "$merge" "$(cat "$T/want.plist")" < "$T/after.plist") && [ -z "$out" ] \
  && pass "writes nothing when Finder already has the values" || fail "writes nothing when Finder already has the values"

section "the saved settings"
grep -qE 'WindowBounds|scrollPosition' "$saved" \
  && fail "hold no window positions or scroll offsets" || pass "hold no window positions or scroll offsets"
# Set by its own line in the settings script; set here too, the two could disagree.
grep -q '<key>_FXSortFoldersFirst</key>' "$saved" \
  && fail "leave _FXSortFoldersFirst to its own line" || pass "leave _FXSortFoldersFirst to its own line"

rm -rf "$T"
summary
