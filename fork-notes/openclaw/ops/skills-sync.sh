#!/bin/zsh
# Keep this Mac mini's skill arsenal and agent instructions in step with the shared arsenal repo.
# The MacBook and the mini both write to the arsenal (each runs Skills Manager; skill IDs come from the
# git-tracked skills/.skills-manager metadata, so both see the same IDs).
#   1. pull the arsenal and refresh its index (arsenal.db, Skills Manager DB)
#   2. deploy the baseline skills in ~/t3-fork/skills-manifest.txt through Skills Manager (idempotent;
#      skills deployed on the mini with `./arsenal deploy` stay, nothing is undeployed here)
#   3. write ~/.claude/CLAUDE.md and ~/.codex/AGENTS.md (header + arsenal native block)
#   skills-sync.sh             do it
#   skills-sync.sh --dry-run   show what would change
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
ARSENAL=$HOME/skills/global-skill-arsenal
MANIFEST=${MANIFEST:-$HOME/t3-fork/skills-manifest.txt}
SM=$HOME/.skills-manager/bin/skills-manager-cli
DRY=${1:-}
dry=(); [[ $DRY == --dry-run ]] && dry=(--dry-run)

if [[ ! -d $ARSENAL/.git ]]; then
  mkdir -p "${ARSENAL:h}"
  git clone -q git@github.com:Borekobama/global-skill-arsenal.git "$ARSENAL" || exit 1
elif [[ -z $dry ]]; then
  # A dirty tree means someone is mid-change here; ff-only still pulls when the files don't overlap.
  git -C "$ARSENAL" pull -q --ff-only || print "warn: arsenal pull failed (local commits or conflicts?)"
fi
dirty=$(git -C "$ARSENAL" status --porcelain | wc -l | tr -d ' ')
(( dirty )) && print "warn: arsenal has $dirty uncommitted change(s); commit and push them"
[[ -z $dry ]] && { (cd "$ARSENAL" && ./arsenal refresh >/dev/null) || print "warn: arsenal refresh failed"; }

typeset -A key=(claude claude_code codex codex)
for agent in claude codex; do
  names=(${(f)"$(awk -v a=$agent '$1 == a { print $2 }' "$MANIFEST")"})
  out=$("$SM" --json skills deploy "${dry[@]}" --agent ${key[$agent]} "${names[@]}" 2>&1)
  changed=$(print -r -- "$out" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("changed_pairs", "?"))' 2>/dev/null) \
    || { print "error: deploy for $agent failed: ${out[1,300]}"; continue; }
  print "$agent: ${#names} baseline skills, $changed changed"
done
for link in $HOME/.claude/skills/*(N-@) $HOME/.codex/skills/*(N-@); do
  print "broken link (skill gone from the arsenal?): $link"
done
print "$(date +%H:%M:%S) arsenal $(git -C "$ARSENAL" rev-parse --short HEAD)"

# Global instruction files: a static header (~/t3-fork/global-*.md) plus the arsenal native block,
# rendered the same way as `arsenal native` (policy + "native <skill>" manifest entries, frontmatter stripped).
/usr/bin/python3 -I - "$ARSENAL" "$MANIFEST" "$DRY" <<'PY'
import datetime, pathlib, re, shutil, sys
arsenal, manifest, dry = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3] == "--dry-run"
home = pathlib.Path.home()
mini_note = (
    "On this Mac mini: the MacBook writes to the same arsenal repo, so run `git pull --ff-only` in the "
    "arsenal before any change, and commit and push right after it. `~/t3-fork/skills-sync.sh` pulls daily "
    "at 05:00 and keeps the baseline skills in `~/t3-fork/skills-manifest.txt` deployed. Deploy other skills "
    "here with `./arsenal deploy --agent claude_code|codex <skill>`. `portless-dev` is MacBook-only: do not "
    "deploy it here."
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
