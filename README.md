# SafeVault

SafeVault is a Bash-first PostgreSQL backup and disaster-recovery portfolio project.

Phase 1 includes:

- PostgreSQL 16 in Docker with a seeded VC-fund schema.
- MinIO as local S3-compatible object storage.
- Full backups with `pg_dump` custom compressed format.
- GPG public-key encryption.
- SHA-256 checksums.
- Upload and checksum verification through the AWS CLI.

Phase 2 includes:

- Interactive or `--latest` full-backup restore into a fresh Postgres container.
- Checksum verification before decrypting.
- Sanity queries after restore.
- Automated DR drill that restores latest backup into a throwaway container and compares row counts with production.

## Quick start

```bash
cp safevault.conf.example safevault.conf
docker compose up -d
export GNUPGHOME="$PWD/.gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-generate-key safevault@example.local default default never
./scripts/backup-full.sh
./scripts/restore.sh --latest
./scripts/verify-drill.sh
```

MinIO console: <http://localhost:9001>

- User: `minioadmin`
- Password: `minioadmin123`

## Seeded tables

- `funds`
- `investors`
- `capital_calls`

## Phase status

Phase 1 is intentionally scoped to environment setup and full backups. Restore drills, WAL archiving, PITR, cron, alerts, CI, and the final README expansion are later phases.

Phase 2 adds restore and DR drill coverage. WAL archiving and point-in-time recovery are still reserved for Phase 3.
