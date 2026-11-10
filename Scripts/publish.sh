#!/bin/zsh
# Publishes the current state of a private branch to GitHub as one clean commit on the branch `public`.
# Usage: Scripts/publish.sh "What changed" [branch]      (branch defaults to the one checked out)
#
# Private branches never leave this Mac. Only `public` is pushed, and only after Scripts/git-hooks/pre-push
# has found no private data in it. The script also installs that hook, so a plain `git push` is guarded too.
set -euo pipefail
cd "$(dirname "$0")/.."
MESSAGE="${1:-}"
SOURCE="${2:-$(git branch --show-current)}"
[[ -n "$MESSAGE" ]] || { echo "Usage: Scripts/publish.sh \"What changed\" [branch]" >&2; exit 2; }
[[ "$SOURCE" != "public" ]] || { echo "Give the private branch to publish from, not 'public'." >&2; exit 2; }
git rev-parse --verify -q "refs/heads/$SOURCE" >/dev/null || { echo "No branch '$SOURCE'." >&2; exit 2; }
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Uncommitted changes: commit them on '$SOURCE' first, because only committed work is published." >&2
  exit 2
fi

# The guard travels with the repository; make sure git runs it, and that a bare `git push` only pushes `public`.
git config core.hooksPath Scripts/git-hooks
chmod +x Scripts/git-hooks/pre-push
if git remote get-url origin >/dev/null 2>&1; then
  git config remote.origin.push refs/heads/public:refs/heads/main
fi

# One clean commit with the branch's files, on top of the public history.
PARENT=$(git rev-parse --verify -q refs/heads/public) || { echo "No 'public' branch to build on." >&2; exit 2; }
if [[ "$(git rev-parse "$SOURCE^{tree}")" == "$(git rev-parse "public^{tree}")" ]]; then
  echo "'public' already has the files of '$SOURCE'. Nothing new to publish."
else
  NEW=$(git commit-tree "$SOURCE^{tree}" -p "$PARENT" -m "$MESSAGE")
  git branch -f public "$NEW"
  echo "public -> $(git log --oneline -1 public)"
fi

echo "Checking 'public' for private data..."
Scripts/git-hooks/pre-push check public

if git remote get-url origin >/dev/null 2>&1; then
  git push origin public:main
else
  echo
  echo "No GitHub remote yet. Create the repository on GitHub, then:"
  echo "  git remote add origin git@github.com:YOUR-NAME/postvak.git"
  echo "  Scripts/publish.sh \"$MESSAGE\" $SOURCE"
fi
