#!/usr/bin/env bash
# Sync gorhill/uBlock -> brave/uBlock `mirror` branch.
#
# Used by:
#   - .github/workflows/sync-from-fork.yml (automated, cron)
#   - admins locally as a break-glass when the automated push is blocked.
#
# Strategy: the mirror branch is the current origin/master plus a 1:1
# sanitized replay of the upstream commits not already present on it:
#   - every such upstream commit becomes exactly one mirror commit (no squashing)
#   - each replayed commit keeps the original author, author date and message,
#     plus an `Upstream: <owner>/<repo>@<sha>` trailer pointing at the source
#     commit (GitHub renders that as a cross-repo commit link)
#   - each replayed commit's .github/ is identical to its parent's, so no
#     pushed commit ever modifies .github/ and a GITHUB_TOKEN push (which
#     lacks the `workflows` permission) is always accepted
#   - upstream commits that touch only .github/ become empty commits, keeping
#     the upstream history 1:1
#
# "Not already present" is decided by patch-id equivalence
# (`rev-list --cherry-pick --left-only`), not ancestry: brave master received
# past upstream work through old sync merges whose commits are rebased copies
# (different SHAs), so ancestry-based ranges would replay already-absorbed
# commits and produce conflicting Fork Sync PRs. Rooting the chain at the
# current origin/master tip makes the Fork Sync PR a fast-forward with a diff
# of only genuinely new upstream work.
#
# The replay is deterministic (author/committer identity and dates are pinned
# to the upstream commit), so re-running with no new upstream commits
# reproduces the existing chain byte-for-byte and pushes nothing. If the
# mirror branch is deleted (e.g. auto-delete after PR merge), the next run
# recreates it from the current master tip, so the sync is self-healing.
# SANITIZE=0 remains as a break-glass escape hatch.
set -euo pipefail

REMOTE_UPSTREAM="${REMOTE_UPSTREAM:-upstream}"
REMOTE_ORIGIN="${REMOTE_ORIGIN:-origin}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/gorhill/uBlock.git}"
ORIGIN_URL="${ORIGIN_URL:-https://github.com/brave/uBlock.git}"
BRANCH_SRC="${BRANCH_SRC:-master}"
BRANCH_MIRROR="${BRANCH_MIRROR:-mirror}"
SANITIZE="${SANITIZE:-1}"
# `<owner>/<repo>` used in the `Upstream:` trailer; GitHub auto-links
# `<owner>/<repo>@<sha>` as a cross-repo commit reference.
UP_SLUG="${UP_SLUG:-$(printf '%s' "$UPSTREAM_URL" | sed -E 's#\.git$##; s#^[^/]+//[^/]+/##')}"

# Locale-independent text processing (e.g. the `Upstream:` trailer parsing
# below) so replays stay deterministic regardless of runner locale.
export LC_ALL=C

# Committer identity for replayed commits. The author identity is preserved
# from upstream; the committer is pinned so that a replay always reproduces
# the same commit SHAs (never derived from runner-local git config).
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-sync_mirror.sh}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sync-mirror@local}"

ensure_remote() {
  local name="$1" url="$2"
  if ! git remote get-url "$name" >/dev/null 2>&1; then
    echo "Remote '${name}' missing. Adding ${url}..."
    git remote add "$name" "$url"
  fi
}

ensure_remote "$REMOTE_UPSTREAM" "$UPSTREAM_URL"
ensure_remote "$REMOTE_ORIGIN" "$ORIGIN_URL"

echo "Fetching ${REMOTE_UPSTREAM}/${BRANCH_SRC}..."
git fetch "$REMOTE_UPSTREAM" "+${BRANCH_SRC}:refs/remotes/${REMOTE_UPSTREAM}/${BRANCH_SRC}"
echo "Fetching ${REMOTE_ORIGIN}/${BRANCH_SRC}..."
git fetch "$REMOTE_ORIGIN" "+${BRANCH_SRC}:refs/remotes/${REMOTE_ORIGIN}/${BRANCH_SRC}"

UP="$(git rev-parse "refs/remotes/${REMOTE_UPSTREAM}/${BRANCH_SRC}")"
M="$(git rev-parse "refs/remotes/${REMOTE_ORIGIN}/${BRANCH_SRC}")"

echo "Checking for existing ${BRANCH_MIRROR} on ${REMOTE_ORIGIN}..."
OLD="$(git ls-remote "$REMOTE_ORIGIN" "refs/heads/${BRANCH_MIRROR}" | awk '{print $1}')"
if [ -n "$OLD" ]; then
  git fetch "$REMOTE_ORIGIN" "${BRANCH_MIRROR}:refs/remotes/${REMOTE_ORIGIN}/${BRANCH_MIRROR}"
  echo "Existing mirror at ${OLD}."
