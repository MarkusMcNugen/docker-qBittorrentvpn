#!/bin/bash
# End-to-end tests on a Docker host.
#
# A test double (tests/e2e/server) plays the VPN provider and the internet:
# WireGuard and OpenVPN servers sit on a "lan" network and a "wan" network,
# NAT client traffic onto wan, resolve DNS inside the tunnel and reply to
# NAT-PMP. The image under test runs on lan only. tcpdump on the lan bridge
# records every packet; a packet from the client that is neither VPN
# transport to the server nor a WebUI or Privoxy reply fails the run as a
# leak.
#
#   tests/e2e/run.sh IMAGE [wireguard|openvpn|openvpn_no_ipv6 ...]
set -uo pipefail
image="${1:?usage: tests/e2e/run.sh IMAGE [scenario...]}"
shift
scenarios=("$@")
[ "${#scenarios[@]}" -gt 0 ] || scenarios=(wireguard wireguard_userspace openvpn openvpn_no_ipv6 start_failure)

here=$(cd "$(dirname "$0")" && pwd)
p=qbtvpn-e2e
lan="${p}-lan"
wan="${p}-wan"
helper="${p}-server"
client_ip=172.31.250.10
work=$(mktemp -d "${TMPDIR:-/tmp}/qbtvpn-e2e.XXXXXX")
fails=0
passes=0

say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
pass() { passes=$((passes + 1)); say "PASS $*"; }
fail() { fails=$((fails + 1)); say "FAIL $*"; }
check() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

# check_eq NAME WANT CMD...: passes when CMD prints exactly WANT; a failure
# shows what it printed and the start of its stderr.
check_eq() {
  local name="$1" want="$2" got
  shift 2
  got=$("$@" 2>"$work/check.err")
  if [ "$got" = "$want" ]; then pass "$name"; return; fi
  fail "${name}: got '${got}' $(tr '\n' ' ' <"$work/check.err")"
}

# check_eq_within NAME SECONDS WANT CMD...: check_eq, rerunning CMD once a
# second until it prints WANT or SECONDS have passed.
check_eq_within() {
  local name="$1" deadline=$(($(date +%s) + $2)) want="$3" got
  shift 3
  while :; do
    got=$("$@" 2>"$work/check.err")
    if [ "$got" = "$want" ]; then pass "$name"; return; fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 1
  done
  fail "${name}: got '${got}' $(tr '\n' ' ' <"$work/check.err")"
}
in_client() { docker exec "${p}-client" "$@"; }

# keep FILE NAME / keep_client_log SCENARIO: with E2E_LOG_DIR set, copy FILE,
# or the client container's whole log, into that directory as NAME or
# SCENARIO-client.log, for debugging and for the wiki's sample output.
keep() { if [ -n "${E2E_LOG_DIR-}" ]; then mkdir -p "$E2E_LOG_DIR" && cp "$1" "$E2E_LOG_DIR/$2"; fi; }
keep_client_log() {
  if [ -n "${E2E_LOG_DIR-}" ]; then
    mkdir -p "$E2E_LOG_DIR" && docker logs "${p}-client" >"$E2E_LOG_DIR/$1-client.log" 2>&1
  fi
}
# probe CMD ARGS...: runs CMD in a throwaway container on the lan network.
probe() {
  local cmd="$1"
  shift
  docker run --rm --network "$lan" --entrypoint "$cmd" "$helper" "$@"
}

remove_containers() {
  local ids
  ids=$(docker ps -aq --filter "name=^${p}-" | tr '\n' ' ')
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker rm -f $ids >/dev/null
  fi
}

cleanup() {
  remove_containers
  docker network rm "$lan" "$wan" >/dev/null 2>&1
  docker run --rm -v "$work:/w" --entrypoint /bin/sh "$helper" -c 'rm -rf /w/*' >/dev/null 2>&1
  rmdir "$work" 2>/dev/null
  return 0
}
trap cleanup EXIT

diagnose() {
  local s
  for s in wg ovpn; do
    if docker inspect "${p}-${s}" >/dev/null 2>&1; then
      say "---- ${s} server log"
      docker logs "${p}-${s}" 2>&1 | awk '{ print "  " $0 }'
    fi
  done
  say "---- client log"
  docker logs "${p}-client" 2>&1 | awk '{ print "  " $0 }'
  say "---- client status"
  docker exec "${p}-client" qbtvpn-status 2>&1 | awk '{ print "  " $0 }'
}

