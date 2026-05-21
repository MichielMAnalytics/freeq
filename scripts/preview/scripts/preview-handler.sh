#!/usr/bin/env bash
# Handler for the `/boxd-preview` slash-command. Invoked by webhook(8)
# after the layer-A gate (HMAC, comment body, author_association ∈
# {OWNER, MEMBER, COLLABORATOR}) has passed. Fires for both issue and
# PR comments; we distinguish via the GitHub API in the handler.
#
# Layer-B (precise auth) and the actual fork-and-checkout work happen
# here, in the background, so the webhook returns 200 fast.
#
# Args (from pass-arguments-to-command):
#   $1  comment.user.login
#   $2  issue.number  (PR number for PR comments, issue number otherwise)
#   $3  repository.full_name  (owner/repo)
#   $4  comment.id    (the triggering comment, for the eyes reaction)
#   $5  comment.body  (used to parse `branch=…` override on issue triggers)
#
# Branch resolution:
#   - PR comment       → fork tracks the PR's head branch
#   - Issue comment    → fork tracks DEFAULT_BRANCH (main) by default
#   - Issue + branch=X → fork tracks branch X
set -euo pipefail

CONF=${FREEQ_PREVIEW_CONF:-/etc/freeq-preview.conf}
[ -f "$CONF" ] && . "$CONF"

# When systemd spawns us via webhook(8), the env is empty — the boxd
# `gh` shell function isn't loaded, so bare /usr/bin/gh has no creds.
# Pull a token from boxd-github-token (the helper at /usr/local/bin/)
# and export it for the rest of the script. Same fix as enable-preview.sh.
if [ -z "${GH_TOKEN:-}" ] && command -v boxd-github-token >/dev/null 2>&1; then
  BOXD_TOKEN=$(boxd-github-token 2>/dev/null || true)
  [ -n "$BOXD_TOKEN" ] && export GH_TOKEN="$BOXD_TOKEN"
fi

OPT_DIR=${FREEQ_PREVIEW_OPT_DIR:-/home/boxd/freeq/scripts/preview}
REPO_DIR=${REPO_DIR:-/home/boxd/freeq}
VM_PREFIX=${VM_PREFIX:-freeq-pr}
VM_PREFIX_ISSUE=${VM_PREFIX_ISSUE:-freeq-issue}
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
# ZONE comes from the conf (written by enable-preview.sh). Fall back to
# deriving from the live boxd info, then to boxd.sh, so the handler
# still works if the conf is missing or stale.
if [ -z "${ZONE:-}" ]; then
  CURRENT_VM=$(boxd info --json 2>/dev/null | jq -r '.name // empty' 2>/dev/null)
  CURRENT_VM=${CURRENT_VM:-$(hostname -s)}
  ZONE=$(boxd info --json 2>/dev/null \
    | jq -r '.proxies[]? | select(.is_default==true) | .domain' \
    | sed -E "s/^${CURRENT_VM//./\\.}\.//")
fi
ZONE=${ZONE:-boxd.sh}
# Vite picks up file changes within ~1–2s of disk write, but on a fresh
# fork it can take a few seconds for the dev-server worker to come back
# online. 5s ready-poll → up to 60 iterations = 5 min hard cap.
URL_POLL_INTERVAL_SECS=${URL_POLL_INTERVAL_SECS:-5}
URL_POLL_MAX_ATTEMPTS=${URL_POLL_MAX_ATTEMPTS:-60}

LOG=${FREEQ_PREVIEW_LOG:-/var/log/freeq-preview.log}
LOG_DIR=${FREEQ_PREVIEW_LOG_DIR:-/var/log/freeq-preview}
mkdir -p "$LOG_DIR" 2>/dev/null || sudo mkdir -p "$LOG_DIR"

# Self-daemonize for direct CLI invocation. The webhook wrapper already
# detaches us, but running this script by hand for debugging shouldn't
# tie the terminal to the long fork-and-sync.
if [ -t 1 ] || [ "${PREVIEW_FOREGROUND:-0}" = "1" ]; then
  : # already foreground
