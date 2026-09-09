#!/bin/bash
# install.sh — ABB Monitoring Installer (SSH Pull only)
# Zabbix connects out to the Synology over SSH — nothing is installed or
# scheduled on the Synology by this script; see INSTALL.md for the one-time
# manual steps there (enable SSH, firewall rule, authorized_keys line, and
# the abb_pull_query.sh + sudoers rule if root SSH login is blocked).
#
# Usage:
#   Interactive:  ./install.sh
#   Direct:       ./install.sh zabbix
#   Check:        ./install.sh --check
#   Uninstall:    ./install.sh --uninstall
set -euo pipefail

###############################################################################
# Defaults
###############################################################################
ZBX_EXT_DIR="/usr/lib/zabbix/externalscripts"
ZBX_USER="zabbix"
ZBX_PULL_CRON_USER="${ZBX_PULL_CRON_USER:-${SUDO_USER:-root}}"
ZBX_PULL_REMOTE_USER="${ZBX_PULL_REMOTE_USER:-root}"   # root (direct) | any other account (via sudo wrapper)
ZBX_CSV_PATH="${ABB_CSV_PATH:-/opt/Zabbix_ABB_Monitoring/abb}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

###############################################################################
# Formatting
###############################################################################
BOLD='\033[1m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { printf "  ${GREEN}[✓]${NC} %s\n" "$*"; }
fail() { printf "  ${RED}[✗]${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}[!]${NC} %s\n" "$*"; }
die()  { fail "$*"; exit 1; }
ask()  { printf "${BOLD}%s${NC} " "$1" >&2; read -r ans; echo "$ans"; }

check_root() {
  [ "$(id -u)" = "0" ] || die "Run as root (sudo ./install.sh)"
}

###############################################################################
# Zabbix installation
###############################################################################
install_zabbix() {
  echo ""
  printf "${BOLD}═══ Installing Zabbix Scripts ═══${NC}\n"

  id "$ZBX_USER" >/dev/null 2>&1 || die "User $ZBX_USER not found"
  [ -d "$ZBX_EXT_DIR" ] || die "External scripts dir not found: $ZBX_EXT_DIR"

  cp -v "${SCRIPT_DIR}/zabbix/abb.sh" "${ZBX_EXT_DIR}/"
  cp -v "${SCRIPT_DIR}/zabbix/abb-enh.sh" "${ZBX_EXT_DIR}/"
  chmod 755 "${ZBX_EXT_DIR}/abb.sh" "${ZBX_EXT_DIR}/abb-enh.sh"
  chown root:"$ZBX_USER" "${ZBX_EXT_DIR}/abb.sh" "${ZBX_EXT_DIR}/abb-enh.sh"
  ok "Scripts installed to ${ZBX_EXT_DIR}"

  setup_zabbix_pull

  # Test
  if [ -f "${ZBX_CSV_PATH}/ActiveBackupExport.csv" ]; then
    local count
    count="$(sudo -u "$ZBX_USER" "${ZBX_EXT_DIR}/abb.sh" device_count 2>/dev/null || echo "FAIL")"
    if [ "$count" != "FAIL" ]; then
      ok "abb.sh device_count = $count (as $ZBX_USER)"
    else
      warn "abb.sh failed as $ZBX_USER — check permissions"
    fi
  else
    warn "CSV not found yet — will appear after the first pull cron cycle fires"
  fi

  ok "Zabbix installation complete"
  echo ""
  warn "Remember to import template/Synology-ABB-Zabbix-Check.xml in Zabbix UI"
  warn "Override {\$ABB.MOUNTPOINT}, {\$ABB.EXPECT_REMOTE}, {\$ABB.EXPECT_FSTYPE} to empty on the host — pull mode has no mount to check"
}

