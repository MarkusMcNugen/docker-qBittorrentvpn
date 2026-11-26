# shellcheck shell=bash
# Port forwarding through the VPN provider. A background loop keeps the
# mapping alive and writes the forwarded port to QBTVPN_RUN/pf/port; the
# supervisor opens that port on the tunnel and gives it to qBittorrent.
#
#   protonvpn  NAT-PMP to the tunnel gateway the way ProtonVPN documents it
#              (public 1, private 0; the gateway assigns the port), renewed
#              every NATPMP_RENEW_INTERVAL seconds
#   natpmp     NAT-PMP mapping requests for qBittorrent's listen port
#   pia        Private Internet Access: token, signed port, bindPort every
#              PIA_BIND_INTERVAL seconds; the signature is kept in
#              /config/openvpn/.pia-portforward.json for reuse across restarts
#   auto       pia for PIA configurations, otherwise one ProtonVPN-style probe

PF_DIR=""
PF_PID=""
PF_MODE=off
# shellcheck disable=SC2034  # set and read by the entrypoint
PF_APPLIED=""
PF_PIA_CACHE=/config/openvpn/.pia-portforward.json
PF_MAPPED=""
PF_MAP_ERROR=""

pf_gateway() {
  if [ -n "$CFG_PF_GATEWAY" ]; then
    printf '%s' "$CFG_PF_GATEWAY"
  elif [ "$VPN_KIND" = openvpn ]; then
    ovpn_gateway
  else
    wg_gateway
  fi
}

# pf_natpmp_map `GATEWAY` `PROTO` `PUBLIC` `PRIVATE`: sends the gateway a
# mapping request. Returns 0 with `PF_MAPPED` set to the public port it
# mapped, or 1 with `PF_MAP_ERROR` set to natpmpc's reason. ProtonVPN takes
# `PUBLIC=1` `PRIVATE=0` and assigns a port of its own; other gateways map
# the ports requested.
pf_natpmp_map() {
  local gw="$1" proto="$2" public="$3" private="$4" wait=15 out rc=0
  PF_MAPPED=""
  PF_MAP_ERROR=""
  out=$(timeout "$wait" natpmpc -g "$gw" -a "$public" "$private" "$proto" "$CFG_NATPMP_LIFETIME" 2>&1) || rc=$?
  PF_MAPPED=$(awk '/Mapped public port/ { print $4; exit }' <<<"$out")
  [ -z "$PF_MAPPED" ] || return 0
  log_debug "nat-pmp: natpmpc ${proto} via ${gw} exited ${rc}: $(tr '\n' ' ' <<<"$out")"
  if [ "$rc" -eq 124 ]; then
    PF_MAP_ERROR="no reply within ${wait} s"
  else
    PF_MAP_ERROR=$(awk '/failed : / { r = substr($0, index($0, "failed : ") + 9); e = "" }
      /^ *errno=/ { e = $0; sub(/^ +/, "", e) }
      /\(FAILED\)/ && r == "" { f = $0 }
      END { if (r == "") r = f; if (e != "") r = r " (" e ")"; print r }' <<<"$out")
    [ -n "$PF_MAP_ERROR" ] || PF_MAP_ERROR="natpmpc exited with status ${rc}"
  fi
  return 1
}

# pf_natpmp_reason `UDP_ERROR` `TCP_ERROR`: one line naming what failed.
pf_natpmp_reason() {
  if [ "$1" = "$2" ]; then
    printf '%s' "$1"
  elif [ -z "$1" ]; then
    printf 'TCP: %s' "$2"
  elif [ -z "$2" ]; then
    printf 'UDP: %s' "$1"
  else
    printf 'UDP: %s; TCP: %s' "$1" "$2"
  fi
}

# Prints the port the generic NAT-PMP mode requests from the gateway.
pf_natpmp_wanted_port() {
  local port
  port=$(pf_current_port)
  [ -n "$port" ] || port="$CFG_INCOMING_PORT"
  [ -n "$port" ] || port=$(qbt_ini_get BitTorrent 'Session\Port')
  [ -n "$port" ] || port=8999
  printf '%s' "$port"
}

pf_resolve_mode() {
  local gw
  case "$CFG_PF_MODE" in
    off) PF_MODE=off ;;
    natpmp) PF_MODE=natpmp ;;
    protonvpn) PF_MODE=protonvpn ;;
    pia) PF_MODE=pia ;;
    auto)
      if { [ "$VPN_KIND" = openvpn ] && [ "$OVPN_IS_PIA" = yes ]; } || [ -n "$CFG_PIA_PF_HOSTNAME" ]; then
        PF_MODE=pia
      else
        gw=$(pf_gateway)
        if [ -n "$gw" ] && pf_natpmp_map "$gw" udp 1 0; then
          PF_MODE=protonvpn
        else
          PF_MODE=off
          log_info "port forwarding: no NAT-PMP mapping from ${gw:-the tunnel gateway}${PF_MAP_ERROR:+ (${PF_MAP_ERROR})}; none in use (set VPN_PORT_FORWARDING or INCOMING_PORT for a fixed forwarded port)"
        fi
      fi
      ;;
  esac
}

