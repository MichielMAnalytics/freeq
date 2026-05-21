#!/usr/bin/env bash
# Conditional deploy script for the freeq-golden boxd VM.
#
# Invoked by golden-sync.sh after `git fetch + checkout -B <branch>` and
# by preview-handler.sh's fork-sync exec block after `git reset --hard
# origin/<branch>`.
#
# freeq's stack runs natively on the host (no docker compose): vite watches
# files in freeq-app/, freeq-server + freeq-auth-broker are long-lived
# debug binaries under target/. That means:
#
#   frontend source change   → nothing to do; vite HMR picks it up via fs watch
#   freeq-app/package.json   → npm install (vite restarts on its own)
#   freeq-sdk-js/**          → rebuild the SDK (vite picks up the new dist/)
#   *.rs / Cargo.* / server  → STUB: print restart instructions; do not auto-restart
#
# Auto-restarting the Rust services would block the deploy for 2–10 min on
# every push (debug builds are slow on this monorepo) and would log out every
# connected client. Surfacing a clear "restart needed" notice instead is the
# correct trade-off for a preview env.
#
# Outputs (consumed by golden-sync.sh / preview-handler.sh):
#   - RUST_RESTART_NEEDED=1 written to $RESTART_FLAG if any rust path changed.
#     Callers post the contents of $RESTART_NOTE as a PR/issue comment.
set -euo pipefail

REPO_DIR=${REPO_DIR:-/home/boxd/freeq}
DEPLOY_MARKER=${DEPLOY_MARKER:-/home/boxd/.freeq-last-deployed-sha}
RESTART_FLAG=${RESTART_FLAG:-/tmp/freeq-restart-needed}
RESTART_NOTE=${RESTART_NOTE:-/tmp/freeq-restart-note}

cd "$REPO_DIR"

HEAD_SHA=$(git rev-parse HEAD)

# Previous SHA: prefer reflog (works for normal pushes), fall back to a
# persistent marker file (survives `git reset --hard` and fork CoW).
PREV_SHA=$(git reflog HEAD --format='%H' 2>/dev/null \
  | awk -v cur="$HEAD_SHA" '$1!=cur {print $1; exit}')

ACTION=""
CHANGED=""
if [ -z "$PREV_SHA" ] && [ -f "$DEPLOY_MARKER" ]; then
  MARKER_SHA=$(cat "$DEPLOY_MARKER" 2>/dev/null || echo "")
  if [ "$MARKER_SHA" = "$HEAD_SHA" ]; then
    echo "$DEPLOY_MARKER matches HEAD ($HEAD_SHA) — already deployed, no action"
    ACTION="none"
  elif [ -n "$MARKER_SHA" ]; then
    PREV_SHA="$MARKER_SHA"
    echo "PREV_SHA from $DEPLOY_MARKER: $PREV_SHA"
  fi
fi

if [ -z "$ACTION" ] && [ -z "$PREV_SHA" ]; then
  echo "no prior deployed commit known — treating as first deploy"
  ACTION="first"
elif [ -z "$ACTION" ]; then
  CHANGED=$(git diff --name-only "$PREV_SHA" "$HEAD_SHA" 2>/dev/null || echo "")
  echo "changed files ($PREV_SHA..$HEAD_SHA):"
  echo "$CHANGED" | sed 's/^/  /'
fi

# Reset state files so re-runs don't carry over a previous "restart needed"
# signal when nothing in this push actually changes the rust side.
rm -f "$RESTART_FLAG" "$RESTART_NOTE"

# Classify each changed path. Three buckets:
#   FRONTEND_DEPS  — package.json / lockfile / SDK source → need `npm install` / SDK rebuild
#   RUST_CHANGED   — any rust source or build config → stub restart
#   FRONTEND_SRC   — TypeScript/CSS/etc. under freeq-app/ → vite HMR handles it
needs_npm_install=no
needs_sdk_build=no
rust_paths=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    freeq-app/package.json|freeq-app/package-lock.json)
      needs_npm_install=yes ;;
    freeq-sdk-js/*)
      needs_sdk_build=yes ;;
    freeq-server/*|freeq-auth-broker/*|freeq-sdk/*|Cargo.toml|Cargo.lock|*.rs)
      rust_paths="$rust_paths $f" ;;
  esac
done <<< "$CHANGED"

# Frontend deps / SDK rebuild — safe to auto-apply, no service interruption
# (vite restarts itself on package.json change; SDK is just a build artifact).
if [ "$needs_sdk_build" = "yes" ]; then
  echo "freeq-sdk-js changed — rebuilding SDK"
  ( cd freeq-sdk-js && npm install --silent && npm run build )
fi
if [ "$needs_npm_install" = "yes" ]; then
  echo "freeq-app deps changed — running npm install"
  ( cd freeq-app && npm install --silent )
fi

# Rust restart stub. We never auto-rebuild + restart from here: debug builds
# on this workspace take 2–10 min and kill every connected session. Instead,
# surface a copy-pasteable instruction set the operator can run when ready.
if [ -n "$rust_paths" ]; then
  affected=$(echo "$rust_paths" | tr ' ' '\n' | sort -u | sed '/^$/d' | sed 's/^/  - /')
  cat > "$RESTART_NOTE" <<NOTE
🦀 **Rust changes detected — manual restart required**

Vite HMR has picked up any frontend changes, but the Rust services need
to be rebuilt + restarted by hand. From inside the preview VM:

\`\`\`
ssh \$(boxd info --json | jq -r .url)
cd $REPO_DIR
# Rebuild affected binaries (incremental — usually 30–90s):
cargo build --bin freeq-server --bin freeq-auth-broker

# Restart the running processes (preserves the SQLite DBs):
pkill -f 'target/debug/freeq-server' && pkill -f 'target/debug/freeq-auth-broker'
# Re-launch with the same args the platform booted them with (see
# /home/boxd/.freeq-runtime-env for the exact BROKER_SHARED_SECRET).
\`\`\`

Files that changed under rust paths:

$affected
NOTE
  echo "RUST_RESTART_NEEDED=1" > "$RESTART_FLAG"
  echo "rust changes detected — wrote $RESTART_NOTE ($(wc -l < "$RESTART_NOTE") lines)"
  echo "  callers should surface this to the user via a PR comment / log."
fi

# Decide the visible action for the log line at the bottom.
if [ "$ACTION" = "first" ] || [ "$ACTION" = "none" ]; then
  :
elif [ -n "$rust_paths" ]; then
  ACTION="rust-restart-needed"
elif [ "$needs_npm_install" = "yes" ] || [ "$needs_sdk_build" = "yes" ]; then
  ACTION="deps-updated"
elif [ -n "$CHANGED" ]; then
  ACTION="vite-hmr"
else
  ACTION="none"
fi

case "$ACTION" in
  none|first)
    echo "no action — services already match HEAD or no usable prior SHA"
    ;;
  vite-hmr)
    echo "frontend source only — vite HMR will pick up the change within a few seconds"
    ;;
  deps-updated)
    echo "frontend deps refreshed; vite restarts on its own"
    ;;
  rust-restart-needed)
    echo "deploy completed but rust services need manual restart (see $RESTART_NOTE)"
    ;;
esac

# Atomic marker write so a concurrent reader can't see a half-written file.
TMP="${DEPLOY_MARKER}.tmp.$$"
echo "$HEAD_SHA" > "$TMP" && mv "$TMP" "$DEPLOY_MARKER"

echo "deployed $(git rev-parse --short HEAD) (action=$ACTION)"