###############################################################################
# Zabbix: SSH Pull setup — Zabbix connects out to the Synology. Nothing is
# deployed there beyond one authorized_keys line with a forced command that
# can only ever run 3 fixed, read-only SELECT queries.
###############################################################################
setup_zabbix_pull() {
  id "$ZBX_PULL_CRON_USER" >/dev/null 2>&1 || die "User $ZBX_PULL_CRON_USER not found (set ZBX_PULL_CRON_USER or answer the prompt with an existing local user)"

  mkdir -p "$ZBX_CSV_PATH"
  chmod 755 "$ZBX_CSV_PATH"
  chown "$ZBX_PULL_CRON_USER" "$ZBX_CSV_PATH"

  cp -v "${SCRIPT_DIR}/zabbix/abb_pull.sh" "${ZBX_EXT_DIR}/"
  chmod 755 "${ZBX_EXT_DIR}/abb_pull.sh"

  local pull_host
  pull_host="$(ask "  Synology host/IP:")"
  if [ -z "$pull_host" ]; then
    warn "No host given — set ABB_PULL_HOST and the cron job manually later"
    return
  fi

  local ssh_dir ssh_key known_hosts
  ssh_dir="$(dirname "$ZBX_CSV_PATH")/.ssh"
  ssh_key="${ssh_dir}/id_ed25519_abbpull"
  known_hosts="${ssh_dir}/known_hosts_abbpull"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  chown "$ZBX_PULL_CRON_USER" "$ssh_dir"

  if [ ! -f "$ssh_key" ]; then
    ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "abbpull@$(hostname)" >/dev/null
    ok "Generated SSH key: ${ssh_key}"
  else
    ok "Reusing existing SSH key: ${ssh_key}"
  fi
  chown "$ZBX_PULL_CRON_USER" "$ssh_key" "${ssh_key}.pub"

  if ssh-keyscan -p 22 "$pull_host" > "$known_hosts" 2>/dev/null && [ -s "$known_hosts" ]; then
    ok "Host key pinned for ${pull_host} — verify this fingerprint against the Synology before trusting it:"
    ssh-keygen -lf "$known_hosts" 2>/dev/null | sed 's/^/      /'
  else
    warn "Could not reach ${pull_host}:22 to pin its host key — run ssh-keyscan manually later"
  fi
  chown "$ZBX_PULL_CRON_USER" "$known_hosts"

  # All settings in one .env file — edit it later without touching cron/install.sh again
  local env_file
  env_file="$(dirname "$ZBX_CSV_PATH")/.env"
  cat > "$env_file" << ENVEOF
ABB_CSV_PATH=${ZBX_CSV_PATH}
ABB_PULL_HOST=${pull_host}
ABB_PULL_USER=${ZBX_PULL_REMOTE_USER}
ABB_PULL_SSH_KEY=${ssh_key}
ABB_PULL_KNOWN_HOSTS=${known_hosts}
ENVEOF
  chmod 600 "$env_file"
  chown "$ZBX_PULL_CRON_USER" "$env_file"
  ok "Config written: ${env_file}"

  # Hourly cron via a dedicated drop-in (doesn't touch anyone's personal crontab)
  cat > /etc/cron.d/abb-monitoring-pull << CRONEOF
0 * * * * ${ZBX_PULL_CRON_USER} ABB_PULL_ENV_FILE=${env_file} ${ZBX_EXT_DIR}/abb_pull.sh
CRONEOF
  chmod 644 /etc/cron.d/abb-monitoring-pull
  ok "Cron installed: /etc/cron.d/abb-monitoring-pull (hourly, as ${ZBX_PULL_CRON_USER})"

  local pubkey line_file
  pubkey="$(cat "${ssh_key}.pub")"
  line_file="${ssh_key}.authorized_keys_line"

  if [ "$ZBX_PULL_REMOTE_USER" = "root" ]; then
    # Build the exact forced command the Synology must authorize: 3 fixed,
    # read-only SELECT queries, piped to stdout separated by ===SPLIT=== markers.
    # This key can NEVER run anything else, even if it leaks. Filters out
    # device_ids no longer present in device_table (e.g. a VM re-cloned with
    # a new ABB device — the old id would otherwise stay stuck forever).
    local q_a q_b q_c layer2 escaped
    q_a="ATTACH DATABASE '/volume1/@ActiveBackup/config.db' AS cfgdb; WITH latest AS (SELECT r.config_device_id, r.device_name, r.status, COALESCE(r.transfered_bytes,0) AS bytes, COALESCE(r.time_start,0) AS tstart, COALESCE(r.time_end,0) AS tend FROM device_result_table r JOIN (SELECT config_device_id, MAX(time_end) AS max_end FROM device_result_table GROUP BY config_device_id) m ON r.config_device_id=m.config_device_id AND r.time_end=m.max_end WHERE r.config_device_id IN (SELECT device_id FROM cfgdb.device_table)), success AS (SELECT config_device_id, MAX(time_end) AS last_success FROM device_result_table WHERE status IN (2,5,8) GROUP BY config_device_id) SELECT l.config_device_id, REPLACE(IFNULL(l.device_name,''),CHAR(34),''), IFNULL(l.status,99), l.bytes, CASE WHEN l.tend>0 AND l.tstart>0 AND l.tend>=l.tstart THEN (l.tend-l.tstart) ELSE 0 END, l.tend, IFNULL(s.last_success,0) FROM latest l LEFT JOIN success s ON s.config_device_id=l.config_device_id ORDER BY l.config_device_id ASC;"
    q_b="SELECT device_id, REPLACE(IFNULL(host_name,''),CHAR(34),''), IFNULL(backup_type,'') FROM device_table ORDER BY device_id ASC;"
    q_c="SELECT IFNULL(SUM(CASE WHEN status IN (2,8) THEN 1 ELSE 0 END),0), IFNULL(SUM(CASE WHEN status IN (3,4) THEN 1 ELSE 0 END),0), IFNULL(SUM(CASE WHEN status=5 THEN 1 ELSE 0 END),0), IFNULL(SUM(CASE WHEN status=1 THEN 1 ELSE 0 END),0) FROM device_result_table WHERE time_end>=strftime('%s','now','localtime','start of day') AND time_end<strftime('%s','now','localtime','start of day','+1 day');"

    layer2="sqlite3 -csv -noheader /volume1/@ActiveBackup/activity.db \"${q_a}\"; echo ===SPLIT===; sqlite3 -csv -noheader /volume1/@ActiveBackup/config.db \"${q_b}\"; echo ===SPLIT===; sqlite3 -csv -noheader /volume1/@ActiveBackup/activity.db \"${q_c}\""
    escaped="${layer2//\"/\\\"}"

    printf 'command="%s",no-agent-forwarding,no-X11-forwarding,no-pty,no-port-forwarding,no-user-rc %s\n' "$escaped" "$pubkey" > "$line_file"
    chmod 600 "$line_file"
    chown "$ZBX_PULL_CRON_USER" "$line_file"

    echo ""
    warn "One manual step left — on the Synology, append this EXACT line to /root/.ssh/authorized_keys (root, since only root can read the ABB SQLite files by default; the forced command restricts this key to 3 fixed read-only queries, nothing else, even if it leaks):"
    echo ""
    cat "$line_file"
    echo ""
    ok "(also saved to ${line_file})"
  else
    # DSM blocks direct root SSH login here: authenticate as a regular admin
    # account instead, and reach root only through a single, tightly scoped
    # NOPASSWD sudo rule for one fixed wrapper script — never a stored password.
    printf 'command="sudo /usr/local/bin/abb_pull_query.sh",no-agent-forwarding,no-X11-forwarding,no-pty,no-port-forwarding,no-user-rc %s\n' "$pubkey" > "$line_file"
    chmod 600 "$line_file"
    chown "$ZBX_PULL_CRON_USER" "$line_file"

    echo ""
    warn "Manual steps left on the Synology (DSM blocks direct root SSH, so this uses ${ZBX_PULL_REMOTE_USER} + a scoped NOPASSWD sudo rule — see INSTALL.md, SSH Pull, 'administrateur + sudo'):"
    warn "  1) Deploy synology/abb_pull_query.sh to /usr/local/bin/abb_pull_query.sh, owned by root, chmod 700"
    warn "  2) sudo visudo  → add exactly this line at the end:"
    echo ""
    echo "     ${ZBX_PULL_REMOTE_USER} ALL=(root) NOPASSWD: /usr/local/bin/abb_pull_query.sh"
    echo ""
    warn "  3) Append this EXACT line to ${ZBX_PULL_REMOTE_USER}'s ~/.ssh/authorized_keys:"
    echo ""
    cat "$line_file"
    echo ""
    ok "(also saved to ${line_file})"
  fi
}

