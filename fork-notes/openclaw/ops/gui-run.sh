#!/bin/zsh
# Run one command inside this user's GUI login session (launchd domain gui/<uid>) and print its output.
# SSH sessions cannot read the login keychain; GUI-session LaunchAgents (Gateway, T3) can.
#   gui-run.sh 'claude auth status --text'
set -euo pipefail
[[ $# -eq 1 ]] || { print -u2 "usage: gui-run.sh '<command>'"; exit 2; }
label=local.gui-run.$$
dir=$(mktemp -d)
chmod 700 "$dir"
plist=$dir/$label.plist
print -r -- "$1" > "$dir/cmd"
/usr/libexec/PlistBuddy -c "Add :Label string $label" \
  -c "Add :ProgramArguments array" \
  -c "Add :ProgramArguments:0 string /bin/zsh" \
  -c "Add :ProgramArguments:1 string $dir/cmd" \
  -c "Add :StandardOutPath string $dir/out" \
  -c "Add :StandardErrorPath string $dir/out" \
  -c "Add :WorkingDirectory string $HOME" \
  -c "Add :RunAtLoad bool true" "$plist" >/dev/null
print -r -- 'print -r -- "__exit=$?" ' >> "$dir/cmd"
launchctl bootstrap "gui/$(id -u)" "$plist"
for _ in {1..600}; do
  grep -q '^__exit=' "$dir/out" 2>/dev/null && break
  sleep 0.5
done
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
cat "$dir/out" 2>/dev/null
rm -rf "$dir"