else
  echo "No existing ${BRANCH_MIRROR} on ${REMOTE_ORIGIN}; bootstrapping from the current ${REMOTE_ORIGIN}/${BRANCH_SRC} tip."
fi

push_mirror() {
  local ref="$1"
  if [ -n "$OLD" ]; then
    # Replays may rewrite the previous chain (e.g. fallback re-bootstrap);
    # often non-ff. --force-with-lease guards against concurrent pushes.
    git push "$REMOTE_ORIGIN" "${ref}:refs/heads/${BRANCH_MIRROR}" \
      --force-with-lease="refs/heads/${BRANCH_MIRROR}:${OLD}"
  else
    git push "$REMOTE_ORIGIN" "${ref}:refs/heads/${BRANCH_MIRROR}"
  fi
}

if [ "$SANITIZE" != "1" ]; then
  echo "SANITIZE=0: mirroring ${REMOTE_UPSTREAM}/${BRANCH_SRC} verbatim (break-glass; workflow files may get rejected)."
  push_mirror "$UP"
  echo "Done. mirror = ${UP}"
  exit 0
fi

# Replay set: the current origin/master tip, plus the upstream commits whose
# patch-id does not already exist on it (see header). Replayed .github/ starts
# from master's, so the chain carries master's .github/ unchanged.
PREV="$M"
echo "Replaying upstream commits missing from ${REMOTE_ORIGIN}/${BRANCH_SRC} onto ${PREV}..."

TMPDIR_SYNC="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SYNC"' EXIT
export GIT_INDEX_FILE="${TMPDIR_SYNC}/index"

# Deterministic per-commit sanitize, no worktree needed: for each upstream
# commit, take its tree, swap .github/ for the replayed parent's, and create
# the mirror commit with the original author identity/message. Commits that
# only touch .github/ come out empty and are kept (1:1 upstream history).
COUNT=0
# Stream the list (process substitution keeps PREV/COUNT in this shell and
# avoids materializing the whole rev-list output in a command substitution).
while read -r C; do
  git read-tree "$C"
  git rm -rfq --cached --ignore-unmatch .github
  if git cat-file -e "${PREV}:.github" 2>/dev/null; then
    git read-tree --prefix .github/ "${PREV}:.github"
  fi
  TREE="$(git write-tree)"
  AD="$(git log -1 --format=%aI "$C")"
  # Write the message to a file and pass it with -F: a command substitution
  # would strip the upstream message's trailing newline(s), breaking the
  # byte-for-byte preservation the deterministic replay promises. Read the
  # raw message out of the commit object (`log --format=%B` appends its own
  # terminating newline, which would corrupt the bytes).
  MSG="${TMPDIR_SYNC}/commit-msg"
  git cat-file commit "$C" | sed '1,/^$/d' >"$MSG"
  # Guarantee the blank-line separator before the trailer (plumbing-created
  # upstream commits may lack a final newline; `git commit` output has one).
  if [ -n "$(tail -c1 "$MSG")" ]; then printf '\n' >>"$MSG"; fi
  printf '\nUpstream: %s@%s\n' "$UP_SLUG" "$C" >>"$MSG"
  NEW="$(GIT_AUTHOR_NAME="$(git log -1 --format=%an "$C")" \
    GIT_AUTHOR_EMAIL="$(git log -1 --format=%ae "$C")" \
    GIT_AUTHOR_DATE="$AD" \
    GIT_COMMITTER_DATE="$AD" \
    git commit-tree "$TREE" -p "$PREV" -F "$MSG")"
  PREV="$NEW"
  COUNT=$((COUNT + 1))
done < <(git rev-list --reverse --topo-order --no-merges --left-only --cherry-pick \
  "refs/remotes/${REMOTE_UPSTREAM}/${BRANCH_SRC}...refs/remotes/${REMOTE_ORIGIN}/${BRANCH_SRC}")
unset GIT_INDEX_FILE

echo "Replayed ${COUNT} upstream commit(s)."
if [ "$COUNT" -eq 0 ]; then
  echo "No changes to sync (no upstream commits missing from ${REMOTE_ORIGIN}/${BRANCH_SRC}). Nothing to push."
  exit 0
fi
if [ -n "$OLD" ] && [ "$PREV" = "$OLD" ]; then
  echo "No changes to sync (deterministic replay reproduced the existing mirror). Nothing to push."
  exit 0
fi

echo "Pushing ${BRANCH_MIRROR} to ${REMOTE_ORIGIN}..."
push_mirror "$PREV"

echo "Done. mirror = ${PREV}"