# wait_healthy SECONDS: waits for the client's health check to pass, printing
# its last result once a minute.
wait_healthy() {
  local start deadline next state health
  start=$(date +%s)
  deadline=$((start + $1))
  next=$((start + 60))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    state=$(docker inspect -f '{{.State.Status}}' "${p}-client" 2>&1)
    if [ "$state" != running ]; then
      say "client is ${state:-gone}"
      return 1
    fi
    if health=$(docker exec "${p}-client" qbtvpn-healthcheck 2>&1); then
      return 0
    fi
    if [ "$(date +%s)" -ge "$next" ]; then
      say "waiting for a healthy client after $(($(date +%s) - start)) s: ${health}"
      next=$((next + 60))
    fi
    sleep 2
  done
  return 1
}

# wait_for SECONDS CMD...: reruns CMD once a second until it succeeds or
# SECONDS have passed on the clock, printing once a minute what CMD last
# printed.
wait_for() {
  local start deadline next out
  start=$(date +%s)
  deadline=$((start + $1))
  next=$((start + 60))
  shift
  while :; do
    if out=$("$@" 2>&1); then return 0; fi
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    if [ "$(date +%s)" -ge "$next" ]; then
      say "still waiting after $(($(date +%s) - start)) s: $* (last output: $(tail -n 1 <<<"$out"))"
      next=$((next + 60))
    fi
    sleep 1
  done
}

# fails_quickly CMD...: true when CMD fails or has not finished after 12 s.
# timeout runs only programs, so CMD runs in a bash that timeout starts,
# which gets in_client and probe and their variables through the environment.
fails_quickly() { ! timeout 12 bash -c '"$@"' _ "$@" >/dev/null 2>&1; }
export -f in_client probe
export p lan helper

# not CMD...: true when CMD fails.
not() { ! "$@"; }

webui_code() { probe curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${client_ip}:8080/"; }

# webui_login USER PASSWORD: prints accepted, refused, or the WebAPI's reply
# when it is neither. qBittorrent 5.3 replies 204 or 401; earlier releases
# reply 200 with "Ok." or "Fails.".
webui_login() {
  local reply code body
  reply=$(probe curl -s -w '\n%{http_code}' --max-time 5 --data-urlencode "username=$1" --data-urlencode "password=$2" \
    -H "Referer: http://${client_ip}:8080" "http://${client_ip}:8080/api/v2/auth/login")
  code="${reply##*$'\n'}"
  body="${reply%$'\n'*}"
  case "${code} ${body}" in
    "204 " | "200 Ok.") echo accepted ;;
    "401 "* | "200 Fails.") echo refused ;;
    *) echo "HTTP ${code} ${body}" ;;
  esac
}

# qbt_pref KEY: prints a qBittorrent preference through the WebAPI.
qbt_pref() {
  probe sh -c "curl -s -c /tmp/j --max-time 5 --data 'username=admin&password=e2e-webui-pass' -H 'Referer: http://${client_ip}:8080' http://${client_ip}:8080/api/v2/auth/login >/dev/null && curl -s -b /tmp/j --max-time 5 http://${client_ip}:8080/api/v2/app/preferences" |
    awk -v k="\"$1\":" '{ i = index($0, k); if (i) { s = substr($0, i + length(k)); sub(/[,}].*/, "", s); gsub(/"/, "", s); print s } }'
}

caps_of() { in_client sh -c "awk '/^Cap(Eff|Bnd)/ { print \$1, \$2 }' /proc/\$(pidof $1 | awk '{ print \$1 }')/status"; }

start_capture() {
  local bridge
  bridge="br-$(docker network inspect -f '{{.Id}}' "$lan" | cut -c1-12)"
  mkdir -p "$work/cap"
  docker run -d --name "${p}-capture" --network host --cap-add NET_RAW --cap-add NET_ADMIN \
    -v "$work/cap:/shared" "$helper" capture "$bridge" >/dev/null
  sleep 2
}

# leak_check TRANSPORT_FILTER: fails when the capture holds a packet from the
# client that is not VPN transport, a WebUI reply, ARP, or IPv6 link-local
# housekeeping from before the firewall started.
leak_check() {
  local transport="$1" mac leaks
  docker stop -t 5 "${p}-capture" >/dev/null
  mac=$(docker inspect -f "{{(index .NetworkSettings.Networks \"${lan}\").MacAddress}}" "${p}-client" 2>/dev/null)
  leaks=$(docker run --rm -v "$work/cap:/shared" --entrypoint tcpdump "$helper" -r /shared/lan.pcap -n \
    "(src host ${client_ip} and not arp and not (${transport}) and not (tcp and src port 8080)) or (ether src ${mac} and ip6 and not src net fe80::/10 and not src host :: and not dst net ff02::/16)" 2>/dev/null)
  if [ -n "$leaks" ]; then
    printf '%s\n' "$leaks" | awk '{ print "  leaked: " $0 }'
    return 1
  fi
  say "capture: $(docker run --rm -v "$work/cap:/shared" --entrypoint tcpdump "$helper" -r /shared/lan.pcap -n "src host ${client_ip}" 2>/dev/null | wc -l) packets from the client, all VPN transport or WebUI and Privoxy replies"
}

