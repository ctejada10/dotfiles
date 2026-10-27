#!/usr/bin/env bash
# Print the window label: SSH hostname when in an SSH session, otherwise the command name.
cmd="$1"
pid="$2"

if [ "$cmd" = "ssh" ]; then
    child=$(pgrep -P "$pid" 2>/dev/null | head -1)
    if [ -n "$child" ]; then
        # Extract the first non-flag argument after "ssh" (the host)
        host=$(ps -o args= -p "$child" 2>/dev/null \
            | awk '{for(i=2;i<=NF;i++){if($i!~/^-/){print $i;exit}}}' \
            | sed 's/.*@//')   # strip user@ prefix if present
        [ -n "$host" ] && echo "$host" && exit
    fi
    echo "ssh"
else
    echo "$cmd"
fi
