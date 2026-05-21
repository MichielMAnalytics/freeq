#!/usr/bin/env bash
# Fire-and-forget wrapper used by the webhook hook entry. Detaches the
# real sync to the background so the webhook(8) listener can reply 200 to
# GitHub within its 10s deadline even if the deploy takes longer.
set -euo pipefail
OPT_DIR=${FREEQ_PREVIEW_OPT_DIR:-/home/boxd/freeq/scripts/preview}
LOG=${FREEQ_GOLDEN_SYNC_LOG:-/var/log/freeq-golden-sync.log}

nohup bash "$OPT_DIR/scripts/golden-sync.sh" \
  >>"$LOG" 2>&1 </dev/null &
disown
echo "queued ($(date -u +%FT%TZ))"
