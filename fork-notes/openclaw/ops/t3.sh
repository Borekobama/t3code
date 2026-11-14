#!/bin/zsh
# T3 CLI for the deployed fork, for people and for Dronk's exec (OpenClaw approval rules apply there).
# Example: ~/t3-fork/t3.sh project add --base-dir ~/.t3 --title <name> <absolute path>
. "$HOME/Developer/t3-env.sh" </dev/null
exec node "$HOME/t3-fork/current/apps/server/dist/bin.mjs" "$@"
