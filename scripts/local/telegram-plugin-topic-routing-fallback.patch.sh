#!/usr/bin/env bash
# Patch: Telegram plugin topic-routing fallback enrichment
# The Telegram plugin routes notifications to forum topics by reading
# `payload.projectName` from each plugin event, but older server builds (or
# unexpected call paths) may emit events without projectName. This patch adds
# a best-effort enrichment step in notify() that resolves projectName by
# fetching the entity → project via ctx.issues.get + ctx.projects.get.
#
# Also adds the `projects.read` capability to the plugin manifest, which is
# required at runtime before ctx.projects.get() can be called.

set -euo pipefail

TARGET_WORKER="/home/abekarar/.paperclip/plugins/node_modules/paperclip-plugin-telegram/dist/worker.js"
TARGET_MANIFEST="/home/abekarar/.paperclip/plugins/node_modules/paperclip-plugin-telegram/dist/manifest.js"

if [ ! -f "$TARGET_WORKER" ] || [ ! -f "$TARGET_MANIFEST" ]; then
  echo "Telegram plugin not installed — skipping patch"
  exit 0
fi

if grep -q "Fallback: derive projectName from entity" "$TARGET_WORKER" 2>/dev/null \
  && grep -q '"projects.read"' "$TARGET_MANIFEST" 2>/dev/null; then
  echo "Patch already applied"
  exit 0
fi

python3 << 'PY'
worker_path = "/home/abekarar/.paperclip/plugins/node_modules/paperclip-plugin-telegram/dist/worker.js"
manifest_path = "/home/abekarar/.paperclip/plugins/node_modules/paperclip-plugin-telegram/dist/manifest.js"

# ---- Patch 1: manifest — add projects.read capability ----
with open(manifest_path, 'r') as f:
    manifest = f.read()

manifest_old = '        "issues.read",\n        "issues.create",'
manifest_new = '        "issues.read",\n        "projects.read",\n        "issues.create",'

if '"projects.read"' in manifest:
    print("Manifest patch: already has projects.read")
elif manifest_old in manifest:
    manifest = manifest.replace(manifest_old, manifest_new)
    with open(manifest_path, 'w') as f:
        f.write(manifest)
    print("Manifest patch: applied (added projects.read capability)")
else:
    print("Manifest patch: WARN — expected pattern not found, capability not added")

# ---- Patch 2: worker.js — fallback enrichment in notify() ----
with open(worker_path, 'r') as f:
    worker = f.read()

worker_old = """            let messageThreadId;
            if (config.topicRouting) {
                const payload = event.payload;
                const projectName = payload.projectName ? String(payload.projectName) : undefined;
                messageThreadId = await getTopicForProject(ctx, chatId, projectName);
            }"""

worker_new = """            let messageThreadId;
            if (config.topicRouting) {
                const payload = event.payload;
                // Fallback: derive projectName from entity if server didn't supply it.
                if (!payload.projectName) {
                    try {
                        let _pId = payload.projectId ? String(payload.projectId) : undefined;
                        if (!_pId) {
                            if (event.entityType === "issue" && event.entityId) {
                                const _iss = await ctx.issues.get(event.entityId, event.companyId);
                                _pId = _iss && _iss.projectId ? String(_iss.projectId) : undefined;
                            } else if (Array.isArray(payload.issueIds) && payload.issueIds[0]) {
                                const _linked = await ctx.issues.get(String(payload.issueIds[0]), event.companyId);
                                _pId = _linked && _linked.projectId ? String(_linked.projectId) : undefined;
                            }
                        }
                        if (_pId) {
                            const _proj = await ctx.projects.get(_pId, event.companyId);
                            if (_proj && _proj.name) payload.projectName = _proj.name;
                        }
                    } catch (_) { /* best effort */ }
                }
                const projectName = payload.projectName ? String(payload.projectName) : undefined;
                messageThreadId = await getTopicForProject(ctx, chatId, projectName);
            }"""

if "Fallback: derive projectName from entity" in worker:
    print("Worker patch: already applied")
elif worker_old in worker:
    worker = worker.replace(worker_old, worker_new)
    with open(worker_path, 'w') as f:
        f.write(worker)
    print("Worker patch: applied (fallback enrichment in notify())")
else:
    print("Worker patch: WARN — expected pattern not found, enrichment not added")
PY

echo "Telegram plugin patched (topic-routing fallback)"
