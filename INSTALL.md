# Installation Guide

For automated setup, run `sudo ./install.sh`. This guide covers manual installation.

---

## Overview

The monitoring stack has two halves:

1. **Synology NAS** — holds the ABB status in SQLite databases
2. **Zabbix Proxy/Server** — reads that status as CSV and feeds Zabbix

They talk over **SSH Pull**: Zabbix connects out to the Synology on an hourly cron, runs 3 fixed read-only queries there, and writes the result locally. **Nothing is installed or scheduled on the Synology** beyond enabling SSH, one firewall rule, and one `authorized_keys` line (plus a small wrapper script if DSM blocks direct root SSH — see Step 2.5).

---

## Step 1: Zabbix Scripts (always required)

```bash
sudo cp zabbix/abb.sh zabbix/abb-enh.sh /usr/lib/zabbix/externalscripts/
sudo chmod 755 /usr/lib/zabbix/externalscripts/abb*.sh
sudo chown root:zabbix /usr/lib/zabbix/externalscripts/abb*.sh
```

`abb.sh` defaults to reading CSVs from `/opt/monitoring/abb`. **Zabbix invokes it directly** (the template's item keys don't set any environment variable), so if you point `ABB_CSV_PATH` anywhere else in Step 2, `abb.sh` itself won't know about it unless you also do one of:

- **Symlink** (simplest): `sudo mkdir -p /opt/monitoring && sudo ln -s /your/actual/csv/dir /opt/monitoring/abb` — no service restart needed.
- **systemd environment override**: `sudo systemctl edit zabbix-server` → add `Environment="ABB_CSV_PATH=/your/actual/csv/dir"` under `[Service]`, then `sudo systemctl daemon-reload && sudo systemctl restart zabbix-server`.
- Or just edit the default directly in `zabbix/abb.sh` / `zabbix/abb-enh.sh` before copying them, if this is a single fixed deployment.

---

## Step 2: SSH Pull — Zabbix Connects Out, Nothing on the Synology

Zabbix runs its own hourly cron, SSHes into the Synology, and runs 3 fixed, read-only `SELECT` queries against the ABB SQLite databases directly — no script, no cron, no rsync needed on the Synology at all.

This normally authenticates as **root** (only root can read the ABB SQLite files by default, and granting a non-root account read ACLs is itself Synology-side setup this method is meant to avoid) — but the key is restricted via a forced command to those 3 exact queries. Even a leaked key can never do anything else: no shell, no other files, no writes. **Many DSM setups block direct root SSH login** — if that's yours, see Step 2.5 below for the fallback (still zero stored passwords).

### 2.1 On the Synology: enable SSH and restrict the firewall

**DSM → Control Panel → Terminal & SNMP** → enable SSH service (note the port, default 22).
Then, on the rack's firewall, allow inbound TCP/22 to the Synology **only from the Zabbix host's IP** — nothing else needed here.

### 2.2 On the Zabbix host: run the installer

```bash
sudo ./install.sh zabbix
# or interactive: sudo ./install.sh → option 1
```

For a fully non-interactive run: `sudo ABB_CSV_PATH=/your/csv/dir ZBX_PULL_REMOTE_USER=administrateur ./install.sh zabbix` (omit `ZBX_PULL_REMOTE_USER` — or set it to `root` — if root SSH login works).

It will ask whether the Synology SSH login is **root (direct)** or **another account + sudo** (pick the latter if you already know root SSH is blocked — see 2.5). Either way it generates a dedicated SSH key, pins the Synology's host-key fingerprint (**verify it** against DSM's own display — Control Panel → Terminal & SNMP — before trusting it), writes every setting into one `.env` file next to the CSV directory, installs an hourly cron (`/etc/cron.d/abb-monitoring-pull`, running as the local user you choose — defaults to whoever ran `sudo`), and prints a ready-to-paste `authorized_keys` line — copy it as-is, there's nothing to fill in.

### 2.3 On the Synology: authorize the key

