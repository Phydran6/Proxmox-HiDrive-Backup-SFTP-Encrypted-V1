# Proxmox-HiDrive-Backup-SFTP-Encrypted

Encrypted offsite backups for Proxmox VE via SFTP with GFS (Grandfather-Father-Son) retention policy.

## Features

- **vzdump** all VMs and containers with ZSTD compression
- **AES-256-CBC** encryption before upload
- **rclone** upload via SFTP with parallel streams
- **GFS retention** policy (daily/weekly/monthly)
- **Email notifications** on failure via PVE sendmail
- **Log rotation** and detailed progress logging

## Requirements

- Proxmox VE 7.x or 8.x
- `rclone` (`apt install rclone`)
- `openssl` (pre-installed on PVE)
- NAS or local storage as intermediate backup target
- `sendmail` (optional, pre-installed on PVE for error notifications)

## Quick Start

### 1. Install rclone and configure SFTP remote

```bash
apt install rclone -y
rclone config
# Follow the prompts to set up your SFTP remote
# Test: rclone lsd your-remote:/
```

### 2. Create encryption key

```bash
echo "YOUR_VERY_SECURE_PASSWORD" > /root/.backup-encryption-key
chmod 600 /root/.backup-encryption-key
```

> ⚠️ **Store this password safely (e.g. password manager, printed in a safe).** Without it, your backups cannot be restored!

### 3. Install the script

```bash
cp pve-backup-offsite.sh /usr/local/bin/
chmod +x /usr/local/bin/pve-backup-offsite.sh
```

### 4. Edit configuration

Edit the `CONFIGURATION` section at the top of the script:

```bash
nano /usr/local/bin/pve-backup-offsite.sh
```

| Variable | Description | Example |
|---|---|---|
| `BACKUP_DIR` | Intermediate storage path (NAS) | `/mnt/pve/NAS-Backup/vzdump-offsite` |
| `RCLONE_REMOTE` | rclone remote + path | `myremote:/backups/pve` |
| `NAS_MOUNTPOINT` | NAS mount to check | `/mnt/pve/NAS-Backup` |
| `GFS_DAILY` | Daily backups to keep | `7` |
| `GFS_WEEKLY` | Weekly backups to keep | `4` |
| `GFS_MONTHLY` | Monthly backups to keep | `12` |

### 5. Test run

```bash
# Run in foreground
/usr/local/bin/pve-backup-offsite.sh

# Or run in background (survives SSH disconnect)
nohup /usr/local/bin/pve-backup-offsite.sh > /var/log/pve-backup-offsite.log 2>&1 &
tail -f /var/log/pve-backup-offsite.log
```

### 6. Automate with cron

```bash
crontab -e
# Add: run daily at 1:00 AM
0 1 * * * /usr/local/bin/pve-backup-offsite.sh >> /var/log/pve-backup-offsite.log 2>&1
```

## Restore

```bash
# 1. Download backup from remote
rclone copy your-remote:/backups/pve/2026-02-16_01-00/ /tmp/restore/

# 2. Decrypt
openssl enc -aes-256-cbc -d -pbkdf2 \
    -in /tmp/restore/vzdump-qemu-100-*.vma.zst.enc \
    -out /tmp/restore/vzdump-qemu-100.vma.zst \
    -pass file:/root/.backup-encryption-key

# 3. Restore in Proxmox
qmrestore /tmp/restore/vzdump-qemu-100.vma.zst 100
```

## GFS Retention Policy

| Level | Default | Description |
|---|---|---|
| **Son** (daily) | 7 | Keeps the last N daily backups |
| **Father** (weekly) | 4 | Keeps the last N Sunday backups |
| **Grandfather** (monthly) | 12 | Keeps the last N 1st-of-month backups |

Backups that don't match any retention category are deleted.

### Storage Calculation

`(GFS_DAILY + GFS_WEEKLY + GFS_MONTHLY) × backup_size = max storage`

Example: (7+4+12) × 150 GiB = ~3.5 TB max. Adjust values to fit your storage.

## Monitoring

```bash
# Live log
tail -f /var/log/pve-backup-offsite.log

# Last backup result
tail -20 /var/log/pve-backup-offsite.log

# Check cron is set
crontab -l
```

## Tested With

- Proxmox VE 8.x
- Strato HiDrive (SFTP)
- Hetzner Storage Box (SFTP)

## License

MIT
