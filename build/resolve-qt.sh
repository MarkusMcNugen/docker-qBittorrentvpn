#!/bin/bash
# Prints the qt6-qtbase version that the Dockerfile's Alpine branch ships for
# this machine's architecture, as QT_VERSION=x.y.z-rN, read from the branch's
# package index. Passed to the build as QT_VERSION, it pins the builder's Qt,
# so a Qt update recompiles qBittorrent and an unchanged Qt reuses the cache.
#
# Environment:
#   ALPINE_VERSION  Alpine branch (default: the Dockerfile's ALPINE_VERSION)
#   APK_ARCH        Alpine architecture (default: this machine's, from uname -m)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ALPINE_VERSION="${ALPINE_VERSION:-$(awk -F= '/^ARG ALPINE_VERSION=/ { print $2; exit }' "$here/../Dockerfile")}"
APK_ARCH="${APK_ARCH:-$(uname -m)}"
[ -n "$ALPINE_VERSION" ] || { echo "resolve-qt: no ALPINE_VERSION in the Dockerfile" >&2; exit 1; }

url="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community/${APK_ARCH}/APKINDEX.tar.gz"
version=$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --max-time 60 "$url" |
  tar -xzOf - APKINDEX |
  awk -F: '$1 == "P" { p = $2 } $1 == "V" && p == "qt6-qtbase" { v = $2 } END { print v }')
[ -n "$version" ] || { echo "resolve-qt: qt6-qtbase is not in ${url}" >&2; exit 1; }
printf 'QT_VERSION=%s\n' "$version"