# client_warnings: prints every warning or error line in the client's log,
# including notes other tools print, such as iptables' "# Warning:".
client_warnings() {
  docker logs "${p}-client" 2>&1 | grep -E '\[(warn|error)\]|WARNING|[Ww]arning:|DEPRECATED|ERROR'
}

# The lines bash itself writes, as opposed to the container's own log lines: a
# script error, or a job notice such as "line 14:   256 Killed   env -i ...".
SHELL_NOTICE_RE='^/[^ :]+: line [0-9]+: '

# shell_notices: prints every line bash itself wrote to the client's log.
shell_notices() {
  docker logs "${p}-client" 2>&1 | grep -E "$SHELL_NOTICE_RE"
}

# server_warnings ROLE: prints every warning or error line in a test server's log.
server_warnings() {
  docker logs "${p}-$1" 2>&1 | grep -Ei 'warning|error|deprecated'
}

start_client() {
  local cfg="$1"
  shift
  docker run -d --name "${p}-client" --cap-add NET_ADMIN --device /dev/net/tun \
    --network "$lan" --ip "$client_ip" --dns-search e2e.invalid -v "$cfg:/config" -v "$work/downloads:/downloads" \
    -e LAN_NETWORK=172.31.250.0/24 -e VPN_CHECK_INTERVAL=3 -e VPN_CONNECT_TIMEOUT=60 \
    -e WEBUI_USERNAME=admin -e WEBUI_PASSWORD=e2e-webui-pass \
    -e QBT_CONF_BitTorrent__Session__MaxConnections=123 \
    "$@" "$image" >/dev/null
}

# scenario_common TUN SERVER_WAN_IP TUNNEL_DNS SERVER_LAN_IP: the checks both
# scenarios share. Each blocked-traffic check has a control showing that the
# same request gets an answer from a container without the firewall.
scenario_common() {
  local tun="$1" server_wan_ip="$2" tunnel_dns="$3" server_lan_ip="$4"
  check "control: fails_quickly does not pass a command that succeeds" not fails_quickly in_client true
  check_eq "egress goes through the tunnel (target sees ${server_wan_ip})" "$server_wan_ip" \
    in_client curl -fsS --max-time 10 http://target.e2e/cgi-bin/ip
  check "resolv.conf points at the tunnel DNS ${tunnel_dns}" in_client grep -q "nameserver ${tunnel_dns}" /etc/resolv.conf
  check "control: Docker's DNS answers for ${p}-client" probe nslookup -type=a "${p}-client." 127.0.0.11
  check "DNS to Docker's 127.0.0.11 is blocked" fails_quickly in_client nslookup -type=a "${p}-client." 127.0.0.11
  check "control: the resolver on the LAN at ${server_lan_ip} answers" probe nslookup -type=a target.e2e "$server_lan_ip"
  check "DNS to the resolver on the LAN is blocked" fails_quickly in_client nslookup -type=a target.e2e "$server_lan_ip"
  check "control: 1.1.1.1 answers through the LAN gateway" probe curl -s -o /dev/null --max-time 5 http://1.1.1.1/
  check "traffic forced out eth0 is blocked" fails_quickly in_client curl -s --interface eth0 --max-time 5 http://1.1.1.1/
  check "control: the LAN gateway answers IPv6" probe ping -6 -c 1 -W 2 fd00:250::1
  check "IPv6 to the LAN is blocked" fails_quickly in_client ping -6 -c 1 -W 2 fd00:250::1
  check_eq "WebUI is reachable from the LAN" 200 webui_code
  check_eq "WebUI login works with WEBUI_PASSWORD" accepted webui_login admin e2e-webui-pass
  check_eq "WebUI login refuses a wrong password" refused webui_login admin wrong
  check_eq "qBittorrent is bound to ${tun}" "$tun" qbt_pref current_network_interface
  check_eq "QBT_CONF_ passthrough reached qBittorrent" 123 qbt_pref max_connec
  check "qBittorrent runs as 99 with no capabilities" \
    test "$(caps_of qbittorrent-nox | tr '\n' ' ')" = "CapEff: 0000000000000000 CapBnd: 0000000000000000 "
  # shellcheck disable=SC2016  # expanded inside the container
  check "qBittorrent process user is 99" test "$(in_client sh -c 'stat -c %u /proc/$(pidof qbittorrent-nox)')" = 99
  check_eq_within "forwarded port 40123 reached qBittorrent" 60 40123 qbt_pref listen_port
  check "forwarded port 40123 is open on ${tun}" wait_for 30 in_client sh -c "iptables-nft -S QBTVPN_TUNNEL_IN 2>/dev/null | grep -q 'dport 40123' || iptables-legacy -S QBTVPN_TUNNEL_IN | grep -q 'dport 40123'"
}

