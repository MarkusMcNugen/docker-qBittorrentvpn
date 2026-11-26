# shellcheck shell=bash
# load_config: defaults, the previous image's spellings, and refusals.

# shellcheck source=/dev/null
. "$QBTVPN_LIB/config.sh"

clear_env() {
  local v
  for v in $(compgen -e); do
    case "$v" in
      VPN_* | LAN_NETWORK | NAME_SERVERS | PUID | PGID | UMASK | WEBUI_* | INCOMING_PORT* | FIREWALL_BACKEND | WIREGUARD_* | NATPMP_* | PIA_* | QBT_* | DEBUG) unset "$v" ;;
    esac
  done
}

test_defaults() {
  clear_env
  load_config
  assert_eq yes "$CFG_VPN_ENABLED"
  assert_eq auto "$CFG_VPN_TYPE"
  assert_eq 99 "$CFG_PUID"
  assert_eq 100 "$CFG_PGID"
  assert_eq 002 "$CFG_UMASK"
  assert_eq 8080 "$CFG_WEBUI_PORT"
  assert_eq "" "$CFG_INCOMING_PORT"
  assert_eq auto "$CFG_PF_MODE"
  assert_eq 300 "$CFG_RECOVERY_TIMEOUT"
  assert_eq yes "$CFG_BLOCK_DOCKER_DNS"
  assert_eq "1.1.1.1 9.9.9.9" "${CFG_DNS_FALLBACK[*]}"
  assert_eq auto "$CFG_FIREWALL_BACKEND"
  assert_eq 25 "$CFG_WG_KEEPALIVE"
}

test_previous_image_spellings() {
  clear_env
  export WEBUI_PORT_ENV=9090 INCOMING_PORT_ENV=6881 PUID=root PGID=root VPN_ENABLED=Yes
  load_config
  assert_eq 9090 "$CFG_WEBUI_PORT"
  assert_eq 6881 "$CFG_INCOMING_PORT"
  assert_eq 0 "$CFG_PUID"
  assert_eq 0 "$CFG_PGID"
  assert_eq yes "$CFG_VPN_ENABLED"
}

test_lists_are_parsed_and_normalized() {
  clear_env
  export LAN_NETWORK=' 192.168.1.77/24, 10.0.0.0/8 ' NAME_SERVERS='9.9.9.9 ,1.0.0.1' VPN_INPUT_PORTS='8989,7878'
  load_config
  assert_eq "192.168.1.0/24 10.0.0.0/8" "${CFG_LAN_NETWORKS[*]}"
  assert_eq "9.9.9.9 1.0.0.1" "${CFG_NAME_SERVERS[*]}"
  assert_eq "8989 7878" "${CFG_INPUT_PORTS[*]}"
}

test_refuses_values_that_would_break_or_bypass_the_vpn() {
  clear_env
  LAN_NETWORK=0.0.0.0/0 assert_fails load_config
  LAN_NETWORK=192.168.1.0 assert_fails load_config
  NAME_SERVERS=dns.example assert_fails load_config
  VPN_RECOVERY_TIMEOUT=soon assert_fails load_config
  VPN_PORT_FORWARDING=maybe assert_fails load_config
  VPN_TYPE=ipsec assert_fails load_config
  WEBUI_PORT=70000 assert_fails load_config
  PUID=873 assert_fails load_config
  UMASK=9 assert_fails load_config
  VPN_USERNAME=onlyuser assert_fails load_config
}

test_secrets_come_from_files() {
  clear_env
  printf 'p1a-user\n' >"$QBTVPN_RUN/u"
  printf 'p1a pass\n' >"$QBTVPN_RUN/p"
  export VPN_USERNAME_FILE="$QBTVPN_RUN/u" VPN_PASSWORD_FILE="$QBTVPN_RUN/p"
  load_config
  assert_eq p1a-user "$CFG_VPN_USERNAME"
  assert_eq 'p1a pass' "$CFG_VPN_PASSWORD"
}
