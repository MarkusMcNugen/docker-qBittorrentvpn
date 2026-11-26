# shellcheck shell=bash
# shellcheck disable=SC2034  # variables read by the library functions under test
# portforward.sh: pf_natpmp_map driving the image's natpmpc against the
# end-to-end NAT-PMP responder on loopback, and pf_pia_loop against PIA's
# port API served by a stand-in curl. The getSignature and bindPort replies in
# tests/fixtures/pia are the examples in the README of PIA's manual-connections
# scripts (https://github.com/pia-foss/manual-connections);
# getSignature-expires_at.json carries that README's decoded payload example
# encoded again, and token.json has the reply shape its get_token.sh reads.

# shellcheck source=/dev/null
. "$QBTVPN_LIB/portforward.sh"

CFG_NATPMP_LIFETIME=60
RESPONDER="${FIXTURES%/fixtures}/e2e/server/natpmp-responder.py"

# natpmp_responder PUBLIC_IP: serves NAT-PMP on 127.0.0.1:5351 until the test
# exits, reporting PUBLIC_IP and mapping every request to port 40123.
natpmp_responder() {
  local pid log="$QBTVPN_RUN/responder.log"
  if ! command -v python3 >/dev/null; then
    echo "python3 is missing; this test needs an image built with INSTALL_PYTHON=yes"
    return 1
  fi
  python3 "$RESPONDER" 127.0.0.1 "$1" 40123 >"$log" 2>&1 &
  pid=$!
  # shellcheck disable=SC2064  # the pid is fixed when the trap is set
  trap "kill ${pid} 2>/dev/null" EXIT
  until grep -q '^natpmp: listening' "$log"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      cat "$log"
      return 1
    fi
    sleep 0.1
  done
}

test_natpmp_map_reports_the_mapped_port() {
  natpmp_responder 1.2.3.4
  pf_natpmp_map 127.0.0.1 udp 1 0 || { echo "no UDP mapping: ${PF_MAP_ERROR}"; return 1; }
  assert_eq 40123 "$PF_MAPPED" "UDP mapping"
  pf_natpmp_map 127.0.0.1 tcp 8999 8999 || { echo "no TCP mapping: ${PF_MAP_ERROR}"; return 1; }
  assert_eq 40123 "$PF_MAPPED" "TCP mapping"
  assert_contains "map tcp public 8999 private 8999 lifetime 60 -> 40123" "$(cat "$QBTVPN_RUN/responder.log")"
}

test_natpmp_map_names_a_refused_public_address() {
  natpmp_responder 172.31.251.2
  if pf_natpmp_map 127.0.0.1 udp 1 0; then
    echo "mapped ${PF_MAPPED} although the gateway reported a private public address"
    return 1
  fi
  assert_eq "invalid Public IP address 172.31.251.2" "$PF_MAP_ERROR"
}

test_natpmp_map_names_a_gateway_without_nat_pmp() {
  if pf_natpmp_map 127.0.0.1 udp 1 0; then
    echo "mapped ${PF_MAPPED} with nothing listening on 5351"
    return 1
  fi
  assert_eq "the gateway does not support nat-pmp (errno=111 'Connection refused')" "$PF_MAP_ERROR"
}

# pia_setup `SIGNATURE_FIXTURE`: points pf_pia_loop at a stand-in curl that
# logs each call to curl.log and prints the fixture for the URL it is given.
pia_setup() {
  local bin="$QBTVPN_RUN/bin"
  mkdir -p "$bin" "$QBTVPN_RUN/pf"
  PF_DIR="$QBTVPN_RUN/pf"
  PF_PIA_CACHE="$QBTVPN_RUN/pia-portforward.json"
  PIA_SIGNATURE="$FIXTURES/pia/$1"
  PIA_BIND_FAILS=no
  export PIA_SIGNATURE PIA_BIND_FAILS
  CFG_VPN_USERNAME=p0123456
  CFG_VPN_PASSWORD=xxxxxxxx
  CFG_PIA_PF_HOSTNAME=london420
  CFG_PIA_PF_GATEWAY=10.4.128.1
  CFG_PIA_BIND_INTERVAL=900
  cat >"$bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$QBTVPN_RUN/curl.log"
url=""
for a; do
  case "$a" in https://*) url="$a" ;; esac
done
case "$url" in
  https://www.privateinternetaccess.com/api/client/v2/token) cat "$FIXTURES/pia/token.json" ;;
  */getSignature) cat "$PIA_SIGNATURE" ;;
  */bindPort)
    if [ "$PIA_BIND_FAILS" = yes ]; then
      echo "curl: (22) The requested URL returned error: 403" >&2
      exit 22
    fi
    cat "$FIXTURES/pia/bindPort.json"
    ;;
  *)
    echo "curl stand-in: unexpected URL ${url}" >&2
    exit 2
    ;;
