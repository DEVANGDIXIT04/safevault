# SafeVault: Automated PostgreSQL Backup & Disaster Recovery System

SafeVault is a robust, automated PostgreSQL backup and disaster recovery portfolio project built entirely in pure Bash. It demonstrates strong DevOps and shell-scripting fundamentals including secure cryptography, continuous WAL archiving, Point-in-Time Recovery (PITR), automated scheduling, lifecycle retention policies, and CI testing.

---

## 🏗️ Architecture

SafeVault is designed around a secure architecture that never allows unencrypted data to touch network storage.

```mermaid
flowchart TD
    subgraph Local Environment
        PG[(PostgreSQL 16\nDocker Container)]
        Cron(Cron / Task Scheduler)
        BashScripts[Bash Automation Scripts\nbackup, setup, verify, etc.]
        GPG((GPG Keys))
    end

    subgraph Object Storage
        MinIO[(MinIO S3 Compatible Storage\nor AWS S3)]
    end

    subgraph CI / Operations
        Actions(GitHub Actions\nShellCheck & Smoke Tests)
        Logrotate(Logrotate)
        Webhook{{Webhook Alerts\nSlack/Discord}}
    end

    Cron -- Triggers --> BashScripts
    BashScripts -- pg_basebackup /\npg_dump --> PG
    PG -- archive_command\n(archive-wal.sh) --> MinIO
    BashScripts -- encrypts with --> GPG
    BashScripts -- pushes encrypted\nbackups to --> MinIO
    BashScripts -- sends alerts to --> Webhook
    Logrotate -. rotates .-> BashScripts
    Actions -. tests .-> BashScripts
```

### Key Features
1. **Physical & Logical Backups:** Supports both `pg_dump` logical backups and `pg_basebackup` physical backups.
2. **Point-in-Time Recovery (PITR):** Continuously archives Postgres Write-Ahead Logs (WALs) allowing recovery to any exact second to undo disastrous commands (e.g., accidental `DROP TABLE`).
3. **End-to-End Encryption:** All database dumps, base backups, and WAL files are GPG encrypted locally *before* being uploaded to storage.
4. **Automated DR Drills:** Features a `verify-drill.sh` script that automatically restores the latest backup into a throwaway container and compares production row counts against restored row counts.
5. **Lifecycle Management:** Applies S3 lifecycle policies to automatically prune old backups.
6. **Alerting:** Notifies external webhooks upon backup failures or successes.

---

## 🚀 Quick Start (Local MinIO)

SafeVault uses a local MinIO container to simulate an S3 bucket for completely free, local development.

```bash
# 1. Setup Configuration
cp safevault.conf.example safevault.conf

# 2. Start PostgreSQL and MinIO Containers
docker compose up -d

# 3. Generate a local GPG key for encryption
export GNUPGHOME="$PWD/.gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-generate-key safevault@example.local default default never

# 4. Initialize WAL Archiving and take a Base Backup
./scripts/backup-wal-setup.sh

# 5. Take a Logical Full Backup (Optional)
./scripts/backup-full.sh

# 6. Verify Backup Integrity via DR Drill
./scripts/verify-drill.sh
```

You can view the encrypted backups in the MinIO console: [http://localhost:9001](http://localhost:9001)
- **User:** `minioadmin`
- **Password:** `minioadmin123`

---

## ☁️ Switching to Production AWS S3

SafeVault is built using the standard `awscli`, meaning switching from the local MinIO container to a real AWS S3 bucket is a simple configuration change. No code rewrites are required.

### Steps to Switch to AWS

1. **Create an AWS S3 Bucket**
   - Go to the AWS Console and create a new bucket (e.g., `my-safevault-production-backups`).
   - Ensure the bucket is private and Block Public Access is fully enabled.

2. **Create an IAM User/Policy**
   - Create an IAM user with programmatic access.
   - Attach a policy allowing `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, and `s3:PutLifecycleConfiguration` exclusively for that bucket.

3. **Update `safevault.conf`**
   Modify your configuration file to point to AWS instead of `localhost`:

   ```bash
   # Remove the custom endpoint URL completely, or comment it out
   # S3_ENDPOINT_URL="http://localhost:9000"
   S3_ENDPOINT_URL=""

   # Set your real AWS bucket name
   S3_BUCKET="my-safevault-production-backups"

   # Add your real AWS credentials
   AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
   AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
   AWS_DEFAULT_REGION="us-east-1"
   ```

4. **Apply S3 Lifecycle Policies**
   Run the lifecycle script to push the retention rules to your real AWS bucket:
   ```bash
   ./scripts/apply-lifecycle.sh
   ```

5. **Restart Postgres Container**
   Because the WAL archiver runs continuously inside the Postgres container, it needs the updated environment variables. Restart the container to pick up the new AWS credentials:
   ```bash
   docker compose restart postgres
   ```

Once restarted, all new WAL segments, base backups, and full dumps will be securely encrypted and pushed directly to your AWS S3 bucket!

---

## 🛠️ Operations & Maintenance

- **Cron Scheduling:** See `cron/safevault.cron` for an example of how to schedule automated backups and drills in a Linux environment.
- **Log Management:** See `logrotate.conf` for standard log rotation configuration.
- **Alerts:** Set the `WEBHOOK_URL` in `safevault.conf` to a Slack or Discord webhook URL to receive success and failure notifications for all cron jobs.
- **CI Testing:** This repository includes a GitHub Actions workflow (`.github/workflows/ci.yml`) that runs `shellcheck` and executes a full Docker-based backup-and-restore smoke test on every push.
