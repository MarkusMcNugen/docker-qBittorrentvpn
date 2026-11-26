#!/bin/bash
# Downloads and verifies the qBittorrent and libtorrent source tarballs, then
# unpacks them under the directory given as $1:
#   $1/qbittorrent   qBittorrent source tree
#   $1/libtorrent    libtorrent source tree
#   $1/versions.env  QBITTORRENT_VERSION, LIBTORRENT_VERSION, LIBTORRENT_SERIES
#
# The qBittorrent tarball must carry a valid OpenPGP signature made by the key
# whose fingerprint is QBITTORRENT_KEY_FPR, read from /keys. Both tarballs must
# match the SHA-256 digest GitHub records for the release asset.
set -euo pipefail

dest="${1:?usage: fetch-sources.sh <destination directory>}"
here=$(cd "$(dirname "$0")" && pwd)
keys_dir="${KEYS_DIR:-/keys}"
QBITTORRENT_KEY_FPR="${QBITTORRENT_KEY_FPR:-D8F3DA77AAC6741053599C136E4A2D025B7CC9A2}"

log() { printf '%s fetch-sources: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { log "$*"; exit 1; }

eval "$("$here/resolve-versions.sh")"
log "qBittorrent ${QBITTORRENT_VERSION}, libtorrent ${LIBTORRENT_VERSION} (series ${LIBTORRENT_SERIES:-2.1})"

api_get() {
  local -a auth=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --max-time 60 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${auth[@]}" "https://api.github.com/$1"
}

# Prints "<download url> <sha256>" for one asset of a release.
asset() {
  local repo="$1" tag="$2" name="$3" release
  release=$(api_get "repos/${repo}/releases/tags/${tag}")
  jq -r --arg n "$name" '
    .assets[] | select(.name == $n)
    | "\(.browser_download_url) \(.digest // "" | ltrimstr("sha256:"))"' <<<"$release"
}

download() {
  local url="$1" out="$2"
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --max-time 600 -o "$out" "$url"
}

check_sha256() {
  local file="$1" want="$2" got
  [ -n "$want" ] || die "GitHub lists no SHA-256 digest for $(basename "$file")"
  got=$(sha256sum "$file" | cut -d' ' -f1)
  [ "$got" = "$want" ] || die "$(basename "$file"): SHA-256 ${got} does not match the published ${want}"
  log "$(basename "$file"): SHA-256 ${got} matches"
}

work=$(mktemp -d)
mkdir -p "$dest"

# qBittorrent: OpenPGP signature plus GitHub digest.
qbt_tag="release-${QBITTORRENT_VERSION}"
qbt_tar="qbittorrent-${QBITTORRENT_VERSION}.tar.xz"
read -r qbt_url qbt_sha < <(asset qbittorrent/qBittorrent "$qbt_tag" "$qbt_tar")
read -r qbt_sig_url _ < <(asset qbittorrent/qBittorrent "$qbt_tag" "${qbt_tar}.asc")
[ -n "${qbt_url:-}" ] || die "release ${qbt_tag} has no asset ${qbt_tar}"
[ -n "${qbt_sig_url:-}" ] || die "release ${qbt_tag} has no asset ${qbt_tar}.asc"
download "$qbt_url" "$work/$qbt_tar"
download "$qbt_sig_url" "$work/$qbt_tar.asc"
check_sha256 "$work/$qbt_tar" "$qbt_sha"

export GNUPGHOME="$work/gnupg"
mkdir -m 0700 "$GNUPGHOME"
gpg --batch --quiet --import "$keys_dir"/qbittorrent-*.asc
imported=$(gpg --batch --with-colons --fingerprint "$QBITTORRENT_KEY_FPR" | awk -F: '$1 == "fpr" {print $10; exit}')
[ "$imported" = "$QBITTORRENT_KEY_FPR" ] || die "signing key ${QBITTORRENT_KEY_FPR} is not in ${keys_dir}"
status=$(gpg --batch --status-fd 1 --verify "$work/$qbt_tar.asc" "$work/$qbt_tar" 2>/dev/null) \
  || die "OpenPGP signature check failed for ${qbt_tar}"
awk -v fpr="$QBITTORRENT_KEY_FPR" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && ($3 == fpr || $12 == fpr) {ok = 1} END {exit !ok}' <<<"$status" \
  || die "${qbt_tar} is not signed by ${QBITTORRENT_KEY_FPR}"
log "${qbt_tar}: valid signature by ${QBITTORRENT_KEY_FPR}"

# libtorrent: GitHub digest.
lt_tag="v${LIBTORRENT_VERSION}"
lt_tar="libtorrent-rasterbar-${LIBTORRENT_VERSION}.tar.gz"
read -r lt_url lt_sha < <(asset arvidn/libtorrent "$lt_tag" "$lt_tar")
[ -n "${lt_url:-}" ] || die "release ${lt_tag} has no asset ${lt_tar}"
download "$lt_url" "$work/$lt_tar"
check_sha256 "$work/$lt_tar" "$lt_sha"

mkdir -p "$dest/qbittorrent" "$dest/libtorrent"
tar -xJf "$work/$qbt_tar" -C "$dest/qbittorrent" --strip-components=1
tar -xzf "$work/$lt_tar" -C "$dest/libtorrent" --strip-components=1

cat >"$dest/versions.env" <<EOF
QBITTORRENT_VERSION=${QBITTORRENT_VERSION}
LIBTORRENT_VERSION=${LIBTORRENT_VERSION}
LIBTORRENT_SERIES=${LIBTORRENT_SERIES:-2.1}
EOF
rm -rf "$work"
log "sources ready in ${dest}"