# privoxy_checks SERVER_WAN_IP SERVER_CONTAINER TUNNEL_IP: Privoxy answers on
# port 8118 from the lan network, sends requests through the tunnel and
# reaches nothing else.
privoxy_checks() {
  local server_wan_ip="$1" server="$2" tunnel_ip="$3" proxy="http://${client_ip}:8118"
  local -a as_privoxy=(setpriv --reuid=privoxy --regid=privoxy --init-groups --)
  check "control: Privoxy's user resolves target.e2e through the tunnel" in_client "${as_privoxy[@]}" nslookup target.e2e
  check_eq "control: Privoxy's user reaches the target through the tunnel" "$server_wan_ip" \
    in_client "${as_privoxy[@]}" curl -fsS --max-time 5 http://172.31.251.10/cgi-bin/ip
  check_eq "Privoxy's requests leave through the tunnel (target sees ${server_wan_ip})" "$server_wan_ip" \
    probe curl -fsS --max-time 10 -x "$proxy" http://target.e2e/cgi-bin/ip
  check "Privoxy logged the request, as PRIVOXY_CONF_DEBUG asked" \
    sh -c "docker logs ${p}-client 2>&1 | grep -q 'privoxy: Request: target.e2e/cgi-bin/ip'"
  check "control: the web server on the LAN answers" probe curl -fsS -o /dev/null --max-time 5 http://172.31.250.20/cgi-bin/ip
  check "Privoxy cannot reach the LAN" fails_quickly probe curl -fsS --max-time 5 -x "$proxy" http://172.31.250.20/cgi-bin/ip
  check "control: the WebUI answers on loopback inside the client" in_client curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8080/
  check "Privoxy cannot reach the client's loopback" fails_quickly probe curl -fsS --max-time 5 -x "$proxy" http://127.0.0.1:8080/
  check "Privoxy is unreachable from the tunnel side" \
    fails_quickly docker exec "$server" curl -fsS --max-time 5 -x "http://${tunnel_ip}:8118" http://target.e2e/cgi-bin/ip
  check "Privoxy runs with no capabilities" \
    test "$(caps_of privoxy | tr '\n' ' ')" = "CapEff: 0000000000000000 CapBnd: 0000000000000000 "
  # shellcheck disable=SC2016  # expanded inside the container
  check "Privoxy process user is privoxy" test "$(in_client sh -c 'stat -c %U /proc/$(pidof privoxy)')" = privoxy
}

fresh_start() {
  remove_containers
  docker run -d --name "${p}-target" --network "$wan" --ip 172.31.251.10 "$helper" target >/dev/null
  docker run -d --name "${p}-lanweb" --network "$lan" --ip 172.31.250.20 "$helper" target >/dev/null
}

# start_ovpn_server NAME: starts the OpenVPN test server with $work/NAME as
# its shared directory and puts its client configuration in
# $work/NAME-client/openvpn. Returns 1 when the server does not start.
start_ovpn_server() {
  local dir="$work/$1"
  mkdir -p "$dir" "$dir-client/openvpn" "$work/downloads"
  chmod 0777 "$work/downloads"
  docker create --name "${p}-ovpn" --cap-add NET_ADMIN --device /dev/net/tun --sysctl net.ipv4.ip_forward=1 -e ENDPOINT_NAME="${p}-ovpn" \
    --network "$lan" --ip 172.31.250.3 -v "$dir:/shared" "$helper" ovpn >/dev/null
  docker network connect --ip 172.31.251.3 "$wan" "${p}-ovpn"
  docker start "${p}-ovpn" >/dev/null
  if ! wait_for 60 test -s "$dir/client.ovpn"; then
    fail "OpenVPN server did not start"
    docker logs "${p}-ovpn"
    return 1
  fi
  cp "$dir/client.ovpn" "$dir-client/openvpn/provider.ovpn"
}

