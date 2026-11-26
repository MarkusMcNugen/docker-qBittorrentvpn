# shellcheck shell=bash
# WireGuard: reads a wg-quick style configuration, pins each peer endpoint to
# a resolved address, and brings up wg0 with the kernel module, or with
# wireguard-go running as the vpn user when the kernel has no WireGuard.
#
# Routing sends 0.0.0.0/1 and 128.0.0.0/1 (and ::/1, 8000::/1 when the tunnel
# has an IPv6 address) through wg0, and each endpoint through the container's
# own gateway, so no fwmark rules or src_valid_mark sysctl are needed.

WG_SRC=/config/wireguard
WG_IF=wg0
WG_CONF=""
WG_ADDRESSES=()
WG_DNS=()
WG_MTU=""
WG_USERSPACE_PID=""
WG_ENDPOINT_IPS=()

wg_pick_config() {
  local -a found=()
  local f
  if [ -n "$CFG_VPN_CONFIG" ]; then
    case "$CFG_VPN_CONFIG" in
      /*) f="$CFG_VPN_CONFIG" ;;
      *) f="$WG_SRC/$CFG_VPN_CONFIG" ;;
    esac
    [ -f "$f" ] || die "VPN_CONFIG ${CFG_VPN_CONFIG}: no such file"
    printf '%s' "$f"
    return 0
  fi
  while IFS= read -r -d '' f; do
    found+=("$f")
  done < <(find "$WG_SRC" -maxdepth 1 -type f -name '*.conf' -print0 | sort -z)
  [ "${#found[@]}" -gt 0 ] || die "no WireGuard configuration in ${WG_SRC}: add your provider's .conf file there"
  if [ "${#found[@]}" -gt 1 ] && [ "$CFG_VPN_CONFIG_RANDOM" = yes ]; then
    f="${found[RANDOM % ${#found[@]}]}"
    log_info "wireguard: ${#found[@]} configurations found; picked ${f##*/} at random"
  else
    f="${found[0]}"
    if [ "${#found[@]}" -gt 1 ]; then
      log_info "wireguard: ${#found[@]} configurations found; using ${f##*/} (set VPN_CONFIG to choose, or VPN_CONFIG_RANDOM=yes)"
    fi
  fi
  printf '%s' "$f"
}

