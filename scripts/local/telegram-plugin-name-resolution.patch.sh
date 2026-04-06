#!/usr/bin/env bash
# Patch: Telegram plugin name-based agent resolution
# The published paperclip-plugin-telegram@0.2.4 calls ctx.agents.get(name, companyId)
# which fails because the API expects a UUID. This patch adds name-to-UUID
# resolution via ctx.agents.list before falling back to ACP mode.

set -euo pipefail

TARGET="/home/abekarar/.paperclip/plugins/node_modules/paperclip-plugin-telegram/dist/acp-bridge.js"
if [ ! -f "$TARGET" ]; then
  echo "Telegram plugin not installed — skipping patch"
  exit 0
fi

if grep -q "Try UUID lookup first, then name lookup via agents.list" "$TARGET" 2>/dev/null; then
  echo "Patch already applied"
  exit 0
fi

python3 << 'PY'
path = "/home/abekarar/.paperclip/plugins/node_modules/paperclip-plugin-telegram/dist/acp-bridge.js"
with open(path, 'r') as f:
    content = f.read()

# Patch 1: handleAcpSpawn (main path)
old1 = """    try {
        const agent = await ctx.agents.get(trimmedName, resolvedCompanyId);
        if (agent) {
            // Native Paperclip agent - create a session
            agentId = agent.id;
            const session = await ctx.agents.sessions.create(agentId, resolvedCompanyId, {
                reason: `Telegram thread ${chatId}/${messageThreadId}`,
            });
            sessionId = session.sessionId;
            transport = "native";
            ctx.logger.info("Created native agent session", { agentId, sessionId });
        }
        else {
            sessionId = `acp_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
        }
    }
    catch {
        // Agent not found in Paperclip - fall back to ACP"""
new1 = """    try {
        // Try UUID lookup first, then name lookup via agents.list
        let agent = null;
        const isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(trimmedName);
        if (isUuid) {
            try { agent = await ctx.agents.get(trimmedName, resolvedCompanyId); } catch { agent = null; }
        }
        if (!agent) {
            // Look up by name (case-insensitive) via agents.list
            try {
                const list = await ctx.agents.list({ companyId: resolvedCompanyId });
                const lowerName = trimmedName.toLowerCase();
                agent = list.find((a) => (a.name || "").toLowerCase() === lowerName
                    || (a.urlKey || "").toLowerCase() === lowerName) ?? null;
            } catch { agent = null; }
        }
        if (agent) {
            // Native Paperclip agent - create a session
            agentId = agent.id;
            const session = await ctx.agents.sessions.create(agentId, resolvedCompanyId, {
                reason: `Telegram thread ${chatId}/${messageThreadId}`,
            });
            sessionId = session.sessionId;
            transport = "native";
            ctx.logger.info("Created native agent session", { agentId, sessionId });
        }
        else {
            sessionId = `acp_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
        }
    }
    catch {
        // Agent not found in Paperclip - fall back to ACP"""

# Patch 2 & 3: handoff / discuss paths (targetAgent)
old2 = "const agent = await ctx.agents.get(targetAgent, companyId);"
new2 = """let agent = null;
            const _isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(targetAgent);
            if (_isUuid) { try { agent = await ctx.agents.get(targetAgent, companyId); } catch { agent = null; } }
            if (!agent) { try { const _list = await ctx.agents.list({ companyId }); const _n = targetAgent.toLowerCase(); agent = _list.find((a) => (a.name || "").toLowerCase() === _n || (a.urlKey || "").toLowerCase() === _n) ?? null; } catch { agent = null; } }"""

if old1 in content:
    content = content.replace(old1, new1)
    print("Patch 1 (handleAcpSpawn): applied")
else:
    print("Patch 1: old pattern not found (possibly already applied)")

count2 = content.count(old2)
if count2 > 0:
    content = content.replace(old2, new2)
    print(f"Patch 2&3 (targetAgent): applied to {count2} locations")
else:
    print("Patch 2&3: old pattern not found")

with open(path, 'w') as f:
    f.write(content)
PY
echo "Telegram plugin patched"
