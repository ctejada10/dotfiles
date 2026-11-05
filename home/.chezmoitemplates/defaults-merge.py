# Writes wanted values into a defaults domain. Reads the domain's plist on
# stdin and the wanted plist from the first argument, and writes the merged
# plist to stdout, or nothing when every wanted value is already there.
# Dictionaries merge key by key, so keys the app adds itself are left alone;
# any other value, lists included, is replaced whole.
import plistlib, sys

def merge(now, want):
    changed = False
    for k, v in want.items():
        if isinstance(v, dict) and isinstance(now.get(k), dict):
            changed |= merge(now[k], v)
        elif k not in now or now[k] != v:
            now[k] = v
            changed = True
    return changed

data = plistlib.loads(sys.stdin.buffer.read())
if merge(data, plistlib.loads(sys.argv[1].encode())):
    sys.stdout.buffer.write(plistlib.dumps(data))
