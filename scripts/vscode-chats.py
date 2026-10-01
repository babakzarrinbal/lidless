#!/usr/bin/env python3
# Usage: python3 scripts/vscode-chats.py
# Counts VS Code's Copilot Chat conversations per window and says which ones
# the agent can't list (no folder, multi-root workspace, remote window). Read
# only; prints folder names and counts, never the chats themselves.
import glob, json, os, urllib.parse
from collections import Counter

sup = os.path.expanduser('~/Library/Application Support')

def prompts(f):
    reqs = []
    try:
        if f.endswith('.json'):
            return sum(1 for r in json.load(open(f)).get('requests', []) if (r.get('message') or {}).get('text', '').strip())
        for line in open(f):
            try: e = json.loads(line)
            except ValueError: continue
            if e.get('kind') == 0: reqs = list((e.get('v') or {}).get('requests', []))
            elif e.get('kind') == 2 and e.get('k') == ['requests']:
                if e.get('i') is not None: reqs = reqs[:e['i']]
                reqs += e.get('v') or []
    except Exception:
        return 0
    return sum(1 for r in reqs if (r.get('message') or {}).get('text', '').strip())

rows = Counter()
for app in ('Code', 'Code - Insiders'):
    user = os.path.join(sup, app, 'User')
    for ws in glob.glob(os.path.join(user, 'workspaceStorage', '*')):
        files = [f for f in glob.glob(os.path.join(ws, 'chatSessions', '*')) if f.endswith(('.json', '.jsonl'))]
        if not files: continue
        try: w = json.load(open(os.path.join(ws, 'workspace.json')))
        except Exception: w = {}
        if 'folder' in w:
            u = urllib.parse.urlparse(w['folder'])
            where = urllib.parse.unquote(u.path) if u.scheme == 'file' and not u.netloc else 'REMOTE ' + u.scheme + ':' + u.netloc
        elif 'workspace' in w:
            where = 'MULTI-ROOT ' + os.path.basename(urllib.parse.unquote(urllib.parse.urlparse(w['workspace']).path))
        else:
            where = 'NO FOLDER (workspace.json missing)'
        for f in files:
            rows[(where, 'said' if prompts(f) else 'empty')] += 1
    for f in glob.glob(os.path.join(user, 'globalStorage', 'emptyWindowChatSessions', '*.json*')):
        rows[('NO FOLDER (empty window)', 'said' if prompts(f) else 'empty')] += 1

for where in sorted({w for w, _ in rows}):
    print(f"{rows[(where, 'said')]:4} chats ({rows[(where, 'empty')]} empty)  {where.replace(os.path.expanduser('~'), '~')}")
