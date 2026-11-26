# shellcheck shell=bash
# openvpn-config.awk on PIA's published configurations, and on short inputs
# for the options those files do not contain.

ovpn_dir="$FIXTURES/openvpn"

parse() { awk -v MODE=parse -f "$QBTVPN_LIB/openvpn-config.awk" <"$1"; }

sanitize() {
  local file="$1" drop_auth="${2-}"
  printf 'remote 203.0.113.7 1198 udp4\nremote 203.0.113.8 1198 udp4\n' >"$QBTVPN_RUN/remotes"
  awk -v MODE=sanitize -v REMOTES="$QBTVPN_RUN/remotes" -v SRCDIR=/config/openvpn \
    -v DSTDIR=/run/qbtvpn/openvpn/config -v DROP_AUTH="$drop_auth" \
    -f "$QBTVPN_LIB/openvpn-config.awk" <"$file" 2>"$QBTVPN_RUN/notes"
}

block_lines() { awk -v b="$2" '$0 == "<" b ">" { on = 1; next } $0 == "</" b ">" { on = 0 } on' "$1"; }

test_parses_pia_udp() {
  local facts
  facts=$(parse "$ovpn_dir/pia-uk_london.ovpn")
  assert_contains 'remote uk-london.privacy.network 1198 udp' "$facts"
  assert_contains 'auth-user-pass -' "$facts"
  assert_contains 'dev tun' "$facts"
  assert_contains 'pia' "$facts"
  assert_not_contains 'connection-block' "$facts"
}

test_parses_pia_strong_and_tcp() {
  assert_contains 'remote uk-london.privacy.network 1197 udp' "$(parse "$ovpn_dir/pia-strong-uk_london.ovpn")"
  assert_contains 'remote uk-london.privacy.network 502 tcp' "$(parse "$ovpn_dir/pia-tcp-uk_london.ovpn")"
}

test_sanitize_pins_remotes_where_the_first_remote_was() {
  local out
  out=$(sanitize "$ovpn_dir/pia-uk_london.ovpn")
  assert_not_contains 'privacy.network' "$out"
  assert_line_order "$out" 'proto udp' 'remote 203.0.113.7 1198 udp4'
  assert_line_order "$out" 'remote 203.0.113.7 1198 udp4' 'remote 203.0.113.8 1198 udp4'
  assert_line_order "$out" 'remote 203.0.113.8 1198 udp4' 'resolv-retry infinite'
}

test_sanitize_keeps_inline_blocks_byte_for_byte() {
  sanitize "$ovpn_dir/pia-uk_london.ovpn" >"$QBTVPN_RUN/out.ovpn"
  assert_eq "$(block_lines "$ovpn_dir/pia-uk_london.ovpn" ca | tr -d '\r')" "$(block_lines "$QBTVPN_RUN/out.ovpn" ca)"
  assert_eq "$(block_lines "$ovpn_dir/pia-uk_london.ovpn" crl-verify | tr -d '\r')" "$(block_lines "$QBTVPN_RUN/out.ovpn" crl-verify)"
}

test_sanitize_drops_persist_key_from_pias_configurations() {
  local out
  out=$(sanitize "$ovpn_dir/pia-uk_london.ovpn")
  assert_eq "" "$(awk '$1 == "persist-key"' <<<"$out")" "persist-key is removed"
  assert_contains 'persist-tun' "$out"
  assert_contains "removed 'persist-key' (OpenVPN 2.7 always keeps keys across restarts)" "$(cat "$QBTVPN_RUN/notes")"
}

test_sanitize_keeps_or_drops_auth_user_pass() {
  assert_contains 'auth-user-pass' "$(sanitize "$ovpn_dir/pia-uk_london.ovpn")"
  assert_not_contains 'auth-user-pass' "$(sanitize "$ovpn_dir/pia-uk_london.ovpn" 1)"
}

