# Finder's sidebar Favorites, through Launch Services' shared file list API:
# deprecated, but the only way to change the list, which sits in a folder
# only Full Disk Access can read.
#   sidebar.py list          prints the Favorites, one per line
#   sidebar.py check PATH... prints what would change, or nothing
#   sidebar.py set PATH...   makes the folders in the Favorites exactly these,
#                            in this order, and prints what it changed
# Paths may start with ~/. A path that doesn't exist on this Mac is skipped.
# Items that aren't folders or files, such as AirDrop, are left alone.
import ctypes, os, sys
from ctypes import c_void_p, c_uint32, c_int32, c_long, c_char_p, c_bool, POINTER

HOME = os.path.expanduser('~')

def short(path):
    return '~' + path[len(HOME):] if path == HOME or path.startswith(HOME + '/') else path

def wanted(paths):
    return [os.path.realpath(os.path.expanduser(p)) for p in paths if os.path.exists(os.path.expanduser(p))]

class Favorites:
    def __init__(self):
        cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        cs = ctypes.CDLL('/System/Library/Frameworks/CoreServices.framework/CoreServices')
        for name, res, args in [
            ('CFRelease', None, [c_void_p]),
            ('CFArrayGetCount', c_long, [c_void_p]),
            ('CFArrayGetValueAtIndex', c_void_p, [c_void_p, c_long]),
            ('CFURLCreateFromFileSystemRepresentation', c_void_p, [c_void_p, c_char_p, c_long, c_bool]),
            ('CFURLGetFileSystemRepresentation', c_bool, [c_void_p, c_bool, c_char_p, c_long]),
            ('CFURLGetString', c_void_p, [c_void_p]),
            ('CFStringGetCString', c_bool, [c_void_p, c_char_p, c_long, c_uint32]),
        ]:
            f = getattr(cf, name); f.restype, f.argtypes = res, args
        for name, res, args in [
            ('LSSharedFileListCreate', c_void_p, [c_void_p, c_void_p, c_void_p]),
            ('LSSharedFileListCopySnapshot', c_void_p, [c_void_p, POINTER(c_uint32)]),
            ('LSSharedFileListItemCopyResolvedURL', c_void_p, [c_void_p, c_uint32, c_void_p]),
            ('LSSharedFileListInsertItemURL', c_void_p, [c_void_p, c_void_p, c_void_p, c_void_p, c_void_p, c_void_p, c_void_p]),
            ('LSSharedFileListItemRemove', c_int32, [c_void_p, c_void_p]),
        ]:
            f = getattr(cs, name); f.restype, f.argtypes = res, args
        self.cf, self.cs = cf, cs
        # kLSSharedFileListItemLast is a marker pointer, never an object.
        self.last = c_void_p.in_dll(cs, 'kLSSharedFileListItemLast').value
        self.list = cs.LSSharedFileListCreate(None, c_void_p.in_dll(cs, 'kLSSharedFileListFavoriteItems').value, None)
        if not self.list:
            sys.exit('sidebar.py: could not open the Favorites list')

    def items(self):
        """(item, path or URL, is a file) for each item, in order."""
        cf, cs, out = self.cf, self.cs, []
        snap = cs.LSSharedFileListCopySnapshot(self.list, ctypes.byref(c_uint32()))
        buf = ctypes.create_string_buffer(4096)
        for i in range(cf.CFArrayGetCount(snap) if snap else 0):
            item = cf.CFArrayGetValueAtIndex(snap, i)
            url = cs.LSSharedFileListItemCopyResolvedURL(item, 3, None)  # no UI, no mounting
            if not url:
                out.append((item, '?', False))
                continue
            if cf.CFURLGetFileSystemRepresentation(url, True, buf, len(buf)):
                out.append((item, buf.value.decode(), True))
            elif cf.CFStringGetCString(cf.CFURLGetString(url), buf, len(buf), 0x08000100):
                out.append((item, buf.value.decode(), False))
            cf.CFRelease(url)
        self.snap = snap  # keeps the items alive until the next snapshot
        return out

    def remove(self, item):
        return self.cs.LSSharedFileListItemRemove(self.list, item) == 0

    def add(self, path):
        raw = path.encode()
        url = self.cf.CFURLCreateFromFileSystemRepresentation(None, raw, len(raw), os.path.isdir(path))
        item = self.cs.LSSharedFileListInsertItemURL(self.list, self.last, None, None, url, None, None)
        self.cf.CFRelease(url)
        if item:
            self.cf.CFRelease(item)
        return bool(item)

def main(argv):
    if not argv or argv[0] not in ('list', 'check', 'set'):
        sys.exit('usage: sidebar.py list|check|set [PATH...]')
    fav = Favorites()
    items = fav.items()
    if argv[0] == 'list':
        for _, where, is_file in items:
            print(short(where) if is_file else where)
        return 0
    now = [where for _, where, is_file in items if is_file]
    want = wanted(argv[1:])
    if now == want:
        return 0
    print('Favorites: ' + ', '.join(map(short, now)) + ' -> ' + ', '.join(map(short, want)))
    if argv[0] == 'check':
        return 0
    # Out of order or not the same folders: all out, then back in order.
    failed = [p for item, p, is_file in items if is_file and not fav.remove(item)]
    failed += [p for p in want if not fav.add(p)]
    if failed:
        print('sidebar.py: FAILED for ' + ', '.join(map(short, failed)), file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