scenario_wireguard() {
  say "== WireGuard"
  fresh_start
  mkdir -p "$work/wg" "$work/wg-client/wireguard" "$work/downloads"
  chmod 0777 "$work/downloads"
  docker create --name "${p}-wg" --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1 -e ENDPOINT_NAME="${p}-wg" \
    --network "$lan" --ip 172.31.250.2 -v "$work/wg:/shared" "$helper" wg >/dev/null
  docker network connect --ip 172.31.251.2 "$wan" "${p}-wg"
  docker start "${p}-wg" >/dev/null
  wait_for 30 test -s "$work/wg/client.conf" || { fail "WireGuard server did not start"; docker logs "${p}-wg"; return; }
  cp "$work/wg/client.conf" "$work/wg-client/wireguard/wg0.conf"
  start_capture
  start_client "$work/wg-client" -e VPN_RECOVERY_TIMEOUT=45 -e VPN_PORT_FORWARDING=natpmp \
    -e PRIVOXY_ENABLED=yes -e $'PRIVOXY_CONF_DEBUG=1\n2'
  if ! wait_healthy 240; then fail "WireGuard client became healthy"; diagnose; return; fi
  pass "WireGuard client became healthy"
  say "qbtvpn-healthcheck: $(docker exec "${p}-client" qbtvpn-healthcheck 2>&1)"
  scenario_common wg0 172.31.251.2 10.13.0.1 172.31.250.2
  privoxy_checks 172.31.251.2 "${p}-wg" 10.13.0.2
  say "---- qbtvpn-status"
  docker exec "${p}-client" qbtvpn-status 2>&1 | tee "$work/status.txt" | awk '{ print "  " $0 }'
  keep "$work/status.txt" wireguard-status.txt
  check "qbtvpn-status shows the WireGuard handshake" grep -q 'latest handshake' "$work/status.txt"
  check "qbtvpn-status shows Privoxy listening on 8118" grep -q '^listening on port 8118 (pid [0-9]*)$' "$work/status.txt"
  check "WebUI is unreachable from the tunnel side" fails_quickly docker exec "${p}-wg" curl -s --max-time 5 http://10.13.0.2:8080/
  check_eq "the client logged no warning or error while the tunnel was up" "" client_warnings
  check_eq "the WireGuard test server logged no warning or error" "" server_warnings wg

  # paused_probe keep|delete: fetches the target with the supervisor, tini's
  # only child, paused, after deleting wg0 when told to. The pause keeps the
  # supervisor from recreating wg0, which it does within milliseconds of its
  # next check, before the fetch. A failure to pause fails both checks.
  # shellcheck disable=SC2016  # expanded inside the container
  local paused_probe='
    unpaused() { kill -CONT "$sup"; if [ "$1" = keep ]; then exit 1; fi; exit 0; }
    sup=$(pgrep -P 1) && grep -q qbtvpn-entrypoint "/proc/${sup}/cmdline" || unpaused "$1"
    kill -STOP "$sup" || unpaused "$1"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      grep -q "^State:.*stopped" "/proc/${sup}/status" && break
      sleep 0.1
    done
    grep -q "^State:.*stopped" "/proc/${sup}/status" || unpaused "$1"
    if [ "$1" = delete ]; then ip link del dev wg0 || unpaused "$1"; fi
    curl -s --max-time 4 http://172.31.251.10/cgi-bin/ip
    rc=$?
    kill -CONT "$sup"
    exit "$rc"'
  check "control: with the supervisor paused and wg0 kept, the probe reaches the target" \
    not fails_quickly in_client sh -c "$paused_probe" _ keep
  check "kill switch: with wg0 deleted, traffic falls back to eth0 and is refused" \
    fails_quickly in_client sh -c "$paused_probe" _ delete
  check "the supervisor saw wg0 gone and recreated it" \
    wait_for 30 sh -c "docker logs ${p}-client 2>&1 | grep -q 'vpn: wg0 is gone; recreating it'"
  check "recreates wg0 in place and traffic flows again" wait_for 90 in_client curl -fsS --max-time 5 http://target.e2e/cgi-bin/ip

  docker exec "${p}-wg" ip link set wg0 down
  sleep 4
  check "kill switch: nothing reaches the target while the server is down" fails_quickly in_client curl -s --max-time 5 http://172.31.251.10/cgi-bin/ip
  check "kill switch: Privoxy reaches nothing while the server is down" \
    fails_quickly probe curl -fsS --max-time 8 -x "http://${client_ip}:8118" http://172.31.251.10/cgi-bin/ip
  docker exec "${p}-wg" ip link set wg0 up
  check "traffic resumes when the server returns" wait_for 90 in_client curl -fsS --max-time 5 http://target.e2e/cgi-bin/ip
  check "the client never restarted" test "$(docker inspect -f '{{.RestartCount}} {{.State.Status}}' "${p}-client")" = "0 running"

  docker exec "${p}-wg" ip link set wg0 down
  check "health turns unhealthy once the handshake is older than 180 s" \
    wait_for 260 in_client grep -q '^unhealthy .*handshake' /run/qbtvpn/state/health
  check "exits after VPN_RECOVERY_TIMEOUT" wait_for 120 sh -c "docker inspect -f '{{.State.Status}}' ${p}-client | grep -qx exited"
  check "exit status is 1" test "$(docker inspect -f '{{.State.ExitCode}}' "${p}-client")" = 1
  check_eq "bash wrote no job notice or error of its own" "" shell_notices
  check "qBittorrent stopped before the tunnel was removed" sh -c \
    "docker logs ${p}-client 2>&1 | awk '/qbittorrent: stopped/ { q = NR } /wireguard: wg0 removed/ { w = NR } END { exit !(q && w && q < w) }'"
  check "no packet left outside the tunnel" leak_check "(udp and dst host 172.31.250.2 and dst port 51820) or (tcp and src port 8118)"
  keep_client_log wireguard
  if [ "$fails" -gt 0 ]; then diagnose; fi
  remove_containers
}

