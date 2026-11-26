# Troubleshooting

Start with the log and the status tool:

```bash
docker logs qbittorrentvpn
docker exec qbittorrentvpn qbtvpn-status
```

Set `DEBUG=yes` to trace every start-up command.

| Log line | Cause and fix |
|---|---|
| `interface docker0 belongs to the host` | The container runs with host networking. Use a bridge network. |
| `no iptables backend works` | Add `--cap-add NET_ADMIN`. On very old kernels, try `FIREWALL_BACKEND=legacy`. |
| `/dev/net/tun is missing and cannot be created` | Add `--device /dev/net/tun`. |
| `no VPN configuration` | Put the provider's file in `/config/openvpn` or `/config/wireguard`. |
| `requires a username and password` | Set `VPN_USERNAME` and `VPN_PASSWORD`. |
| `could not resolve` | The container's own DNS cannot resolve the VPN server; check the host's DNS, or put addresses in the configuration. |
| `no connection within 120 s` | Wrong credentials, a blocked port, or a dead server. The OpenVPN or WireGuard lines above it say which; for OpenVPN, the `last management interface reply` line just before it shows the state it reached. |
| `kernel refused a WireGuard interface` | The host kernel has no WireGuard module; `wireguard-go` is used unless `WIREGUARD_USERSPACE=no`. |
| `nat-pmp: no mapping from` | The reason is in brackets. `the gateway does not support nat-pmp` means the server or the configuration has no port forwarding; for ProtonVPN, use a P2P server and `+pmp`. See [Port forwarding](Port-Forwarding.md). |
| `/downloads is not writable` | Set `PUID`/`PGID` to the folder's owner, or change its ownership. |
| `down for ... past VPN_RECOVERY_TIMEOUT` | The tunnel stayed down; the restart policy starts the container again. |

## The WebUI does not load

- From another machine, `LAN_NETWORK` must include that machine's network.
- Behind a reverse proxy that changes the `Host` header, set `WEBUI_CSRF_PROTECTION=no` or configure the proxy to pass the header.
- If the WebUI port is not 8080, set `WEBUI_PORT` and publish that same port.

## Other containers cannot reach this one's services

Containers that use `network_mode: service:qbittorrentvpn` share its firewall. Accept their ports from the LAN with `VPN_INPUT_PORTS`. Names of other containers do not resolve inside it while `VPN_BLOCK_DOCKER_DNS=yes`; use addresses, or `extra_hosts`.
