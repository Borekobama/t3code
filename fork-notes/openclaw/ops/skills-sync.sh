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

# Global instruction files: a static header (~/t3-fork/global-*.md) plus the arsenal native block,
# rendered the same way as `arsenal native` (policy + "native <skill>" manifest entries, frontmatter stripped).
/usr/bin/python3 -I - "$ARSENAL" "$MANIFEST" "$DRY" <<'PY'
import datetime, pathlib, re, shutil, sys
arsenal, manifest, dry = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3] == "--dry-run"
home = pathlib.Path.home()
mini_note = (
    "Exception on this Mac mini: the arsenal here is a read-only mirror. Skills Manager and the review "
    "database live on the MacBook. Do not run `./arsenal` install, deploy, native or tier commands here, and "
    "do not put skills into `~/.claude/skills` or `~/.codex/skills` by hand. Ask the user to install the skill "
    "on the MacBook. `~/t3-fork/skills-sync.sh` mirrors it here after it is pushed to the arsenal repo and "
    "listed in `~/t3-fork/skills-manifest.txt`."
)
sections = [(arsenal / "INSTALLATION_RULES.md").read_text().replace("{{ARSENAL_ROOT}}", str(arsenal)).rstrip()
            + "\n\n" + mini_note + "\n"]
for line in manifest.read_text().splitlines():
    parts = line.split()
    if len(parts) == 2 and parts[0] == "native":
        text = (arsenal / "skills" / parts[1] / "SKILL.md").read_text()
        body = re.sub(r"\A---\n.*?\n---\s*\n", "", text, count=1, flags=re.DOTALL)
        sections.append(f"# Native skill: {parts[1]}\n\n{body.strip()}")
block = "<!-- BEGIN ARSENAL NATIVE -->\n" + "\n\n".join(sections) + "\n<!-- END ARSENAL NATIVE -->"
for header, target in (("global-claude.md", ".claude/CLAUDE.md"), ("global-codex.md", ".codex/AGENTS.md")):
    src, dst = home / "t3-fork" / header, home / target
    if not src.exists():
        continue
    new = src.read_text().rstrip() + "\n\n" + block + "\n"
    old = dst.read_text() if dst.exists() else ""
    if new == old:
        continue
    print(f"instructions {'would change' if dry else 'updated'}: {dst}")
    if dry:
        continue
    if old:
        shutil.copy2(dst, dst.with_name(dst.name + ".bak-" + datetime.datetime.now().strftime("%Y%m%d%H%M%S")))
    dst.write_text(new)
PY
