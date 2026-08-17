#!/usr/bin/env bash
# Sync gorhill/uBlock -> brave/uBlock `mirror` branch.
#
# Used by:
#   - .github/workflows/sync-from-fork.yml (automated, hourly cron)
#   - admins locally as a break-glass when the automated push is blocked.
#
# Sanitization: any new upstream commit's changes under .github/ are stripped
# before pushing. GitHub refuses pushes via GITHUB_TOKEN that modify files under
# .github/workflows/* without the `workflows` permission, and granting that
# scope would allow workflow edits -> secret exfiltration. By rebasing the new
# upstream commits onto the existing origin/mirror and amending each one to
# restore .github/ from its parent, the pushed commit range contains zero
# .github/ modifications, so the push is permitted and no upstream .github/
# changes flow into the master<-mirror merge (which is what previously required
# per-sync manual conflict resolution).
set -euo pipefail

REMOTE_UPSTREAM="${REMOTE_UPSTREAM:-upstream}"
REMOTE_ORIGIN="${REMOTE_ORIGIN:-origin}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/gorhill/uBlock.git}"
ORIGIN_URL="${ORIGIN_URL:-https://github.com/brave/uBlock.git}"
BRANCH_SRC="${BRANCH_SRC:-master}"
BRANCH_MIRROR="${BRANCH_MIRROR:-mirror}"
SANITIZE="${SANITIZE:-1}"

ensure_remote() {
  local name="$1" url="$2"
  if ! git remote get-url "$name" >/dev/null 2>&1; then
    echo "Remote '${name}' missing. Adding ${url}..."
    git remote add "$name" "$url"
  fi
}

# `git commit --amend` during rebase needs an identity. Set a local fallback
# only if none is configured (never touches global/user-supplied config).
if ! git config user.email >/dev/null 2>&1; then
  git config user.email "sync-mirror@local"
fi
if ! git config user.name >/dev/null 2>&1; then
  git config user.name "sync_mirror.sh"
fi

ensure_remote "$REMOTE_UPSTREAM" "$UPSTREAM_URL"
ensure_remote "$REMOTE_ORIGIN" "$ORIGIN_URL"

echo "Fetching ${REMOTE_UPSTREAM}/${BRANCH_SRC}..."
git fetch "$REMOTE_UPSTREAM" "${BRANCH_SRC}:refs/remotes/${REMOTE_UPSTREAM}/${BRANCH_SRC}"

echo "Checking for existing ${BRANCH_MIRROR} on ${REMOTE_ORIGIN}..."
if git ls-remote --exit-code "$REMOTE_ORIGIN" "$BRANCH_MIRROR" >/dev/null 2>&1; then
  git fetch "$REMOTE_ORIGIN" "${BRANCH_MIRROR}:refs/remotes/${REMOTE_ORIGIN}/${BRANCH_MIRROR}"
  HAVE_MIRROR=1
else
  echo "No existing ${BRANCH_MIRROR} on ${REMOTE_ORIGIN}; bootstrapping."
  HAVE_MIRROR=0
fi

echo "Pointing local ${BRANCH_MIRROR} at ${REMOTE_UPSTREAM}/${BRANCH_SRC}..."
git checkout -B "$BRANCH_MIRROR" "refs/remotes/${REMOTE_UPSTREAM}/${BRANCH_SRC}"

if [ "$SANITIZE" = "1" ] && [ "$HAVE_MIRROR" = "1" ]; then
  base="refs/remotes/${REMOTE_ORIGIN}/${BRANCH_MIRROR}"
  echo "Sanitizing .github/ out of new commits (rebase onto ${base})..."
  # Replays only (base..HEAD) = new upstream commits onto the existing mirror
  # tip. For each replayed commit, restore .github/ from its parent and amend,
  # so the commit carries no .github/ diff. --keep-empty preserves commits that
  # become empty (upstream .github-only changes).
  git rebase "$base" --keep-empty \
    --exec 'git restore --source=HEAD^ --staged --worktree -- .github/ && git commit --amend --no-edit --allow-empty'
elif [ "$SANITIZE" = "1" ]; then
  echo "Bootstrap: no prior mirror to rebase against; skipping sanitize of full history."
fi

echo "Pushing ${BRANCH_MIRROR} to ${REMOTE_ORIGIN}..."
if [ "$HAVE_MIRROR" = "1" ]; then
  # Rebased commits have new SHAs -> non-ff; --force-with-lease guards against
  # concurrent pushes.
  git push "$REMOTE_ORIGIN" "${BRANCH_MIRROR}:refs/heads/${BRANCH_MIRROR}" --force-with-lease="refs/heads/${BRANCH_MIRROR}:refs/remotes/${REMOTE_ORIGIN}/${BRANCH_MIRROR}"
else
  git push "$REMOTE_ORIGIN" "${BRANCH_MIRROR}:refs/heads/${BRANCH_MIRROR}"
fi

echo "Done. $(git log --oneline -1 "$BRANCH_MIRROR")"