else
  PREVIEW_FOREGROUND=1 nohup "$0" "$@" >>"$LOG" 2>&1 </dev/null &
  disown
  echo "queued"
  exit 0
fi

VM_LOG=""
log() {
  local ts msg
  ts="[$(date -u +%FT%TZ)]"
  msg="$*"
  printf '%s %s\n' "$ts" "$msg"
  [ -n "$VM_LOG" ] && printf '%s %s\n' "$ts" "$msg" >>"$VM_LOG" 2>/dev/null || true
}

COMMENTER=${1:?missing arg: commenter}
ISSUE_NUMBER=${2:?missing arg: issue_number}
REPO=${3:?missing arg: repo}
COMMENT_ID=${4:?missing arg: comment_id}
COMMENT_BODY=${5:-}

echo
echo "$(date -u +%FT%TZ) /boxd-preview @$COMMENTER on $REPO#$ISSUE_NUMBER (comment $COMMENT_ID)"

# Eyes reaction — Layer-A already filtered randoms.
gh api -X POST "repos/$REPO/issues/comments/$COMMENT_ID/reactions" \
  -f content=eyes >/dev/null 2>&1 || echo "  (eyes reaction failed; continuing)"

# Layer-B: precise per-repo permission.
PERM=$(gh api "repos/$REPO/collaborators/$COMMENTER/permission" --jq '.permission' 2>&1 \
  || echo "lookup_failed")
echo "  permission: $PERM"

post_comment() {
  gh api -X POST "/repos/$REPO/issues/$ISSUE_NUMBER/comments" \
    -f body="$1" --jq .id
}

case "$PERM" in
  admin|maintain|write) ;;
  *)
    post_comment "@$COMMENTER /boxd-preview requires write access. Your effective permission is \`$PERM\`." >/dev/null
    echo "  bounced (insufficient permission)"
    exit 0
    ;;
esac

# Don't fork a golden that's mid-deploy or just-deployed.
LOCK=/tmp/freeq-golden-sync.lock
LAST=/tmp/freeq-golden-sync.last
COOLDOWN_S=15
NOW=$(date +%s)
COOLDOWN_REASON=""

if [ -f "$LOCK" ]; then
  AGE=$((NOW - $(stat -c %Y "$LOCK" 2>/dev/null || echo "$NOW")))
  if [ "$AGE" -lt 600 ]; then
    COOLDOWN_REASON="a golden deploy is in progress (started ${AGE}s ago)"
  fi
fi
if [ -z "$COOLDOWN_REASON" ] && [ -f "$LAST" ]; then
  AGE=$((NOW - $(cat "$LAST" 2>/dev/null || echo 0)))
  if [ "$AGE" -lt "$COOLDOWN_S" ]; then
    COOLDOWN_REASON="golden was updated ${AGE}s ago, give it ~$((COOLDOWN_S-AGE))s to settle"
  fi
fi

if [ -n "$COOLDOWN_REASON" ]; then
  post_comment "@$COMMENTER ⏸ $COOLDOWN_REASON. Try \`/boxd-preview\` again in a moment." >/dev/null
  echo "  cooldown: $COOLDOWN_REASON — bounced"
  exit 0
fi

# Distinguish PR from issue.
IS_PR=$(gh api "repos/$REPO/issues/$ISSUE_NUMBER" --jq '.pull_request != null' 2>/dev/null || echo "false")
if [ "$IS_PR" = "true" ]; then
  KIND="PR"
  PREVIEW_BRANCH=$(gh api "repos/$REPO/pulls/$ISSUE_NUMBER" --jq .head.ref)
  VM_NAME="$VM_PREFIX-$ISSUE_NUMBER"
else
  KIND="issue"
  # Optional `branch=<ref>` override anywhere in the comment body.
  if [[ "$COMMENT_BODY" =~ branch=([A-Za-z0-9._/-]+) ]]; then
    PREVIEW_BRANCH="${BASH_REMATCH[1]}"
  else
    PREVIEW_BRANCH="$DEFAULT_BRANCH"
  fi
  VM_NAME="$VM_PREFIX_ISSUE-$ISSUE_NUMBER"
