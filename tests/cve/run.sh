#!/bin/bash
# CVE scan: Trivy, pinned below, scans IMAGE from the local Docker daemon for
# known vulnerabilities in its packages and for secrets. Every finding is
# listed; the scan fails only on a vulnerability that has a fix, or on any
# secret. The image upgrades every package when it is built, so a fixable
# finding means a fix it should have and does not; an unfixed one has nothing
# to upgrade to yet. qBittorrent and libtorrent are built from source and carry
# no package metadata, so no scanner sees them; the image builds their latest
# releases.
#   tests/cve/run.sh IMAGE
# TRIVY_CACHE_DIR keeps Trivy's vulnerability database between runs.
set -uo pipefail
image="${1:?usage: tests/cve/run.sh IMAGE}"
trivy_image="aquasec/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb"
cache="${TRIVY_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/trivy}"
mkdir -p "$cache"

trivy() {
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$cache:/root/.cache/trivy" "$trivy_image" "$@"
}

echo "== every known vulnerability and secret, fixed or not"
trivy image --quiet --scanners vuln,secret --format table "$image" || { echo "cve: the scan did not run" >&2; exit 2; }
echo "== findings with a fix, and secrets: any fails the scan"
trivy image --quiet --scanners vuln,secret --ignore-unfixed --exit-code 1 --format table "$image"
