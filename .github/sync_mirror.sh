#!/usr/bin/env bash
# Sync gorhill/uBlock -> brave/uBlock `mirror` branch.
#
# Used by:
#   - .github/workflows/sync-from-fork.yml (automated, cron)
#   - admins locally as a break-glass when the automated push is blocked.
#
# Strategy: the mirror branch is origin/master plus ONE squashed "Sync
# upstream" commit per run:
#   - parent  = current origin/master tip
#   - tree    = upstream tree, with .github/ replaced by origin/master's and
#               Brave-only files (on master, not upstream) carried over
#   - the commit message records the synced upstream SHA
#
# The sync commit never modifies .github/ relative to its parent, so a
# GITHUB_TOKEN push (which lacks the `workflows` permission) is always
# accepted: GitHub only rejects pushes whose *new* commits touch workflow
# files. It also keeps the master<-mirror merge free of .github/ conflicts.
# If the mirror branch is deleted (e.g. auto-delete after PR merge), the next
# run recreates it from the current master tip, so the sync is self-healing.
set -euo pipefail

REMOTE_UPSTREAM="${REMOTE_UPSTREAM:-upstream}"
REMOTE_ORIGIN="${REMOTE_ORIGIN:-origin}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/gorhill/uBlock.git}"
ORIGIN_URL="${ORIGIN_URL:-https://github.com/brave/uBlock.git}"
BRANCH_SRC="${BRANCH_SRC:-master}"
BRANCH_MIRROR="${BRANCH_MIRROR:-mirror}"
SANITIZE="${SANITIZE:-1}"

# Deterministic byte-wise sorting: git ls-tree output order must match `sort`
# order for the `comm` set operations below, independent of runner locale.
export LC_ALL=C

ensure_remote() {
  local name="$1" url="$2"
  if ! git remote get-url "$name" >/dev/null 2>&1; then
    echo "Remote '${name}' missing. Adding ${url}..."
    git remote add "$name" "$url"
  fi
}

# `git commit-tree` needs an identity. Set a local fallback only if none is
# configured (never touches global/user-supplied config).
if ! git config user.email >/dev/null 2>&1; then
  git config user.email "sync-mirror@local"
fi
if ! git config user.name >/dev/null 2>&1; then
  git config user.name "sync_mirror.sh"
fi

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
  echo "No existing ${BRANCH_MIRROR} on ${REMOTE_ORIGIN}; bootstrapping from current ${REMOTE_ORIGIN}/${BRANCH_SRC}."
fi

push_mirror() {
  local ref="$1"
  if [ -n "$OLD" ]; then
    # Replaces the previous sync commit (often non-ff); --force-with-lease
    # guards against concurrent pushes.
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

# Upstream SHA recorded by the previous sync commit; used to honor upstream
# deletions (a file present at the last synced upstream but gone now must not
# be carried back from master).
UP_PREV=""
if [ -n "$OLD" ]; then
  UP_PREV="$(git log -1 --format=%B "refs/remotes/${REMOTE_ORIGIN}/${BRANCH_MIRROR}" \
    | grep -om1 -E '[0-9a-f]{40}' || true)"
  if [ -n "$UP_PREV" ] && ! git cat-file -e "$UP_PREV^{commit}" 2>/dev/null; then
    echo "WARN: recorded upstream SHA ${UP_PREV} not present locally; ignoring."
    UP_PREV=""
  fi
  if [ -z "$UP_PREV" ]; then
    echo "WARN: no upstream SHA found in previous mirror commit ${OLD}; upstream deletions may be resurrected this run."
  fi
fi

TMPDIR_SYNC="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SYNC"' EXIT
export GIT_INDEX_FILE="${TMPDIR_SYNC}/index"

# Build the sanitized sync tree in a temporary index (no worktree needed):
# upstream tree, with .github/ swapped for master's and Brave-only files kept.
git read-tree "$UP"
git rm -rfq --cached --ignore-unmatch .github
if git cat-file -e "${M}:.github" 2>/dev/null; then
  git read-tree --prefix .github/ "${M}:.github"
fi

# Brave-only files: on master, absent upstream, not under .github/. Files that
# upstream deleted since the last sync are NOT carried (they must go away).
git ls-tree -r --name-only "$M" | sort > "${TMPDIR_SYNC}/master.lst"
git ls-tree -r --name-only "$UP" | sort > "${TMPDIR_SYNC}/upstream.lst"
comm -23 "${TMPDIR_SYNC}/master.lst" "${TMPDIR_SYNC}/upstream.lst" \
  | grep -v '^\.github/' > "${TMPDIR_SYNC}/carry.lst" || true
if [ -n "$UP_PREV" ] && [ -s "${TMPDIR_SYNC}/carry.lst" ]; then
  git ls-tree -r --name-only "$UP_PREV" | sort > "${TMPDIR_SYNC}/upstream-prev.lst"
  comm -23 "${TMPDIR_SYNC}/carry.lst" "${TMPDIR_SYNC}/upstream-prev.lst" \
    > "${TMPDIR_SYNC}/carry.tmp" && mv "${TMPDIR_SYNC}/carry.tmp" "${TMPDIR_SYNC}/carry.lst"
fi
if [ -s "${TMPDIR_SYNC}/carry.lst" ]; then
  echo "Carrying Brave-only files: $(wc -l < "${TMPDIR_SYNC}/carry.lst") file(s)."
  while IFS= read -r path; do
    git ls-tree "$M" -- "$path" | git update-index --index-info
  done < "${TMPDIR_SYNC}/carry.lst"
fi

TREE="$(git write-tree)"
if [ "$TREE" = "$(git rev-parse "${M}^{tree}")" ]; then
  echo "No changes to sync (upstream matches master after sanitize). Nothing to push."
  exit 0
fi
if [ -n "$OLD" ] && [ "$TREE" = "$(git rev-parse "${OLD}^{tree}")" ]; then
  echo "No changes to sync (mirror already carries this upstream tree). Nothing to push."
  exit 0
fi

# Full upstream SHA in the message doubles as the UP_PREV marker parsed above.
COMMIT="$(git commit-tree "$TREE" -p "$M" -m "Sync upstream gorhill/uBlock at ${UP}")"
echo "Created sync commit ${COMMIT} (upstream ${UP})."
unset GIT_INDEX_FILE

echo "Pushing ${BRANCH_MIRROR} to ${REMOTE_ORIGIN}..."
push_mirror "$COMMIT"

echo "Done. mirror = ${COMMIT}"