fi
URL="https://$VM_NAME.$ZONE"
VM_LOG="$LOG_DIR/$VM_NAME.log"
{
  echo
  echo "===== $(date -u +%FT%TZ) /boxd-preview @$COMMENTER on $REPO#$ISSUE_NUMBER (comment $COMMENT_ID) ====="
} >>"$VM_LOG"
log "kind: $KIND"
log "branch: $PREVIEW_BRANCH"
log "vm: $VM_NAME"
log "url: $URL"

# Per-VM lock — prevents concurrent /boxd-preview triggers from racing on
# the same fork name. PID-based so stale locks reclaim automatically.
LOCK_FILE="/tmp/freeq-preview-${VM_NAME}.lock"
if [ -f "$LOCK_FILE" ]; then
  EXISTING_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
    log "another preview handler (PID $EXISTING_PID) is already in flight for $VM_NAME — bouncing"
    post_comment "⏸ Another \`/boxd-preview\` for \`$VM_NAME\` is already in flight (PID \`$EXISTING_PID\`). Wait ~1–2 min for it to finish." >/dev/null
    exit 0
  fi
  log "stale lock at $LOCK_FILE (PID $EXISTING_PID no longer running) — claiming"
fi
echo "$$" > "$LOCK_FILE"
log "acquired lock $LOCK_FILE (PID $$)"

# Pre-flight: don't fork from a broken golden.
GOLDEN_HOST=$(boxd info --json 2>/dev/null | jq -r '.url // empty')
[ -z "$GOLDEN_HOST" ] && GOLDEN_HOST="$(hostname).$ZONE"
GOLDEN_URL="https://$GOLDEN_HOST/"
log "preflight: probing golden at $GOLDEN_URL"
GOLDEN_CODE=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 8 "$GOLDEN_URL" 2>/dev/null || echo "000")
log "preflight: golden HTTP $GOLDEN_CODE"
if ! [[ "$GOLDEN_CODE" =~ ^[23] ]]; then
  post_comment "⚠️ The golden VM \`$GOLDEN_HOST\` isn't serving right now (HTTP \`$GOLDEN_CODE\` at $GOLDEN_URL). Forking from a broken golden would just produce a broken preview, so I'm stopping. Bring the app back up and re-comment \`/boxd-preview\`." >/dev/null
  log "preflight failed (HTTP $GOLDEN_CODE) — bounced"
  exit 0
fi

