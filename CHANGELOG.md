# Changelog

## [2.1.0] - 2026-11-26

### VPN and firewall
- OpenVPN connects in a container with IPv6 switched off, as some NAS hosts run them: the IPv6 address and routes the server pushes are ignored instead of stopping OpenVPN.
- OpenVPN and WireGuard treat IPv6 as off when either `net.ipv6.conf.all.disable_ipv6` or `net.ipv6.conf.default.disable_ipv6` is set, since a new interface takes its setting from `default`.

### Privoxy
- Privoxy is in the image and off by default; `PRIVOXY_ENABLED=yes` starts it on `PRIVOXY_PORT` (8118) once the VPN is up.
- It runs as its own user with no capabilities. Its port is accepted from local networks only, and its own connections leave only through the tunnel: it cannot reach the LAN, the Docker networks or the container's loopback.
- `PRIVOXY_CONF_<option>` adds any Privoxy setting, and `user.action` and `user.filter` in `/config/privoxy` replace the package's samples.
- Privoxy is restarted if it exits, and `qbtvpn-status` shows it.

### Documentation and releases
- A guide to running other containers through the tunnel, with a Soulseek client as the example.
- Each new version gets a GitHub release whose notes are its changelog section.

## [2.0.0] - 2026-11-25

### Image
- Alpine Linux 3.24 base, about 190 MB.
- qBittorrent and libtorrent compiled from source for each release; the qBittorrent tarball is checked against its OpenPGP signature and both tarballs against GitHub's SHA-256 digests.
- libtorrent 2.1 by default, with WebTorrent support off; `LIBTORRENT_SERIES` builds 2.0 or 1.2.
- libtorrent's `FS_IOC_*` ioctl requests are cast to musl's `int` request type when the source still passes them bare.
- A Qt update recompiles qBittorrent, and a build fails rather than pair qBittorrent with a Qt other than the one it was compiled against.
- Published for linux/amd64 and linux/arm64 to Docker Hub and GHCR, automatically on each qBittorrent or libtorrent release and weekly for Alpine fixes.

### VPN and firewall
- WireGuard support beside OpenVPN 2.7, with `wireguard-go` when the kernel has no WireGuard module.
- OpenVPN sends IPv4, and IPv6 whenever the server assigns an IPv6 address, through the tunnel; the server's pushed redirect options are ignored.
- The firewall is closed before the VPN starts and allows traffic out only through the tunnel and to the resolved address and port of each VPN server; IPv6 leaves only through the tunnel.
- DNS goes only through the tunnel; Docker's resolver at 127.0.0.11 is blocked unless `VPN_BLOCK_DOCKER_DNS=no`.
- qBittorrent is bound to the tunnel interface and runs as PUID:PGID with no capabilities; OpenVPN runs as its own user with only `CAP_NET_ADMIN`.
- A dropped tunnel recovers in place; one down longer than `VPN_RECOVERY_TIMEOUT` stops the container for its restart policy.
- Port forwarding for ProtonVPN and other NAT-PMP providers and for Private Internet Access.
- A failed NAT-PMP mapping is logged with `natpmpc`'s reason, once per reason; an OpenVPN connect timeout logs the management interface's last reply.

### Configuration
- `WEBUI_USERNAME`, `WEBUI_PASSWORD`, `VPN_USERNAME` and `VPN_PASSWORD` accept `_FILE` variants for Docker secrets.
- `QBT_CONF_<Section>__<Key>` sets any qBittorrent.conf value on every start.
- `VPN_OPTIONS` is passed to OpenVPN.
- Without `PUID`/`PGID`, qBittorrent runs as 99:100 instead of root.
- New installs keep qBittorrent's WebUI CSRF protection on; `WEBUI_CSRF_PROTECTION` sets it.