# WireGuard through wireguard-go, as on hosts without the kernel module:
# wireguard-go killed and replaced in place, and a clean stop.
scenario_wireguard_userspace() {
  say "== WireGuard through wireguard-go"
  fresh_start
  mkdir -p "$work/wgu" "$work/wgu-client/wireguard" "$work/downloads"
  chmod 0777 "$work/downloads"
  docker create --name "${p}-wg" --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1 -e ENDPOINT_NAME="${p}-wg" \
    --network "$lan" --ip 172.31.250.2 -v "$work/wgu:/shared" "$helper" wg >/dev/null
  docker network connect --ip 172.31.251.2 "$wan" "${p}-wg"
  docker start "${p}-wg" >/dev/null
  wait_for 30 test -s "$work/wgu/client.conf" || { fail "WireGuard server did not start"; docker logs "${p}-wg"; return; }
  cp "$work/wgu/client.conf" "$work/wgu-client/wireguard/wg0.conf"
  start_client "$work/wgu-client" -e WIREGUARD_USERSPACE=yes
  if ! wait_healthy 240; then fail "client with wireguard-go became healthy"; diagnose; return; fi
  pass "client with wireguard-go became healthy"
  check_eq "egress goes through the tunnel (target sees 172.31.251.2)" 172.31.251.2 \
    in_client curl -fsS --max-time 10 http://target.e2e/cgi-bin/ip
  # shellcheck disable=SC2016  # expanded inside the container
  check "wireguard-go runs as the vpn user" test "$(in_client sh -c 'stat -c %U /proc/$(pidof wireguard-go)')" = vpn
  check_eq "the client logged no warning or error while the tunnel was up" "" client_warnings
  check "wireguard-go is killed" in_client pkill -KILL -x wireguard-go
  check "the supervisor saw wireguard-go gone and replaced it" \
    wait_for 30 sh -c "docker logs ${p}-client 2>&1 | grep -qE 'vpn: (wg0 is gone|wireguard-go exited); recreating it'"
  check "traffic flows again through the new wireguard-go" \
    wait_for 60 in_client curl -fsS --max-time 5 http://target.e2e/cgi-bin/ip
  docker stop -t 60 "${p}-client" >/dev/null
  check "docker stop exits cleanly" test "$(docker inspect -f '{{.State.ExitCode}}' "${p}-client")" = 0
  check_eq "bash wrote no job notice or error of its own" "" shell_notices
  check_eq "neither wireguard-go printed its banner" "" sh -c "docker logs ${p}-client 2>&1 | grep -F 'Running wireguard-go is not required'"
  keep_client_log wireguard_userspace
  if [ "$fails" -gt 0 ]; then diagnose; fi
  remove_containers
}

