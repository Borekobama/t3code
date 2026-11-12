#!/bin/zsh
# Mirror the MacBook's arsenal skill deployments onto this Mac mini.
# The arsenal repo is pulled; each manifest entry becomes a symlink in ~/.claude/skills or ~/.codex/skills.
# Only symlinks that point into the arsenal are managed; other entries (e.g. T3's "synced") are left alone.
#   skills-sync.sh             pull and relink
#   skills-sync.sh --dry-run   show what would change
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
ARSENAL=$HOME/skills/global-skill-arsenal
MANIFEST=${MANIFEST:-$HOME/t3-fork/skills-manifest.txt}
DRY=${1:-}

if [[ ! -d $ARSENAL/.git ]]; then
  mkdir -p "${ARSENAL:h}"
  git clone -q git@github.com:Borekobama/global-skill-arsenal.git "$ARSENAL"
else
  git -C "$ARSENAL" pull -q --ff-only
fi

typeset -A root=(claude "$HOME/.claude/skills" codex "$HOME/.codex/skills")
typeset -A wanted
linked=0; removed=0; missing=0
while read -r agent name; do
  [[ -z $agent || $agent == \#* ]] && continue
  dir=${root[$agent]:-}; [[ -n $dir ]] || continue
  wanted[$agent/$name]=1
  src=$ARSENAL/skills/$name
  if [[ ! -f $src/SKILL.md ]]; then print "missing in arsenal: $name"; ((missing++)) || true; continue; fi
  if [[ "$(readlink "$dir/$name" 2>/dev/null)" != "$src" ]]; then
    if [[ -e $dir/$name && ! -L $dir/$name ]]; then print "skip (real folder exists): $dir/$name"; continue; fi
    [[ $DRY == --dry-run ]] || { mkdir -p "$dir"; ln -sfn "$src" "$dir/$name"; }
    ((linked++)) || true
  fi
done < "$MANIFEST"

for agent dir in ${(kv)root}; do
  for link in "$dir"/*(N@); do
    target=$(readlink "$link")
    [[ $target == $ARSENAL/skills/* ]] || continue
    if [[ -z ${wanted[$agent/${link:t}]:-} ]]; then
      [[ $DRY == --dry-run ]] || rm -f "$link"
      ((removed++)) || true
    fi
  done
done
print "$(date +%H:%M:%S) linked=$linked removed=$removed missing=$missing (arsenal $(git -C "$ARSENAL" rev-parse --short HEAD))"