pf_publish() {
  printf '%s\n' "$1" >"$PF_DIR/port.tmp"
  mv -f "$PF_DIR/port.tmp" "$PF_DIR/port"
}

# pf_natpmp_loop `GATEWAY` `STYLE`: style protonvpn requests 1/0 and takes the
# assigned port; style natpmp requests the wanted port for both sides.
pf_natpmp_loop() {
  local gw="$1" style="$2" udp tcp udp_err tcp_err reason said="" port last="" public private
  while :; do
    if [ "$style" = protonvpn ]; then
      public=1
      private=0
    else
      public=$(pf_natpmp_wanted_port)
      private="$public"
    fi
    udp=""
    tcp=""
    udp_err=""
    tcp_err=""
    if pf_natpmp_map "$gw" udp "$public" "$private"; then udp="$PF_MAPPED"; else udp_err="$PF_MAP_ERROR"; fi
    if pf_natpmp_map "$gw" tcp "$public" "$private"; then tcp="$PF_MAPPED"; else tcp_err="$PF_MAP_ERROR"; fi
    if [ -n "$udp" ] && [ -n "$tcp" ]; then
      said=""
      port="$tcp"
      if [ "$udp" != "$tcp" ]; then
        log_warn "nat-pmp: UDP mapped to ${udp} and TCP to ${tcp}; qBittorrent uses one port, so TCP ${tcp} is used"
      fi
      if [ "$port" != "$last" ]; then
        log_info "nat-pmp: forwarded port ${port} from ${gw}"
        pf_publish "$port"
        last="$port"
      fi
      sleep "$CFG_NATPMP_INTERVAL"
    else
      reason=$(pf_natpmp_reason "$udp_err" "$tcp_err")
      if [ "$reason" != "$said" ]; then
        log_warn "nat-pmp: no mapping from ${gw} (${reason}); retrying every 10 s, logged again only when the reason changes"
        said="$reason"
      fi
      sleep 10
    fi
  done
}

# Prints a PIA API token for the VPN credentials.
pia_token() {
  local user="$CFG_VPN_USERNAME" pass="$CFG_VPN_PASSWORD" out
  if [ -z "$user" ] && [ -r "${OVPN_AUTH_FILE:-}" ]; then
    user=$(awk 'NR == 1' "$OVPN_AUTH_FILE")
    pass=$(awk 'NR == 2' "$OVPN_AUTH_FILE")
  fi
  if [ -z "$user" ] || [ -z "$pass" ]; then
    log_error "pia: port forwarding needs the PIA username and password (VPN_USERNAME and VPN_PASSWORD)"
    return 1
  fi
  if ! out=$(curl -fsS --max-time 20 -X POST https://www.privateinternetaccess.com/api/client/v2/token \
    --form-string "username=${user}" --form-string "password=${pass}" 2>&1); then
    log_warn "pia: token request failed: ${out}"
    return 1
  fi
  jq -er '.token' <<<"$out"
}

# pia_expiry `PAYLOAD`: prints the `expires_at` that PIA's base64 payload
# carries, or nothing when it carries none.
pia_expiry() {
  jq -rn --arg p "$1" '$p | @base64d | fromjson | .expires_at // empty'
}

pia_call() {
  local host="$1" gw="$2" path="$3"
  shift 3
  curl -fsS --max-time 20 --connect-to "${host}::${gw}:" --cacert "$QBTVPN_SHARE/pia-ca.rsa.4096.crt" \
    -G "$@" "https://${host}:19999/${path}"
}

