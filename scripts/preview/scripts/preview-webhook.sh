#!/usr/bin/env bash
# Fire-and-forget wrapper used by the webhook hook entry. Detaches the
# real handler so the webhook(8) listener can reply 200 to GitHub within
# its 10s deadline even when the handler itself takes 1–6 minutes
# (fork + sync + URL probe).
set -euo pipefail
OPT_DIR=${FREEQ_PREVIEW_OPT_DIR:-/home/boxd/freeq/scripts/preview}
LOG=${FREEQ_PREVIEW_LOG:-/var/log/freeq-preview.log}

# Pass through all 5 positional args from webhook.conf.json's
# pass-arguments-to-command list:
#   $1 comment.user.login
#   $2 issue.number
#   $3 repository.full_name
#   $4 comment.id
#   $5 comment.body
nohup bash "$OPT_DIR/scripts/preview-handler.sh" "$@" \
  >>"$LOG" 2>&1 </dev/null &
disown
echo "queued ($(date -u +%FT%TZ))"