**If root SSH works:** paste the line the installer printed into `/root/.ssh/authorized_keys` (create the file/dir with mode `600`/`700` if they don't exist yet). That's the only file this method touches on the NAS.

**If DSM blocked root SSH** and you chose the sudo fallback: see 2.5 instead — there are a couple more one-time steps.

### 2.4 Test

```bash
# Everything comes from the .env file the installer wrote — pass just that:
ABB_PULL_ENV_FILE=/opt/Zabbix_ABB_Monitoring/.env /usr/lib/zabbix/externalscripts/abb_pull.sh
head -2 /opt/Zabbix_ABB_Monitoring/abb/ActiveBackupExport.csv   # should show 7 columns
```

(Adjust the paths above to wherever you actually pointed `ABB_CSV_PATH`.) If it fails, check `pull.log` next to the CSVs first — a mismatched forced command, an unreachable host, or a permissions issue on the NAS shows up there.

**All configuration lives in `.env`** (host, port, user, key/known_hosts paths, CSV directory) — edit that file to change anything later; no need to touch cron or re-run the installer. Nothing in it is secret (the private key itself is a separate, permission-protected file), so it's safe to inspect or back up.

### 2.5 If DSM blocks direct root SSH: administrateur + sudo (still no password)

Same key, same forced-command principle — just one extra hop, and **still zero stored or typed passwords**: the key logs in as a normal admin account, and a single, narrowly scoped `NOPASSWD` sudo rule lets it reach root for exactly one fixed script, nothing else.

1. **Deploy the query script** — copy `synology/abb_pull_query.sh` to the Synology as `/usr/local/bin/abb_pull_query.sh`, then:
   ```bash
   sudo chown root:root /usr/local/bin/abb_pull_query.sh
   sudo chmod 700 /usr/local/bin/abb_pull_query.sh
   ```
2. **Authorize it via sudoers** — `sudo visudo` (always use `visudo`, never edit `/etc/sudoers` directly with a text editor — it validates syntax before saving, so a typo can't lock out sudo entirely) and add this one line at the end:
   ```
   administrateur ALL=(root) NOPASSWD: /usr/local/bin/abb_pull_query.sh
   ```
   (replace `administrateur` with whatever account you told the installer). This grants passwordless `sudo` for **that exact script only** — nothing else that account can run gets a NOPASSWD pass.
3. **Authorize the key** — append the line `install.sh` printed (the short `command="sudo /usr/local/bin/abb_pull_query.sh",...` one) to that account's `~/.ssh/authorized_keys`.
4. **Test** the same way as 2.4. If it fails with something like `sudo: sorry, you must have a tty to run sudo`, add one more scoped sudoers line: `Defaults:administrateur !requiretty`.

**Keeping `abb_pull_query.sh` up to date**: it contains the same SQL as the root-direct forced command, including a filter so a device re-created with a new ABB device ID (e.g. after cloning a VM and re-pointing its backup task) doesn't leave its old ID stuck forever in "last status". If you ever change the SQL in `install.sh`'s root path, mirror the change into `synology/abb_pull_query.sh` and redeploy just that one file (steps above) — no need to touch the key, the sudoers rule, or the cron.

---

## Point Zabbix at the local directory, skip the mount check

Use `ABB_CSV_PATH=/opt/monitoring/abb` (or whatever directory you chose) — see Step 1's note if that's not the default. In the template, override these **host-level** macros to empty — `abb.sh check` skips the mount check entirely when `{$ABB.MOUNTPOINT}` is blank, and still validates CSV readability + freshness:

| Macro | Value |
|-------|-------|
| `{$ABB.MOUNTPOINT}` | *(empty)* |
| `{$ABB.EXPECT_REMOTE}` | *(empty)* |
| `{$ABB.EXPECT_FSTYPE}` | *(empty)* |

---

## Step 3: Zabbix Template

### Import

**Zabbix UI → Data collection → Templates → Import** → select `template/Synology-ABB-Zabbix-Check.xml` → **Import**

### Assign to host

**Data collection → Hosts → (your host) → Templates → Link new template** → search `Synology Active Backup` → **Update**

### Adjust macros

Host → **Macros** → **Inherited and host macros** → override as needed (see [README.md](README.md#template-macros) and the mount-macro table above). In particular, `{$ABB.EXPORT.MAXAGE}` (default 5400s/90min) should stay comfortably above your pull interval (1h), and `{$ABB.BACKUP.MAX.AGE}` supports a per-device override via macro context for devices with a different backup schedule than the rest of the fleet — see the README.

### Set trigger dependencies (recommended)

**Templates → Synology ABB… → Triggers** → each trigger → **Dependencies** → add `ABB: Export script or mount not OK`

---

## Step 4: Verify

1. Wait for the first pull cycle (hourly)
2. **Monitoring → Latest data** → filter by host → `ABB Raw JSON data` should have a value
3. All dependent items will populate automatically
4. After ~1 hour, LLD runs and per-device items appear
5. **Dashboards → ABB Monitoring** for the overview

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| JSON item empty | CSV not readable by zabbix | Check file permissions on the CSV directory |
| `check` returns 1 | CSV stale or missing | Re-run `abb_pull.sh` manually and check `pull.log` |
| `awk: cannot open .../ActiveBackupExport.csv` when running `abb.sh` manually without `ABB_CSV_PATH` set | Custom CSV path not visible to `abb.sh`'s own default | Symlink `/opt/monitoring/abb` to the real path, or set `ABB_CSV_PATH` in zabbix-server's systemd environment (see Step 1) |
| A specific device's trigger stays in PROBLEM forever even though backups now succeed | Device was re-created in ABB with a new device ID (e.g. cloned VM); the old ID's last status is stuck | Already handled going forward by the device_table filter in the query — for an already-stuck trigger, manually close it once in Zabbix (it won't reopen, since the orphaned ID no longer appears in the data at all) |
| Discovery finds no devices | JSON master empty | Fix JSON item first |
| All devices "Unknown" (99) | DEVICEID mismatch | Check CSV format |
| Template import fails | Zabbix too old | Requires 6.4+ with JS preprocessing |
| CSV not updating | SSH/forced-command/cron issue | Check `pull.log` next to the CSVs, test `abb_pull.sh` manually (Step 2.4) |

---

## Uninstall

```bash
sudo ./install.sh --uninstall
```

Or manually:

```bash
sudo rm /usr/lib/zabbix/externalscripts/abb.sh /usr/lib/zabbix/externalscripts/abb-enh.sh /usr/lib/zabbix/externalscripts/abb_pull.sh
sudo rm /etc/cron.d/abb-monitoring-pull
sudo rm /opt/Zabbix_ABB_Monitoring/.env   # or wherever ABB_CSV_PATH's parent directory is
```

On the Synology: remove the forced-command line from `authorized_keys` (root's or the admin account's), and if the sudo fallback was used, also remove the sudoers line and `/usr/local/bin/abb_pull_query.sh`.

Remove the template from the Zabbix UI separately.