esac
EOF
  chmod 0755 "$bin/curl"
  PATH="$bin:$PATH"
}

# pia_run [`NOW`]: runs pf_pia_loop until its first sleep, with its log in
# pia.log; `NOW` (YYYY-MM-DDTHH:MM:SS) is the time the loop reads.
pia_run() {
  local now="${1:-}"
  : >"$QBTVPN_RUN/curl.log"
  (
    # shellcheck disable=SC2329  # called by pf_pia_loop
    sleep() { exit 0; }
    if [ -n "$now" ]; then
      # shellcheck disable=SC2329  # called by pf_pia_loop
      date() { if [ "$*" = "-u +%Y-%m-%dT%H:%M:%S" ]; then printf '%s\n' "$now"; else command date "$@"; fi; }
    fi
    pf_pia_loop
  ) 2>"$QBTVPN_RUN/pia.log"
}

test_pia_binds_the_port_from_pias_published_example() {
  local calls log
  pia_setup getSignature.json
  pia_run
  calls=$(cat "$QBTVPN_RUN/curl.log")
  log=$(cat "$QBTVPN_RUN/pia.log")
  assert_eq 47047 "$(cat "$PF_DIR/port")" "published port"
  assert_line_order "$calls" "api/client/v2/token" "getSignature"
  assert_line_order "$calls" "getSignature" "bindPort"
  assert_contains "--data-urlencode token=xxxxxxxxx" "$calls"
  assert_contains "--connect-to london420::10.4.128.1:" "$calls"
  assert_contains "pia: forwarded port 47047" "$log"
  assert_not_contains "valid until" "$log"
  assert_eq london420 "$(jq -r .host "$PF_PIA_CACHE")" "cached host"
  assert_eq "$(jq -r .payload "$FIXTURES/pia/getSignature.json")" "$(jq -r .payload "$PF_PIA_CACHE")" "cached payload"
}

test_pia_reuses_a_cached_signature_until_it_expires() {
  pia_setup getSignature-expires_at.json
  pia_run 2020-05-01T00:00:00
  pia_run 2020-05-01T00:00:00
  assert_not_contains "getSignature" "$(cat "$QBTVPN_RUN/curl.log")"
  assert_not_contains "api/client/v2/token" "$(cat "$QBTVPN_RUN/curl.log")"
  assert_contains "bindPort" "$(cat "$QBTVPN_RUN/curl.log")"
  assert_contains "reusing the signed port from ${PF_PIA_CACHE}, valid until 2020-06-30T22:33:44.114369906Z" "$(cat "$QBTVPN_RUN/pia.log")"
  assert_eq 47047 "$(cat "$PF_DIR/port")" "published port"
}

test_pia_requests_a_new_signature_once_the_cached_one_expires() {
  pia_setup getSignature-expires_at.json
  pia_run 2020-05-01T00:00:00
  pia_run 2020-07-01T00:00:00
  assert_line_order "$(cat "$QBTVPN_RUN/curl.log")" "getSignature" "bindPort"
  assert_not_contains "reusing" "$(cat "$QBTVPN_RUN/pia.log")"
}

test_pia_reuses_a_cached_payload_that_states_no_expiry() {
  pia_setup getSignature.json
  pia_run
  pia_run
  assert_not_contains "getSignature" "$(cat "$QBTVPN_RUN/curl.log")"
  assert_contains "reusing the signed port from ${PF_PIA_CACHE}" "$(cat "$QBTVPN_RUN/pia.log")"
}

test_pia_bind_failure_drops_the_cached_signature() {
  pia_setup getSignature-expires_at.json
  PIA_BIND_FAILS=yes
  pia_run 2020-05-01T00:00:00
  assert_contains "pia: bindPort failed: curl: (22) The requested URL returned error: 403; requesting a new signature" "$(cat "$QBTVPN_RUN/pia.log")"
  assert_eq '{}' "$(cat "$PF_PIA_CACHE")" "cache after a failed bind"
  if [ -e "$PF_DIR/port" ]; then
    echo "a port was published although bindPort failed"
    return 1
  fi
}

test_pia_ignores_an_unreadable_cache() {
  pia_setup getSignature-expires_at.json
  printf 'not json\n' >"$PF_PIA_CACHE"
  pia_run 2020-05-01T00:00:00
  assert_contains "pia: ignoring ${PF_PIA_CACHE}: " "$(cat "$QBTVPN_RUN/pia.log")"
  assert_contains "getSignature" "$(cat "$QBTVPN_RUN/curl.log")"
}

test_natpmp_reason_merges_equal_reasons() {
  assert_eq "no reply within 15 s" "$(pf_natpmp_reason "no reply within 15 s" "no reply within 15 s")"
  assert_eq "TCP: x" "$(pf_natpmp_reason "" x)"
  assert_eq "UDP: a; TCP: b" "$(pf_natpmp_reason a b)"
}
