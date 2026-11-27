#!/bin/bash
# The test entry point.
#   tests/run.sh unit [IMAGE]   unit tests, run inside IMAGE (default qbittorrentvpn:dev)
#                               so they use the image's own bash, busybox and awk
#   tests/run.sh e2e [IMAGE]    end-to-end tunnel, kill-switch and leak tests on this
#                               Docker host; needs sudo for tcpdump on the bridge
#   tests/run.sh rootless [IMAGE] [MODE...]
#                               the image under rootless Podman, as an ordinary
#                               user: OpenVPN and WireGuard connect, recover and stop
#   tests/run.sh cve [IMAGE]    Trivy's CVE and secret scan; fails on anything fixable
#   tests/run.sh in-container   what `unit` runs inside the image
#
# Exits non-zero when any test fails.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cmd="${1:-unit}"
image="${2:-qbittorrentvpn:dev}"

run_unit_tests() {
  local file t log pass=0 fail=0
  local -a failed=()
  export QBTVPN_LIB=/usr/local/lib/qbtvpn
  export QBTVPN_SHARE=/usr/local/share/qbtvpn
  export FIXTURES="$here/fixtures"
  log=$(mktemp)
  for file in "$here"/unit/*.sh; do
    while read -r t; do
      # A separate bash process: inside an `if` condition bash ignores set -e
      # for every nested command, so an in-process subshell would report a
      # test by its last command only.
      # shellcheck disable=SC2016
      if bash -c '
        set -euo pipefail
        QBTVPN_RUN=$(mktemp -d)
        export QBTVPN_RUN
        . "$QBTVPN_LIB/common.sh"
        . "$1/lib/assert.sh"
        . "$2"
        "$3"' _ "$here" "$file" "$t" >"$log" 2>&1; then
        pass=$((pass + 1))
        printf 'ok    %s %s\n' "${file##*/}" "$t"
      else
        fail=$((fail + 1))
        failed+=("${file##*/} ${t}")
        printf 'FAIL  %s %s\n' "${file##*/}" "$t"
        awk '{ print "      " $0 }' "$log"
      fi
    done < <(bash -c '. "$1"; declare -F' _ "$file" | awk '$3 ~ /^test_/ { print $3 }')
  done
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  if [ "$fail" -gt 0 ]; then
    printf 'failed: %s\n' "${failed[@]}"
    return 1
  fi
}

case "$cmd" in
  in-container)
    run_unit_tests
    ;;
  unit)
    docker run --rm --cap-add NET_ADMIN --sysctl net.ipv6.conf.all.disable_ipv6=0 \
      --sysctl net.ipv6.conf.default.disable_ipv6=0 --entrypoint /bin/bash \
      -v "$here:/tests:ro" "$image" /tests/run.sh in-container
    ;;
  e2e)
    shift $(($# >= 2 ? 2 : $#))
    exec bash "$here/e2e/run.sh" "$image" "$@"
    ;;
  rootless)
    shift $(($# >= 2 ? 2 : $#))
    exec bash "$here/rootless/run.sh" "$image" "$@"
    ;;
  cve)
    exec bash "$here/cve/run.sh" "$image"
    ;;
  *)
    echo "usage: tests/run.sh unit|e2e|rootless|cve [IMAGE]" >&2
    exit 2
    ;;
esac
