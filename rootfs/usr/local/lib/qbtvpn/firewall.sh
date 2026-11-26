# shellcheck shell=bash
# The kill switch. Every ruleset is rendered as iptables-restore text by a
# function that only prints, then loaded in one atomic restore per address
# family, so the filter table never passes through a half-built state.
#
# Policy in the final ruleset:
#   - The `INPUT`, `FORWARD` and `OUTPUT` chains default to `DROP` for IPv4 and IPv6.
#   - Anything may leave through the tunnel interface.
#   - Outside the tunnel, only these leave: packets to each pinned VPN
#     endpoint on its port and protocol (never from the qBittorrent user),
#     DNS to `NAME_SERVERS` entries on a local network, and traffic to the
#     container's own subnets and `LAN_NETWORK`. Every other DNS packet is
#     dropped, and Docker's resolver at 127.0.0.11 is dropped unless
#     `VPN_BLOCK_DOCKER_DNS=no`.
#   - Inbound: established flows, the WebUI port, `VPN_INPUT_PORTS` and,
#     with Privoxy enabled, `PRIVOXY_PORT` from local subnets, and on the
#     tunnel only the ports in `QBTVPN_TUNNEL_IN`.
#   - Privoxy's own new connections leave only through the tunnel, apart from
#     DNS, which the rules above decide as for every other user.
#   - IPv6 leaves only through the tunnel.

FW_BACKEND=""
FW_IPT=""
FW_IPT_RESTORE=""
FW_IP6T=""
FW_IP6T_RESTORE=""
FW_V6=no      # yes when an ip6tables backend works
FW_OWNER=yes  # owner match available
FW_REJECT=yes # REJECT target available
FW_TUN=""     # tunnel interface name
FW_ENDPOINTS=()      # "ip port proto"
FW_LOCAL=()          # "dev cidr"
FW_DNS_EXCEPTIONS=() # IPv4 nameservers on local networks that NAME_SERVERS names
FW_TUNNEL_PORTS=()   # ports accepted inbound on the tunnel
FW_PRIVOXY_UID=""    # Privoxy's user when it is enabled, which adds its rules

fw_probe() { "iptables-$1" -w 5 -t filter -S >/dev/null 2>&1; }

fw_detect_backend() {
  local nft=no legacy=no legacy_rules=no
  if fw_probe nft; then nft=yes; fi
  if fw_probe legacy; then
    legacy=yes
    if iptables-legacy-save 2>/dev/null | awk '/^-A / { found = 1 } END { exit !found }'; then
      legacy_rules=yes
    fi
  fi
  case "$CFG_FIREWALL_BACKEND" in
    nft) [ "$nft" = yes ] || die "FIREWALL_BACKEND=nft, but iptables-nft does not work here"; FW_BACKEND=nft ;;
    legacy) [ "$legacy" = yes ] || die "FIREWALL_BACKEND=legacy, but iptables-legacy does not work here"; FW_BACKEND=legacy ;;
    auto)
      if [ "$legacy_rules" = yes ]; then
        FW_BACKEND=legacy
      elif [ "$nft" = yes ]; then
        FW_BACKEND=nft
      elif [ "$legacy" = yes ]; then
        FW_BACKEND=legacy
      else
        die "no iptables backend works: run the container with --cap-add=NET_ADMIN on a kernel with iptables or nftables support"
      fi
      ;;
  esac
  FW_IPT="iptables-${FW_BACKEND}"
  FW_IPT_RESTORE="iptables-${FW_BACKEND}-restore"
  FW_IP6T="ip6tables-${FW_BACKEND}"
  FW_IP6T_RESTORE="ip6tables-${FW_BACKEND}-restore"
  if "$FW_IP6T" -w 5 -t filter -S >/dev/null 2>&1; then FW_V6=yes; else FW_V6=no; fi
  log_info "firewall: iptables-${FW_BACKEND} backend, IPv6 filtering ${FW_V6}"
}

