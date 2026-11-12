#!/bin/zsh
# Store the Telegram bot token for OpenClaw without echoing it (channels.telegram.tokenFile).
set -euo pipefail
dir=$HOME/.openclaw/secrets; file=$dir/telegram-bot-token
umask 077; mkdir -p "$dir"; chmod 700 "$dir"
print -n "Paste the NEW bot token from BotFather (input hidden), then Enter: "
IFS= read -rs token; print
token=${token//[[:space:]]/}
if [[ ! $token =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$ ]]; then print "That does not look like a bot token; nothing saved." >&2; exit 1; fi
print -rn -- "$token" > "$file.tmp" && chmod 600 "$file.tmp" && mv -f "$file.tmp" "$file"
unset token
print "Saved to $file (mode 600, ${#$(cat $file)} characters). You can close this tab."
