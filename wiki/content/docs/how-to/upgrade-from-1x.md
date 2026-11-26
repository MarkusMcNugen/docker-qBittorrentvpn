---
title: Upgrade from 1.x
weight: 10
---

Pull the new image and start it with the volumes and variables you already use. Nothing needs moving.

## What stays the same

- `/config/openvpn/*.ovpn`, a `credentials.conf` next to it, and `auth-user-pass credentials.conf` in the file.
- qBittorrent's settings in `/config/qBittorrent`. qBittorrent 5.3 migrates them on its first start; the container writes the settings it manages in the new layout.
- `VPN_ENABLED`, `VPN_USERNAME`, `VPN_PASSWORD`, `LAN_NETWORK`, `NAME_SERVERS`, `PUID`, `PGID`, `UMASK`, `VPN_OPTIONS`, `WEBUI_PORT_ENV` and `INCOMING_PORT_ENV`.

## What changes

- **No root by default.** Without `PUID`/`PGID`, qBittorrent runs as 99:100. The container gives it `/config/qBittorrent`; a download folder owned by root needs `chown -R 99:100` once, or set `PUID`/`PGID` to its owner.
- **No default password.** qBittorrent prints a temporary WebUI password in the log on its first start, or set `WEBUI_USERNAME` and `WEBUI_PASSWORD`.
- **`--privileged` is no longer needed.** Use `--cap-add NET_ADMIN --device /dev/net/tun`.
- **Publishing port 8999 is no longer needed.** Peers reach qBittorrent through the VPN, on a forwarded port; see [Forward a port](../forward-a-port/).
- **DNS.** Without `NAME_SERVERS`, the VPN provider's DNS servers are used, then 1.1.1.1 and 9.9.9.9, always through the tunnel.
- **A stop takes longer.** qBittorrent saves its resume data before the VPN goes down. Give `docker stop` time: `stop_grace_period: 150s` in Compose, or `docker stop -t 150`.
- **OpenVPN options.** Options OpenVPN 2.7 removed (`keysize`, `ncp-disable`, `ns-cert-type`, `tls-remote` and others) are dropped or translated in a private copy, and each change is logged. Your file is not modified; see [Set up OpenVPN](../set-up-openvpn/#what-the-container-changes).

Every new variable is in the [environment variable reference](../../reference/environment-variables/).
