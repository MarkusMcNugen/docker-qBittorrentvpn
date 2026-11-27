#!/bin/bash
# Rootless tests: the image under rootless Podman, which puts the container in
# a user namespace as rootless Docker does, so the host's /dev/net/tun belongs
# to a user the container does not map. For each VPN, the e2e test double
# plays the provider: the client must become healthy and reach the target
# through the tunnel, recover when its VPN process is killed or its interface
# deleted, and stop cleanly.
#   tests/rootless/run.sh IMAGE [openvpn|wg-kernel|wg-userspace ...]
# IMAGE is copied from Docker into Podman unless Podman already has it. Runs as
# an ordinary user; exits non-zero when any check fails.
set -uo pipefail
image="${1:?usage: tests/rootless/run.sh IMAGE [MODE...]}"
shift
modes=("$@")
[ "${#modes[@]}" -gt 0 ] || modes=(openvpn wg-kernel wg-userspace)

here=$(cd "$(dirname "$0")" && pwd)
p="qbtvpn-rootless-$$"
lan="${p}-lan"
wan="${p}-wan"
helper="localhost/qbtvpn-e2e-server:rootless"
passes=0
fails=0
work=""

# The lines bash itself writes, as opposed to the container's own log lines.
SHELL_NOTICE_RE='^/[^ :]+: line [0-9]+: '

say() { echo "$(date '+%H:%M:%S') $*"; }
pass() { passes=$((passes + 1)); say "PASS $1"; }
fail() { fails=$((fails + 1)); say "FAIL $1"; }
check() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}
check_eq() {
  local name="$1" want="$2" got
  shift 2
  got=$("$@" 2>&1)
  if [ "$got" = "$want" ]; then pass "$name"; else fail "${name}: got '${got}'"; fi
}
client_log() { podman logs "${p}-client" 2>&1; }

remove_containers() {
  local c
  for c in client server target; do
    if podman container exists "${p}-${c}"; then podman rm -f -t 0 "${p}-${c}" >/dev/null; fi
  done
}
cleanup() {
  local n
  remove_containers
  for n in "$lan" "$wan"; do
    if podman network exists "$n"; then podman network rm "$n" >/dev/null; fi
  done
  if [ -n "$work" ]; then podman unshare rm -rf "$work"; fi
}
trap cleanup EXIT

# Stops with the reason when this host cannot run rootless Podman at all, so
# a host problem is not mistaken for a failing check.
preflight() {
  command -v podman >/dev/null || { echo "rootless: podman is not installed" >&2; exit 2; }
  if [ "$(id -u)" = 0 ]; then echo "rootless: run as an ordinary user, not root" >&2; exit 2; fi
  local rootless
  rootless=$(podman info --format '{{.Host.Security.Rootless}}' 2>&1) ||
    { echo "rootless: podman info failed: ${rootless}" >&2; exit 2; }
  [ "$rootless" = true ] || { echo "rootless: podman is not running rootless (${rootless})" >&2; exit 2; }
}

# The image in Podman: as it is when Podman has it, else copied from Docker.
podman_image() {
  local loaded
  if podman image exists "$image"; then
    printf '%s' "$image"
    return 0
  fi
  loaded=$(docker save "$image" | podman load -q | awk '/^Loaded image/ { print $NF }')
  [ -n "$loaded" ] || { echo "rootless: could not copy ${image} from Docker into Podman" >&2; exit 2; }
  printf '%s' "$loaded"
}

