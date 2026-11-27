# shellcheck shell=bash
# shellcheck disable=SC2034  # variables read by the library functions under test
# network.sh: ipv6_disabled, against stand-ins for /proc/sys/net and against
# the test container's own settings.

# shellcheck source=/dev/null
. "$QBTVPN_LIB/network.sh"

# sysctl_tree ALL DEFAULT: points NET_SYSCTL at a tree whose all and default
# disable_ipv6 files hold ALL and DEFAULT.
sysctl_tree() {
  NET_SYSCTL="$QBTVPN_RUN/sysctl-$1-$2"
  mkdir -p "$NET_SYSCTL/ipv6/conf/all" "$NET_SYSCTL/ipv6/conf/default"
  printf '%s\n' "$1" >"$NET_SYSCTL/ipv6/conf/all/disable_ipv6"
  printf '%s\n' "$2" >"$NET_SYSCTL/ipv6/conf/default/disable_ipv6"
}

test_ipv6_disabled_when_the_kernel_has_no_ipv6() {
  NET_SYSCTL="$QBTVPN_RUN/sysctl-no-ipv6"
  mkdir -p "$NET_SYSCTL/ipv4"
  assert_succeeds ipv6_disabled
}

test_ipv6_disabled_when_all_or_default_switch_it_off() {
  sysctl_tree 1 1
  assert_succeeds ipv6_disabled
  sysctl_tree 0 1
  assert_succeeds ipv6_disabled
  sysctl_tree 1 0
  assert_succeeds ipv6_disabled
}

test_ipv6_enabled_when_both_allow_it() {
  sysctl_tree 0 0
  assert_fails ipv6_disabled
}

# tests/run.sh starts the unit container with both settings at 0.
test_ipv6_enabled_in_the_test_container() {
  NET_SYSCTL=/proc/sys/net
  assert_fails ipv6_disabled
}

# uid_map LINE...: points NET_UID_MAP at a stand-in holding LINEs.
uid_map() {
  NET_UID_MAP="$QBTVPN_RUN/uid_map"
  printf '%s\n' "$@" >"$NET_UID_MAP"
}

test_the_hosts_user_namespace_is_not_a_user_namespace() {
  uid_map '         0          0 4294967295'
  assert_fails in_user_namespace
}

test_rootless_mappings_are_a_user_namespace() {
  uid_map '         0       1000          1' '         1     100000      65536'
  assert_succeeds in_user_namespace
  uid_map '         0     100000      65536'
  assert_succeeds in_user_namespace
}

test_no_uid_map_is_not_a_user_namespace() {
  NET_UID_MAP="$QBTVPN_RUN/no-such-uid_map"
  assert_fails in_user_namespace
}