fw_owner_not_qbt() {
  if [ "$FW_OWNER" = yes ] && [ "$CFG_PUID" != 0 ]; then
    printf -- '-m owner ! --uid-owner %s ' "$CFG_PUID"
  fi
}

fw_render_v4_lockdown() {
  local r owner=""
  if [ "$FW_OWNER" = yes ]; then owner="-m owner --uid-owner 0 "; fi
  printf '%s\n' '*filter' ':INPUT DROP [0:0]' ':FORWARD DROP [0:0]' ':OUTPUT DROP [0:0]' \
    '-A INPUT -i lo -j ACCEPT' \
    '-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' \
    '-A OUTPUT -o lo -j ACCEPT'
  for r in "${NET_RESOLVERS[@]}"; do
    is_ipv4 "$r" || continue
    case "$r" in 127.*) continue ;; esac
    printf -- '-A OUTPUT -d %s/32 -p udp --dport 53 %s-j ACCEPT\n' "$r" "$owner"
    printf -- '-A OUTPUT -d %s/32 -p tcp --dport 53 %s-j ACCEPT\n' "$r" "$owner"
  done
  printf '%s\n' 'COMMIT'
}

fw_render_v6_lockdown() {
  printf '%s\n' '*filter' ':INPUT DROP [0:0]' ':FORWARD DROP [0:0]' ':OUTPUT DROP [0:0]' \
    '-A INPUT -i lo -j ACCEPT' '-A OUTPUT -o lo -j ACCEPT' 'COMMIT'
}

fw_render_tunnel_chain() {
  local p
  for p in "${FW_TUNNEL_PORTS[@]}"; do
    printf -- '-A QBTVPN_TUNNEL_IN -p tcp --dport %s -j ACCEPT\n' "$p"
    printf -- '-A QBTVPN_TUNNEL_IN -p udp --dport %s -j ACCEPT\n' "$p"
  done
}

# True when Privoxy is enabled and the owner match can confine it.
fw_privoxy_on() { [ -n "$FW_PRIVOXY_UID" ] && [ "$FW_OWNER" = yes ]; }

# fw_render_privoxy_chain v4|v6: QBTVPN_PRIVOXY_OUT, which OUTPUT sends every
# new connection from Privoxy's user through first. Connections into the
# tunnel and DNS return to OUTPUT, whose rules decide them as for any other
# user; every other connection, to loopback included, is refused.
fw_render_privoxy_chain() {
  printf -- '-A QBTVPN_PRIVOXY_OUT -o %s -j RETURN\n' "$FW_TUN"
  printf '%s\n' '-A QBTVPN_PRIVOXY_OUT -p udp --dport 53 -j RETURN' '-A QBTVPN_PRIVOXY_OUT -p tcp --dport 53 -j RETURN'
  if [ "$FW_REJECT" != yes ]; then
    printf '%s\n' '-A QBTVPN_PRIVOXY_OUT -j DROP'
  elif [ "$1" = v4 ]; then
    printf '%s\n' '-A QBTVPN_PRIVOXY_OUT -j REJECT --reject-with icmp-admin-prohibited'
  else
    printf '%s\n' '-A QBTVPN_PRIVOXY_OUT -j REJECT --reject-with icmp6-adm-prohibited'
  fi
  printf -- '-A OUTPUT -m owner --uid-owner %s -m conntrack --ctstate NEW -j QBTVPN_PRIVOXY_OUT\n' "$FW_PRIVOXY_UID"
}

