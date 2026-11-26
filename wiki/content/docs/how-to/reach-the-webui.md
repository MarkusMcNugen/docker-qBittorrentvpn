---
title: Reach the WebUI
weight: 3
---

The firewall accepts the WebUI only from `LAN_NETWORK` and the container's own Docker networks. Nothing reaches it through the tunnel.

## From your LAN

Set `LAN_NETWORK` to the network your browser is on, publish the port, and open `http://<docker host>:8080`:

```yaml
environment:
  LAN_NETWORK: 192.168.1.0/24
ports:
  - 8080:8080
```

Several networks are separated by commas: `192.168.1.0/24,10.8.0.0/24`. Traffic to these networks also leaves outside the tunnel, so name only networks you trust; `0.0.0.0/0` is refused, because it would route everything around the VPN. Without `LAN_NETWORK`, the WebUI answers only containers on the same Docker network.

## Log in

With `WEBUI_USERNAME` and `WEBUI_PASSWORD` set, those are the login, applied at every start. Without a password, qBittorrent prints a temporary one in the log on its first start:

```bash
docker logs qbittorrentvpn 2>&1 | grep -i 'temporary password'
```

Set your own under Options, WebUI, or in the environment.

## On another port

`WEBUI_PORT` changes the port qBittorrent listens on and the one the firewall opens. Publish the same port on both sides:

```yaml
environment:
  WEBUI_PORT: "9090"
ports:
  - 9090:9090
```

Mapping a different outside port, such as `9090:8080`, also works; then only the outside port changes.

## Behind a reverse proxy

The proxy must reach the container from a network `LAN_NETWORK` names, or from the Docker network the two share. qBittorrent's CSRF protection refuses requests whose `Host` or `Origin` it does not expect: pass the original `Host` header through, or set `WEBUI_CSRF_PROTECTION: "no"` when the proxy cannot. Further WebUI settings, such as trusted reverse proxies and host header validation, can be set with [`QBT_CONF_`](../change-qbittorrent-settings/).

## When it does not load

- `docker exec qbittorrentvpn qbtvpn-healthcheck` says `WebUI not responding on port <port>`: qBittorrent has not started, or listens elsewhere; the log says which.
- The page times out from another machine: that machine's network is not in `LAN_NETWORK`.
- The page loads but login fails with the right password: a reverse proxy changes the `Host` header; see above.
