# shellcheck shell=bash
# shellcheck disable=SC2034  # variables read by the library functions under test
# openvpn.sh: ovpn_route_ipv6 on a kernel dummy interface standing in for the
# tunnel.

# shellcheck source=/dev/null
. "$QBTVPN_LIB/openvpn.sh"

# tunnel_setup: creates the dummy interface qbtvpn6 as FW_TUN, removed when
# the test exits.
tunnel_setup() {
  FW_TUN=qbtvpn6
  ip link add "$FW_TUN" type dummy
  trap 'ip link del qbtvpn6' EXIT
  ip link set "$FW_TUN" up
}

test_route_ipv6_waits_for_a_global_address() {
  tunnel_setup
  ovpn_route_ipv6 2>"$QBTVPN_RUN/log"
  assert_eq "" "$(ip -6 route show 2000::/4 dev "$FW_TUN")" "no route with only a link-local address"
  assert_eq "" "$(cat "$QBTVPN_RUN/log")" "nothing logged"
}

test_route_ipv6_routes_the_four_ranges_once() {
  local net
  tunnel_setup
  ip -6 addr add fd00:14::1000/64 dev "$FW_TUN" nodad
  ovpn_route_ipv6 2>"$QBTVPN_RUN/log"
  for net in ::/3 2000::/4 3000::/4 fc00::/7; do
    assert_contains "$net" "$(ip -6 route show "$net" dev "$FW_TUN")" "${net} goes into the tunnel"
  done
  assert_contains "openvpn: IPv6 ::/3 2000::/4 3000::/4 fc00::/7 routed into qbtvpn6" "$(cat "$QBTVPN_RUN/log")"
  ovpn_route_ipv6 2>"$QBTVPN_RUN/log"
  assert_eq "" "$(cat "$QBTVPN_RUN/log")" "a second pass adds and logs nothing"
}
