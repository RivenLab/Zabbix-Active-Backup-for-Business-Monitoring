#!/bin/bash
# abb_pull.sh — Pull ABB status from the Synology over SSH and write local CSVs
# Runs on the Zabbix host (cron). Nothing to deploy or schedule on the Synology
# side — it only needs SSH enabled, firewall restricted to this host's IP, and
# one authorized_keys entry with a forced command (see INSTALL.md, Step 3:
# SSH Pull — install.sh prints the exact line to paste there).
#
# The forced command runs 3 fixed, read-only SELECT queries against ABB's
# SQLite databases and prints them to stdout, separated by "===SPLIT==="
# markers. Whatever command we pass over SSH is ignored by design — the
# remote end always runs that same fixed command regardless.
#
# All settings can live in one ABB_PULL_ENV_FILE instead of the cron line —
# see install.sh, which generates one automatically.
#
# Cron:  0 * * * *  <user>  ABB_PULL_ENV_FILE=/path/to/.env  abb_pull.sh
#        (hourly is plenty — ABB backups run nightly)
#
# Maintainer: Alexander Fox | PlaNet Fox

set -euo pipefail

###############################################################################
# Optional .env file — put ALL settings there instead of the cron line.
# Anything already set in the environment (e.g. by cron) still wins over it.
###############################################################################
if [ -n "${ABB_PULL_ENV_FILE:-}" ] && [ -r "$ABB_PULL_ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ABB_PULL_ENV_FILE"
  set +a
fi

###############################################################################
# Configuration (all overridable via environment / the .env file above)
###############################################################################
CSV_PATH="${ABB_CSV_PATH:-/opt/Zabbix_ABB_Monitoring/abb}"
SSH_HOST="${ABB_PULL_HOST:?ABB_PULL_HOST must be set (Synology host/IP)}"
SSH_PORT="${ABB_PULL_PORT:-22}"
SSH_USER="${ABB_PULL_USER:-root}"
SSH_KEY="${ABB_PULL_SSH_KEY:-/opt/monitoring/.ssh/id_ed25519_abbpull}"
KNOWN_HOSTS="${ABB_PULL_KNOWN_HOSTS:-/opt/monitoring/.ssh/known_hosts_abbpull}"
LOG="${CSV_PATH}/pull.log"
LOG_MAX_LINES="${ABB_LOG_MAX:-2000}"

CSV_EXPORT="${CSV_PATH}/ActiveBackupExport.csv"
CSV_HOSTS="${CSV_PATH}/ActiveBackupHostExport.csv"
CSV_STATS="${CSV_PATH}/ActiveBackupStats.csv"

###############################################################################
# Helpers
###############################################################################
log() { printf '%s [PULL] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

rotate_log() {
  [ -f "$LOG" ] || return 0
  local lines
  lines="$(wc -l < "$LOG")"
  if [ "$lines" -gt "$LOG_MAX_LINES" ]; then
    tail -n "$(( LOG_MAX_LINES / 2 ))" "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
  fi
}

fail_cycle() {
  log "ERROR $*"
  rotate_log
  exit 1
}

mkdir -p "$CSV_PATH"

TMP_DIR="$(mktemp -d "${CSV_PATH}/.pull.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

###############################################################################
# Checks
###############################################################################
[ -r "$SSH_KEY" ]     || fail_cycle "SSH key not readable: $SSH_KEY"
[ -r "$KNOWN_HOSTS" ] || fail_cycle "known_hosts not readable: $KNOWN_HOSTS"

###############################################################################
# Pull — one SSH call runs all 3 read-only queries on the Synology.
# The actual queries are pinned server-side in authorized_keys' forced
# command; the argument below is ignored by the remote end by design.
###############################################################################
TMP_ALL="${TMP_DIR}/all.csv"
TMP_ERR="${TMP_DIR}/err"

if ! ssh -i "$SSH_KEY" -p "$SSH_PORT" \
      -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=yes \
      -o BatchMode=yes -o ConnectTimeout=10 \
      "${SSH_USER}@${SSH_HOST}" pull > "$TMP_ALL" 2>"$TMP_ERR"; then
  fail_cycle "ssh pull failed: $(tr '\n' ' ' < "$TMP_ERR")"
fi

###############################################################################
# Split the combined stdout on the ===SPLIT=== markers
###############################################################################
TMP_A="${TMP_DIR}/export.csv"
TMP_B="${TMP_DIR}/hosts.csv"
TMP_C="${TMP_DIR}/stats.csv"

awk -v out1="$TMP_A" -v out2="$TMP_B" -v out3="$TMP_C" '
  BEGIN { part=1 }
  /^===SPLIT===$/ { part++; next }
  { gsub(/\r$/,"") }
  part==1 { print > out1 }
  part==2 { print > out2 }
  part==3 { print > out3 }
' "$TMP_ALL"

[ -s "$TMP_A" ] || fail_cycle "empty export result — check the Synology-side forced command / DB permissions"

###############################################################################
# Write final CSVs (header + data), atomically
###############################################################################
{ echo "DEVICEID,HOSTNAME,STATUS,BYTES,DURATION,TS,LAST_SUCCESS_TS"; cat "$TMP_A"; } > "${TMP_A}.final"
{ echo "DEVICEID,HOSTNAME,BACKUPTYPE";                                cat "$TMP_B"; } > "${TMP_B}.final"
{ echo "Successful,Failed,Warning,Running";                           cat "$TMP_C"; } > "${TMP_C}.final"

mv -f "${TMP_A}.final" "$CSV_EXPORT"
mv -f "${TMP_B}.final" "$CSV_HOSTS"
mv -f "${TMP_C}.final" "$CSV_STATS"
chmod 644 "$CSV_EXPORT" "$CSV_HOSTS" "$CSV_STATS"

DEVICE_COUNT="$(awk -F',' 'NR>1{c++} END{print c+0}' "$CSV_EXPORT")"
log "OK devices=$DEVICE_COUNT"
rotate_log
exit 0
