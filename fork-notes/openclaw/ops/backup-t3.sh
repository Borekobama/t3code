#!/bin/zsh
# Encrypted restic backup of T3 (~/.t3 userdata) and Codex (~/.codex) to R2, next to the OpenClaw backups.
#   backup-t3.sh                    run a backup, apply retention, check the repository
#   backup-t3.sh init               create the repository (once)
#   backup-t3.sh <restic args...>   run restic against the repository (e.g. snapshots, restore)
# Secrets come from ~/.openclaw/.env (R2 token + OPENCLAW_STORAGE_PASSPHRASE, reused as the restic password).
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
set -a; . "$HOME/.openclaw/.env"; set +a
export AWS_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=auto
export RESTIC_PASSWORD=$OPENCLAW_STORAGE_PASSPHRASE
export RESTIC_REPOSITORY="s3:https://9b7d41a22815b37d87c6115d3f774afb.r2.cloudflarestorage.com/openclaw-backups/mac-mini-m6/t3"
unset R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY OPENCLAW_STORAGE_PASSPHRASE

if [[ ${1:-} == init ]]; then exec restic init; fi
if [[ $# -gt 0 ]]; then exec restic "$@"; fi

stage="$HOME/.t3-backup-staging"
rm -rf "$stage"
mkdir -m 700 "$stage"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT
# Consistent copies of live SQLite databases (WAL mode), taken while T3 and Codex keep running.
sqlite3 "$HOME/.t3/userdata/statev2.sqlite" ".backup \"$stage/t3-statev2.sqlite\""
if [[ -f "$HOME/.codex/state_5.sqlite" ]]; then
  sqlite3 "$HOME/.codex/state_5.sqlite" ".backup \"$stage/codex-state_5.sqlite\""
fi

restic backup --host mac-mini-m6 --tag t3 \
  --exclude "$HOME/.t3/userdata/logs" \
  --exclude "$HOME/.t3/userdata/*.sqlite" --exclude "$HOME/.t3/userdata/*.sqlite-*" \
  --exclude "$HOME/.codex/*.sqlite" --exclude "$HOME/.codex/*.sqlite-*" --exclude "$HOME/.codex/log" \
  "$HOME/.t3/userdata" "$HOME/.t3/service.env" "$HOME/.codex" "$stage"
restic forget --host mac-mini-m6 --tag t3 --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
restic check
