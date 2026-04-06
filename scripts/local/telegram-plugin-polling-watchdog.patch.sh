#!/usr/bin/env bash
# Patch: Telegram plugin polling watchdog & resilience
#
# Fixes three issues that cause the Telegram bot to silently stop receiving messages:
#
# 1. No HTTP-level timeout on getUpdates — if the TCP connection stalls (half-open),
#    the polling loop blocks forever. Fix: AbortController with 30s timeout.
#
# 2. Silent API failures — if Telegram returns ok:false (409 Conflict, auth revoked),
#    the loop silently continues. Fix: log + back off on non-ok responses.
#
# 3. No liveness watchdog — onHealth() always returns "ok" even when polling is dead.
#    Fix: track lastPollAt, report unhealthy after 120s of silence, and auto-restart
#    the polling loop when stalled.

set -euo pipefail

TARGET="/home/abekarar/.paperclip/plugins/node_modules/paperclip-plugin-telegram/dist/worker.js"
if [ ! -f "$TARGET" ]; then
  echo "Telegram plugin not installed — skipping patch"
  exit 0
fi

if grep -q "POLLING_WATCHDOG_TIMEOUT_MS" "$TARGET" 2>/dev/null; then
  echo "Patch already applied"
  exit 0
fi

python3 << 'PY'
import re

path = "/home/abekarar/.paperclip/plugins/node_modules/paperclip-plugin-telegram/dist/worker.js"
with open(path, 'r') as f:
    content = f.read()

# --- Patch 1: Replace the polling loop with a resilient version ---
old_polling = """        // --- Long polling for inbound messages ---
        let pollingActive = true;
        let lastUpdateId = 0;
        async function pollUpdates() {
            while (pollingActive) {
                try {
                    const res = await ctx.http.fetch(`${TELEGRAM_API}/bot${token}/getUpdates?offset=${lastUpdateId + 1}&timeout=10&allowed_updates=["message","callback_query"]`, { method: "GET" });
                    const data = (await res.json());
                    if (data.ok && data.result) {
                        for (const update of data.result) {
                            lastUpdateId = Math.max(lastUpdateId, update.update_id);
                            await handleUpdate(ctx, token, config, update, baseUrl, publicUrl);
                        }
                    }
                }
                catch (err) {
                    ctx.logger.error("Telegram polling error", { error: String(err) });
                    await new Promise((r) => setTimeout(r, 5000));
                }
            }
        }
        if (config.enableCommands || config.enableInbound) {
            pollUpdates().catch((err) => ctx.logger.error("Polling loop crashed", { error: String(err) }));
        }"""

new_polling = """        // --- Long polling for inbound messages (with watchdog) ---
        const POLLING_WATCHDOG_TIMEOUT_MS = 120000; // 2 minutes
        const POLLING_FETCH_TIMEOUT_MS = 30000; // 30s HTTP timeout (Telegram long-poll is 10s)
        let pollingActive = true;
        let lastUpdateId = 0;
        let lastPollAt = Date.now();
        let pollLoopRunning = false;
        let consecutiveErrors = 0;
        async function pollUpdates() {
            if (pollLoopRunning) return;
            pollLoopRunning = true;
            consecutiveErrors = 0;
            ctx.logger.info("Telegram polling loop started");
            while (pollingActive) {
                try {
                    const controller = new AbortController();
                    const fetchTimer = setTimeout(() => controller.abort(), POLLING_FETCH_TIMEOUT_MS);
                    let res;
                    try {
                        res = await ctx.http.fetch(
                            `${TELEGRAM_API}/bot${token}/getUpdates?offset=${lastUpdateId + 1}&timeout=10&allowed_updates=["message","callback_query"]`,
                            { method: "GET", signal: controller.signal }
                        );
                    } finally {
                        clearTimeout(fetchTimer);
                    }
                    const data = (await res.json());
                    lastPollAt = Date.now();
                    if (data.ok && data.result) {
                        consecutiveErrors = 0;
                        for (const update of data.result) {
                            lastUpdateId = Math.max(lastUpdateId, update.update_id);
                            await handleUpdate(ctx, token, config, update, baseUrl, publicUrl);
                        }
                    } else if (!data.ok) {
                        consecutiveErrors++;
                        ctx.logger.error("Telegram getUpdates returned non-ok", {
                            description: data.description,
                            errorCode: data.error_code,
                            consecutiveErrors,
                        });
                        const backoff = Math.min(consecutiveErrors * 5000, 60000);
                        await new Promise((r) => setTimeout(r, backoff));
                    }
                }
                catch (err) {
                    consecutiveErrors++;
                    const errStr = String(err);
                    const isAbort = errStr.includes("abort") || errStr.includes("AbortError");
                    ctx.logger.error("Telegram polling error", {
                        error: errStr,
                        isTimeout: isAbort,
                        consecutiveErrors,
                    });
                    const backoff = Math.min(consecutiveErrors * 5000, 60000);
                    await new Promise((r) => setTimeout(r, backoff));
                }
            }
            pollLoopRunning = false;
            ctx.logger.info("Telegram polling loop stopped");
        }
        // Watchdog: restart polling if stalled
        const watchdogInterval = setInterval(() => {
            if (!pollingActive) return;
            const silenceMs = Date.now() - lastPollAt;
            if (silenceMs > POLLING_WATCHDOG_TIMEOUT_MS) {
                ctx.logger.error("Telegram polling watchdog: loop stalled, restarting", {
                    silenceMs,
                    pollLoopRunning,
                    consecutiveErrors,
                });
                pollLoopRunning = false;
                pollUpdates().catch((err) =>
                    ctx.logger.error("Polling loop crashed on watchdog restart", { error: String(err) })
                );
            }
        }, 60000);
        if (config.enableCommands || config.enableInbound) {
            pollUpdates().catch((err) => ctx.logger.error("Polling loop crashed", { error: String(err) }));
        }"""

if old_polling not in content:
    print("ERROR: Could not find polling loop to patch")
    exit(1)

content = content.replace(old_polling, new_polling)

# --- Patch 2: Update plugin.stopping handler to clear watchdog ---
old_stopping = """        ctx.events.on("plugin.stopping", async () => {
            pollingActive = false;
        });"""

new_stopping = """        ctx.events.on("plugin.stopping", async () => {
            pollingActive = false;
            clearInterval(watchdogInterval);
        });"""

if old_stopping in content:
    content = content.replace(old_stopping, new_stopping)
else:
    print("WARNING: Could not find plugin.stopping handler to patch")

# --- Patch 3: Make onHealth() report actual polling liveness ---
old_health = """    async onHealth() {
        return { status: "ok" };
    },"""

new_health = """    async onHealth() {
        const silenceMs = Date.now() - (typeof lastPollAt !== "undefined" ? lastPollAt : Date.now());
        if (silenceMs > 120000) {
            return { status: "degraded", detail: `polling silent for ${Math.round(silenceMs / 1000)}s` };
        }
        return { status: "ok" };
    },"""

if old_health in content:
    content = content.replace(old_health, new_health)
else:
    print("WARNING: Could not find onHealth to patch")

with open(path, 'w') as f:
    f.write(content)

print("Patch applied successfully")
PY