###############################################################################
# Check installation
###############################################################################
check_installation() {
  echo ""
  printf "${BOLD}═══ Installation Check ═══${NC}\n"
  local errors=0

  id "$ZBX_USER" >/dev/null 2>&1 || die "User $ZBX_USER not found — run this on the Zabbix host"

  printf "\n${BOLD}Zabbix:${NC}\n"
  [ -x "${ZBX_EXT_DIR}/abb.sh" ] && ok "abb.sh" || { fail "abb.sh missing"; errors=$((errors+1)); }
  [ -x "${ZBX_EXT_DIR}/abb_pull.sh" ] && ok "abb_pull.sh" || { fail "abb_pull.sh missing"; errors=$((errors+1)); }
  [ -f /etc/cron.d/abb-monitoring-pull ] && ok "Pull cron present" || { fail "Pull cron missing: /etc/cron.d/abb-monitoring-pull"; errors=$((errors+1)); }
  [ -d "$ZBX_CSV_PATH" ] && ok "CSV path reachable" || { fail "CSV path missing: $ZBX_CSV_PATH"; errors=$((errors+1)); }

  if [ -f "${ZBX_CSV_PATH}/ActiveBackupExport.csv" ]; then
    local age
    age=$(( $(date +%s) - $(stat -c '%Y' "${ZBX_CSV_PATH}/ActiveBackupExport.csv") ))
    [ "$age" -lt 5400 ] && ok "CSV age: ${age}s (fresh)" || warn "CSV age: ${age}s (stale >5400s — check pull.log)"

    local count
    count="$(sudo -u "$ZBX_USER" "${ZBX_EXT_DIR}/abb.sh" device_count 2>/dev/null || echo "FAIL")"
    [ "$count" != "FAIL" ] && ok "device_count=$count (as $ZBX_USER)" || { fail "abb.sh fails as $ZBX_USER"; errors=$((errors+1)); }

    local check
    check="$(sudo -u "$ZBX_USER" "${ZBX_EXT_DIR}/abb.sh" check 5400 2>/dev/null; echo $?)"
    [ "$check" = "0" ] || [ "$(echo "$check" | tail -1)" = "0" ] && ok "check passed" || { fail "check failed"; errors=$((errors+1)); }
  else
    warn "CSV not found yet — check pull.log next to where it should be"
  fi

  echo ""
  [ "$errors" = "0" ] && ok "All checks passed" || fail "$errors error(s) found"
}

