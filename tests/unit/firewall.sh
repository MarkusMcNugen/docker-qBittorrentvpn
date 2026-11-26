# shellcheck shell=bash
# shellcheck disable=SC2034  # variables read by the library functions under test
# The rendered kill-switch rulesets: their content and order, and that the
# kernel's own iptables-restore accepts them (this needs NET_ADMIN).

# shellcheck source=/dev/null
. "$QBTVPN_LIB/network.sh"
# shellcheck source=/dev/null
. "$QBTVPN_LIB/firewall.sh"

setup() {
  FW_TUN=wg0
  NET_DEV=eth0
  NET_RESOLVERS=(127.0.0.11 192.168.1.1)
  FW_LOCAL=("eth0 172.17.0.0/16" "eth0 192.168.1.0/24")
  FW_ENDPOINTS=("203.0.113.5 51820 udp" "203.0.113.6 1194 tcp")
  FW_DNS_EXCEPTIONS=()
  FW_TUNNEL_PORTS=(51413)
  FW_OWNER=yes
  FW_REJECT=yes
  CFG_WEBUI_PORT=8080
  CFG_INPUT_PORTS=(9117)
  CFG_PUID=99
  CFG_BLOCK_DOCKER_DNS=yes
}

test_final_drops_by_default_in_every_chain() {
  setup
  local v4 v6
  v4=$(fw_render_v4_final)
  v6=$(fw_render_v6_final)
  for c in INPUT FORWARD OUTPUT; do
    assert_contains ":${c} DROP [0:0]" "$v4"
    assert_contains ":${c} DROP [0:0]" "$v6"
  done
}

test_final_lets_nothing_but_endpoints_and_local_nets_leave_eth0() {
  setup
  local v4 eth0_out
  v4=$(fw_render_v4_final)
  eth0_out=$(awk '/^-A OUTPUT -o eth0/' <<<"$v4")
  assert_eq 4 "$(wc -l <<<"$eth0_out")" "two endpoints and two local networks"
  assert_contains '-A OUTPUT -o eth0 -d 203.0.113.5/32 -p udp --dport 51820 -m owner ! --uid-owner 99 -j ACCEPT' "$eth0_out"
  assert_contains '-A OUTPUT -o eth0 -d 203.0.113.6/32 -p tcp --dport 1194 -m owner ! --uid-owner 99 -j ACCEPT' "$eth0_out"
  assert_contains '-A OUTPUT -o eth0 -d 172.17.0.0/16 -j ACCEPT' "$eth0_out"
  assert_contains '-A OUTPUT -o eth0 -d 192.168.1.0/24 -j ACCEPT' "$eth0_out"
  assert_eq "" "$(awk '/^-A OUTPUT/ && !/-d / && !/-o (lo|wg0)/ && !/--dport (53|853)/ && !/REJECT/' <<<"$v4")" "no unrestricted OUTPUT accept"
}

test_final_dns_is_dropped_after_the_tunnel_accept_and_before_local_nets() {
  setup
  local v4
  v4=$(fw_render_v4_final)
  assert_line_order "$v4" '-A OUTPUT -o lo -d 127.0.0.11/32 -j DROP' '-A OUTPUT -o lo -j ACCEPT'
  assert_line_order "$v4" '-A OUTPUT -o wg0 -j ACCEPT' '-A OUTPUT -p udp --dport 53 -j DROP'
  assert_line_order "$v4" '-A OUTPUT -p tcp --dport 853 -j DROP' '-A OUTPUT -o eth0 -d 172.17.0.0/16 -j ACCEPT'
  assert_eq '-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited' "$(awk '/^-A OUTPUT/' <<<"$v4" | tail -n 1)"
}

test_final_lan_dns_exception_comes_before_the_dns_drop() {
  setup
  FW_DNS_EXCEPTIONS=(192.168.1.2)
  local v4
  v4=$(fw_render_v4_final)
  assert_line_order "$v4" '-A OUTPUT -d 192.168.1.2/32 -p udp --dport 53 -j ACCEPT' '-A OUTPUT -p udp --dport 53 -j DROP'
  assert_line_order "$v4" '-A OUTPUT -d 192.168.1.2/32 -p tcp --dport 53 -j ACCEPT' '-A OUTPUT -p tcp --dport 53 -j DROP'
}