fw_render_v4_final() {
  local l dev cidr p e ip port proto owner
  local -a ports=("$CFG_WEBUI_PORT" "${CFG_INPUT_PORTS[@]}")
  owner=$(fw_owner_not_qbt)
  printf '%s\n' '*filter' ':INPUT DROP [0:0]' ':FORWARD DROP [0:0]' ':OUTPUT DROP [0:0]' ':QBTVPN_TUNNEL_IN - [0:0]'
  if fw_privoxy_on; then
    printf '%s\n' ':QBTVPN_PRIVOXY_OUT - [0:0]'
    ports+=("$CFG_PRIVOXY_PORT")
  fi
  printf '%s\n' '-A INPUT -i lo -j ACCEPT' \
    '-A INPUT -m conntrack --ctstate INVALID -j DROP' \
    '-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' \
    "-A INPUT -i ${FW_TUN} -j QBTVPN_TUNNEL_IN"
  for l in "${FW_LOCAL[@]}"; do
    dev="${l%% *}"
    cidr="${l#* }"
    for p in "${ports[@]}"; do
      printf -- '-A INPUT -i %s -s %s -p tcp --dport %s -j ACCEPT\n' "$dev" "$cidr" "$p"
    done
  done
  fw_render_tunnel_chain
  if fw_privoxy_on; then fw_render_privoxy_chain v4; fi
  if [ "$CFG_BLOCK_DOCKER_DNS" = yes ]; then
    printf '%s\n' '-A OUTPUT -o lo -d 127.0.0.11/32 -j DROP'
  fi
  printf '%s\n' '-A OUTPUT -o lo -j ACCEPT' "-A OUTPUT -o ${FW_TUN} -j ACCEPT"
  for e in "${FW_ENDPOINTS[@]}"; do
    read -r ip port proto <<<"$e"
    printf -- '-A OUTPUT -o %s -d %s/32 -p %s --dport %s %s-j ACCEPT\n' "$NET_DEV" "$ip" "$proto" "$port" "$owner"
  done
  for ip in "${FW_DNS_EXCEPTIONS[@]}"; do
    printf -- '-A OUTPUT -d %s/32 -p udp --dport 53 -j ACCEPT\n' "$ip"
    printf -- '-A OUTPUT -d %s/32 -p tcp --dport 53 -j ACCEPT\n' "$ip"
  done
  printf '%s\n' '-A OUTPUT -p udp --dport 53 -j DROP' \
    '-A OUTPUT -p tcp --dport 53 -j DROP' \
    '-A OUTPUT -p tcp --dport 853 -j DROP'
  for l in "${FW_LOCAL[@]}"; do
    printf -- '-A OUTPUT -o %s -d %s -j ACCEPT\n' "${l%% *}" "${l#* }"
  done
  if [ "$FW_REJECT" = yes ]; then
    printf '%s\n' '-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited'
  fi
  printf '%s\n' 'COMMIT'
}

fw_render_v6_final() {
  printf '%s\n' '*filter' ':INPUT DROP [0:0]' ':FORWARD DROP [0:0]' ':OUTPUT DROP [0:0]' ':QBTVPN_TUNNEL_IN - [0:0]'
  if fw_privoxy_on; then printf '%s\n' ':QBTVPN_PRIVOXY_OUT - [0:0]'; fi
  printf '%s\n' '-A INPUT -i lo -j ACCEPT' \
    '-A INPUT -m conntrack --ctstate INVALID -j DROP' \
    '-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' \
    "-A INPUT -i ${FW_TUN} -j QBTVPN_TUNNEL_IN"
  fw_render_tunnel_chain
  if fw_privoxy_on; then fw_render_privoxy_chain v6; fi
  printf '%s\n' '-A OUTPUT -o lo -j ACCEPT' "-A OUTPUT -o ${FW_TUN} -j ACCEPT"
  if [ "$FW_REJECT" = yes ]; then
    printf '%s\n' '-A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited'
  fi
  printf '%s\n' 'COMMIT'
}

