# shellcheck shell=bash
# OpenVPN: picks the configuration, pins its remotes to resolved addresses,
# writes a sanitized copy the unprivileged vpn user can read, and runs
# OpenVPN as that user with only CAP_NET_ADMIN.

OVPN_SRC=/config/openvpn
OVPN_DIR="" # private copy of OVPN_SRC owned by the vpn user
OVPN_STATE="" # state files written by the hook, and the management socket
OVPN_CONF=""
OVPN_PID=""
OVPN_AUTH_FILE="" # username/password file OpenVPN reads, inside OVPN_DIR
OVPN_IS_PIA=no
OVPN_DEV_TYPE=tun

# Prints the configuration file to use, or exits when there is none.
ovpn_pick_config() {
  local -a found=()
  local f
  if [ -n "$CFG_VPN_CONFIG" ]; then
    case "$CFG_VPN_CONFIG" in
      /*) f="$CFG_VPN_CONFIG" ;;
      *) f="$OVPN_SRC/$CFG_VPN_CONFIG" ;;
    esac
    [ -f "$f" ] || die "VPN_CONFIG ${CFG_VPN_CONFIG}: no such file"
    printf '%s' "$f"
    return 0
  fi
  while IFS= read -r -d '' f; do
    case "${f##*/}" in
      credentials.conf | .*) continue ;;
    esac
    if awk '{ sub(/\r$/, "") } /^[ \t]*(--)?(remote|client)([ \t]|$)/ { found = 1; exit } END { exit !found }' "$f"; then
      found+=("$f")
    fi
  done < <(find "$OVPN_SRC" -maxdepth 1 -type f \( -name '*.ovpn' -o -name '*.conf' \) -print0 | sort -z)
  [ "${#found[@]}" -gt 0 ] || die "no OpenVPN configuration in ${OVPN_SRC}: add your provider's .ovpn file there"
  if [ "${#found[@]}" -gt 1 ]; then
    if [ "$CFG_VPN_CONFIG_RANDOM" = yes ]; then
      f="${found[RANDOM % ${#found[@]}]}"
      log_info "openvpn: ${#found[@]} configurations found; picked ${f##*/} at random"
    else
      f="${found[0]}"
      log_info "openvpn: ${#found[@]} configurations found; using ${f##*/} (set VPN_CONFIG to choose, or VPN_CONFIG_RANDOM=yes)"
    fi
  else
    f="${found[0]}"
  fi
  printf '%s' "$f"
}

# Maps an OpenVPN proto to "<firewall proto> <proto for the pinned remote>".
ovpn_proto() {
  case "${1,,}" in
    udp | udp4) printf 'udp udp4' ;;
    udp6) log_warn "openvpn: proto udp6 used over IPv4, the only endpoint family the firewall pins"; printf 'udp udp4' ;;
    tcp | tcp-client | tcp4 | tcp4-client) printf 'tcp tcp4-client' ;;
    tcp6 | tcp6-client) log_warn "openvpn: proto ${1} used over IPv4, the only endpoint family the firewall pins"; printf 'tcp tcp4-client' ;;
    *) die "openvpn: unsupported proto '${1}'" ;;
  esac
}

