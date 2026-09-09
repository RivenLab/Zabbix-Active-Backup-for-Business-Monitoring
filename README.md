# Synology Active Backup for Business — Zabbix Monitoring

Monitor [Synology Active Backup for Business](https://www.synology.com/en-global/dsm/feature/active_backup_business) with Zabbix using CSV exports and a single external script.

## Features

- **Minimal overhead** — 4 external script calls per cycle, regardless of device count
- **Dependent-item architecture** — one JSON master, 12+ items derived via JavaScript preprocessing
- **Auto-discovery** — new backup devices appear automatically via LLD
- **Recovery triggers** — all alerts auto-resolve, no manual close needed
- **Backup-window awareness** — "last success too old" suppressed while backup is running
- **Per-device graphs** — backup size + duration created automatically per device
- **Dashboard included** — KPI widgets, problem overview, trend graphs

## Architecture

```
┌──────────────────────────┐   SSH Pull     ┌──────────────────────────┐
│  Synology NAS            │  (hourly)      │  Zabbix Proxy / Server   │
│                          │ ◄──────────────│                          │
│  SQLite DBs              │  CSV files     │  abb_pull.sh (cron)      │
│  (root, forced command,  │  (7 columns)   │    ↓                     │
│   3 fixed read-only      │                │  ActiveBackupExport.csv │
│   SELECT queries)        │                │                          │
│                          │                │  abb.sh json  (1 fork)   │
│  Nothing else installed  │                │    ├─ 12 dependent items │
│  or scheduled here       │                │    └─ LLD (dependent)    │
│                          │                │  abb.sh check (1 fork)   │
│                          │                │  abb.sh *_today (2 fork) │
│                          │                │  Total: 4 forks/cycle    │
└──────────────────────────┘                └──────────────────────────┘
```

No NFS, no agent, no cron on the Synology — Zabbix connects out over SSH once an hour, and that's the only traffic between the two sides. See [INSTALL.md](INSTALL.md) for setup, including the fallback for DSM setups that block direct root SSH login.

## Quick Start

```bash
git clone <this-repo-url>
cd Zabbix-Active-Backup-for-Business-Monitoring
sudo ./install.sh
```

The interactive installer walks you through the Zabbix-side setup. See **[INSTALL.md](INSTALL.md)** for detailed manual instructions.

## Requirements

| Component | Version | Notes |
|-----------|---------|-------|
| Synology DSM | 7.x | Active Backup for Business installed |
| Zabbix | 6.4+ | Tested on 7.4+. JavaScript preprocessing required |
| SSH | — | Zabbix host → Synology, outbound only — see [INSTALL.md](INSTALL.md) |
| sqlite3 | — | Pre-installed on Synology |

## Repository Layout

```
├── synology/
│   └── abb_pull_query.sh                   # Deployed on the Synology only if root SSH is blocked
├── zabbix/
│   ├── abb.sh                              # External script (json, check, …)
│   ├── abb_pull.sh                         # Hourly cron: pulls CSVs from the Synology over SSH
│   └── abb-enh.sh                          # Enhanced report functions
├── template/
│   ├── Synology-ABB-Zabbix-Check.xml       # Zabbix template (import via UI)
│   └── ABB-Grafana-Dashboard.json          # Optional Grafana dashboard (alexanderzobnin-zabbix-datasource)
├── install.sh                              # Interactive / CLI installer (Zabbix side)
├── INSTALL.md                              # Setup guide
├── CHANGES.md                              # Changelog
└── README.md                               # This file
```

## Status Codes

These are ABB's internal status codes as stored in `device_result_table`:

| Code | Status  | Category | Trigger action |
|------|---------|----------|----------------|
| 1    | Running | Active   | Suppresses "too old" trigger |
| 2    | Success | OK       | Resolves ERROR/WARNING triggers |
| 3    | Aborted | Failed   | Counted as failed today |
| 4    | Error   | Failed   | HIGH alert per device |
| 5    | Warning | Warning  | WARNING alert per device |
| 8    | Partial | OK       | Resolves ERROR/WARNING triggers |
| 99   | Unknown | Fallback | Device not found in JSON |

## Template Macros

All thresholds are configurable — override per host as needed.

| Macro | Default | Description |
|-------|---------|-------------|
| `{$ABB.BACKUP.MAX.AGE}` | `129600` (36 h) | Alert if no success within this many seconds. Supports per-device override — see below |
| `{$ABB.BACKUP.MAX.DURATION}` | `43200` (12 h) | Alert if a single backup takes longer |
| `{$ABB.EXPORT.MAXAGE}` | `5400` (90 min) | CSV file staleness threshold — sized for the hourly pull cadence |
| `{$ABB.FAILED.THRESHOLD}` | `1` | Min. daily failures to trigger |
| `{$ABB.RATE.THRESHOLD}` | `90` | Min. overall success rate (%) |
| `{$ABB.MOUNTPOINT}` | *(empty)* | Only set if using an actual mount; `check` skips the mount check when empty |
| `{$ABB.EXPECT_REMOTE}` | *(empty)* | Expected remote source, only checked if `{$ABB.MOUNTPOINT}` is set |
| `{$ABB.EXPECT_FSTYPE}` | *(empty)* | Expected filesystem type, only checked if `{$ABB.MOUNTPOINT}` is set |

> Leave the three macros above empty (the default) — `check` then just validates CSV readability + freshness, with nothing to mount.

**Per-device backup schedule** — some VMs back up less often than others (e.g. 2×/week instead of daily), and the global `{$ABB.BACKUP.MAX.AGE}` would false-positive on those. Override it per device using Zabbix's macro context, keyed by the device's hostname as discovered (`{#HOSTNAME}`): on the host, add a macro named `{$ABB.BACKUP.MAX.AGE:"3CX_FCLR"}` with a larger value (e.g. `604800` for weekly) — that device's trigger uses it instead of the global default; every other device is unaffected.

## Triggers

| Trigger | Severity | Auto-recovers when… |
|---------|----------|----------------------|
| Export script or mount not OK | AVERAGE | `check` returns 0 |
| Device backup ERROR | HIGH | Status → Success (2) or Partial (8) |
| Device backup WARNING | WARNING | Status → Success (2) or Partial (8) |
| No successful backup for too long | HIGH | Age drops below `MAX_AGE` |
| Backup duration too long | WARNING | Duration drops below `MAX_DURATION` |
| N device(s) in ERROR (global) | WARNING | Error count = 0 |
| N failed backup(s) today | WARNING | Count drops below threshold |
| Success rate below N% | WARNING | Rate rises above threshold |

> **Post-import tip:** Set trigger dependencies in the Zabbix UI so that all triggers depend on *"Export script or mount not OK"*. This prevents alert storms when the SSH pull stops working.

## Dashboard

The template ships with a ready-made dashboard:

| Row | Widgets |
|-----|---------|
| 1 | Success Rate · Devices · Errors · Warnings · Total Bytes · Export Health |
| 2 | Active Problems (trigger overview) · Not-OK Device List |
| 3 | Backup Volume graph (7 d) · Success / Errors / Warnings trend (7 d) |

A standalone Grafana version is also available: `template/ABB-Grafana-Dashboard.json` (for the `alexanderzobnin-zabbix-datasource` plugin) — Grafana → Dashboards → Import → upload the file, pick your Zabbix datasource and host when prompted.

## Debugging

```bash
# Full JSON output (as zabbix user)
sudo -u zabbix /usr/lib/zabbix/externalscripts/abb.sh json | python3 -m json.tool

# Health check with debug output
ABB_DEBUG=1 /usr/lib/zabbix/externalscripts/abb.sh check 5400

# Human-readable report
/usr/lib/zabbix/externalscripts/abb-enh.sh report

# CSV sanity check (should show 7 columns)
head -2 /opt/monitoring/abb/ActiveBackupExport.csv
```

## Contributing

Issues and pull requests are welcome. Please test with `bash -n` (syntax check) and `xmllint --noout` (template validation) before submitting.

## License

[MIT](LICENSE)

## Author

Alexander Fox | [PlaNet Fox](https://planet-fox.com)