test_sanitize_drops_managed_and_removed_options() {
  local out notes
  cat >"$QBTVPN_RUN/in.ovpn" <<'EOF'
client
dev tun
user nobody
group nogroup
script-security 3
up /etc/openvpn/update-resolv-conf
down /etc/openvpn/update-resolv-conf
log /var/log/openvpn.log
daemon
route-nopull
block-outside-dns
keysize 256
ncp-disable
mlock
remote-random-hostname
redirect-gateway def1 bypass-dhcp
redirect-private local
remote vpn.example.net 1194 udp
cipher AES-256-GCM
EOF
  out=$(sanitize "$QBTVPN_RUN/in.ovpn")
  notes=$(cat "$QBTVPN_RUN/notes")
  for opt in 'user ' 'group ' script-security 'up ' 'down ' 'log ' daemon route-nopull block-outside-dns keysize ncp-disable mlock remote-random-hostname 'dev ' redirect-gateway redirect-private; do
    assert_eq "" "$(awk -v o="$opt" 'index($0, o) == 1' <<<"$out")" "${opt} is removed"
  done
  assert_contains 'client' "$out"
  assert_contains 'cipher AES-256-GCM' "$out"
  assert_contains "removed 'keysize' (removed from OpenVPN)" "$notes"
  assert_contains "removed 'block-outside-dns' (Windows only)" "$notes"
  assert_contains "removed 'redirect-gateway' (the container routes all traffic through the tunnel itself)" "$notes"
}

test_sanitize_translates_ns_cert_type_and_tls_remote() {
  local out
  printf 'client\nns-cert-type server\ntls-remote server.example.net\nremote a.example.net\n' >"$QBTVPN_RUN/in.ovpn"
  out=$(sanitize "$QBTVPN_RUN/in.ovpn")
  assert_contains 'remote-cert-tls server' "$out"
  assert_contains 'verify-x509-name server.example.net name' "$out"
  assert_not_contains 'ns-cert-type' "$out"
  assert_not_contains 'tls-remote' "$out"
}

test_sanitize_rewrites_paths_under_config_openvpn() {
  local out
  printf 'client\nca /config/openvpn/ca.crt\ncert client.crt\nremote a.example.net\n' >"$QBTVPN_RUN/in.ovpn"
  out=$(sanitize "$QBTVPN_RUN/in.ovpn")
  assert_contains 'ca /run/qbtvpn/openvpn/config/ca.crt' "$out"
  assert_contains 'cert client.crt' "$out"
}

test_parse_fills_global_port_and_proto() {
  local facts
  printf 'client\nproto tcp-client\nport 443\nremote a.example.net\nremote b.example.net 8443\nremote c.example.net 53 udp\n' >"$QBTVPN_RUN/in.ovpn"
  facts=$(parse "$QBTVPN_RUN/in.ovpn")
  assert_contains 'remote a.example.net 443 tcp-client' "$facts"
  assert_contains 'remote b.example.net 8443 tcp-client' "$facts"
  assert_contains 'remote c.example.net 53 udp' "$facts"
}

test_parse_reports_connection_blocks_and_static_keys() {
  printf 'client\n<connection>\nremote a.example.net 1194 udp\n</connection>\n' >"$QBTVPN_RUN/in.ovpn"
  assert_contains 'connection-block' "$(parse "$QBTVPN_RUN/in.ovpn")"
  printf 'dev tun\nsecret static.key\nremote a.example.net\n' >"$QBTVPN_RUN/in.ovpn"
  assert_contains 'secret' "$(parse "$QBTVPN_RUN/in.ovpn")"
}

test_remote_text_inside_an_inline_block_is_not_a_remote() {
  printf 'client\n<ca>\nremote not-an-option.example 1\n</ca>\nremote real.example 1194 udp\n' >"$QBTVPN_RUN/in.ovpn"
  local facts
  facts=$(parse "$QBTVPN_RUN/in.ovpn")
  assert_contains 'remote real.example 1194 udp' "$facts"
  assert_not_contains 'not-an-option' "$facts"
}
