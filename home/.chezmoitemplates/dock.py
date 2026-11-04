# Arranges the Dock's apps into groups split by small spacers. Reads the
# com.apple.dock plist on stdin and writes the arranged one to stdout, or
# nothing when it's already arranged. Only apps already in the Dock are
# placed; any other app comes out of it.
import os, plistlib, sys

data = plistlib.loads(sys.stdin.buffer.read())
apps = data.get('persistent-apps', [])
def keys(a):
    td = a.get('tile-data', {}); k = set()
    if td.get('bundle-identifier'): k.add(td['bundle-identifier'].lower())
    url = td.get('file-data', {}).get('_CFURLString', '')
    if url: k.add(os.path.basename(url.rstrip('/')).replace('%20',' ').lower())
    return k
groups = [
    [('company.thebrowser.dia','Dia.app')],
    [('com.tinyspeck.slackmacgap','Slack.app'), ('com.apple.MobileSMS','Messages.app'),
     ('com.apple.mail','Mail.app'), ('com.automattic.beeper.desktop','Beeper Desktop.app')],
    [('com.t3tools.t3code','T3 Code (Beta).app'), ('com.mitchellh.ghostty','Ghostty.app')],
    [('md.obsidian','Obsidian.app'), ('com.flexibits.fantastical2.mac','Fantastical.app'), ('com.todoist.mac.Todoist','Todoist.app')],
]
pool = [a for a in apps if a.get('tile-type') not in ('spacer-tile','small-spacer-tile')]
new, used = [], []
for g in groups:
    items = []
    for b, f in g:
        for a in pool:
            if a not in used and ({b.lower(), f.lower()} & keys(a)):
                items.append(a); used.append(a); break
    if not items: continue
    if new: new.append({'tile-data': {}, 'tile-type': 'small-spacer-tile'})
    new += items
# Compared by kind and app, not whole tiles: the Dock adds a GUID to each.
sig = lambda tiles: [(a.get('tile-type'), sorted(keys(a))) for a in tiles]
if sig(new) != sig(apps):
    data['persistent-apps'] = new
    sys.stdout.buffer.write(plistlib.dumps(data))
