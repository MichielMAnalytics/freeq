#!/usr/bin/env bash
# Invoked by golden-sync-webhook.sh on push events to the tracked branch.
# Fetches origin and runs freeq-deploy.sh if HEAD has moved.
#
# Config lives at /etc/freeq-preview.conf (written by enable-preview.sh).
set -euo pipefail

CONF=${FREEQ_PREVIEW_CONF:-/etc/freeq-preview.conf}
[ -f "$CONF" ] && . "$CONF"
BRANCH=${BRANCH:-main}
REPO_DIR=${REPO_DIR:-/home/boxd/freeq}

cd "$REPO_DIR"

git fetch --quiet origin "$BRANCH"
LOCAL=$(git rev-parse HEAD 2>/dev/null || echo "")
REMOTE=$(git rev-parse "origin/$BRANCH")

if [ "$LOCAL" = "$REMOTE" ]; then
  echo "$(date -Is) sync: already at $REMOTE on $BRANCH — nothing to do"
  exit 0
fi

# Cooperative lock so concurrent /boxd-preview triggers can hold off until
# we settle. `last` file records the wall-clock of the last successful
# deploy; the handler uses that to enforce a short cooldown.
LOCK=/tmp/freeq-golden-sync.lock
LAST=/tmp/freeq-golden-sync.last
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

echo "$(date -Is) sync: $LOCAL -> $REMOTE on $BRANCH"
git checkout -B "$BRANCH" "origin/$BRANCH"

bash "$(dirname "$0")/freeq-deploy.sh"

date +%s > "$LAST"