ovpn_prepare() {
  local src facts line host port proto fw_proto ovpn_proto_name ip pinned auth_arg="" pair
  local -a remotes=()
  src=$(ovpn_pick_config) || exit 1
  log_info "openvpn: configuration ${src}"

  facts=$(awk -v MODE=parse -f "$QBTVPN_LIB/openvpn-config.awk" <"$src")
  if grep -qx 'connection-block' <<<"$facts"; then
    die "openvpn: <connection> blocks are not supported; write each server as a remote line"
  fi
  if grep -qx 'secret' <<<"$facts"; then
    die "openvpn: static-key (secret) configurations are insecure and OpenVPN 2.7 refuses them"
  fi
  if grep -qx 'pia' <<<"$facts"; then OVPN_IS_PIA=yes; fi
  case "$(awk '$1 == "dev" { print $2; exit }' <<<"$facts")" in
    tap*) OVPN_DEV_TYPE=tap ;;
    *) OVPN_DEV_TYPE=tun ;;
  esac
  FW_TUN="${OVPN_DEV_TYPE}0"
  auth_arg=$(awk '$1 == "auth-user-pass" { print $2; exit }' <<<"$facts")
  if [ "$auth_arg" = - ] && [ -z "$CFG_VPN_USERNAME" ]; then
    die "openvpn: the configuration requires a username and password; set VPN_USERNAME and VPN_PASSWORD"
  fi

  OVPN_DIR="$QBTVPN_RUN/openvpn/config"
  OVPN_STATE="$QBTVPN_RUN/openvpn/state"
  mkdir -p "$OVPN_DIR" "$OVPN_STATE"
  cp -R "$OVPN_SRC/." "$OVPN_DIR/"

  pinned="$QBTVPN_RUN/openvpn/remotes"
  : >"$pinned"
  FW_ENDPOINTS=()
  while read -r line; do
    read -r _ host port proto <<<"$line"
    remotes+=("$host")
    pair=$(ovpn_proto "$proto") || exit 1
    read -r fw_proto ovpn_proto_name <<<"$pair"
    is_port "$port" || die "openvpn: remote ${host} has an invalid port '${port}'"
    local resolved
    resolved=$(resolve_ipv4 "$host") || die "openvpn: could not resolve ${host}"
    while read -r ip; do
      printf 'remote %s %s %s\n' "$ip" "$port" "$ovpn_proto_name" >>"$pinned"
      FW_ENDPOINTS+=("$ip $port $fw_proto")
    done <<<"$resolved"
    log_info "openvpn: remote ${host} ${port}/${fw_proto} -> $(tr '\n' ' ' <<<"$resolved")"
  done < <(awk '$1 == "remote"' <<<"$facts")
  [ "${#FW_ENDPOINTS[@]}" -gt 0 ] || die "openvpn: the configuration has no remote line"

  OVPN_CONF="$QBTVPN_RUN/openvpn/client.conf"
  awk -v MODE=sanitize -v REMOTES="$pinned" -v SRCDIR="$OVPN_SRC" -v DSTDIR="$OVPN_DIR" \
    -v DROP_AUTH="$([ -n "$CFG_VPN_USERNAME" ] && printf 1)" \
    -f "$QBTVPN_LIB/openvpn-config.awk" <"$src" >"$OVPN_CONF" 2> >(while read -r l; do log_info "$l"; done)

  OVPN_AUTH_FILE=""
  if [ -n "$CFG_VPN_USERNAME" ]; then
    OVPN_AUTH_FILE="$OVPN_DIR/.qbtvpn-credentials"
    printf '%s\n%s\n' "$CFG_VPN_USERNAME" "$CFG_VPN_PASSWORD" >"$OVPN_AUTH_FILE"
  elif [ -n "$auth_arg" ] && [ "$auth_arg" != - ]; then
    case "$auth_arg" in
      "$OVPN_SRC"/*) OVPN_AUTH_FILE="$OVPN_DIR/${auth_arg#"$OVPN_SRC"/}" ;;
      /*) OVPN_AUTH_FILE="$auth_arg" ;;
      *) OVPN_AUTH_FILE="$OVPN_DIR/$auth_arg" ;;
    esac
    [ -r "$OVPN_AUTH_FILE" ] || die "openvpn: auth-user-pass names ${auth_arg}, which does not exist; set VPN_USERNAME and VPN_PASSWORD or add the file"
  fi
  chown -R vpn:vpn "$QBTVPN_RUN/openvpn"
  chmod -R u=rwX,go= "$QBTVPN_RUN/openvpn"
}

ovpn_start() {
  local -a args extra=()
  args=(
    --config "$OVPN_CONF"
    --cd "$OVPN_DIR"
    --dev "$FW_TUN"
    --dev-type "$OVPN_DEV_TYPE"
    --script-security 2
    --up "$QBTVPN_LIB/openvpn-hook"
    --up-restart
    --route-up "$QBTVPN_LIB/openvpn-hook"
    --down "$QBTVPN_LIB/openvpn-hook"
    --dns-updown disable
    --setenv QBTVPN_OVPN_STATE "$OVPN_STATE"
    --management "$OVPN_STATE/mgmt.sock" unix
    --management-client-user root
    --auth-nocache
    --redirect-gateway def1
    --pull-filter ignore redirect-gateway
    --pull-filter ignore redirect-private
    --verb 3
  )
  if [ -n "$CFG_VPN_USERNAME" ]; then
    args+=(--auth-user-pass "$OVPN_DIR/.qbtvpn-credentials")
  fi
  if ipv6_disabled; then
    args+=(--pull-filter ignore ifconfig-ipv6 --pull-filter ignore route-ipv6)
    log_info "openvpn: IPv6 is disabled in this container; ignoring the server's IPv6 address and routes"
  fi
  if [ "$OVPN_IS_PIA" = yes ] && [ "$CFG_PF_MODE" != off ]; then
    args+=(--tls-verify "$QBTVPN_LIB/openvpn-hook")
  fi
  if [ -n "$CFG_VPN_OPTIONS" ]; then
    read -r -a extra <<<"$CFG_VPN_OPTIONS"
    args+=("${extra[@]}")
    log_info "openvpn: extra options from VPN_OPTIONS: ${CFG_VPN_OPTIONS}"
  fi
  env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    setpriv --reuid=vpn --regid=vpn --init-groups \
    --inh-caps=-all,+net_admin --ambient-caps=-all,+net_admin --bounding-set=-all,+net_admin \
    --no-new-privs -- openvpn "${args[@]}" \
    > >(awk '!/MANAGEMENT: (Client (connected|disconnected)|CMD .state.)/ { print; fflush() }') 2>&1 &
  OVPN_PID=$!
  # Disowned, so bash prints no job notice of its own when a signal ends
  # OpenVPN; the supervisor logs the exit and restarts it. Bash still reaps it,
  # but keeps no exit status, so ovpn_alive and ovpn_stop poll the pid.
  disown "$OVPN_PID"
  log_info "openvpn: started as user vpn (pid ${OVPN_PID})"
}

# ovpn_mgmt SOCKET COMMAND: prints OpenVPN's reply to one management command.
# The command is sent alone and followed by end-of-file, because OpenVPN
# discards the replies to commands that arrive in the same read as `quit`.
ovpn_mgmt() {
  printf '%s\n' "$2" | timeout 5 nc -U -N -w 3 "$1"
}

# Prints OpenVPN's state name from its management interface (CONNECTED,
# RECONNECTING, ...), NOSOCKET before the socket exists, or UNKNOWN. The raw
# reply, or why there is none, goes to the openvpn-mgmt state file.
ovpn_state() {
  local sock="$OVPN_STATE/mgmt.sock" out
  if [ ! -S "$sock" ]; then
    state_write openvpn-mgmt "no management socket at ${sock}"
    printf 'NOSOCKET'
    return 0
  fi
  if ! out=$(ovpn_mgmt "$sock" state 2>&1); then
    state_write openvpn-mgmt "query failed: ${out}"
    printf 'UNKNOWN'
    return 0
  fi
  state_write openvpn-mgmt "$out"
  awk -F, '/^[0-9]+,[A-Z_]+,/ { print $2; found = 1; exit } END { if (!found) print "UNKNOWN" }' <<<"$out"
}

ovpn_alive() { [ -n "$OVPN_PID" ] && kill -0 "$OVPN_PID" 2>/dev/null; }

# ovpn_route_ipv6: when the tunnel has a global IPv6 address, routes the
# ranges OpenVPN's own `redirect-gateway ipv6` uses (::/3, 2000::/4, 3000::/4,
# fc00::/7) into it. Adds only missing routes and logs only those.
ovpn_route_ipv6() {
  local net
  local -a added=()
  [ -n "$(ip -6 -o addr show dev "$FW_TUN" scope global)" ] || return 0
  for net in ::/3 2000::/4 3000::/4 fc00::/7; do
    if [ -z "$(ip -6 route show "$net" dev "$FW_TUN")" ]; then
      ip -6 route replace "$net" dev "$FW_TUN" && added+=("$net")
    fi
  done
  if [ "${#added[@]}" -gt 0 ]; then
    log_info "openvpn: IPv6 ${added[*]} routed into ${FW_TUN}"
  fi
  return 0
}

# Copies the DNS servers OpenVPN reported into the shared vpn-dns state.
ovpn_refresh_dns() {
  if [ -r "$OVPN_STATE/dns" ]; then
    state_write vpn-dns "$(awk 'NF' "$OVPN_STATE/dns")"
  fi
}

# Prints the first non-empty line of a hook state file, or nothing before the hook wrote it.
ovpn_state_line() {
  local f="$OVPN_STATE/$1"
  if [ -r "$f" ]; then
    awk 'NF { print; exit }' "$f"
  fi
  return 0
}

ovpn_gateway() { ovpn_state_line gateway; }

ovpn_server_cn() { ovpn_state_line server-cn; }

ovpn_stop() {
  if ovpn_alive; then
    kill -TERM "$OVPN_PID"
    for _ in $(seq 1 10); do
      ovpn_alive || break
      sleep 1
    done
    if ovpn_alive; then
      log_warn "openvpn: still running after 10 s; sending SIGKILL"
      kill -KILL "$OVPN_PID"
      for _ in $(seq 1 20); do
        ovpn_alive || break
        sleep 0.1
      done
    fi
    log_info "openvpn: stopped"
  fi
  return 0
}