# healthy SECONDS: true once the client's health check passes; false when it
# exits or the time runs out.
healthy() {
  local deadline=$(($(date +%s) + $1)) state
  while [ "$(date +%s)" -lt "$deadline" ]; do
    state=$(podman inspect -f '{{.State.Status}}' "${p}-client" 2>&1)
    if [ "$state" != running ]; then
      say "client is ${state}, exit code $(podman inspect -f '{{.State.ExitCode}}' "${p}-client" 2>&1)"
      return 1
    fi
    if podman exec "${p}-client" qbtvpn-healthcheck >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

# reaches SECONDS: true once the target answers through the tunnel.
reaches() {
  local deadline=$(($(date +%s) + $1))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if podman exec "${p}-client" curl -fsS --max-time 5 http://target.e2e/cgi-bin/ip >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

run_mode() {
  local mode="$1" role srv_lan srv_wan want break_it stop_line before="$fails"
  local -a extra=() args=()
  case "$mode" in
    openvpn)
      role=ovpn srv_lan=172.31.250.3 srv_wan=172.31.251.3 want=client.ovpn extra=(--device /dev/net/tun)
      args=(-e VPN_USERNAME=e2e -e VPN_PASSWORD=e2e-vpn-pass)
      break_it="pkill -KILL -x openvpn" stop_line="openvpn: stopped"
      ;;
    wg-kernel)
      role=wg srv_lan=172.31.250.2 srv_wan=172.31.251.2 want=client.conf args=(-e WIREGUARD_USERSPACE=no)
      break_it="ip link del dev wg0" stop_line="wireguard: wg0 removed"
      ;;
    wg-userspace)
      role=wg srv_lan=172.31.250.2 srv_wan=172.31.251.2 want=client.conf args=(-e WIREGUARD_USERSPACE=yes)
      break_it="pkill -KILL -x wireguard-go" stop_line="wireguard: wg0 removed"
      ;;
    *)
      fail "unknown mode ${mode}"
      return
      ;;
  esac
  say "== ${mode}"
  remove_containers
  mkdir -p "$work/$mode/shared" "$work/$mode/client/openvpn" "$work/$mode/client/wireguard"
  podman run -d --name "${p}-target" --network "${wan}:ip=172.31.251.10" "$helper" target >/dev/null
  podman run -d --name "${p}-server" --cap-add NET_ADMIN "${extra[@]}" --sysctl net.ipv4.ip_forward=1 \
    -e ENDPOINT_NAME="${p}-server" --network "${lan}:ip=${srv_lan}" --network "${wan}:ip=${srv_wan}" \
    -v "$work/$mode/shared:/shared" "$helper" "$role" >/dev/null
  for _ in $(seq 60); do
    [ -s "$work/$mode/shared/$want" ] && break
    sleep 1
  done
  if [ ! -s "$work/$mode/shared/$want" ]; then
    fail "${mode}: the test server started"
    podman logs "${p}-server" 2>&1 | tail -20
    return
  fi
  case "$role" in
    ovpn) cp "$work/$mode/shared/client.ovpn" "$work/$mode/client/openvpn/provider.ovpn" ;;
    wg) cp "$work/$mode/shared/client.conf" "$work/$mode/client/wireguard/wg0.conf" ;;
  esac
  podman run -d --name "${p}-client" --cap-add NET_ADMIN --device /dev/net/tun --network "${lan}:ip=172.31.250.5" \
    -v "$work/$mode/client:/config" -e LAN_NETWORK=172.31.250.0/24 -e VPN_CHECK_INTERVAL=3 \
    -e VPN_CONNECT_TIMEOUT=60 -e PUID=0 -e PGID=0 "${args[@]}" "$podman_ref" >/dev/null

  if ! healthy 180; then
    fail "${mode}: client became healthy"
    client_log | tail -40
    echo "---- ${role} test server log"
    podman logs "${p}-server" 2>&1 | tail -40
    return
  fi
  pass "${mode}: client became healthy"
  check_eq "${mode}: egress goes through the tunnel (target sees ${srv_wan})" "$srv_wan" \
    podman exec "${p}-client" curl -fsS --max-time 10 http://target.e2e/cgi-bin/ip
  if [ "$mode" != wg-kernel ]; then
    check "${mode}: /dev/net/tun owned outside the user namespace is used as it is" \
      sh -c "podman logs ${p}-client 2>&1 | grep -q \"outside this container's user namespace\""
  fi
  if [ "$mode" = openvpn ]; then
    check "${mode}: data channel offload is off in the user namespace" \
      sh -c "podman logs ${p}-client 2>&1 | grep -q 'in a user namespace, so data channel offload is off'"
  fi
  # shellcheck disable=SC2086  # break_it is a command and its arguments
  check "${mode}: ${break_it}" podman exec "${p}-client" $break_it
  check "${mode}: the supervisor repairs it in place and traffic flows again" reaches 90
  podman stop -t 60 "${p}-client" >/dev/null
  check_eq "${mode}: podman stop exits cleanly" 0 podman inspect -f '{{.State.ExitCode}}' "${p}-client"
  # The repair logs the same line, so only one after the stop signal counts.
  check "${mode}: the stop takes the VPN down (${stop_line})" \
    sh -c "podman logs ${p}-client 2>&1 | awk -v s='${stop_line}' '/received SIGTERM/ { t = 1 } t && index(\$0, s) { f = 1 } END { exit !f }'"
  check_eq "${mode}: the client logged no error" "" sh -c "podman logs ${p}-client 2>&1 | grep -F '[error]'"
  check_eq "${mode}: bash wrote no job notice or error of its own" "" sh -c "podman logs ${p}-client 2>&1 | grep -E '${SHELL_NOTICE_RE}'"
  if [ "$fails" -gt "$before" ]; then client_log | tail -40; fi
  remove_containers
}

preflight
say "rootless Podman $(podman version --format '{{.Client.Version}}') as $(id -un), uid $(id -u)"
work=$(mktemp -d)
podman_ref=$(podman_image) || exit 2
say "client image ${podman_ref}"
say "building the test double"
podman build -q -t "$helper" "$here/../e2e/server" >/dev/null || { echo "rootless: the test double did not build" >&2; exit 2; }
podman network create --subnet 172.31.250.0/24 "$lan" >/dev/null || exit 2
podman network create --internal --subnet 172.31.251.0/24 "$wan" >/dev/null || exit 2
for m in "${modes[@]}"; do run_mode "$m"; done
say "${passes} passed, ${fails} failed"
[ "$fails" -eq 0 ]
