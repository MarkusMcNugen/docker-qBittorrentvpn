# shellcheck shell=bash
# The VPN as the supervisor sees it, independent of OpenVPN or WireGuard:
# choosing the kind, preparing the tun device, waiting for the first
# connection, health checks that restart a dead VPN process in place, DNS
# refresh, and shutdown.

VPN_KIND=none
VPN_HEALTH_DETAIL=""
WG_HEALTH_BY_HANDSHAKE=yes
TUN_DEV="${TUN_DEV:-/dev/net/tun}"

has_files() {
  local pattern="$1" skip="${2-}" f
  for f in $pattern; do
    [ -f "$f" ] || continue
    [ -n "$skip" ] && [ "${f##*/}" = "$skip" ] && continue
    return 0
  done
  return 1
}

vpn_select_kind() {
  local ovpn=no wg=no
  case "$CFG_VPN_TYPE" in
    openvpn | wireguard)
      VPN_KIND="$CFG_VPN_TYPE"
      return 0
      ;;
  esac
  if has_files "/config/wireguard/*.conf"; then wg=yes; fi
  if has_files "/config/openvpn/*.ovpn" || has_files "/config/openvpn/*.conf" credentials.conf; then ovpn=yes; fi
  if [ "$wg" = yes ] && [ "$ovpn" = yes ]; then
    die "both /config/openvpn and /config/wireguard hold configurations; set VPN_TYPE=openvpn or VPN_TYPE=wireguard"
  elif [ "$wg" = yes ]; then
    VPN_KIND=wireguard
  elif [ "$ovpn" = yes ]; then
    VPN_KIND=openvpn
  else
    mkdir -p /config/openvpn /config/wireguard
    die "no VPN configuration: put your provider's .ovpn file in /config/openvpn or its WireGuard .conf file in /config/wireguard, then restart"
  fi
  log_info "vpn: using ${VPN_KIND} (VPN_TYPE=auto)"
}

# Makes the tun device exist and gives it to the vpn group, so no other user
# in the container can open it. Under rootless Docker or Podman, or a daemon
# with userns-remap, the device belongs to a host user the container does not
# map and its group cannot change; it is then used as it is, provided the vpn
# user can open it.
vpn_prepare_tun() {
  local err
  if [ ! -c "$TUN_DEV" ]; then
    mkdir -p "${TUN_DEV%/*}"
    mknod -m 0660 "$TUN_DEV" c 10 200 ||
      die "${TUN_DEV} is missing and cannot be created: run the container with --device /dev/net/tun"
    log_info "vpn: created ${TUN_DEV}"
  fi
  if err=$(chgrp vpn "$TUN_DEV" 2>&1); then
    chmod 0660 "$TUN_DEV"
    return 0
  fi
  if setpriv --reuid=vpn --regid=vpn --init-groups -- test -r "$TUN_DEV" -a -w "$TUN_DEV"; then
    log_info "vpn: ${TUN_DEV} belongs to $(stat -c %U:%G "$TUN_DEV") outside this container's user namespace (${err#chgrp: }); using it as it is, mode $(stat -c %a "$TUN_DEV")"
    return 0
  fi
  die "vpn: the vpn user cannot open ${TUN_DEV} (owner $(stat -c %U:%G "$TUN_DEV"), mode $(stat -c %a "$TUN_DEV")) and its group cannot be changed (${err#chgrp: }); on the host, run chmod 0666 /dev/net/tun"
}

vpn_prepare() {
  case "$VPN_KIND" in
    openvpn) ovpn_prepare ;;
    wireguard)
      wg_prepare
      if ! awk 'tolower($1) == "persistentkeepalive" && $3 + 0 > 0 { ok = 1 } END { exit !ok }' "$WG_CONF"; then
        WG_HEALTH_BY_HANDSHAKE=no
        log_info "wireguard: no persistent keepalive, so the health check cannot judge the tunnel by handshake age; it checks the interface only"
      fi
      ;;
  esac
}

vpn_start() {
  case "$VPN_KIND" in
    openvpn)
      vpn_prepare_tun
      ovpn_start
      ;;
    wireguard)
      if [ "$CFG_WG_USERSPACE" != no ]; then vpn_prepare_tun; fi
      wg_up
      ;;
  esac
}

vpn_wait_connected() {
  local deadline state probe_at=0 target
  deadline=$(($(now) + CFG_CONNECT_TIMEOUT))
  while [ "$(now)" -lt "$deadline" ]; do
    case "$VPN_KIND" in
      openvpn)
        ovpn_alive || die "openvpn: exited before connecting; its log lines above say why"
        state=$(ovpn_state)
        if [ "$state" = CONNECTED ]; then
          log_info "openvpn: connected, tunnel address $(ovpn_state_line local), gateway $(ovpn_gateway)"
          ovpn_route_ipv6
          return 0
        fi
        ;;
      wireguard)
        if [ "$(wg_handshake_age)" != never ]; then
          log_info "wireguard: handshake complete"
          return 0
        fi
        if [ "$(now)" -ge "$probe_at" ]; then
          target=$(wg_gateway)
          ping -c 1 -W 1 -I "$WG_IF" "${target:-1.1.1.1}" >/dev/null 2>&1 || log_debug "wireguard: handshake probe sent"
          probe_at=$(($(now) + 5))
        fi
        ;;
    esac
    sleep 1
  done
  if [ "$VPN_KIND" = openvpn ]; then
    log_error "openvpn: last management interface reply: $(state_read openvpn-mgmt | tr -d '\r' | tr '\n' ' ')"
  fi
  die "vpn: no connection within ${CFG_CONNECT_TIMEOUT} s (VPN_CONNECT_TIMEOUT)"
}

# True when the tunnel is up. Sets VPN_HEALTH_DETAIL either way, and
# restarts a VPN process that has exited.
vpn_healthy() {
  local state age
  case "$VPN_KIND" in
    openvpn)
      if ! ovpn_alive; then
        VPN_HEALTH_DETAIL="openvpn process exited; restarting it"
        log_warn "vpn: ${VPN_HEALTH_DETAIL}"
        ovpn_start
        return 1
      fi
      state=$(ovpn_state)
      VPN_HEALTH_DETAIL="openvpn ${state}"
      [ "$state" = CONNECTED ] || return 1
      ovpn_route_ipv6
      ;;
    wireguard)
      if ! wg_alive; then
        VPN_HEALTH_DETAIL="${WG_DOWN_REASON}; recreating it"
        log_warn "vpn: ${VPN_HEALTH_DETAIL}"
        wg_down
        wg_up
        return 1
      fi
      age=$(wg_handshake_age)
      VPN_HEALTH_DETAIL="wireguard handshake age ${age}"
      [ "$WG_HEALTH_BY_HANDSHAKE" = no ] && return 0
      [ "$age" != never ] && [ "$age" -le "$CFG_WG_HANDSHAKE_MAX_AGE" ]
      ;;
    *)
      VPN_HEALTH_DETAIL="vpn disabled"
      return 0
      ;;
  esac
}

vpn_refresh_dns() {
  if [ "$VPN_KIND" = openvpn ]; then ovpn_refresh_dns; fi
  dns_apply
}

vpn_stop() {
  case "$VPN_KIND" in
    openvpn) ovpn_stop ;;
    wireguard) wg_down ;;
  esac
}
