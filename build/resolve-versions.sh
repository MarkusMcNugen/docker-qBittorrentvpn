#!/bin/bash
# Resolves the qBittorrent and libtorrent versions to build and prints them as
#   QBITTORRENT_VERSION=x.y.z
#   LIBTORRENT_VERSION=x.y.z
#
# Environment:
#   QBITTORRENT_VERSION  "latest" (newest stable release) or an exact x.y.z
#   LIBTORRENT_SERIES    2.1, 2.0 or 1.2
#   LIBTORRENT_VERSION   "latest" (newest stable release of LIBTORRENT_SERIES) or an exact x.y.z
#   GITHUB_TOKEN         optional; raises the GitHub API rate limit
#
# Every page of each project's release list is read, so an older series is
# found however many newer releases precede it.
set -euo pipefail

QBITTORRENT_VERSION="${QBITTORRENT_VERSION:-latest}"
LIBTORRENT_SERIES="${LIBTORRENT_SERIES:-2.1}"
LIBTORRENT_VERSION="${LIBTORRENT_VERSION:-latest}"

die() { printf 'resolve-versions: %s\n' "$*" >&2; exit 1; }

api_get() {
  local url="https://api.github.com/$1"
  local -a auth=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --max-time 60 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${auth[@]}" "$url"
}

# Prints every non-draft, non-prerelease tag of a repository, one per line.
stable_tags() {
  local repo="$1" page=1 body count
  while :; do
    body=$(api_get "repos/${repo}/releases?per_page=100&page=${page}")
    count=$(jq 'length' <<<"$body")
    [ "$count" -gt 0 ] || break
    jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name' <<<"$body"
    page=$((page + 1))
  done
}

# Prints the highest x.y.z among tags matching ^<prefix>x.y.z$, with the prefix removed.
highest() {
  local prefix="$1" series="$2"
  jq -R -s -r --arg p "$prefix" --arg s "$series" '
    split("\n")
    | map(select(startswith($p)) | ltrimstr($p))
    | map(select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))
    | map(select($s == "" or startswith($s + ".")))
    | sort_by(split(".") | map(tonumber))
    | last // empty'
}

is_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

case "$LIBTORRENT_SERIES" in
  2.1|2.0|1.2) ;;
  *) die "LIBTORRENT_SERIES must be 2.1, 2.0 or 1.2, not '${LIBTORRENT_SERIES}'" ;;
esac

if [ "$QBITTORRENT_VERSION" = latest ]; then
  QBITTORRENT_VERSION=$(stable_tags qbittorrent/qBittorrent | highest release- "")
  [ -n "$QBITTORRENT_VERSION" ] || die "no stable qBittorrent release found"
elif ! is_version "$QBITTORRENT_VERSION"; then
  die "QBITTORRENT_VERSION must be 'latest' or x.y.z, not '${QBITTORRENT_VERSION}'"
fi

if [ "$LIBTORRENT_VERSION" = latest ]; then
  LIBTORRENT_VERSION=$(stable_tags arvidn/libtorrent | highest v "$LIBTORRENT_SERIES")
  [ -n "$LIBTORRENT_VERSION" ] || die "no stable libtorrent ${LIBTORRENT_SERIES}.x release found"
elif ! is_version "$LIBTORRENT_VERSION"; then
  die "LIBTORRENT_VERSION must be 'latest' or x.y.z, not '${LIBTORRENT_VERSION}'"
elif [[ "$LIBTORRENT_VERSION" != "${LIBTORRENT_SERIES}."* ]]; then
  die "LIBTORRENT_VERSION ${LIBTORRENT_VERSION} is not in series ${LIBTORRENT_SERIES}"
fi

qbt_major=${QBITTORRENT_VERSION%%.*}
[ "$qbt_major" -ge 5 ] || die "qBittorrent ${QBITTORRENT_VERSION} is older than 5.0, which this image does not build"

printf 'QBITTORRENT_VERSION=%s\nLIBTORRENT_VERSION=%s\n' "$QBITTORRENT_VERSION" "$LIBTORRENT_VERSION"