# fw_load FAMILY NAME RENDERER: renders, saves under QBTVPN_RUN/firewall and
# restores. Returns the restore status; its errors go to the log.
fw_load() {
  local family="$1" name="$2" renderer="$3" file restore out
  file="$QBTVPN_RUN/firewall/${name}.${family}.rules"
  mkdir -p "$QBTVPN_RUN/firewall"
  "$renderer" >"$file"
  if [ "$family" = v4 ]; then restore="$FW_IPT_RESTORE"; else restore="$FW_IP6T_RESTORE"; fi
  if ! out=$("$restore" -w 5 <"$file" 2>&1); then
    log_warn "firewall: ${restore} rejected ${file}: $(tr '\n' ' ' <<<"$out")"
    return 1
  fi
  return 0
}

fw_verify_policy() {
  local family="$1" ipt chain
  if [ "$family" = v4 ]; then ipt="$FW_IPT"; else ipt="$FW_IP6T"; fi
  for chain in INPUT FORWARD OUTPUT; do
    "$ipt" -w 5 -S "$chain" | awk -v c="$chain" 'NR == 1 && $1 == "-P" && $2 == c && $3 == "DROP" { ok = 1 } END { exit !ok }' \
      || die "firewall: ${family} ${chain} policy is not DROP after loading the ruleset"
  done
}

fw_apply_lockdown() {
  fw_load v4 lockdown fw_render_v4_lockdown || {
    FW_OWNER=no
    log_warn "firewall: owner match unavailable; the lockdown allows bootstrap DNS from every user"
    fw_load v4 lockdown fw_render_v4_lockdown || die "firewall: the IPv4 lockdown ruleset could not be loaded"
  }
  fw_verify_policy v4
  if [ "$FW_V6" = yes ]; then
    fw_load v6 lockdown fw_render_v6_lockdown || die "firewall: the IPv6 lockdown ruleset could not be loaded"
    fw_verify_policy v6
  elif ipv6_active; then
    net_disable_ipv6_paths
  fi
  log_info "firewall: lockdown in place; nothing but bootstrap DNS leaves the container"
}

fw_apply_final() {
  if ! fw_load v4 final fw_render_v4_final; then
    if [ "$FW_OWNER" = yes ]; then
      FW_OWNER=no
      log_warn "firewall: retrying without the owner match"
    fi
    if ! fw_load v4 final fw_render_v4_final; then
      FW_REJECT=no
      log_warn "firewall: retrying without REJECT; blocked packets are dropped silently"
      fw_load v4 final fw_render_v4_final || die "firewall: the IPv4 ruleset could not be loaded; refusing to start"
    fi
  fi
  fw_verify_policy v4
  if [ "$FW_V6" = yes ]; then
    fw_load v6 final fw_render_v6_final || {
      FW_REJECT=no
      fw_load v6 final fw_render_v6_final || die "firewall: the IPv6 ruleset could not be loaded; refusing to start"
    }
    fw_verify_policy v6
  fi
  log_info "firewall: kill switch active on ${FW_TUN}; ${#FW_ENDPOINTS[@]} endpoint(s) pinned"
}

# fw_set_tunnel_ports PORT...: replaces the ports accepted inbound on the tunnel.
fw_set_tunnel_ports() {
  FW_TUNNEL_PORTS=("$@")
  local file="$QBTVPN_RUN/firewall/tunnel-ports.rules" out
  { printf '%s\n' '*filter' ':QBTVPN_TUNNEL_IN - [0:0]'; fw_render_tunnel_chain; printf '%s\n' 'COMMIT'; } >"$file"
  if ! out=$("$FW_IPT_RESTORE" -w 5 --noflush <"$file" 2>&1); then
    log_error "firewall: could not update the tunnel ports: $(tr '\n' ' ' <<<"$out")"
    return 1
  fi
  if [ "$FW_V6" = yes ] && ! out=$("$FW_IP6T_RESTORE" -w 5 --noflush <"$file" 2>&1); then
    log_error "firewall: could not update the IPv6 tunnel ports: $(tr '\n' ' ' <<<"$out")"
    return 1
  fi
  log_info "firewall: tunnel accepts inbound on port(s) ${FW_TUNNEL_PORTS[*]:-none}"
}
