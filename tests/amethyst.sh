#!/usr/bin/env bash
# Amethyst's config and the macOS shortcuts it leans on: every key bound once,
# no built-in key left to come back, every layout it names exists, and the
# Switch to Desktop shortcuts match the Spaces it throws windows to. Then the
# layouts' log lines and Hammerspoon's keys and defaults agree with it. Reads
# only this repo.
#
#   bash tests/amethyst.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

config=$REPO/home/dot_amethyst.yml
layouts=$REPO/home/private_Library/private_Application\ Support/Amethyst/Layouts
hotkeys=$REPO/home/.chezmoitemplates/symbolic-hotkeys.plist

section "amethyst.yml"
# The commands Amethyst gives a key of its own (Amethyst/default.amethyst).
# Left out of the config, each would come back with the config's modifiers.
builtin="cycle-layout cycle-layout-backward select-tall-layout select-wide-layout
select-fullscreen-layout select-column-layout focus-screen-ccw focus-screen-cw
focus-screen-1 focus-screen-2 focus-screen-3 focus-screen-4 focus-screen-5
throw-screen-1 throw-screen-2 throw-screen-3 throw-screen-4 throw-screen-5
shrink-main expand-main increase-main decrease-main focus-ccw focus-cw focus-main
swap-screen-ccw swap-screen-cw swap-ccw swap-cw swap-main throw-space-1
throw-space-2 throw-space-3 throw-space-4 throw-space-5 throw-space-6
throw-space-7 throw-space-8 throw-space-9 throw-space-10 throw-space-left
throw-space-right toggle-float toggle-tiling display-current-layout
reevaluate-windows toggle-focus-follows-mouse relaunch-amethyst"

out=$(python3 -I - "$config" "$layouts" "$builtin" <<'PY'
import os, re, sys
from collections import Counter
# A flat YAML file: top-level keys, each a scalar, a list or a mod/key pair.
conf, cur = {}, None
for line in open(sys.argv[1]):
    line = line.split(' #')[0].rstrip()
    if not line or line.startswith('#'): continue
    m = re.match(r'^([a-z0-9-]+):\s*(.*)$', line)
    if m:
        cur = m.group(1); conf[cur] = m.group(2) or {}
        continue
    m = re.match(r'^\s+(mod|key):\s*(.+)$', line)
    if m and isinstance(conf[cur], dict):
        conf[cur][m.group(1)] = m.group(2).strip("'\""); continue
    m = re.match(r'^\s+-\s*(.+)$', line)
    if m:
        conf[cur] = (conf[cur] if isinstance(conf[cur], list) else []) + [m.group(1)]
bound = {k: v for k, v in conf.items() if isinstance(v, dict) and 'key' in v}
dupes = [f'{m}+{k}' for (m, k), n in Counter((v['mod'], v['key']) for v in bound.values()).items() if n > 1]
print('dupes=' + ' '.join(dupes))
print('leaks=' + ' '.join(c for c in sys.argv[3].split() if c not in conf))
builtin = {'tall', 'tall-right', 'wide', 'two-pane', 'two-pane-right', '3column-left', 'middle-wide',
           '3column-right', '4column-left', '4column-right', 'fullscreen', 'column', 'row', 'floating',
           'widescreen-tall', 'widescreen-tall-right', 'bsp'}
custom = {f[:-3] for f in os.listdir(sys.argv[2]) if f.endswith('.js')}
print('unknown=' + ' '.join(l for l in conf.get('layouts', []) if l not in builtin | custom))
print('selects=' + ' '.join(k[7:-7] for k in bound if k.startswith('select-') and k[7:-7] not in conf.get('layouts', [])))
print('spaces=' + ' '.join(f"{k[12:]}:{v['key']}" for k, v in bound.items() if re.match(r'throw-space-\d+$', k)))
PY
)
val() { sed -n "s/^$1=//p" <<< "$out"; }
[ -z "$(val dupes)" ] && pass "binds every key once" || fail "binds every key once" "$(val dupes)"
[ -z "$(val leaks)" ] && pass "leaves no built-in key to come back" || fail "leaves no built-in key to come back" "$(val leaks)"
[ -z "$(val unknown)" ] && pass "names only layouts that exist" || fail "names only layouts that exist" "$(val unknown)"
[ -z "$(val selects)" ] && pass "has a key only for layouts in its list" || fail "has a key only for layouts in its list" "$(val selects)"

section "the layouts, Hammerspoon and the HUD"
# Every layout is custom and reports itself in Amethyst's log under its own
# key, and Hammerspoon presses the same keys amethyst.yml binds. The HUD that
# draws them is in the scripts repo, interfaces/layout-hud.
hud=$(python3 -I - "$config" "$layouts" "$REPO/home/dot_hammerspoon/amethyst-hud.lua" <<'PY'
import os, re, sys
conf = open(sys.argv[1]).read()
listed = re.search(r'^layouts:\n((?:  - .+\n)+)', conf, re.M).group(1).split()[1::2]
binds = dict(re.findall(r'^select-([a-z0-9-]+)-layout:\n  mod: mod1\n  key: (\S+)', conf, re.M))
files = [f[:-3] for f in os.listdir(sys.argv[2]) if f.endswith('.js')]
print('silent=' + ' '.join(f for f in files
                           if f'report("{f}"' not in open(os.path.join(sys.argv[2], f + '.js')).read()))
print('builtin=' + ' '.join(l for l in listed if l not in files))
lua = open(sys.argv[3]).read()
keys = dict(re.findall(r'\[?"?([a-z0-9-]+)"?\]? = "([a-z])"', re.search(r'local KEYS = \{(.*?)\}', lua).group(1)))
print('keys=' + ' '.join(f'{l}:{keys.get(l)}/{binds.get(l)}' for l in listed if keys.get(l) != binds.get(l)))
defaults = re.findall(r'"([a-z0-9-]+)"', re.search(r'M\.defaults = \{(.*?)\n\}', lua, re.S).group(1))
print('defaults=' + ' '.join(sorted(set(d for d in defaults if d not in listed))))
PY
)
for check in "silent:reports itself in Amethyst's log under its own key" \
             "builtin:is a custom layout, so it reports itself" \
             "keys:has Hammerspoon pressing the key amethyst.yml binds" \
             "defaults:has a default that's in amethyst.yml's list"; do
  name=${check%%:*}; what=${check#*:}
  got=$(sed -n "s/^$name=//p" <<< "$hud")
  [ -z "$got" ] && pass "every layout $what" || fail "every layout $what" "$got"
done

section "the Switch to Desktop shortcuts"
# Desktop n is symbolic hot key 117 + n.
desktops=$(python3 -I - "$hotkeys" <<'PY'
import plistlib, sys
hk = plistlib.load(open(sys.argv[1], 'rb'))['AppleSymbolicHotKeys']
print(' '.join(str(int(k) - 117) for k, v in sorted(hk.items(), key=lambda kv: int(kv[0]))
               if 118 <= int(k) <= 133 and v['enabled']))
print('off' if hk.get('61', {}).get('enabled') is False else 'on')
PY
)
want=$(val spaces | tr ' ' '\n' | cut -d: -f1 | sort -n | xargs)
[ "$(head -1 <<< "$desktops")" = "$want" ] && pass "turn on a shortcut for each Space Amethyst throws to" \
  || fail "turn on a shortcut for each Space Amethyst throws to" "on: $(head -1 <<< "$desktops"); throws to: $want"
[ "$(tail -1 <<< "$desktops")" = off ] && pass "turn off ⌃⌥Space for input sources" || fail "turn off ⌃⌥Space for input sources"

summary
