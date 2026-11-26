---
title: Troubleshoot
weight: 12
---

Start with the log and the status command:

```bash
docker logs qbittorrentvpn
docker exec qbittorrentvpn qbtvpn-status
```

`DEBUG=yes` traces every command the entrypoint runs. Every message the container prints is listed, by stage, in [Logs](../../reference/logs/).

## A line in the log

| Log line | Cause and fix |
|---|---|
| `interface docker0 belongs to the host` | The container runs with host networking. Use a bridge network. |
| `no iptables backend works` | Add `--cap-add NET_ADMIN`. On very old kernels, try `FIREWALL_BACKEND=legacy`. |
| `/dev/net/tun is missing and cannot be created` | Add `--device /dev/net/tun`. |
| `no VPN configuration` | Put the provider's file in `/config/openvpn` or `/config/wireguard`. |
| `both /config/openvpn and /config/wireguard hold configurations` | Set `VPN_TYPE` to the one to use. |
| `requires a username and password` | Set `VPN_USERNAME` and `VPN_PASSWORD`. |
| `could not resolve` | The container's own DNS cannot resolve the VPN server; check the host's DNS, or put addresses in the configuration. |
| `no connection within 120 s` | Wrong credentials, a blocked port, or a dead server. The OpenVPN or WireGuard lines above it say which; for OpenVPN, the `last management interface reply` line just before it shows the state it reached. |
| `kernel refused a WireGuard interface` | The host kernel has no WireGuard module; `wireguard-go` is used unless `WIREGUARD_USERSPACE=no`. |
| `wireguard: unknown key` | The WireGuard file has a key the container does not know, often a typing error; see [Set up WireGuard](../set-up-wireguard/#what-the-container-reads). |
| `IPv6 endpoint ... is not supported` | Use the provider's IPv4 endpoint for the server. |
| `nat-pmp: no mapping from` | The reason is in brackets. `the gateway does not support nat-pmp` means the server or the configuration has no port forwarding; for ProtonVPN, use a P2P server and `+pmp`. `invalid Public IP address` means the gateway reported a private or reserved address. See [Forward a port](../forward-a-port/). |
| `/downloads is not writable` | Set `PUID`/`PGID` to the folder's owner, or change its ownership. |
| `privoxy: not started` | Privoxy runs only where its traffic can be kept in the tunnel: not with `VPN_ENABLED=no`, and not on a kernel without the iptables owner match. The rest of the line says which. |
| `privoxy: the configuration was refused` | A `PRIVOXY_CONF_` option, or a file in `/config/privoxy`, that Privoxy rejects; the rest of the line is Privoxy's reason. |
| `down for ... past VPN_RECOVERY_TIMEOUT` | The tunnel stayed down; the restart policy starts the container again. See [When the tunnel drops](../../explanation/when-the-tunnel-drops/). |

## The WebUI does not load

- From another machine, `LAN_NETWORK` must include that machine's network.
- Behind a reverse proxy that changes the `Host` header, set `WEBUI_CSRF_PROTECTION=no` or configure the proxy to pass the header.
- If the WebUI port is not 8080, set `WEBUI_PORT` and publish that same port.

More in [Reach the WebUI](../reach-the-webui/).

## Other containers cannot reach this one's services

Containers that use `network_mode: service:qbittorrentvpn` share its firewall. Accept their ports from the LAN with `VPN_INPUT_PORTS`. Names of other containers do not resolve inside it while `VPN_BLOCK_DOCKER_DNS=yes`; use addresses, or `extra_hosts`. A joined container also loses its network when this one restarts on its own, until it is restarted too. [Run other containers through the tunnel](../run-other-containers-through-the-tunnel/) has a full example.

## Downloads are slow or stall

- Without a forwarded port, peers behind NAT cannot connect to you, which is most of them; see [Forward a port](../forward-a-port/). `qbtvpn-status` shows whether one is set.
- The tunnel itself sets the ceiling: try another server of your provider, or WireGuard instead of OpenVPN.
- qBittorrent must be bound to the tunnel; `qbtvpn-status` shows `Session\Interface` as `tun0` or `wg0`.
