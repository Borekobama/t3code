#!/bin/zsh
# Store R2 credentials and a generated backup passphrase in ~/.openclaw/.env without echoing them.
set -euo pipefail
envf=$HOME/.openclaw/.env
umask 077; touch "$envf"; chmod 600 "$envf"
setvar() {  # setvar NAME VALUE: replace or append NAME=VALUE in $envf
  local tmp=$(mktemp "$envf.XXXXXX")
  grep -v "^$1=" "$envf" > "$tmp" || true
  print -r -- "$1=$2" >> "$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$envf"
}
if ! grep -q "^OPENCLAW_STORAGE_PASSPHRASE=" "$envf"; then
  setvar OPENCLAW_STORAGE_PASSPHRASE "$(openssl rand -base64 32 | tr -d "\n")"
  print "Generated a new backup encryption passphrase."
else
  print "Keeping the existing backup encryption passphrase."
fi
print -n "R2 Access Key ID (hidden): "; IFS= read -rs kid; print
print -n "R2 Secret Access Key (hidden): "; IFS= read -rs sec; print
kid=${kid//[[:space:]]/}; sec=${sec//[[:space:]]/}
[[ $kid =~ ^[A-Za-z0-9]{20,64}$ && $sec =~ ^[A-Za-z0-9]{40,128}$ ]] || { print "Those do not look like R2 S3 keys; nothing changed for them." >&2; exit 1; }
setvar R2_ACCESS_KEY_ID "$kid"; setvar R2_SECRET_ACCESS_KEY "$sec"; unset kid sec
print "Saved R2 keys to $envf (mode 600)."
print
print "Save the backup passphrase in your password manager now. Without it the backups cannot be read."
print -n "Press Enter to show it... "; read -r _
grep "^OPENCLAW_STORAGE_PASSPHRASE=" "$envf" | cut -d= -f2-
print -n "Press Enter once it is saved; the screen will be cleared... "; read -r _
printf "\033[2J\033[3J\033[H"; print "Done. You can close this tab."
