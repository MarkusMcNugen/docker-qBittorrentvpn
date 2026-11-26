---
title: When the tunnel drops
weight: 2
---

A VPN connection drops sooner or later: the provider restarts a server, the network blips, a session expires. The container keeps qBittorrent running behind the closed firewall while the tunnel recovers, and only gives up, stopping for its restart policy, when the tunnel stays down too long. The logic is in `rootfs/usr/local/bin/qbtvpn-entrypoint` and `rootfs/usr/local/lib/qbtvpn/vpn.sh`.

## How it notices

Every `VPN_CHECK_INTERVAL` seconds (15 by default) the supervisor checks the tunnel:

| VPN | Healthy when | Repaired in place |
|---|---|---|
| OpenVPN | Its management interface reports `CONNECTED` | When the OpenVPN process has exited, it is started again with the same pinned configuration |
| WireGuard | The last handshake is at most `WIREGUARD_HANDSHAKE_MAX_AGE` seconds old (180) | When `wg0` is gone, it is created again with the same configuration |

WireGuard's handshake age tells only when the tunnel carries traffic, so it needs a keepalive. The container adds `PersistentKeepalive = 25` (`WIREGUARD_KEEPALIVE`) to peers that set none; with `WIREGUARD_KEEPALIVE=0` and no keepalive in the file, the check looks at the interface only, and says so in the log at start.

The same check looks at qBittorrent's WebUI and, when it is enabled, Privoxy, which it restarts if it has exited. Each check writes the health record that [`qbtvpn-healthcheck`](../../reference/commands/#qbtvpn-healthcheck) reports to Docker.

## While it is down

Nothing leaks: the [kill switch](../the-kill-switch/) does not depend on the tunnel being up. With the tunnel interface gone, its routes go with it, and traffic toward the container's gateway is refused. qBittorrent keeps running; its connections simply fail until the tunnel returns.

The log says once that the tunnel is down, and once that it recovered. These lines come from the end-to-end tests, which delete `wg0` while the container runs with `VPN_CHECK_INTERVAL=3`:

```text
2026-11-26 08:41:06 [warn] vpn: wg0 is gone; recreating it
2026-11-26 08:41:06 [info] wireguard: wg0 removed
2026-11-26 08:41:06 [info] wireguard: using the kernel module
2026-11-26 08:41:06 [info] wireguard: wg0 up, mtu 1420, addresses 10.13.0.2/32
2026-11-26 08:41:06 [warn] vpn: tunnel down (wg0 is gone; recreating it); traffic stays blocked while it recovers
2026-11-26 08:41:09 [info] vpn: recovered after 3 s (wireguard handshake age 3)
```

Over OpenVPN, with the OpenVPN process killed, the same test logs:

```text
2026-11-26 08:45:57 [warn] vpn: openvpn process exited; restarting it
2026-11-26 08:45:57 [warn] vpn: tunnel down (openvpn process exited; restarting it); traffic stays blocked while it recovers
2026-11-26 08:46:01 [info] vpn: recovered after 4 s (openvpn CONNECTED)
```

## When it gives up

A tunnel down for `VPN_RECOVERY_TIMEOUT` seconds (300 by default) stops the container with status 1:

```text
2026-11-26 08:44:29 [warn] vpn: tunnel down (wireguard handshake age 183); traffic stays blocked while it recovers
2026-11-26 08:45:15 [error] vpn: down for 46 s, past VPN_RECOVERY_TIMEOUT=45; stopping so the restart policy starts afresh
```

Those lines come from the end-to-end tests, which stop the WireGuard server and set `VPN_RECOVERY_TIMEOUT=45`: the handshake ages past 180 seconds, and 46 seconds later the container gives up. The container stops in the same order as for `docker stop`: port forwarding and Privoxy first, then qBittorrent, which saves its resume data, then the VPN. With `restart: unless-stopped`, Docker starts it again from scratch, which resolves the VPN servers again, picks a new random configuration with `VPN_CONFIG_RANDOM=yes`, and sets up port forwarding again.

`VPN_RECOVERY_TIMEOUT=0` never stops the container: it keeps repairing the tunnel in place for as long as it takes.

## At the first start

The first connection gets `VPN_CONNECT_TIMEOUT` seconds (120). When it does not come, the container stops and says why:

| Message | Meaning |
|---|---|
| `[error] openvpn: last management interface reply: <reply>` | The state OpenVPN reached, from its management interface, just before the next line |
| `[error] vpn: no connection within <seconds> s (VPN_CONNECT_TIMEOUT)` | No connection in time: wrong credentials, a blocked port or a dead server; the VPN's own lines above say which |
| `[error] openvpn: exited before connecting; its log lines above say why` | OpenVPN stopped by itself, so the container stops at once |
