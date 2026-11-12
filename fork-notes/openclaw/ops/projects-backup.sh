#!/bin/zsh
# Nightly protection for ~/Projects on the Mac mini.
#  1. Unpushed commits in repos you own (origin Borekobama/*) are pushed to hidden refs
#     refs/backup/mac-mini-m6/<branch> on GitHub. Real branches are never touched, so no CI or deploy runs.
#     Restore: git fetch origin 'refs/backup/mac-mini-m6/*:refs/remotes/backup/*'
#  2. What GitHub can't hold goes to the encrypted restic repo on R2 (tag "projects"): every .env* file
#     (examples excluded) and the .git folder of repos without a pushable remote.
#  3. Telegram: one message per branch that stays unpushed for more than a day, and any backup failure.
#   projects-backup.sh            run it
#   projects-backup.sh --seed     record today's unpushed branches as already reported (no messages)
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
ROOT=$HOME/Projects
HOST=mac-mini-m6
STATE=$HOME/.projects-backup-state
OPENCLAW=$HOME/.openclaw/bin/openclaw
TELEGRAM_TO=640306272
SEED=${1:-}
set -a; . "$HOME/.openclaw/.env"; set +a
export AWS_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=auto
export RESTIC_PASSWORD=$OPENCLAW_STORAGE_PASSPHRASE
export RESTIC_REPOSITORY="s3:https://9b7d41a22815b37d87c6115d3f774afb.r2.cloudflarestorage.com/openclaw-backups/mac-mini-m6/t3"
unset R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY OPENCLAW_STORAGE_PASSPHRASE

prune=( \( -name node_modules -o -name .next -o -name vendor -o -name .venv -o -name venv -o -name dist -o -name build \) -prune )
list=$(mktemp); trap 'rm -f $list' EXIT
touch "$STATE"
now=$(date +%s); failures=(); stale=(); pushed=0

for gitpath in ${(f)"$(find "$ROOT" "${prune[@]}" -o -name .git -print -prune 2>/dev/null)"}; do
  repo=${gitpath:h}; rel=${repo#$ROOT/}
  origin=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  if [[ $origin != *Borekobama/* ]]; then
    print -r -- "$gitpath" >> "$list"   # no pushable remote: back up the whole history to R2
    continue
  fi
  git -C "$repo" fetch -q origin 2>/dev/null || { failures+=("fetch $rel"); continue; }
  for b in ${(f)"$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads)"}; do
    oldest=$(git -C "$repo" rev-list "$b" --not --remotes 2>/dev/null | tail -1)
    [[ -n $oldest ]] || continue
    if git -C "$repo" push -q --force origin "refs/heads/${b}:refs/backup/${HOST}/${b}" 2>/dev/null; then
      ((pushed++))
    else
      failures+=("push $rel $b")
    fi
    age=$(( now - $(git -C "$repo" log -1 --format=%ct "$oldest") ))
    key="${origin:t:r}|$b|$(git -C "$repo" rev-parse --short "$b")"
    if (( age > 86400 )) && ! grep -qxF -- "$key" "$STATE"; then
      print -r -- "$key" >> "$STATE"
      stale+=("$rel: $b ($(git -C "$repo" rev-list --count "$b" --not --remotes) commits)")
    fi
  done
done

find "$ROOT" "${prune[@]}" -o -name .git -prune -o -type f -name '.env*' ! -name '*.example' ! -name '*.sample' ! -name '*.template' -print >> "$list" 2>/dev/null
if ! restic backup --host $HOST --tag projects --quiet --files-from-verbatim "$list"; then failures+=("restic backup"); fi
restic forget --host $HOST --tag projects --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune --quiet || failures+=("restic forget")

print "$(date +%F\ %T) backup refs pushed=$pushed newly-stale=${#stale} failures=${#failures} files=$(wc -l < $list | tr -d ' ')"
[[ $SEED == --seed ]] && exit 0
msg=""
(( ${#stale} )) && msg+="Unpushed for over a day (safe in refs/backup on GitHub):"$'\n'"${(F)stale}"$'\n'
(( ${#failures} )) && msg+="Projects backup problems:"$'\n'"${(F)failures}"
[[ -n $msg ]] && "$OPENCLAW" message send --channel telegram -t $TELEGRAM_TO -m "🤖 ${msg}" >/dev/null 2>&1
(( ${#failures} == 0 ))