test_final_docker_dns_block_follows_the_setting() {
  setup
  CFG_BLOCK_DOCKER_DNS=no
  assert_not_contains '127.0.0.11' "$(fw_render_v4_final)"
}

test_final_webui_and_input_ports_only_from_local_networks() {
  setup
  local v4
  v4=$(fw_render_v4_final)
  assert_contains '-A INPUT -i eth0 -s 172.17.0.0/16 -p tcp --dport 8080 -j ACCEPT' "$v4"
  assert_contains '-A INPUT -i eth0 -s 192.168.1.0/24 -p tcp --dport 9117 -j ACCEPT' "$v4"
  assert_eq "" "$(awk '/^-A INPUT -i wg0/ && /ACCEPT/' <<<"$v4")" "nothing accepted straight from the tunnel"
  assert_contains '-A INPUT -i wg0 -j QBTVPN_TUNNEL_IN' "$v4"
  assert_contains '-A QBTVPN_TUNNEL_IN -p tcp --dport 51413 -j ACCEPT' "$v4"
  assert_contains '-A QBTVPN_TUNNEL_IN -p udp --dport 51413 -j ACCEPT' "$v4"
  assert_not_contains 'QBTVPN_TUNNEL_IN -p tcp --dport 8080' "$v4"
}

test_final_without_owner_match_or_reject() {
  setup
  FW_OWNER=no
  FW_REJECT=no
  local v4
  v4=$(fw_render_v4_final)
  assert_not_contains 'owner' "$v4"
  assert_not_contains 'REJECT' "$v4"
  assert_contains '-A OUTPUT -o eth0 -d 203.0.113.5/32 -p udp --dport 51820 -j ACCEPT' "$v4"
}

test_root_puid_gets_no_owner_exception() {
  setup
  CFG_PUID=0
  assert_not_contains 'uid-owner' "$(fw_render_v4_final)"
}

test_v6_final_leaves_only_through_the_tunnel() {
  setup
  local v6
  v6=$(fw_render_v6_final)
  assert_eq $'-A OUTPUT -o lo -j ACCEPT\n-A OUTPUT -o wg0 -j ACCEPT\n-A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited' "$(awk '/^-A OUTPUT/' <<<"$v6")"
}

test_lockdown_allows_root_dns_to_non_loopback_resolvers_only() {
  setup
  local v4
  v4=$(fw_render_v4_lockdown)
  assert_contains '-A OUTPUT -d 192.168.1.1/32 -p udp --dport 53 -m owner --uid-owner 0 -j ACCEPT' "$v4"
  assert_contains '-A OUTPUT -d 192.168.1.1/32 -p tcp --dport 53 -m owner --uid-owner 0 -j ACCEPT' "$v4"
  assert_not_contains '127.0.0.11/32' "$v4"
  assert_eq 3 "$(awk '/^-A OUTPUT/' <<<"$v4" | wc -l)"
}

# Every rendered ruleset passes iptables-restore --test on each backend the
# kernel offers; at least one backend must be present.
test_kernel_accepts_every_ruleset() {
  setup
  local backend checked=0 r file
  for backend in nft legacy; do
    if ! "iptables-${backend}" -w 5 -S >/dev/null 2>&1; then
      echo "backend ${backend}: not available in this kernel"
      continue
    fi
    for r in fw_render_v4_lockdown fw_render_v4_final; do
      file="$QBTVPN_RUN/${r}.rules"
      "$r" >"$file"
      assert_succeeds "iptables-${backend}-restore" --test "$file"
    done
    if "ip6tables-${backend}" -w 5 -S >/dev/null 2>&1; then
      for r in fw_render_v6_lockdown fw_render_v6_final; do
        file="$QBTVPN_RUN/${r}.rules"
        "$r" >"$file"
        assert_succeeds "ip6tables-${backend}-restore" --test "$file"
      done
    fi
    echo "backend ${backend}: every ruleset accepted"
    checked=$((checked + 1))
  done
  [ "$checked" -gt 0 ] || { echo "no iptables backend available: run the unit tests with --cap-add NET_ADMIN"; return 1; }
}
