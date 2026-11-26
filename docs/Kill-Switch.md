# The kill switch

The firewall controls what may leave the container. It is loaded before any VPN process runs and is never opened again, so a VPN that stops, crashes or reconnects cannot let traffic out another way.

## Order at start-up

1. **Lockdown.** Every chain drops by default. Loopback and replies to existing connections are allowed, and so is DNS from root to the resolvers Docker configured, because the VPN server names must be resolved once.
2. **Pinning.** Each OpenVPN `remote` and WireGuard `Endpoint` name is resolved and written into a private copy of the configuration as an address. The VPN never needs DNS outside the tunnel again.
3. **Final rules,** loaded in one atomic `iptables-restore` per address family:
   - anything may leave through the tunnel (`tun0` or `wg0`);
   - outside the tunnel, only packets to each pinned server address on its port and protocol, and never from qBittorrent's user;
   - traffic to the container's own Docker networks and to `LAN_NETWORK`;
   - DNS (ports 53 and 853) is dropped everywhere but the tunnel, apart from `NAME_SERVERS` entries on a local network;
   - Docker's resolver at 127.0.0.11 is dropped (`VPN_BLOCK_DOCKER_DNS`);
   - inbound, the WebUI and `VPN_INPUT_PORTS` from local networks only, and on the tunnel only qBittorrent's listen port;
   - IPv6 leaves only through the tunnel. Without a working `ip6tables`, IPv6 addresses and routes are removed instead, and the container refuses to start if they cannot be.
4. **VPN, DNS, qBittorrent.** The VPN starts, `/etc/resolv.conf` is pointed at the VPN's servers, and qBittorrent starts bound to the tunnel interface. OpenVPN routes all IPv4 traffic into the tunnel, and IPv6 too when the server assigns an IPv6 address; redirect options in the configuration or pushed by the server are not used.

If the tunnel interface disappears, its routes go with it. Traffic then routes toward the container's own gateway, where the firewall refuses it.

## Check it yourself

```bash
docker exec qbittorrentvpn qbtvpn-status
docker exec qbittorrentvpn iptables-nft -S
docker exec qbittorrentvpn sh -c 'curl -s --interface eth0 --max-time 5 https://example.com || echo blocked'
```

`qbtvpn-status` prints the tunnel, the public address seen through it, the DNS servers, the forwarded port and the firewall policy. On hosts whose Docker uses legacy iptables, read the rules with `iptables-legacy -S`.

## What the tests prove

`tests/e2e/run.sh` runs the image against WireGuard and OpenVPN servers in containers. A tcpdump on the container's network records every packet it sends. A run fails if any of them is not VPN transport to the server or a reply from the WebUI, including while the tunnel interface is deleted, the VPN process is killed, or the server is down.
