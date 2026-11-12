#!/bin/zsh
# Deploy (or roll back to) one commit of the T3 fork as the live server on this Mac.
#
#   deploy.sh            deploy HEAD of ~/Developer/t3code
#   deploy.sh <commit>   deploy that commit; an already built release is reused, so this is also rollback
#   deploy.sh --list     show built releases and the live one
#
# Each release is a detached git worktree under ~/t3-fork/releases/<sha12> with its own node_modules
# and build. ~/t3-fork/current points at the live one; the LaunchAgent local.t3code-fork runs it.
# User data stays in ~/.t3 and is never touched here.
set -euo pipefail

REPO=$HOME/Developer/t3code
ROOT=$HOME/t3-fork
NODE_BIN=$HOME/.local/share/vite-plus/js_runtime/node/26.12.1/bin
LABEL=local.t3code-fork
export PATH="$NODE_BIN:$HOME/.local/share/vite-plus/bin:$PATH"

if [[ ${1:-} == --list ]]; then
  live=$(readlink "$ROOT/current" 2>/dev/null || true)
  for dir in "$ROOT"/releases/*(N/); do
    mark=" "; [[ $dir == "$live" ]] && mark="*"
    print "$mark ${dir:t}  $(git -C "$dir" log -1 --format='%cs %s' 2>/dev/null)"
  done
  exit 0
fi

commit=$(git -C "$REPO" rev-parse --verify "${1:-HEAD}^{commit}")
dir=$ROOT/releases/${commit[1,12]}

if [[ ! -f $dir/apps/server/dist/bin.mjs ]]; then
  mkdir -p "$ROOT/releases"
  [[ -d $dir ]] || git -C "$REPO" worktree add --detach "$dir" "$commit"
  (cd "$dir" && vp i && vp run --filter @t3tools/web --filter t3 build)
fi

"$NODE_BIN/node" "$dir/apps/server/dist/bin.mjs" --version
ln -sfh "$dir" "$ROOT/current"
print "live: ${dir:t} ($(git -C "$dir" log -1 --format='%h %s'))"

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
  print "restarted $LABEL"
else
  print "$LABEL is not loaded; load it with: launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$LABEL.plist"
fi