###############################################################################
# Uninstall
###############################################################################
uninstall() {
  echo ""
  printf "${BOLD}═══ Uninstall ═══${NC}\n"
  local ans
  ans="$(ask "This will remove all ABB monitoring scripts from this Zabbix host. Continue? [y/N]")"
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "Aborted."; exit 0; }

  rm -f "${ZBX_EXT_DIR}/abb.sh" "${ZBX_EXT_DIR}/abb-enh.sh" "${ZBX_EXT_DIR}/abb_pull.sh" 2>/dev/null && ok "Zabbix scripts removed" || true
  rm -f /etc/cron.d/abb-monitoring-pull 2>/dev/null && ok "Pull cron removed" || true
  rm -f "$(dirname "$ZBX_CSV_PATH")/.env" 2>/dev/null && ok ".env removed" || true

  warn "CSV files and the Zabbix template were NOT removed (manual cleanup if needed)"
  warn "On the Synology: remove the forced-command line from authorized_keys (and, if used, the sudoers rule + abb_pull_query.sh)"
  ok "Uninstall complete"
}

###############################################################################
# Interactive / CLI
###############################################################################
configure_zabbix_paths() {
  local v
  v="$(ask "  External scripts directory [$ZBX_EXT_DIR]:")"
  [ -n "$v" ] && ZBX_EXT_DIR="$v"

  v="$(ask "  CSV directory [$ZBX_CSV_PATH]:")"
  [ -n "$v" ] && ZBX_CSV_PATH="$v"

  v="$(ask "  Run the pull cron as which LOCAL user [$ZBX_PULL_CRON_USER]:")"
  [ -n "$v" ] && ZBX_PULL_CRON_USER="$v"

  v="$(ask "  Synology SSH login — [1] root (direct)  [2] another account + sudo (DSM often blocks direct root SSH) [1]:")"
  if [ "$v" = "2" ]; then
    v="$(ask "  Synology account to SSH as [administrateur]:")"
    ZBX_PULL_REMOTE_USER="${v:-administrateur}"
  else
    ZBX_PULL_REMOTE_USER="root"
  fi

  v="$(ask "  Zabbix user [$ZBX_USER]:")"
  [ -n "$v" ] && ZBX_USER="$v"
}

main_interactive() {
  printf "\n${BOLD}═══ ABB Monitoring Installer (SSH Pull) ═══${NC}\n"

  printf "  ${BOLD}1)${NC} Install / reconfigure\n"
  printf "  ${BOLD}2)${NC} Check installation\n"
  printf "  ${BOLD}3)${NC} Uninstall\n"
  printf "  ${BOLD}q)${NC} Quit\n"

  local choice
  choice="$(ask "Select [1-3/q]:")"
  choice="$(echo "$choice" | tr -d ')')"

  case "$choice" in
    1) check_root; configure_zabbix_paths; install_zabbix ;;
    2) check_installation ;;
    3) check_root; uninstall ;;
    q|Q) exit 0 ;;
    *) die "Invalid choice. Use 1-3 or q." ;;
  esac
}

###############################################################################
# Entrypoint
###############################################################################
case "${1:-}" in
  zabbix)      check_root; install_zabbix ;;
  --check)     check_installation ;;
  --uninstall) check_root; uninstall ;;
  --help|-h)
    echo "Usage: $0 [zabbix|--check|--uninstall]"
    echo "  No args = interactive mode"
    ;;
  *)           main_interactive ;;
esac
