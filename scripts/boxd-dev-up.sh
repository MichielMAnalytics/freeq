#!/usr/bin/env bash
# Bring up the freeq dev stack on a boxd VM (idempotent — re-run after a fork).
#
# Provides:
#   - Vite (freeq-app) on 5173 → default boxd proxy ($BOXD_VM_NAME.boxd.sh)
#   - freeq-server on 127.0.0.1:8080 (proxied through Vite for /irc, /api, /auth, /client-metadata.json)
#   - freeq-auth-broker on 0.0.0.0:8081 → auth.$BOXD_VM_NAME.boxd.sh
#
# Persistent state lives in /home/boxd/freeq-data/.
# Logs in /home/boxd/freeq-logs/.

set -euo pipefail
cd /home/boxd/freeq

DATA_DIR=/home/boxd/freeq-data
LOG_DIR=/home/boxd/freeq-logs
mkdir -p "$DATA_DIR" "$LOG_DIR"

# 1. Shared secret (generate once, reuse forever).
SECRET_FILE="$DATA_DIR/broker-secret"
if [ ! -s "$SECRET_FILE" ]; then
  openssl rand -hex 32 > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
fi
SECRET=$(cat "$SECRET_FILE")

# 2. boxd proxies. set-port is a no-op if already correct; new fails harmlessly if exists.
boxd proxy set-port --port=5173 >/dev/null 2>&1 || true
boxd proxy new auth --port=8081 >/dev/null 2>&1 || true

# 3. Kill any previous instances.
pkill -f 'target/release/freeq-server'      2>/dev/null || true
pkill -f 'target/release/freeq-auth-broker' 2>/dev/null || true
pkill -f 'vite'                              2>/dev/null || true
sleep 1

# 4. freeq-server.
nohup ./target/release/freeq-server \
  --web-addr 127.0.0.1:8080 \
  --db-path "$DATA_DIR/freeq.db" \
  --broker-shared-secret "$SECRET" \
  --motd "freeq dev on $BOXD_VM_NAME" \
  > "$LOG_DIR/freeq-server.log" 2>&1 &

# 5. Auth broker.
BROKER_SHARED_SECRET="$SECRET" \
BROKER_PUBLIC_URL="https://auth.$BOXD_VM_NAME.boxd.sh" \
FREEQ_SERVER_URL="https://$BOXD_VM_NAME.boxd.sh" \
BROKER_DB_PATH="$DATA_DIR/broker.db" \
BROKER_ADDR="0.0.0.0:8081" \
RUST_LOG=info \
nohup ./target/release/freeq-auth-broker \
  > "$LOG_DIR/broker.log" 2>&1 &

# 6. Vite (frontend).
( cd freeq-app && nohup npm run dev -- --host 0.0.0.0 \
  > "$LOG_DIR/vite.log" 2>&1 & )

sleep 2
echo
echo "freeq dev stack up on $BOXD_VM_NAME"
echo "  app    : https://$BOXD_VM_NAME.boxd.sh"
echo "  broker : https://auth.$BOXD_VM_NAME.boxd.sh"
echo "  logs   : $LOG_DIR/"