# wg_prepare: parses the configuration into WG_* variables and writes the
# stripped, endpoint-pinned copy that `wg setconf` loads.
wg_prepare() {
  local src line key val section="" item host port ip resolved peer_has_keepalive=no peers=0
  src=$(wg_pick_config) || exit 1
  log_info "wireguard: configuration ${src}"
  mkdir -p "$QBTVPN_RUN/wireguard"
  chmod 0700 "$QBTVPN_RUN/wireguard"
  WG_CONF="$QBTVPN_RUN/wireguard/${WG_IF}.conf"
  # shellcheck disable=SC2034  # read by firewall.sh
  FW_TUN="$WG_IF"
  FW_ENDPOINTS=()
  WG_ADDRESSES=()
  WG_DNS=()
  WG_ENDPOINT_IPS=()
  WG_MTU=""

  finish_peer() {
    if [ "$section" = peer ] && [ "$peer_has_keepalive" = no ] && [ "$CFG_WG_KEEPALIVE" -gt 0 ]; then
      printf 'PersistentKeepalive = %s\n' "$CFG_WG_KEEPALIVE"
    fi
  }

  {
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      line="${line%%#*}"
      line=$(trim "$line")
      [ -n "$line" ] || continue
      case "${line,,}" in
        "[interface]")
          finish_peer
          section=interface
          printf '[Interface]\n'
          continue
          ;;
        "[peer]")
          finish_peer
          section=peer
          peer_has_keepalive=no
          peers=$((peers + 1))
          printf '\n[Peer]\n'
          continue
          ;;
      esac
      [[ "$line" == *=* ]] || die "wireguard: cannot read line '${line}' in ${src}"
      key=$(trim "${line%%=*}")
      val=$(trim "${line#*=}")
      case "${section}:${key,,}" in
        interface:address)
          while IFS= read -r item; do WG_ADDRESSES+=("$item"); done < <(split_list "$val")
          ;;
        interface:dns)
          while IFS= read -r item; do
            if is_ipv4 "$item" || is_ipv6 "$item"; then WG_DNS+=("$item"); fi
          done < <(split_list "$val")
          ;;
        interface:mtu)
          is_uint "$val" || die "wireguard: MTU '${val}' is not a number"
          WG_MTU="$val"
          ;;
        interface:table | interface:saveconfig)
          log_info "wireguard: ignoring ${key}; the container manages routing"
          ;;
        interface:preup | interface:postup | interface:predown | interface:postdown)
          log_warn "wireguard: ignoring ${key} = ${val}; shell hooks from a configuration file are not run"
          ;;
        interface:privatekey | interface:listenport | interface:fwmark)
          printf '%s = %s\n' "$key" "$val"
          ;;
        peer:endpoint)
          if [[ "$val" == \[* ]]; then
            die "wireguard: IPv6 endpoint ${val} is not supported; use the provider's IPv4 endpoint"
          fi
          host="${val%:*}"
          port="${val##*:}"
          is_port "$port" || die "wireguard: endpoint '${val}' has no valid port"
          resolved=$(resolve_ipv4 "$host") || die "wireguard: could not resolve ${host}"
          ip=$(awk 'NR == 1' <<<"$resolved")
          if [ "$(wc -l <<<"$resolved")" -gt 1 ]; then
            log_info "wireguard: ${host} has several addresses; a peer takes one, using ${ip}"
          fi
          log_info "wireguard: endpoint ${host}:${port} -> ${ip}"
          FW_ENDPOINTS+=("$ip $port udp")
          WG_ENDPOINT_IPS+=("$ip")
          printf 'Endpoint = %s:%s\n' "$ip" "$port"
          ;;
        peer:persistentkeepalive)
          peer_has_keepalive=yes
          printf '%s = %s\n' "$key" "$val"
          ;;
        peer:publickey | peer:presharedkey | peer:allowedips)
          printf '%s = %s\n' "$key" "$val"
          ;;
        *)
          die "wireguard: unknown key '${key}' in ${src}"
          ;;
      esac
    done <"$src"
    finish_peer
  } >"$WG_CONF"
  chmod 0600 "$WG_CONF"
  unset -f finish_peer

  [ "$peers" -gt 0 ] || die "wireguard: ${src} has no [Peer] section"
  [ "${#WG_ENDPOINT_IPS[@]}" -gt 0 ] || die "wireguard: ${src} has no peer Endpoint"
  [ "${#WG_ADDRESSES[@]}" -gt 0 ] || die "wireguard: ${src} has no Address"
  if ! awk 'tolower($1) == "allowedips" && /0\.0\.0\.0\/0/ { ok = 1 } END { exit !ok }' "$WG_CONF"; then
    log_warn "wireguard: no peer allows 0.0.0.0/0; traffic for other destinations is dropped, not leaked"
  fi
  state_write vpn-dns "$(printf '%s\n' "${WG_DNS[@]}")"
}

wg_create_interface() {
  local err=""
  if [ "$CFG_WG_USERSPACE" != yes ]; then
    if err=$(ip link add dev "$WG_IF" type wireguard 2>&1); then
      log_info "wireguard: using the kernel module"
      return 0
    fi
    [ "$CFG_WG_USERSPACE" = auto ] || die "wireguard: the kernel refused a WireGuard interface (${err}) and WIREGUARD_USERSPACE=no"
    log_warn "wireguard: kernel module unavailable (${err}); using wireguard-go"
  fi
  install -d -o vpn -g vpn -m 0700 /run/wireguard
  env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LOG_LEVEL=error \
    setpriv --reuid=vpn --regid=vpn --init-groups \
    --inh-caps=-all,+net_admin --ambient-caps=-all,+net_admin --bounding-set=-all,+net_admin \
    --no-new-privs -- wireguard-go -f "$WG_IF" &
  WG_USERSPACE_PID=$!
  for _ in $(seq 1 50); do
    if [ -S "/run/wireguard/${WG_IF}.sock" ]; then
      log_info "wireguard: wireguard-go running as user vpn (pid ${WG_USERSPACE_PID})"
      return 0
    fi
    kill -0 "$WG_USERSPACE_PID" 2>/dev/null || die "wireguard: wireguard-go exited during start-up"
    sleep 0.2
  done
  die "wireguard: wireguard-go did not create its control socket"
}

