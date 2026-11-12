#!/bin/zsh
# Copy every git repo under ~/Downloads/Projects to ~/Projects/<same path> on the Mac mini.
# A bundle (all local branches and commits) streams over SSH, so unpushed work and repos without a
# remote come along and nothing is pushed to GitHub. origin is then pointed back at GitHub.
# Usage: transfer-repos.sh <list-of-relative-repo-paths>   (idempotent: existing clones are skipped)
set -u
SRC=$HOME/Downloads/Projects
MINI=mac-mini-m6
while IFS= read -r d; do
  [[ -z $d ]] && continue
  remote=$(git -C "$SRC/$d" remote get-url origin 2>/dev/null || true)
  branch=$(git -C "$SRC/$d" branch --show-current 2>/dev/null || true)
  if ! git -C "$SRC/$d" rev-parse -q --verify HEAD >/dev/null 2>&1 && [[ -z $(git -C "$SRC/$d" for-each-ref refs/heads) ]]; then
    ssh -o BatchMode=yes $MINI "d=\$HOME/Projects/$d; [ -d \"\$d/.git\" ] || { mkdir -p \"\$d\" && git -C \"\$d\" init -q && [ -n '$remote' ] && git -C \"\$d\" remote add origin '$remote'; }; true"
    print "empty   $d"; continue
  fi
  res=$(git -C "$SRC/$d" bundle create - --all 2>/dev/null | ssh -o BatchMode=yes $MINI "
    set -e; d=\$HOME/Projects/$d
    if [ -d \"\$d/.git\" ]; then cat >/dev/null; echo skip; exit 0; fi
    b=\$(mktemp \$HOME/.cache/repo-bundle.XXXXXX)
    cat > \"\$b\"; mkdir -p \"\$(dirname \"\$d\")\"
    if [ -e \"\$d\" ] && [ -n \"\$(ls -A \"\$d\" 2>/dev/null)\" ]; then rm -f \"\$b\"; echo 'blocked (path exists, not empty)'; exit 0; fi
    # LFS files are not in bundles: skip the smudge here and pull them from GitHub below.
    export GIT_LFS_SKIP_SMUDGE=1
    git clone -q ${branch:+-b '$branch'} \"\$b\" \"\$d\" 2>/tmp/clone-err.txt || { rm -rf \"\$d\"; git clone -q \"\$b\" \"\$d\" 2>>/tmp/clone-err.txt; } || { rm -rf \"\$d\" \"\$b\"; tail -1 /tmp/clone-err.txt; exit 0; }
    cd \"\$d\"; cur=\$(git branch --show-current)
    for r in \$(git for-each-ref --format='%(refname:short)' refs/remotes/origin/ | grep -v '^origin/HEAD\$' | grep -v '^origin\$'); do
      n=\${r#origin/}; [ \"\$n\" = \"\$cur\" ] || git branch -q \"\$n\" \"\$r\" 2>/dev/null || true
    done
    if [ -n '$remote' ]; then
      git remote set-url origin '$remote'
      if git fetch -q --prune origin 2>/dev/null; then
        for n in \$(git for-each-ref --format='%(refname:short)' refs/heads/); do
          git rev-parse -q --verify \"origin/\$n\" >/dev/null && git branch -q -u \"origin/\$n\" \"\$n\" >/dev/null 2>&1 || true
        done
        if grep -qs 'filter=lfs' .gitattributes; then
          unset GIT_LFS_SKIP_SMUDGE
          git lfs pull -q 2>/dev/null && echo 'ok (lfs pulled)' || echo 'ok (lfs pull FAILED)'
        else echo ok; fi
      else echo 'ok (GitHub fetch failed)'; fi
    else git remote remove origin; echo 'ok (no remote)'; fi
    rm -f \"\$b\"" 2>&1 | tail -1)
  print "${res:-FAILED}   $d"
done < "${1:-/dev/stdin}"
