#!/usr/bin/env bash
# The Dock arranger: a made-up Dock in, the arranged one out, and nothing out
# once it's arranged. Never reads or writes this Mac's Dock.
#
#   bash tests/dock.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

dock=$REPO/home/.chezmoitemplates/dock.py
T=$(mktemp -d "${TMPDIR:-/tmp}/dock-test.XXXXXX")

# A Dock out of order, with apps outside the groups, a big spacer and an app
# found only by its path.
python3 -I - "$T/before.plist" <<'PY'
import plistlib, sys
def app(bundle, name):
    td = {'file-data': {'_CFURLString': f'file:///Applications/{name.replace(" ", "%20")}/', '_CFURLStringType': 15}}
    if bundle: td['bundle-identifier'] = bundle
    return {'tile-data': td, 'tile-type': 'file-tile'}
apps = [app('com.apple.Safari', 'Safari.app'), app('com.mitchellh.ghostty', 'Ghostty.app'),
        {'tile-data': {}, 'tile-type': 'spacer-tile'}, app('md.obsidian', 'Obsidian.app'),
        app('company.thebrowser.dia', 'Dia.app'), app('com.apple.mail', 'Mail.app'),
        app(None, 'T3 Code (Beta).app'), app('com.tinyspeck.slackmacgap', 'Slack.app')]
plistlib.dump({'persistent-apps': apps, 'tilesize': 36}, open(sys.argv[1], 'wb'))
PY

order() {
  python3 -I -c 'import plistlib, sys
for a in plistlib.load(sys.stdin.buffer)["persistent-apps"]:
    td = a["tile-data"]
    print(td.get("bundle-identifier") or td.get("file-data", {}).get("_CFURLString") or a["tile-type"])'
}

section "dock.py"
python3 -I "$dock" < "$T/before.plist" > "$T/after.plist"
want="company.thebrowser.dia
small-spacer-tile
com.tinyspeck.slackmacgap
com.apple.mail
small-spacer-tile
file:///Applications/T3%20Code%20(Beta).app/
com.mitchellh.ghostty
small-spacer-tile
md.obsidian"
got=$(order < "$T/after.plist")
[ "$got" = "$want" ] && pass "puts the groups in order, split by small spacers, and drops the rest" \
  || fail "puts the groups in order, split by small spacers, and drops the rest" "$got"
python3 -I -c 'import plistlib, sys; sys.exit(plistlib.load(sys.stdin.buffer).get("tilesize") != 36)' < "$T/after.plist" \
  && pass "keeps the Dock's other settings" || fail "keeps the Dock's other settings"

# The Dock gives each spacer a GUID once it has loaded them, which mustn't
# count as out of order.
python3 -I - "$T/after.plist" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
for i, a in enumerate(d['persistent-apps']): a['GUID'] = i
plistlib.dump(d, open(sys.argv[1], 'wb'))
PY
out=$(python3 -I "$dock" < "$T/after.plist") && [ -z "$out" ] \
  && pass "writes nothing for a Dock already arranged" || fail "writes nothing for a Dock already arranged"

rm -rf "$T"
summary