scenario_openvpn() {
  say "== OpenVPN"
  fresh_start
  start_ovpn_server ovpn || return
  start_capture
  start_client "$work/ovpn-client" -e VPN_USERNAME=e2e -e VPN_PASSWORD=e2e-vpn-pass -e VPN_RECOVERY_TIMEOUT=0 -e VPN_PORT_FORWARDING=auto
  if ! wait_healthy 240; then fail "OpenVPN client became healthy"; diagnose; return; fi
  pass "OpenVPN client became healthy"
  say "qbtvpn-healthcheck: $(docker exec "${p}-client" qbtvpn-healthcheck 2>&1)"
  scenario_common tun0 172.31.251.3 10.14.0.1 172.31.250.3
  # shellcheck disable=SC2016  # expanded inside the container
  check "OpenVPN runs as the vpn user" test "$(in_client sh -c 'stat -c %U /proc/$(pidof openvpn)')" = vpn
  check "OpenVPN holds only CAP_NET_ADMIN" \
    test "$(caps_of openvpn | tr '\n' ' ')" = "CapEff: 0000000000001000 CapBnd: 0000000000001000 "
  check "IPv6 the server assigns goes through the tunnel" in_client ping -6 -c 1 -W 3 fd00:14::1
  check_eq "global IPv6 is routed into tun0" "2000::/4 dev tun0" \
    sh -c "docker exec ${p}-client ip -6 route show 2000::/4 | awk '{ print \$1, \$2, \$3 }'"
  say "---- qbtvpn-status"
  docker exec "${p}-client" qbtvpn-status 2>&1 | tee "$work/status.txt" | awk '{ print "  " $0 }'
  keep "$work/status.txt" openvpn-status.txt
  check_eq "qbtvpn-status shows the OpenVPN tunnel" "openvpn: CONNECTED 10.14.0.2 server 172.31.250.3" \
    grep '^openvpn:' "$work/status.txt"
  check "Privoxy is off by default" \
    fails_quickly probe curl -fsS --max-time 5 -x "http://${client_ip}:8118" http://target.e2e/cgi-bin/ip
  check_eq "qbtvpn-status has no Privoxy section by default" "" grep '^== privoxy' "$work/status.txt"
  check_eq "the client logged no warning or error while the tunnel was up" "" client_warnings
  check_eq "the OpenVPN test server logged no warning or error" "" server_warnings ovpn

  # The probe runs as soon as that OpenVPN process is gone, before the
  # supervisor's next check can start another and reconnect.
  # shellcheck disable=SC2016  # expanded inside the container
  check "kill switch: with OpenVPN killed, traffic falls back to eth0 and is refused" \
    fails_quickly in_client sh -c 'pid=$(pidof openvpn) && kill -KILL "$pid" && while kill -0 "$pid" 2>/dev/null; do sleep 0.05; done && curl -s --max-time 4 http://172.31.251.10/cgi-bin/ip'
  check "the supervisor saw OpenVPN exit and restarted it" \
    wait_for 30 sh -c "docker logs ${p}-client 2>&1 | grep -q 'vpn: openvpn process exited; restarting it'"
  check "restarts OpenVPN in place and traffic flows again" wait_for 120 in_client curl -fsS --max-time 5 http://target.e2e/cgi-bin/ip

  docker exec "${p}-ovpn" pkill -x openvpn
  sleep 5
  check "kill switch: nothing reaches the target while the server is down" fails_quickly in_client curl -s --max-time 5 http://172.31.251.10/cgi-bin/ip
  docker exec -d "${p}-ovpn" openvpn --config /pki/server.conf
  check "recovers in place when the server returns" wait_for 120 in_client curl -fsS --max-time 5 http://target.e2e/cgi-bin/ip
  check "the client never restarted" test "$(docker inspect -f '{{.RestartCount}} {{.State.Status}}' "${p}-client")" = "0 running"

  docker stop -t 60 "${p}-client" >/dev/null
  check "docker stop exits cleanly" test "$(docker inspect -f '{{.State.ExitCode}}' "${p}-client")" = 0
  # shellcheck disable=SC2016  # $1 and $2 belong to sh -c
  check "control: the shell-notice pattern matches a job notice" sh -c 'printf "%s\n" "$1" | grep -Eq "$2"' _ \
    '/usr/local/lib/qbtvpn/common.sh: line 14:   256 Killed                     env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin setpriv' "$SHELL_NOTICE_RE"
  check_eq "bash wrote no job notice or error of its own, with OpenVPN killed and stopped" "" shell_notices
  check "qBittorrent stopped before OpenVPN" sh -c \
    "docker logs ${p}-client 2>&1 | awk '/qbittorrent: stopped/ { q = NR } /openvpn: stopped/ { o = NR } END { exit !(q && o && q < o) }'"
  check "no packet left outside the tunnel" leak_check "udp and dst host 172.31.250.3 and dst port 1194"
  keep_client_log openvpn
  if [ "$fails" -gt 0 ]; then diagnose; fi
  remove_containers
}

