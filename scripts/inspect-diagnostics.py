#!/usr/bin/env python3
"""Inspect Debug and Release JSONL journals without launching DropPoint."""
import argparse
from collections import defaultdict
from datetime import datetime
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--directory', type=Path, default=Path.home() / 'Library/Logs/DropPoint')
parser.add_argument('--session')
parser.add_argument('--category')
parser.add_argument('--last', type=int, default=50)
parser.add_argument('--summary', action='store_true')
args = parser.parse_args()
entries = []
for file in args.directory.glob('*.jsonl'):
    for line in file.read_text(errors='replace').splitlines():
        try:
            entry = json.loads(line)
            if args.session and entry.get('session') != args.session: continue
            if args.category and entry.get('category') != args.category: continue
            entries.append(entry)
        except json.JSONDecodeError:
            pass  # An interrupted final line must not hide earlier diagnostics.
entries.sort(key=lambda e: e.get('timestamp', 0))
if args.summary:
    sessions = defaultdict(list)
    for e in entries: sessions[e.get('session', 'unknown')].append(e)
    for session, events in sessions.items():
        context = events[0].get('context', {})
        ended = any(e.get('event') == 'application-terminate-normal' for e in events)
        print(json.dumps({'session': session, **context, 'events': len(events),
                          'lastEvent': events[-1].get('event'), 'normalExitRecorded': ended}, ensure_ascii=False))
else:
    for e in entries[-max(0, args.last):]:
        stamp = datetime.fromtimestamp(e.get('timestamp', 0)).astimezone().isoformat(timespec='milliseconds')
        print(stamp, e.get('pid'), e.get('session'), e.get('category'), e.get('event'),
              json.dumps(e.get('fields', {}), ensure_ascii=False))