wg_up() {
  local addr mtu dev ip v6=no
  wg_create_interface
  wg setconf "$WG_IF" "$WG_CONF"
  for addr in "${WG_ADDRESSES[@]}"; do
    if [[ "$addr" == *:* ]]; then
      if ipv6_disabled; then
        log_warn "wireguard: IPv6 is disabled in this container; skipping address ${addr}"
        continue
      fi
      if ip -6 address add "$addr" dev "$WG_IF"; then v6=yes; else log_warn "wireguard: could not add ${addr}"; fi
    else
      ip -4 address add "$addr" dev "$WG_IF"
    fi
  done
  if [ -n "$WG_MTU" ]; then
    mtu="$WG_MTU"
  else
    dev=$(ip -4 route get "${WG_ENDPOINT_IPS[0]}" | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
    mtu=$(( $(cat "/sys/class/net/${dev:-$NET_DEV}/mtu") - 80 ))
  fi
  ip link set dev "$WG_IF" mtu "$mtu" up
  for ip in "${WG_ENDPOINT_IPS[@]}"; do
    if [ -n "$NET_GW" ]; then
      ip -4 route replace "${ip}/32" via "$NET_GW" dev "$NET_DEV"
    else
      ip -4 route replace "${ip}/32" dev "$NET_DEV"
    fi
  done
  ip -4 route replace 0.0.0.0/1 dev "$WG_IF"
  ip -4 route replace 128.0.0.0/1 dev "$WG_IF"
  if [ "$v6" = yes ]; then
    ip -6 route replace ::/1 dev "$WG_IF"
    ip -6 route replace 8000::/1 dev "$WG_IF"
  fi
  log_info "wireguard: ${WG_IF} up, mtu ${mtu}, addresses ${WG_ADDRESSES[*]}"
}

# Prints the age in seconds of the newest peer handshake, or "never".
wg_handshake_age() {
  local newest
  newest=$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk '$2 > max { max = $2 } END { print max + 0 }')
  if [ "${newest:-0}" -eq 0 ]; then
    printf 'never'
  else
    printf '%s' $(($(now) - newest))
  fi
}

wg_alive() {
  ip link show dev "$WG_IF" >/dev/null 2>&1 || return 1
  if [ -n "$WG_USERSPACE_PID" ]; then
    kill -0 "$WG_USERSPACE_PID" 2>/dev/null || return 1
  fi
  return 0
}

# Prints the first host address of the tunnel's IPv4 network with its last
# octet set to 1, which is where ProtonVPN and most NAT-PMP providers run
# their NAT-PMP gateway.
wg_gateway() {
  local addr
  for addr in "${WG_ADDRESSES[@]}"; do
    addr="${addr%/*}"
    if is_ipv4 "$addr"; then
      printf '%s.1' "${addr%.*}"
      return 0
    fi
  done
  return 0
}

wg_down() {
  if ip link show dev "$WG_IF" >/dev/null 2>&1; then
    ip link del dev "$WG_IF"
  fi
  if [ -n "$WG_USERSPACE_PID" ] && kill -0 "$WG_USERSPACE_PID" 2>/dev/null; then
    kill -TERM "$WG_USERSPACE_PID"
    wait "$WG_USERSPACE_PID" 2>/dev/null
  fi
  log_info "wireguard: ${WG_IF} removed"
  return 0
}
