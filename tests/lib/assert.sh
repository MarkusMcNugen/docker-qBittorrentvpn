# shellcheck shell=bash
# Assertions for the unit tests. Each prints what it saw and returns 1 on
# failure, which under set -e ends the test.

assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'expected: %s\n  actual: %s\n  (%s)\n' "$1" "$2" "${3:-assert_eq}"
    return 1
  fi
}

assert_contains() {
  if [[ "$2" != *"$1"* ]]; then
    printf 'expected to contain: %s\nin:\n%s\n(%s)\n' "$1" "$2" "${3:-assert_contains}"
    return 1
  fi
}

assert_not_contains() {
  if [[ "$2" == *"$1"* ]]; then
    printf 'expected not to contain: %s\nin:\n%s\n(%s)\n' "$1" "$2" "${3:-assert_not_contains}"
    return 1
  fi
}

# assert_line_order TEXT FIRST SECOND: FIRST appears on an earlier line than SECOND.
assert_line_order() {
  local a b
  a=$(NEEDLE="$2" awk 'index($0, ENVIRON["NEEDLE"]) { print NR; exit }' <<<"$1")
  b=$(NEEDLE="$3" awk 'index($0, ENVIRON["NEEDLE"]) { print NR; exit }' <<<"$1")
  if [ -z "$a" ] || [ -z "$b" ] || [ "$a" -ge "$b" ]; then
    printf 'expected line with "%s" (line %s) before "%s" (line %s) in:\n%s\n' "$2" "${a:-none}" "$3" "${b:-none}" "$1"
    return 1
  fi
}

# Both run the command in a subshell, so a command that exits (die) is
# reported instead of ending the test.
assert_fails() {
  if ("$@") >/dev/null 2>&1; then
    printf 'expected failure: %s\n' "$*"
    return 1
  fi
}

assert_succeeds() {
  local out
  if ! out=$( ("$@") 2>&1); then
    printf 'expected success: %s\noutput:\n%s\n' "$*" "$out"
    return 1
  fi
}
