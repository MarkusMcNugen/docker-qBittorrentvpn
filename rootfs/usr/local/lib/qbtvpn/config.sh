# shellcheck shell=bash
# Reads, validates and normalizes every environment variable the container
# accepts into CFG_* variables. Older spellings are accepted beside the
# current ones: WEBUI_PORT_ENV, INCOMING_PORT_ENV and PUID/PGID=root.
#
# Each validator runs in a command substitution and exits that subshell on a
# bad value; the `|| exit 1` after it ends load_config's shell too, so a bad
# value stops start-up whatever context load_config is called from.

# shellcheck disable=SC2034  # CFG_* variables are read by the other libraries.
load_config() {
  local item raw

  QBTVPN_DEBUG=$(env_bool DEBUG no) || exit 1
  if [ "$QBTVPN_DEBUG" = yes ]; then QBTVPN_DEBUG=1; else QBTVPN_DEBUG=0; fi

  CFG_VPN_ENABLED=$(env_bool VPN_ENABLED yes) || exit 1
  CFG_VPN_TYPE=$(env_choice VPN_TYPE auto auto openvpn wireguard) || exit 1
  CFG_VPN_CONFIG=$(trim "${VPN_CONFIG-}")
  CFG_VPN_CONFIG_RANDOM=$(env_bool VPN_CONFIG_RANDOM no) || exit 1
  CFG_VPN_USERNAME=$(env_secret VPN_USERNAME) || exit 1
  CFG_VPN_PASSWORD=$(env_secret VPN_PASSWORD) || exit 1
  if { [ -n "$CFG_VPN_USERNAME" ] && [ -z "$CFG_VPN_PASSWORD" ]; } ||
    { [ -z "$CFG_VPN_USERNAME" ] && [ -n "$CFG_VPN_PASSWORD" ]; }; then
    die "VPN_USERNAME and VPN_PASSWORD must be set together"
  fi
  CFG_VPN_OPTIONS="${VPN_OPTIONS-}"

  CFG_LAN_NETWORKS=()
  while IFS= read -r item; do
    is_ipv4_cidr "$item" || die "LAN_NETWORK entry '${item}' is not an IPv4 network in CIDR form such as 192.168.1.0/24"
    item=$(cidr_normalize "$item")
    [ "${item##*/}" -ge 1 ] || die "LAN_NETWORK entry '${item}' covers every address, which would route all traffic around the VPN"
    if ! is_private_ipv4 "${item%/*}"; then
      log_warn "LAN_NETWORK entry ${item} is a public range; traffic to it leaves outside the VPN"
    fi
    CFG_LAN_NETWORKS+=("$item")
  done < <(split_list "${LAN_NETWORK-}")

  CFG_NAME_SERVERS=()
  while IFS= read -r item; do
    is_ipv4 "$item" || is_ipv6 "$item" || die "NAME_SERVERS entry '${item}' is not an IP address"
    CFG_NAME_SERVERS+=("$item")
  done < <(split_list "${NAME_SERVERS-}")

  CFG_DNS_FALLBACK=()
  while IFS= read -r item; do
    is_ipv4 "$item" || is_ipv6 "$item" || die "VPN_DNS_FALLBACK entry '${item}' is not an IP address"
    CFG_DNS_FALLBACK+=("$item")
  done < <(split_list "${VPN_DNS_FALLBACK-1.1.1.1,9.9.9.9}")

  CFG_BLOCK_DOCKER_DNS=$(env_bool VPN_BLOCK_DOCKER_DNS yes) || exit 1

  CFG_INPUT_PORTS=()
  while IFS= read -r item; do
    is_port "$item" || die "VPN_INPUT_PORTS entry '${item}' is not a port number"
    CFG_INPUT_PORTS+=("$((10#$item))")
  done < <(split_list "${VPN_INPUT_PORTS-}")

  CFG_RECOVERY_TIMEOUT=$(env_uint VPN_RECOVERY_TIMEOUT 300) || exit 1
  CFG_CHECK_INTERVAL=$(env_uint VPN_CHECK_INTERVAL 15 1) || exit 1
  CFG_CONNECT_TIMEOUT=$(env_uint VPN_CONNECT_TIMEOUT 120 1) || exit 1
  CFG_FIREWALL_BACKEND=$(env_choice FIREWALL_BACKEND auto auto nft legacy) || exit 1

  CFG_WG_KEEPALIVE=$(env_uint WIREGUARD_KEEPALIVE 25) || exit 1
  CFG_WG_HANDSHAKE_MAX_AGE=$(env_uint WIREGUARD_HANDSHAKE_MAX_AGE 180 1) || exit 1
  CFG_WG_USERSPACE=$(env_choice WIREGUARD_USERSPACE auto auto yes no) || exit 1

  CFG_PF_MODE=$(env_choice VPN_PORT_FORWARDING auto off auto natpmp protonvpn pia) || exit 1
  CFG_PF_GATEWAY=$(trim "${VPN_PORT_FORWARDING_GATEWAY-}")
  if [ -n "$CFG_PF_GATEWAY" ] && ! is_ipv4 "$CFG_PF_GATEWAY"; then
    die "VPN_PORT_FORWARDING_GATEWAY must be an IPv4 address, not '${CFG_PF_GATEWAY}'"
  fi
  CFG_PF_WAIT=$(env_uint VPN_PORT_FORWARDING_WAIT 30) || exit 1
  CFG_NATPMP_INTERVAL=$(env_uint NATPMP_RENEW_INTERVAL 45 1) || exit 1
  CFG_NATPMP_LIFETIME=$(env_uint NATPMP_LIFETIME 60 1) || exit 1
  CFG_PIA_PF_HOSTNAME=$(trim "${PIA_PF_HOSTNAME-}")
  CFG_PIA_PF_GATEWAY=$(trim "${PIA_PF_GATEWAY-}")
  if [ -n "$CFG_PIA_PF_GATEWAY" ] && ! is_ipv4 "$CFG_PIA_PF_GATEWAY"; then
    die "PIA_PF_GATEWAY must be an IPv4 address, not '${CFG_PIA_PF_GATEWAY}'"
  fi
  CFG_PIA_BIND_INTERVAL=$(env_uint PIA_BIND_INTERVAL 900 60) || exit 1

  raw=$(trim "${PUID-}")
  if [ "${raw,,}" = root ]; then raw=0; fi
  PUID="$raw"
  CFG_PUID=$(env_uint PUID 99) || exit 1
  raw=$(trim "${PGID-}")
  if [ "${raw,,}" = root ]; then raw=0; fi
  PGID="$raw"
  CFG_PGID=$(env_uint PGID 100) || exit 1
  if [ "$CFG_PUID" = 873 ] || [ "$CFG_PGID" = 873 ]; then
    die "PUID/PGID 873 belongs to the container's vpn user; choose another id"
  fi
  CFG_UMASK=$(trim "${UMASK-}")
  [ -n "$CFG_UMASK" ] || CFG_UMASK=002
  [[ "$CFG_UMASK" =~ ^0?[0-7]{3}$ ]] || die "UMASK must be three octal digits such as 002, not '${CFG_UMASK}'"

  CFG_WEBUI_PORT=$(first_set WEBUI_PORT WEBUI_PORT_ENV)
  [ -n "$CFG_WEBUI_PORT" ] || CFG_WEBUI_PORT=8080
  is_port "$CFG_WEBUI_PORT" || die "WEBUI_PORT must be a port number, not '${CFG_WEBUI_PORT}'"
  CFG_WEBUI_PORT=$((10#$CFG_WEBUI_PORT))
  CFG_INCOMING_PORT=$(first_set INCOMING_PORT INCOMING_PORT_ENV)
  if [ -n "$CFG_INCOMING_PORT" ]; then
    is_port "$CFG_INCOMING_PORT" || die "INCOMING_PORT must be a port number, not '${CFG_INCOMING_PORT}'"
    CFG_INCOMING_PORT=$((10#$CFG_INCOMING_PORT))
  fi
  CFG_WEBUI_USERNAME=$(env_secret WEBUI_USERNAME) || exit 1
  CFG_WEBUI_PASSWORD=$(env_secret WEBUI_PASSWORD) || exit 1
  CFG_WEBUI_CSRF=""
  if [ -n "$(trim "${WEBUI_CSRF_PROTECTION-}")" ]; then
    CFG_WEBUI_CSRF=$(env_bool WEBUI_CSRF_PROTECTION yes) || exit 1
  fi
  CFG_QBT_STOP_TIMEOUT=$(env_uint QBT_STOP_TIMEOUT 120 1) || exit 1
}

# Logs the effective configuration without any secret.
log_config() {
  log_info "VPN_ENABLED=${CFG_VPN_ENABLED} VPN_TYPE=${CFG_VPN_TYPE} VPN_CONFIG=${CFG_VPN_CONFIG:-<auto>}"
  log_info "LAN_NETWORK=${CFG_LAN_NETWORKS[*]:-<none>} NAME_SERVERS=${CFG_NAME_SERVERS[*]:-<from VPN>} VPN_DNS_FALLBACK=${CFG_DNS_FALLBACK[*]:-<none>}"
  log_info "VPN_PORT_FORWARDING=${CFG_PF_MODE} VPN_RECOVERY_TIMEOUT=${CFG_RECOVERY_TIMEOUT}s VPN_BLOCK_DOCKER_DNS=${CFG_BLOCK_DOCKER_DNS} FIREWALL_BACKEND=${CFG_FIREWALL_BACKEND}"
  log_info "PUID=${CFG_PUID} PGID=${CFG_PGID} UMASK=${CFG_UMASK} WEBUI_PORT=${CFG_WEBUI_PORT} INCOMING_PORT=${CFG_INCOMING_PORT:-<from qBittorrent.conf>}"
  if [ -n "$CFG_VPN_USERNAME" ]; then log_info "VPN credentials: provided"; fi
  if [ -n "$CFG_WEBUI_USERNAME" ] || [ -n "$CFG_WEBUI_PASSWORD" ]; then log_info "WebUI credentials: provided"; fi
}
