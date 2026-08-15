#!/usr/bin/env bash
set -euo pipefail

REMOTE_UPSTREAM="${REMOTE_UPSTREAM:-gorhill}"
REMOTE_ORIGIN="${REMOTE_ORIGIN:-origin}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/gorhill/uBlock.git}"
ORIGIN_URL="${ORIGIN_URL:-git@github.com:brave/uBlock.git}"
BRANCH_SRC="master"
BRANCH_MIRROR="mirror"

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
git fetch "$REMOTE_UPSTREAM" "$BRANCH_SRC"

echo "Updating local ${BRANCH_MIRROR} to ${REMOTE_UPSTREAM}/${BRANCH_SRC}..."
git update-ref "refs/heads/${BRANCH_MIRROR}" "${REMOTE_UPSTREAM}/${BRANCH_SRC}"

echo "Pushing ${BRANCH_MIRROR} to ${REMOTE_ORIGIN}..."
git push "$REMOTE_ORIGIN" "${BRANCH_MIRROR}:refs/heads/${BRANCH_MIRROR}"

echo "Done. $(git log --oneline -1 "$BRANCH_MIRROR")"
