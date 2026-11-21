#!/usr/bin/env python3
"""Hermes's script for the rivendell-state webhook route.

Rivendell's hermes-relay posts a snapshot of its records and services here.
This stores it as ~/.hermes/rivendell/state.json for the rivendell-events skill
and prints [SILENT], so Hermes starts no agent run and sends no message. Bad
input, a snapshot over MAX_BYTES, or one older than the stored one is logged
to stderr and dropped, and the last snapshot stays.
"""

import json
import os
import sys
import tempfile
from pathlib import Path

# Hermes runs route scripts only from HERMES_HOME/scripts and may remap HOME,
# so the state folder is found from here.
STATE_DIR = Path(__file__).resolve().parent.parent / "rivendell"
# The relay sends at most 256 KiB; the skill reads the whole file into context.
MAX_BYTES = 256 * 1024


def problem(snapshot):
    if not isinstance(snapshot, dict):
        return "not a JSON object"
    if not isinstance(snapshot.get("generated_at"), str):
        return "generated_at is missing or not a string"
    if not isinstance(snapshot.get("records"), list):
        return "records is missing or not a list"
    return None


def stored_at():
    """The stored snapshot's generated_at, or None."""
    try:
        return json.loads((STATE_DIR / "state.json").read_text()).get("generated_at")
    except (OSError, ValueError, RecursionError, AttributeError):
        return None


def store(snapshot: dict) -> None:
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    STATE_DIR.chmod(0o700)
    # mkstemp creates the file 0600; the rename makes the write all or nothing.
    fd, tmp = tempfile.mkstemp(dir=STATE_DIR, prefix=".state.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(snapshot, out)
        os.replace(tmp, STATE_DIR / "state.json")
    except BaseException:
        os.unlink(tmp)
        raise


def main() -> None:
    raw = sys.stdin.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        print(f"rivendell-state: dropped, over {MAX_BYTES} bytes", file=sys.stderr)
        return
    try:
        snapshot = json.loads(raw)
    except (ValueError, RecursionError) as exc:
        print(f"rivendell-state: dropped, not JSON: {type(exc).__name__}", file=sys.stderr)
        return
    if why := problem(snapshot):
        print(f"rivendell-state: dropped, {why}", file=sys.stderr)
        return
    # The relay's times are fixed-width UTC, so they sort as strings. A late or
    # replayed post must not roll the state back.
    last = stored_at()
    if isinstance(last, str) and snapshot["generated_at"] < last:
        print("rivendell-state: dropped, older than the stored snapshot", file=sys.stderr)
        return
    try:
        store(snapshot)
    except OSError as exc:
        print(f"rivendell-state: couldn't store the snapshot: {exc}", file=sys.stderr)


if __name__ == "__main__":
    main()
    print("[SILENT]")
