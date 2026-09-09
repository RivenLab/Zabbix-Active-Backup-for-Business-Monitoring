#!/bin/sh
# abb_pull_query.sh — read-only ABB status queries for the SSH Pull transport.
#
# Deploy this ONCE on the Synology (e.g. to /usr/local/bin/abb_pull_query.sh,
# root-owned, mode 700) when direct root SSH login is not available (DSM
# often restricts it). It is invoked via a single, tightly scoped NOPASSWD
# sudo rule from a forced SSH command on a regular admin account — see
# INSTALL.md, "SSH Pull — administrateur + sudo".
#
# Prints 3 fixed, read-only SELECT results to stdout, separated by
# "===SPLIT===" markers. Takes no arguments — none are needed or used.
#
# Maintainer: Alexander Fox | PlaNet Fox

set -eu

DB_DIR="${ABB_DB_DIR:-/volume1/@ActiveBackup}"
SQLITE="${ABB_SQLITE:-/usr/bin/sqlite3}"

"$SQLITE" -csv -noheader "${DB_DIR}/activity.db" "ATTACH DATABASE '${DB_DIR}/config.db' AS cfgdb; WITH latest AS (SELECT r.config_device_id, r.device_name, r.status, COALESCE(r.transfered_bytes,0) AS bytes, COALESCE(r.time_start,0) AS tstart, COALESCE(r.time_end,0) AS tend FROM device_result_table r JOIN (SELECT config_device_id, MAX(time_end) AS max_end FROM device_result_table GROUP BY config_device_id) m ON r.config_device_id=m.config_device_id AND r.time_end=m.max_end WHERE r.config_device_id IN (SELECT device_id FROM cfgdb.device_table)), success AS (SELECT config_device_id, MAX(time_end) AS last_success FROM device_result_table WHERE status IN (2,5,8) GROUP BY config_device_id) SELECT l.config_device_id, REPLACE(IFNULL(l.device_name,''),CHAR(34),''), IFNULL(l.status,99), l.bytes, CASE WHEN l.tend>0 AND l.tstart>0 AND l.tend>=l.tstart THEN (l.tend-l.tstart) ELSE 0 END, l.tend, IFNULL(s.last_success,0) FROM latest l LEFT JOIN success s ON s.config_device_id=l.config_device_id ORDER BY l.config_device_id ASC;"

echo "===SPLIT==="

"$SQLITE" -csv -noheader "${DB_DIR}/config.db" "SELECT device_id, REPLACE(IFNULL(host_name,''),CHAR(34),''), IFNULL(backup_type,'') FROM device_table ORDER BY device_id ASC;"

echo "===SPLIT==="

"$SQLITE" -csv -noheader "${DB_DIR}/activity.db" "SELECT IFNULL(SUM(CASE WHEN status IN (2,8) THEN 1 ELSE 0 END),0), IFNULL(SUM(CASE WHEN status IN (3,4) THEN 1 ELSE 0 END),0), IFNULL(SUM(CASE WHEN status=5 THEN 1 ELSE 0 END),0), IFNULL(SUM(CASE WHEN status=1 THEN 1 ELSE 0 END),0) FROM device_result_table WHERE time_end>=strftime('%s','now','localtime','start of day') AND time_end<strftime('%s','now','localtime','start of day','+1 day');"
