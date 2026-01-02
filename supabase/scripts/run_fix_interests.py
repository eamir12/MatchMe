"""
Small script to fix parent_id and metadata in the interests table via Supabase REST using the provided service_role key.
Run it like:
  $env:SUPABASE_URL='https://<proj>.supabase.co'
  $env:SUPABASE_SERVICE_ROLE_KEY='<service_role_key>'
  python run_fix_interests.py

The script will:
 - GET all interests
 - Compute parent for orphans using longest-prefix heuristic
 - Compute type (intent/category/sub) and group (root key)
 - PATCH each changed row using the service role key
 - Print a short summary

Note: This script mutates production data. Use with caution and review the summary before/after.
"""

import os
import sys
import json
from urllib import request, parse

import argparse

parser = argparse.ArgumentParser()
parser.add_argument('--supabase-url', default=os.environ.get('SUPABASE_URL'))
parser.add_argument('--service-key', default=os.environ.get('SUPABASE_SERVICE_ROLE_KEY'))
args = parser.parse_args()

SUPABASE_URL = args.supabase_url
SERVICE_KEY = args.service_key

if not SUPABASE_URL or not SERVICE_KEY:
    print('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY (either via env or CLI args)')
    sys.exit(2)

headers = {
    'Authorization': f'Bearer {SERVICE_KEY}',
    'apikey': SERVICE_KEY,
    'Content-Type': 'application/json',
    'Prefer': 'return=representation'
}

def http_get(path):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    req = request.Request(url, headers=headers)
    req.get_method = lambda: 'GET'
    with request.urlopen(req) as res:
        return json.load(res)

def http_patch(path, body):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    data = json.dumps(body).encode('utf-8')
    req = request.Request(url, data=data, headers=headers)
    req.get_method = lambda: 'PATCH'
    with request.urlopen(req) as res:
        return res.read().decode('utf-8')

# 1) Fetch interests (all columns we need)
all_interests = http_get("interests?select=id,key,parent_id,metadata&order=id")
print(f"Fetched {len(all_interests)} interests")

# Build helper maps
id_by_key = {row['key']: row['id'] for row in all_interests}
row_by_id = {row['id']: row for row in all_interests}

# Helper: find root ancestor key for a row
def find_root_key(row):
    cur = row
    seen = set()
    while cur and cur.get('parent_id'):
        pid = cur['parent_id']
        if pid in seen:
            break
        seen.add(pid)
        cur = row_by_id.get(pid)
    return cur['key'] if cur else row['key']

# 2) Compute parent assignments using longest matching prefix
updates = []  # tuples (id, new_parent_id)
for row in all_interests:
    if row['parent_id'] is None:
        key = row['key']
        parts = key.split('_')
        # try longest prefix first (exclude full key)
        found = None
        for l in range(len(parts)-1, 0, -1):
            prefix = '_'.join(parts[:l])
            pid = id_by_key.get(prefix)
            if pid and pid != row['id']:
                found = pid
                break
        if found:
            updates.append({'id': row['id'], 'parent_id': found})

print(f"Computed {len(updates)} parent assignments (orphan -> parent)")

# Apply parent patches
applied = 0
for u in updates:
    body = {'parent_id': u['parent_id']}
    try:
        http_patch(f"interests?id=eq.{u['id']}", body)
        applied += 1
    except Exception as e:
        print('Patch failed for id', u['id'], str(e))

print(f"Applied {applied} parent updates")

# Re-fetch to pick up new parent_ids
all_interests = http_get("interests?select=id,key,parent_id,metadata&order=id")
id_by_key = {row['key']: row['id'] for row in all_interests}
row_by_id = {row['id']: row for row in all_interests}

# 3) Compute metadata updates (type and group)
meta_updates = []
for row in all_interests:
    meta = row.get('metadata') or {}
    changed = False
    # determine type
    if row['parent_id'] is None:
        if meta.get('type') != 'intent':
            meta['type'] = 'intent'
            changed = True
    else:
        parent = row_by_id.get(row['parent_id'])
        if parent and parent.get('parent_id') is None:
            desired = 'category'
        else:
            desired = 'sub'
        if meta.get('type') != desired:
            meta['type'] = desired
            changed = True
    # determine group (root key)
    root = find_root_key(row)
    if meta.get('group') != root:
        meta['group'] = root
        changed = True
    if changed:
        meta_updates.append({'id': row['id'], 'metadata': meta})

print(f"Computed {len(meta_updates)} metadata updates")

# Apply metadata patches in batches to avoid heavy payloads
applied = 0
for u in meta_updates:
    body = {'metadata': u['metadata']}
    try:
        http_patch(f"interests?id=eq.{u['id']}", body)
        applied += 1
    except Exception as e:
        print('Metadata patch failed for id', u['id'], str(e))

print(f"Applied {applied} metadata updates")

# 3b) Mark parent interests with is_social / is_business in metadata
# Parent interests are those that have at least one child (child.parent_id == parent.id)
parent_ids = set([r['parent_id'] for r in all_interests if r.get('parent_id') is not None])
parent_meta_updates = []
for pid in parent_ids:
    p = row_by_id.get(pid)
    if not p:
        continue
    meta = p.get('metadata') or {}
    # determine group
    grp = meta.get('group') or find_root_key(p)
    changed = False
    if grp == 'business_networking' or p.get('key') == 'business':
        if meta.get('is_business') is not True:
            meta['is_business'] = True
            changed = True
        if meta.get('is_social') is True:
            meta.pop('is_social', None)
            changed = True
    else:
        if meta.get('is_social') is not True:
            meta['is_social'] = True
            changed = True
        if meta.get('is_business') is True:
            meta.pop('is_business', None)
            changed = True
    if changed:
        parent_meta_updates.append({'id': pid, 'metadata': meta})

print(f"Computed {len(parent_meta_updates)} parent metadata flag updates")

applied = 0
for u in parent_meta_updates:
    body = {'metadata': u['metadata']}
    try:
        http_patch(f"interests?id=eq.{u['id']}", body)
        applied += 1
    except Exception as e:
        print('Parent metadata patch failed for id', u['id'], str(e))

print(f"Applied {applied} parent metadata updates")


# 4) Final verification (local checks)
summary = {}
summary['total_interests'] = len(all_interests)
missing = [r for r in all_interests if ((r.get('metadata') or {}).get('group') is None) or ((r.get('metadata') or {}).get('type') is None)]
summary['interests_missing_metadata'] = len(missing)

print('\nSummary:')
for k,v in summary.items():
    print(f"  {k}: {v}")

if len(missing) > 0:
    print('\nSample missing metadata rows (up to 20):')
    for r in missing[:20]:
        print(r)

print('\nDone')