BOOT_COMMENT_ID=$(post_comment "⏳ creating boxd preview env for \`$PREVIEW_BRANCH\` → $URL

you can also ssh in: \`ssh $VM_NAME.$ZONE\`

<sub>hang tight, this takes a moment</sub>")
log "boot comment id: $BOOT_COMMENT_ID"

BOOT_COMMENT_FINALIZED=no
on_exit() {
  local exit_code=$?
  if [ -n "${LOCK_FILE:-}" ] && [ -f "$LOCK_FILE" ] \
     && [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$$" ]; then
    rm -f "$LOCK_FILE"
  fi
  if [ "$BOOT_COMMENT_FINALIZED" = "no" ] && [ -n "${BOOT_COMMENT_ID:-}" ]; then
    gh api -X PATCH "/repos/$REPO/issues/comments/$BOOT_COMMENT_ID" \
      -f body="⚠️ **preview setup didn't complete** — the handler exited unexpectedly (rc=$exit_code) before it could finalize \`$VM_NAME\`.

Check the handler log on the golden:
\`\`\`
ssh \$(boxd info --json | jq -r .url)
sudo tail -100 $LOG_DIR/$VM_NAME.log
\`\`\`

Then re-comment \`/boxd-preview\` to try again." >/dev/null 2>&1 || true
  fi
}
trap on_exit EXIT

# Fork golden if the VM doesn't exist yet, otherwise reuse.
FRESH_FORK=no
MAX_FORK_ATTEMPTS=6
fork_status() {
  boxd list --json 2>/dev/null \
    | jq -r --arg n "$VM_NAME" '.[] | select(.name==$n) | .status' \
    | head -1
}
fork_backoff() {
  case "$1" in
    1) echo 5 ;;
    2) echo 15 ;;
    3) echo 30 ;;
    4) echo 60 ;;
    5) echo 90 ;;
    *) echo 5 ;;
  esac
}
update_boot_progress() {
  gh api -X PATCH "/repos/$REPO/issues/comments/$BOOT_COMMENT_ID" \
    -f body="$1" >/dev/null 2>&1 || true
}

EXISTING_STATUS=$(fork_status)
if [ -n "$EXISTING_STATUS" ] && [ "$EXISTING_STATUS" != "failed" ]; then
  log "VM $VM_NAME already exists (status=$EXISTING_STATUS) — reusing"
else
  if [ "$EXISTING_STATUS" = "failed" ]; then
    log "found stale failed $VM_NAME — destroying before retry"
    boxd destroy "$VM_NAME" -y 2>&1 | sed 's/^/  destroy: /' | tee -a "$VM_LOG" || true
    sleep 3
  fi

  log "forking golden → $VM_NAME (up to $MAX_FORK_ATTEMPTS attempts)"
  FORK_OK=no
  LAST_FORK_MSG=""
  for attempt in $(seq 1 $MAX_FORK_ATTEMPTS); do
    FORK_ERR=$(mktemp)
    T0=$(date +%s)
    if boxd fork --name "$VM_NAME" --json >/dev/null 2>"$FORK_ERR"; then
      sleep 2
      POST_STATUS=$(fork_status)
      if [ "$POST_STATUS" = "running" ] || [ "$POST_STATUS" = "booting" ]; then
        log "fork attempt $attempt: $POST_STATUS in $(( $(date +%s) - T0 ))s"
        rm -f "$FORK_ERR"
        FORK_OK=yes
        break
      fi
      LAST_FORK_MSG="fork returned 0 but VM landed in status=$POST_STATUS"
      log "fork attempt $attempt: $LAST_FORK_MSG"
    else
      LAST_FORK_MSG=$(cat "$FORK_ERR" | head -c 300)
      log "fork attempt $attempt: failed — $LAST_FORK_MSG"
    fi
    rm -f "$FORK_ERR"
    boxd destroy "$VM_NAME" -y >/dev/null 2>&1 || true

    if [ "$attempt" -lt "$MAX_FORK_ATTEMPTS" ]; then
      delay=$(fork_backoff "$attempt")
      log "  backing off ${delay}s before attempt $((attempt + 1))"
      update_boot_progress "⏳ creating boxd preview env for \`$PREVIEW_BRANCH\` → $URL

attempt $((attempt + 1))/$MAX_FORK_ATTEMPTS — boxd platform is being slow (\`$LAST_FORK_MSG\`), retrying in ${delay}s…"
      sleep "$delay"
    fi
  done

  if [ "$FORK_OK" = "no" ]; then
    log "fork failed after $MAX_FORK_ATTEMPTS attempts"
    update_boot_progress "❌ couldn't fork the golden VM after $MAX_FORK_ATTEMPTS attempts.

\`\`\`
$LAST_FORK_MSG
\`\`\`

Almost always a transient boxd platform flake. Re-comment \`/boxd-preview\` to try again."
    BOOT_COMMENT_FINALIZED=yes
    exit 0
  fi
  FRESH_FORK=yes
fi

# Forks inherit the default proxy. Re-point it at the frontend (vite) and
# also create the auth proxy on the fork for the broker.
log "configuring proxies on fork (5173 default, 8081 auth)"
boxd proxy set-port --vm "$VM_NAME" --port 5173 2>&1 \
  | sed 's/^/  proxy: /' | tee -a "$VM_LOG" || true
# auth proxy: best-effort create; ignored if already present from the
# golden's CoW.
boxd proxy new --vm "$VM_NAME" auth --port 8081 2>&1 \
  | sed 's/^/  proxy(auth): /' | tee -a "$VM_LOG" || true

# Wedge check before exec'ing into the fork. The CoW agent can be briefly
# unresponsive after fork; a 6s probe-then-reboot fallback covers that.
WEDGE_OK=no
if [ "$FRESH_FORK" = "yes" ]; then
  log "checking fork agent responsiveness…"
  T0=$(date +%s)
  for i in 1 2 3; do
    if timeout 8 boxd exec "$VM_NAME" --timeout 5 -- true >/dev/null 2>&1; then
      WEDGE_OK=yes
      log "  fork agent responsive after $(( $(date +%s) - T0 ))s"
      break
    fi
    sleep 2
  done

  if [ "$WEDGE_OK" = "no" ]; then
    log "  fork agent unresponsive — cold-rebooting"
    boxd reboot "$VM_NAME" 2>&1 | sed 's/^/    /' | tee -a "$VM_LOG" || true
    sleep 10
    for i in $(seq 1 30); do
      if timeout 10 boxd exec "$VM_NAME" --timeout 5 -- true >/dev/null 2>&1; then
        WEDGE_OK=yes
        log "  exec ready after reboot — settling 5s"
        sleep 5
        break
      fi
      sleep 2
    done
  fi
else
  WEDGE_OK=yes
fi

# Fast path: if the golden's HEAD already matches origin/<branch>, the
# memory-fork has the right code under vite and the broker/server are
# already serving it. Skip fork-sync entirely.
FAST_PATH=no
if [ "$FRESH_FORK" = "yes" ] && [ "$WEDGE_OK" = "yes" ]; then
  GOLDEN_HEAD_SHA=$(cd "$REPO_DIR" && git rev-parse HEAD 2>/dev/null || echo "")
  PREVIEW_SHA=$(cd "$REPO_DIR" && git rev-parse "origin/$PREVIEW_BRANCH" 2>/dev/null || echo "")
  if [ -n "$GOLDEN_HEAD_SHA" ] && [ "$GOLDEN_HEAD_SHA" = "$PREVIEW_SHA" ]; then
    FAST_PATH=yes
    log "fast path: golden HEAD == origin/$PREVIEW_BRANCH ($GOLDEN_HEAD_SHA) — skipping fork-sync"
  fi
fi

RUST_RESTART_NOTE=""
if [ "$FAST_PATH" = "yes" ]; then
  log "fast path active — vite is already serving origin/$PREVIEW_BRANCH"
else
  log "syncing fork to origin/$PREVIEW_BRANCH"
  SYNC_OUT=$(mktemp)
  for attempt in 1 2 3; do
    if ! boxd list --json 2>/dev/null | jq -e ".[] | select(.name==\"$VM_NAME\")" >/dev/null; then
      log "fork-sync: $VM_NAME no longer exists — aborting"
      break
    fi

    log "fork-sync attempt $attempt: starting exec block (timeout 180s)"
    T0=$(date +%s)
    if timeout 200 boxd exec "$VM_NAME" --timeout 180 -- bash -c "
set -e
echo
echo \"===== \$(date -u +%FT%TZ) fork-sync attempt $attempt branch=$PREVIEW_BRANCH =====\"
cd '$REPO_DIR'
rm -f .git/index.lock 2>/dev/null || true
git fetch --quiet origin '$PREVIEW_BRANCH'
git reset --hard 'origin/$PREVIEW_BRANCH'
echo \"HEAD now \$(git rev-parse --short HEAD)\"
bash $OPT_DIR/scripts/freeq-deploy.sh
" >"$SYNC_OUT" 2>&1; then
      log "fork-sync attempt $attempt OK in $(( $(date +%s) - T0 ))s"
      sed 's/^/  fork-sync: /' "$SYNC_OUT" | tee -a "$VM_LOG"
      break
    fi
    log "fork-sync attempt $attempt FAILED in $(( $(date +%s) - T0 ))s (rc=$?)"
    sed 's/^/  fork-sync (attempt '$attempt' failed): /' "$SYNC_OUT" | tee -a "$VM_LOG"
    if [ "$attempt" -lt 3 ]; then
      log "retrying in 5s…"
      sleep 5
    fi
  done
  rm -f "$SYNC_OUT"

  # Pull the rust-restart note (if any) off the fork so we can surface it
  # in the GitHub comment. Best-effort: missing file just means rust
  # didn't change in this push.
  NOTE_LOCAL=$(mktemp)
  if boxd cp "$VM_NAME":/tmp/freeq-restart-note "$NOTE_LOCAL" 2>/dev/null \
     && [ -s "$NOTE_LOCAL" ]; then
    RUST_RESTART_NOTE=$(cat "$NOTE_LOCAL")
    log "fork has a pending rust restart note ($(wc -l < "$NOTE_LOCAL") lines)"
  fi
  rm -f "$NOTE_LOCAL"
fi

# Wait for the fork to serve. Vite is fast; 5s polling × 60 = 5 min cap.
log "waiting for $URL to serve (poll every ${URL_POLL_INTERVAL_SECS}s, up to ${URL_POLL_MAX_ATTEMPTS}x)…"
T0=$(date +%s)
READY="no"
CODE=000
for i in $(seq 1 "$URL_POLL_MAX_ATTEMPTS"); do
  CODE=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "$URL/" 2>/dev/null || echo "000")
  if [[ "$CODE" =~ ^[23] ]]; then READY="yes"; break; fi
  sleep "$URL_POLL_INTERVAL_SECS"
done
log "ready=$READY (last HTTP $CODE) after $(( $(date +%s) - T0 ))s"

SSH_HOST="$VM_NAME.$ZONE"
FOOTER="<sub>made with ❤️ by the <a href=\"https://boxd.sh\">boxd.sh</a> team</sub>"

if [ "$READY" = "yes" ]; then
  EXTRA=""
  [ -n "$RUST_RESTART_NOTE" ] && EXTRA="

---

$RUST_RESTART_NOTE"
  READY_BODY=$(cat <<EOF
✅ **preview ready for \`$PREVIEW_BRANCH\`**

🌐 $URL
🔌 SSH: \`ssh $SSH_HOST\`
$EXTRA

---
$FOOTER
EOF
)
  gh api -X PATCH "/repos/$REPO/issues/comments/$BOOT_COMMENT_ID" \
    -f body="$READY_BODY" >/dev/null
  BOOT_COMMENT_FINALIZED=yes
else
  case "$CODE" in
    502|503|504)
      WARMING_BODY=$(cat <<EOF
🔧 **preview env created, app still warming up for \`$PREVIEW_BRANCH\`**

🌐 $URL  (last HTTP \`$CODE\` — proxy reachable, app not yet serving)
🔌 SSH: \`ssh $SSH_HOST\`

Give it ~1 min and refresh. Still not responding?
\`\`\`
ssh $SSH_HOST
ss -tlnp | grep -E ':(5173|8080|8081)'
\`\`\`

---
$FOOTER
EOF
)
      gh api -X PATCH "/repos/$REPO/issues/comments/$BOOT_COMMENT_ID" \
        -f body="$WARMING_BODY" >/dev/null
      ;;
    *)
      ERROR_BODY=$(cat <<EOF
⚠️ **preview env not reachable for \`$PREVIEW_BRANCH\`**

URL: $URL  (last HTTP \`$CODE\`)

Possible causes: vite died on the fork, or the boxd proxy lost its route.
SSH to debug:
\`\`\`
ssh $SSH_HOST
ss -tlnp | grep -E ':(5173|8080|8081)'
tail -50 /var/log/freeq-preview.log
\`\`\`

---
$FOOTER
EOF
)
      gh api -X PATCH "/repos/$REPO/issues/comments/$BOOT_COMMENT_ID" \
        -f body="$ERROR_BODY" >/dev/null
      ;;
  esac
  BOOT_COMMENT_FINALIZED=yes
fi
log "done"