pf_pia_loop() {
  local host gw token sig status payload signature port expires bind now_iso cached
  host="${CFG_PIA_PF_HOSTNAME:-$(ovpn_server_cn)}"
  gw="${CFG_PIA_PF_GATEWAY:-$(pf_gateway)}"
  if [ -z "$host" ] || [ -z "$gw" ]; then
    log_error "pia: unknown server name (${host:-none}) or gateway (${gw:-none}); set PIA_PF_HOSTNAME and PIA_PF_GATEWAY"
    return 1
  fi
  log_info "pia: port forwarding with server ${host} via ${gw}"
  while :; do
    payload=""
    signature=""
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%S)
    cached=""
    if [ -s "$PF_PIA_CACHE" ] && ! cached=$(jq -c --arg h "$host" \
      'select(.host == $h and (.payload | type) == "string" and (.signature | type) == "string")' "$PF_PIA_CACHE" 2>&1); then
      log_warn "pia: ignoring ${PF_PIA_CACHE}: ${cached}"
      cached=""
    fi
    if [ -n "$cached" ]; then
      expires=$(pia_expiry "$(jq -r '.payload' <<<"$cached")")
      if [ -z "$expires" ] || [[ "${expires:0:19}" > "$now_iso" ]]; then
        payload=$(jq -r '.payload' <<<"$cached")
        signature=$(jq -r '.signature' <<<"$cached")
        log_info "pia: reusing the signed port from ${PF_PIA_CACHE}${expires:+, valid until ${expires}}"
      fi
    fi
    if [ -z "$payload" ]; then
      if ! token=$(pia_token); then
        sleep 60
        continue
      fi
      if ! sig=$(pia_call "$host" "$gw" getSignature --data-urlencode "token=${token}" 2>&1); then
        log_warn "pia: getSignature failed (does this server allow port forwarding?): ${sig}"
        sleep 60
        continue
      fi
      status=$(jq -r '.status' <<<"$sig")
      if [ "$status" != OK ]; then
        log_warn "pia: getSignature returned status ${status}: ${sig}"
        sleep 60
        continue
      fi
      payload=$(jq -r '.payload' <<<"$sig")
      signature=$(jq -r '.signature' <<<"$sig")
      (
        umask 077
        jq -n --arg h "$host" --arg p "$payload" --arg s "$signature" '{host: $h, payload: $p, signature: $s}' >"$PF_PIA_CACHE"
      )
    fi
    port=$(jq -rn --arg p "$payload" '$p | @base64d | fromjson | .port')
    expires=$(pia_expiry "$payload")
    is_port "$port" || { log_warn "pia: signature carried no valid port"; sleep 60; continue; }
    while :; do
      if ! bind=$(pia_call "$host" "$gw" bindPort --data-urlencode "payload=${payload}" --data-urlencode "signature=${signature}" 2>&1) \
        || [ "$(jq -r '.status' <<<"$bind")" != OK ]; then
        log_warn "pia: bindPort failed: ${bind}; requesting a new signature"
        printf '{}\n' >"$PF_PIA_CACHE"
        break
      fi
      if [ "$(state_read pf-port-logged)" != "$port" ]; then
        log_info "pia: forwarded port ${port}${expires:+, signature valid until ${expires}}"
        state_write pf-port-logged "$port"
      fi
      pf_publish "$port"
      sleep "$CFG_PIA_BIND_INTERVAL"
    done
    sleep 10
  done
}

# Starts the loop for the resolved mode in the background.
pf_start() {
  PF_DIR="$QBTVPN_RUN/pf"
  mkdir -p "$PF_DIR"
  pf_resolve_mode
  case "$PF_MODE" in
    off) return 0 ;;
    natpmp | protonvpn)
      local gw
      gw=$(pf_gateway)
      [ -n "$gw" ] || { log_error "nat-pmp: no gateway known; set VPN_PORT_FORWARDING_GATEWAY"; return 0; }
      (trap - ERR; set +e; pf_natpmp_loop "$gw" "$PF_MODE") &
      ;;
    pia)
      (trap - ERR; set +e; pf_pia_loop) &
      ;;
  esac
  PF_PID=$!
  log_info "port forwarding: ${PF_MODE} loop started (pid ${PF_PID})"
}

# Waits up to VPN_PORT_FORWARDING_WAIT seconds for the first forwarded port
# and prints it, or prints nothing.
pf_wait_first_port() {
  local i
  [ "$PF_MODE" != off ] || return 0
  for ((i = 0; i < CFG_PF_WAIT; i++)); do
    if [ -s "$PF_DIR/port" ]; then
      awk 'NR == 1' "$PF_DIR/port"
      return 0
    fi
    sleep 1
  done
  log_warn "port forwarding: no port within ${CFG_PF_WAIT} s; qBittorrent starts on its configured port and switches when one arrives"
  return 0
}

pf_current_port() {
  if [ -n "$PF_DIR" ] && [ -s "$PF_DIR/port" ]; then
    awk 'NR == 1' "$PF_DIR/port"
  fi
  return 0
}

# Stops the port forwarding loop, then the command it was running. The loop
# goes first: a shell that outlives its killed child reports the kill in the log.
pf_stop() {
  local kids
  if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
    kids=$(pgrep -P "$PF_PID" | tr '\n' ' ') || kids=""
    kill -TERM "$PF_PID"
    if [ -n "$kids" ]; then
      # shellcheck disable=SC2086  # one pid per word; a child may have exited already
      kill -TERM $kids 2>/dev/null || :
    fi
    wait "$PF_PID" 2>/dev/null
  fi
  return 0
}
