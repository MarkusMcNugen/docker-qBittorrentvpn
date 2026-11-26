# shellcheck shell=bash
# The runner itself: a failing assertion anywhere in a test fails the test,
# not only a failure in its last command.

test_an_early_failed_assertion_fails_the_test() {
  local probe="$QBTVPN_RUN/probe.sh"
  cat >"$probe" <<'EOF'
test_probe() {
  assert_eq one two "deliberate failure"
  assert_eq same same
}
EOF
  # shellcheck disable=SC2016
  if bash -c '
    set -euo pipefail
    . "$QBTVPN_LIB/common.sh"
    . "$1/lib/assert.sh"
    . "$2"
    test_probe' _ "$(dirname "$FIXTURES")" "$probe" >/dev/null 2>&1; then
    echo "a test whose first assertion fails was reported as passing"
    return 1
  fi
}
