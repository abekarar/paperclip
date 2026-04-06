#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/home/abekarar/paperclip"
PATCH_DIR="$REPO_DIR/scripts/local"
LOG_DIR="/home/abekarar/.paperclip-local/logs"
LOG_FILE="$LOG_DIR/update.log"
mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

cd "$REPO_DIR"

log "=== Starting Paperclip update ==="

# 1. Stash local changes
if ! git diff --quiet; then
  log "Stashing local changes..."
  git stash push -m "auto-update-$(date +%s)"
else
  log "No local changes to stash"
fi

# 2. Pull latest from upstream
log "Pulling latest from origin/master..."
BEFORE=$(git rev-parse HEAD)
git pull --ff-only origin master
AFTER=$(git rev-parse HEAD)

if [ "$BEFORE" = "$AFTER" ]; then
  log "Already up to date. Reapplying local patches..."
  git stash pop 2>/dev/null || true
  log "=== No update needed ==="
  exit 0
fi

log "Updated: $BEFORE -> $AFTER"
log "$(git log --oneline "$BEFORE".."$AFTER")"

# 3. Install dependencies
log "Installing dependencies..."
pnpm install --frozen-lockfile 2>&1 | tail -5 | tee -a "$LOG_FILE"

# 4. Reapply local patches (git patches to repo source)
for patch in "$PATCH_DIR"/*.patch; do
  [ -f "$patch" ] || continue
  log "Applying patch: $(basename "$patch")"
  if git apply --check "$patch" 2>/dev/null; then
    git apply "$patch"
    log "  Applied successfully"
  else
    log "  WARNING: Patch failed to apply cleanly -- may have been merged upstream"
  fi
done

# 4b. Run shell-based patches (for node_modules / installed plugins)
for script in "$PATCH_DIR"/*.patch.sh; do
  [ -f "$script" ] || continue
  log "Running patch script: $(basename "$script")"
  bash "$script" 2>&1 | tee -a "$LOG_FILE" || log "  WARNING: Patch script exited non-zero"
done

# 5. Restart via systemd
log "Restarting Paperclip service..."
systemctl --user restart paperclip

# 6. Wait for health check
log "Waiting for server to come up..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:3100/api/health > /dev/null 2>&1; then
    log "Server is healthy!"
    log "=== Update complete ==="
    exit 0
  fi
  sleep 2
done

log "ERROR: Server did not come up within 60 seconds. Check logs."
log "Service status: $(systemctl --user status paperclip --no-pager 2>&1 | head -5)"
exit 1
