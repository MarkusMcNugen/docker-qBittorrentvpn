# shellcheck shell=bash
# shellcheck disable=SC2034  # variables read by the library functions under test
# wireguard.sh: parsing a wg-quick configuration made with real keys, the
# stripped copy, and that `wg setconf` accepts it on a kernel interface.

# shellcheck source=/dev/null
. "$QBTVPN_LIB/network.sh"
# shellcheck source=/dev/null
. "$QBTVPN_LIB/firewall.sh"
# shellcheck source=/dev/null
. "$QBTVPN_LIB/wireguard.sh"

wg_setup() {
  WG_SRC="$QBTVPN_RUN/wireguard-src"
  mkdir -p "$WG_SRC"
  CFG_VPN_CONFIG=""
  CFG_VPN_CONFIG_RANDOM=no
  CFG_WG_KEEPALIVE=25
  local priv peer_pub psk
  priv=$(wg genkey)
  peer_pub=$(wg genkey | wg pubkey)
  psk=$(wg genpsk)
  cat >"$WG_SRC/provider.conf" <<EOF
# Provider-style configuration
[Interface]
PrivateKey = ${priv}
Address = 10.2.0.2/32, fd00:10:2::2/128
DNS = 10.2.0.1, search.example
MTU = 1380
PostUp = iptables -A OUTPUT -j ACCEPT
PreDown = echo bye

[Peer]
PublicKey = ${peer_pub}
PresharedKey = ${psk}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.44:51820
EOF
}

test_prepare_strips_hooks_and_pins_the_endpoint() {
  wg_setup
  wg_prepare 2>"$QBTVPN_RUN/log"
  local conf
  conf=$(cat "$WG_CONF")
  assert_contains 'PrivateKey = ' "$conf"
  assert_contains 'PresharedKey = ' "$conf"
  assert_contains 'AllowedIPs = 0.0.0.0/0, ::/0' "$conf"
  assert_contains 'Endpoint = 203.0.113.44:51820' "$conf"
  assert_contains 'PersistentKeepalive = 25' "$conf"
  for key in Address DNS MTU PostUp PreDown; do
    assert_not_contains "${key} =" "$conf"
  done
  assert_contains 'shell hooks from a configuration file are not run' "$(cat "$QBTVPN_RUN/log")"
  assert_eq "10.2.0.2/32 fd00:10:2::2/128" "${WG_ADDRESSES[*]}"
  assert_eq "10.2.0.1" "${WG_DNS[*]}"
  assert_eq 1380 "$WG_MTU"
  assert_eq "203.0.113.44 51820 udp" "${FW_ENDPOINTS[*]}"
  assert_eq wg0 "$FW_TUN"
  assert_eq 10.2.0.1 "$(state_read vpn-dns)"
  assert_eq 10.2.0.1 "$(wg_gateway)"
}

test_existing_keepalive_is_kept() {
  wg_setup
  printf 'PersistentKeepalive = 15\n' >>"$WG_SRC/provider.conf"
  wg_prepare 2>/dev/null
  assert_contains 'PersistentKeepalive = 15' "$(cat "$WG_CONF")"
  assert_not_contains 'PersistentKeepalive = 25' "$(cat "$WG_CONF")"
}

test_ipv6_endpoints_and_unknown_keys_are_refused() {
  wg_setup
  awk '{ sub(/Endpoint = .*/, "Endpoint = [2001:db8::1]:51820"); print }' "$WG_SRC/provider.conf" >"$WG_SRC/v6.conf"
  rm "$WG_SRC/provider.conf"
  assert_fails wg_prepare
  printf '[Interface]\nPrivateKey = %s\nBogusKey = 1\n' "$(wg genkey)" >"$WG_SRC/v6.conf"
  assert_fails wg_prepare
}

test_wg_accepts_the_stripped_configuration() {
  wg_setup
  wg_prepare 2>/dev/null
  if ! ip link add dev wgtest0 type wireguard; then
    echo "this test needs kernel WireGuard and NET_ADMIN to load the configuration into a real interface"
    return 1
  fi
  assert_succeeds wg setconf wgtest0 "$WG_CONF"
  assert_contains '203.0.113.44:51820' "$(wg show wgtest0 endpoints)"
  assert_contains '25' "$(wg show wgtest0 persistent-keepalive)"
  ip link del dev wgtest0
}