# A start-up failure after the supervisor's traps are in place: /config holds
# no VPN configuration. The reason is logged once and the exit status is 1.
scenario_start_failure() {
  say "== A start-up failure"
  remove_containers
  mkdir -p "$work/empty-config" "$work/downloads"
  start_client "$work/empty-config"
  check "stops when /config holds no VPN configuration" \
    wait_for 60 sh -c "docker inspect -f '{{.State.Status}}' ${p}-client | grep -qx exited"
  check "exit status is 1" test "$(docker inspect -f '{{.State.ExitCode}}' "${p}-client")" = 1
  check_eq "the reason is logged once" 1 sh -c "docker logs ${p}-client 2>&1 | grep -c '\[error\] no VPN configuration'"
  check_eq "nothing else is logged as an error" "" sh -c "docker logs ${p}-client 2>&1 | grep '\[error\]' | grep -v 'no VPN configuration'"
  check_eq "bash wrote no job notice or error of its own" "" shell_notices
  keep_client_log start_failure
  if [ "$fails" -gt 0 ]; then diagnose; fi
  remove_containers
}

# The server pushes an IPv6 address and routes to a client whose container
# has IPv6 switched off.
scenario_openvpn_no_ipv6() {
  say "== OpenVPN with IPv6 disabled in the container"
  fresh_start
  start_ovpn_server ovpn-no-ipv6 || return
  start_capture
  start_client "$work/ovpn-no-ipv6-client" -e VPN_USERNAME=e2e -e VPN_PASSWORD=e2e-vpn-pass -e VPN_RECOVERY_TIMEOUT=0 \
    --sysctl net.ipv6.conf.all.disable_ipv6=1
  if ! wait_healthy 240; then fail "OpenVPN client with IPv6 disabled became healthy"; diagnose; return; fi
  pass "OpenVPN client with IPv6 disabled became healthy"
  check_eq "IPv6 is disabled in the client" 1 in_client cat /proc/sys/net/ipv6/conf/default/disable_ipv6
  check_eq "egress goes through the tunnel (target sees 172.31.251.3)" 172.31.251.3 \
    in_client curl -fsS --max-time 10 http://target.e2e/cgi-bin/ip
  check "the client logged that it ignores the server's IPv6" \
    sh -c "docker logs ${p}-client 2>&1 | grep -q 'openvpn: IPv6 is disabled in this container'"
  check_eq "tun0 has no IPv6 address" "" in_client ip -6 -o addr show dev tun0
  check_eq "qbtvpn-status shows the OpenVPN tunnel" "openvpn: CONNECTED 10.14.0.2 server 172.31.250.3" \
    sh -c "docker exec ${p}-client qbtvpn-status 2>&1 | grep '^openvpn:'"
  check_eq "the client logged no warning or error" "" client_warnings
  check_eq "the OpenVPN test server logged no warning or error" "" server_warnings ovpn
  docker stop -t 60 "${p}-client" >/dev/null
  check "docker stop exits cleanly" test "$(docker inspect -f '{{.State.ExitCode}}' "${p}-client")" = 0
  check_eq "bash wrote no job notice or error of its own" "" shell_notices
  check "no packet left outside the tunnel" leak_check "udp and dst host 172.31.250.3 and dst port 1194"
  keep_client_log openvpn_no_ipv6
  if [ "$fails" -gt 0 ]; then diagnose; fi
  remove_containers
}

say "building the test double"
docker build -q -t "$helper" "$here/server" >/dev/null || { echo "could not build the test double"; exit 1; }
cleanup
work=$(mktemp -d "${TMPDIR:-/tmp}/qbtvpn-e2e.XXXXXX")
docker network create --driver bridge --subnet 172.31.250.0/24 --gateway 172.31.250.1 \
  --ipv6 --subnet fd00:250::/64 "$lan" >/dev/null || { echo "could not create the lan network"; exit 1; }
docker network create --driver bridge --internal --subnet 172.31.251.0/24 "$wan" >/dev/null

for s in "${scenarios[@]}"; do
  "scenario_${s}"
done

say "${passes} passed, ${fails} failed"
[ "$fails" -eq 0 ]
