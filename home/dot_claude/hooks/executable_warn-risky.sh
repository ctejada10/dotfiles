#!/bin/bash
# PreToolUse advisory for Bash. Never blocks (always exit 0). Its warnings go out
# as additionalContext in one JSON object on stdout: stderr from a hook that
# exits 0 reaches nobody. Claude reads it with the tool's result, after the
# command has run: in time for an explanation like the pytest one, too late
# for advice. Those commands are gated elsewhere: on the laptop each has an ask
# or deny rule (when one matches, Claude Code builds the prompt from the rule
# and drops a hook's reason), and the mini denies gc, repack, prune and
# force-pushes and has no vault.

payload=$(cat)
cmd=$(printf '%s' "$payload" | /usr/bin/python3 -I -c \
  'import json,sys
try:
    print((json.load(sys.stdin).get("tool_input") or {}).get("command") or "")
except Exception:
    print("")' 2>/dev/null)

[ -z "$cmd" ] && exit 0
warnings=""
warn() { warnings="${warnings:+$warnings
}WARNING: $1"; }

case "$cmd" in
  *"git gc"*|*"git repack"*|*"git prune"*)
    warn "git gc/repack/prune rewrites the object store. Every repo here is under Dropbox CloudStorage and one object store has already been destroyed. Confirm com.dropbox.ignored is set on .git before running this." ;;
esac
case "$cmd" in
  *"push --force"*|*"push -f "*)
    warn "force-push. Check what you are overwriting on the remote first." ;;
esac
case "$cmd" in
  *armenelos*)
    case "$cmd" in
      rm\ *|*" rm "*|mv\ *|*" mv "*)
        warn "rm/mv inside the vault breaks inbound wikilinks. Use the Obsidian CLI move/rename so links update, and move unwanted notes to '00 Meta/08 Quarantine/' instead of deleting. The vault has no .trash and no git." ;;
    esac ;;
esac
case "$cmd" in
  *pytest*)
    case "$cmd" in
      *--no-cov*|*"make test"*) : ;;
      *tests/*|*-k\ *)
        warn "subset pytest run: hurin, rivendell and media-organizer weld --cov into addopts with a fail_under floor, so this will fail on coverage even if every test passes. Add --no-cov." ;;
    esac ;;
esac

# Nothing else on stdout: Claude Code reads it as one JSON object. -I keeps a
# json.py in the session's folder from standing in for the real one.
if [ -n "$warnings" ]; then
  printf '%s' "$warnings" | /usr/bin/python3 -I -c 'import json,sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": sys.stdin.read()}}))'
fi
exit 0
