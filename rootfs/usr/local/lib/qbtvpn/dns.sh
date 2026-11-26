# shellcheck shell=bash
# DNS for everything in the container. Servers come from `NAME_SERVERS`
# first, then from the VPN provider, then from `VPN_DNS_FALLBACK`. The
# firewall lets DNS leave only through the tunnel, apart from the
# `NAME_SERVERS` entries on a local network that dns_lan_exceptions returns.

DNS_ACTIVE="" # the servers last written, space separated

# Prints the IPv4 `NAME_SERVERS` entries that sit on a local network, one per
# line, warning for each that its lookups travel outside the tunnel.
dns_lan_exceptions() {
  local ns dev
  for ns in "${CFG_NAME_SERVERS[@]}"; do
    is_ipv4 "$ns" || continue
    dev=$(net_local_dev_for "$ns")
    if [ -z "$dev" ]; then
      local cidr
      for cidr in "${CFG_LAN_NETWORKS[@]}"; do
        if cidr_contains "$cidr" "$ns"; then dev="$NET_DEV"; fi
      done
    fi
    if [ -n "$dev" ]; then
      log_warn "dns: NAME_SERVERS entry ${ns} is on a local network (${dev}); its lookups, and whatever it forwards upstream, travel outside the VPN"
      printf '%s\n' "$ns"
    fi
  done
  return 0
}

# Prints the DNS servers the VPN provider pushed, one per line.
dns_from_vpn() {
  state_read vpn-dns | awk 'NF'
}

# Prints the servers to use, one per line, logging where they came from.
dns_select() {
  local -a pushed=()
  local s
  if [ "${#CFG_NAME_SERVERS[@]}" -gt 0 ]; then
    printf '%s\n' "${CFG_NAME_SERVERS[@]}"
    return 0
  fi
  while read -r s; do pushed+=("$s"); done < <(dns_from_vpn)
  if [ "${#pushed[@]}" -gt 0 ]; then
    printf '%s\n' "${pushed[@]}"
    return 0
  fi
  printf '%s\n' "${CFG_DNS_FALLBACK[@]}"
}

# Writes /etc/resolv.conf in place when the selected servers changed. Docker
# bind-mounts that file, so it is rewritten rather than replaced.
dns_apply() {
  local -a servers=()
  local s source
  while read -r s; do [ -n "$s" ] && servers+=("$s"); done < <(dns_select)
  [ "${#servers[@]}" -gt 0 ] || die "dns: no DNS server: set NAME_SERVERS or VPN_DNS_FALLBACK"
  if [ "${servers[*]}" = "$DNS_ACTIVE" ]; then
    return 0
  fi
  if [ "${#CFG_NAME_SERVERS[@]}" -gt 0 ]; then
    source=NAME_SERVERS
  elif [ -n "$(dns_from_vpn)" ]; then
    source="the VPN provider"
  else
    source=VPN_DNS_FALLBACK
  fi
  {
    printf '%s\n' '# Written by qbittorrentvpn. Lookups leave only through the VPN tunnel.'
    for s in "${servers[@]:0:3}"; do printf 'nameserver %s\n' "$s"; done
    printf '%s\n' 'options timeout:2 attempts:2'
  } >"$QBTVPN_RUN/resolv.conf.new"
  if ! cat "$QBTVPN_RUN/resolv.conf.new" >/etc/resolv.conf; then
    die "dns: cannot write /etc/resolv.conf; it must stay writable (a read-only root filesystem keeps Docker's bind mount writable)"
  fi
  if [ "${#servers[@]}" -gt 3 ]; then
    log_warn "dns: only the first 3 of ${#servers[@]} servers are used; the C library reads no more"
  fi
  DNS_ACTIVE="${servers[*]}"
  log_info "dns: using ${servers[*]:0:3} from ${source}"
}
