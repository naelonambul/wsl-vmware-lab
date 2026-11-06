#!/usr/bin/env bash
# Keep the Codex copy of the skill identical to the Claude Code copy.
#   bash tools/sync-agent-skills.sh          # copy .claude/skills -> .agents/skills
#   bash tools/sync-agent-skills.sh --check  # exit 1 if the copies differ (used by CI)
#
# Source of truth: .claude/skills/<name>/ (edit there).
# Codex reads skills from .agents/skills/<name>/ (repository) and
# ~/.agents/skills/<name>/ (user); Claude Code reads .claude/skills/<name>/.
# Git symlinks are not used because Windows checkouts turn them into text files.
set -euo pipefail
cd "$(dirname "$0")/.."
src=.claude/skills
dst=.agents/skills
status=0
for dir in "$src"/*/; do
  name=$(basename "$dir")
  [[ -f "$src/$name/SKILL.md" ]] || continue
  if [[ "${1:-}" == --check ]]; then
    if ! diff -r "$src/$name" "$dst/$name" >/dev/null 2>&1; then
      echo "[ERROR] $dst/$name differs from $src/$name; run: bash tools/sync-agent-skills.sh" >&2
      diff -rq "$src/$name" "$dst/$name" >&2 || true
      status=1
    else
      echo "[OK] $dst/$name matches $src/$name"
    fi
  else
    mkdir -p "$dst"
    rm -rf -- "${dst:?}/$name.new"
    cp -r "$src/$name" "$dst/$name.new"
    rm -rf -- "${dst:?}/$name"
    mv -- "$dst/$name.new" "$dst/$name"
    echo "[OK] Copied $src/$name -> $dst/$name"
  fi
done
# Copies in .agents/skills without a source would be stale.
for dir in "$dst"/*/; do
  [[ -d "$dir" ]] || continue
  name=$(basename "$dir")
  if [[ ! -d "$src/$name" ]]; then
    echo "[ERROR] $dst/$name has no source in $src" >&2
    status=1
  fi
done
exit "$status"
