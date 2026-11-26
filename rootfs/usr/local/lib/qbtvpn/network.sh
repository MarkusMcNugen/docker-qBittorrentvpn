# shellcheck shell=bash
# Network discovery and routing. Records the container's interfaces, routes
# and resolvers before the VPN changes them, adds return routes for
# LAN_NETWORK, and resolves VPN endpoint names to IPv4 addresses.

NET_DEV=""       # interface that holds the IPv4 default route
NET_GW=""        # its gateway; empty for an on-link default route
NET_ADDR=""      # its IPv4 address
NET_LOCAL=()     # "dev cidr" for each directly connected IPv4 subnet outside the tunnel
NET_RESOLVERS=() # nameservers of the resolv.conf the container started with

# Exits when the container shares the host's network namespace, where the
# firewall this image installs would replace the host's own.
net_refuse_host_network() {
  local name
  while read -r name; do
    case "$name" in
      docker0 | veth* | br-* | virbr* | cni* | flannel* | cali* | podman*)
        die "interface ${name} belongs to the host: this container cannot run with host networking, because its firewall would replace the host's"
        ;;
    esac
  done < <(ip -o link show | awk -F': ' '{ sub(/@.*/, "", $2); print $2 }')
}

net_capture() {
  local dev cidr
  read -r NET_GW NET_DEV < <(ip -4 route show default | awk '
    { g = "-"; d = ""
      for (i = 1; i < NF; i++) { if ($i == "via") g = $(i + 1); if ($i == "dev") d = $(i + 1) }
      print g, d; exit }')
  [ -n "${NET_DEV:-}" ] || die "the container has no IPv4 default route"
  if [ "$NET_GW" = - ]; then NET_GW=""; fi
  NET_ADDR=$(ip -4 -o addr show dev "$NET_DEV" | awk '{ split($4, a, "/"); print a[1]; exit }')

  NET_LOCAL=()
  while read -r cidr dev; do
    case "$dev" in
      tun* | tap* | wg*) continue ;;
    esac
    is_ipv4_cidr "$cidr" || continue
    NET_LOCAL+=("$dev $cidr")
  done < <(ip -4 route show proto kernel scope link | awk '
    { d = ""; for (i = 1; i < NF; i++) if ($i == "dev") d = $(i + 1); print $1, d }')

  NET_RESOLVERS=()
  if [ -r /etc/resolv.conf ]; then
    cp /etc/resolv.conf "$QBTVPN_RUN/resolv.conf.orig"
    while read -r cidr; do
      NET_RESOLVERS+=("$cidr")
    done < <(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf)
  fi

  log_info "network: default route via ${NET_GW:-on-link} dev ${NET_DEV}, address ${NET_ADDR:-none}"
  log_info "network: local subnets ${NET_LOCAL[*]:-none}; resolvers ${NET_RESOLVERS[*]:-none}"
}

# Prints the device of the connected subnet containing IPv4 address $1, or nothing.
net_local_dev_for() {
  local l
  for l in "${NET_LOCAL[@]}"; do
    if cidr_contains "${l#* }" "$1"; then
      printf '%s' "${l%% *}"
      return 0
    fi
  done
  return 0
}

# True when CIDR $1 lies inside one of the connected subnets.
net_covered_by_local() {
  local l net="${1%/*}" len="${1##*/}" local_len
  for l in "${NET_LOCAL[@]}"; do
    local_len="${l##*/}"
    if [ "$len" -ge "$local_len" ] && cidr_contains "${l#* }" "$net"; then
      return 0
    fi
  done
  return 1
}

# Routes each LAN_NETWORK through the container's own gateway, so replies to
# LAN clients leave the way they came instead of through the tunnel.
net_add_lan_routes() {
  local cidr
  for cidr in "${CFG_LAN_NETWORKS[@]}"; do
    if net_covered_by_local "$cidr"; then
      log_info "route: LAN ${cidr} is directly connected"
      continue
    fi
    if [ -n "$NET_GW" ]; then
      ip -4 route replace "$cidr" via "$NET_GW" dev "$NET_DEV"
    else
      ip -4 route replace "$cidr" dev "$NET_DEV"
    fi
    log_info "route: LAN ${cidr} via ${NET_GW:-on-link} dev ${NET_DEV}"
  done
}

# Prints "dev cidr" for every subnet the firewall treats as local: the
# connected subnets plus each LAN_NETWORK routed through NET_DEV.
net_local_and_lan() {
  local l cidr
  for l in "${NET_LOCAL[@]}"; do
    printf '%s\n' "$l"
  done
  for cidr in "${CFG_LAN_NETWORKS[@]}"; do
    if ! net_covered_by_local "$cidr"; then
      printf '%s %s\n' "$NET_DEV" "$cidr"
    fi
  done
}

# resolve_ipv4 `HOST`: prints each IPv4 address of `HOST`, one per line. A
# literal address prints itself. Tries three times before giving up with
# status 1. busybox nslookup queries a name without a dot only with the search
# domains appended, so such a name is looked up first as `HOST.`, the bare name
# Docker's container names need, and then with the search domains.
resolve_ipv4() {
  local host="$1" out attempt found="" name errors
  local -a names=("$host")
  if is_ipv4 "$host"; then
    printf '%s\n' "$host"
    return 0
  fi
  case "$host" in
    *.*) ;;
    *) names=("${host}." "$host") ;;
  esac
  for attempt in 1 2 3; do
    errors=""
    for name in "${names[@]}"; do
      if out=$(timeout 20 nslookup -type=a "$name" 2>&1); then
        found=$(awk '
          /^Name:/ { n = 1; next }
          n && /^Address/ { sub(/^Address[^:]*:[ \t]*/, ""); sub(/#.*/, ""); print }' <<<"$out")
        if [ -n "$found" ]; then
          break 2
        fi
        out="no IPv4 address"
      fi
      errors="${errors}${errors:+; }${name}: $(tr '\n' ' ' <<<"$out")"
    done
    log_warn "resolve: lookup ${attempt}/3 of ${host} failed: ${errors}"
    if [ "$attempt" -lt 3 ]; then
      sleep 3
    fi
  done
  local ip any=no
  while read -r ip; do
    if is_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      any=yes
    fi
  done <<<"$found"
  [ "$any" = yes ]
}

ipv6_active() {
  [ -r /proc/net/if_inet6 ] && awk '$6 != "lo" { found = 1 } END { exit !found }' /proc/net/if_inet6
}

# Removes IPv6 addresses and routes from every interface but loopback. Used
# only when IPv6 is active and no ip6tables backend works, so IPv6 traffic
# has no path out at all.
net_disable_ipv6_paths() {
  local dev
  while read -r dev; do
    [ "$dev" = lo ] && continue
    ip -6 addr flush dev "$dev"
    ip -6 route flush dev "$dev"
  done < <(ip -o link show | awk -F': ' '{ sub(/@.*/, "", $2); print $2 }')
  if ipv6_active; then
    die "IPv6 is active, ip6tables does not work in this kernel, and the IPv6 addresses could not be removed; refusing to start"
  fi
  log_warn "ip6tables is unavailable: removed every IPv6 address and route instead"
}
