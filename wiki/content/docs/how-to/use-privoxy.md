---
title: Use Privoxy
weight: 5
---

Privoxy is an HTTP proxy in the image, off by default. Other applications on your LAN, such as a browser or an indexer, can send their web traffic through it, and it leaves only through the tunnel, like qBittorrent's.

## Turn it on

```yaml
environment:
  PRIVOXY_ENABLED: "yes"
ports:
  - 8080:8080
  - 8118:8118
```

Then point the application's HTTP and HTTPS proxy at `http://<docker host>:8118`. HTTPS goes through as an encrypted tunnel; Privoxy sees only the host name. `PRIVOXY_PORT` changes the port.

The firewall accepts the port from `LAN_NETWORK` and the container's own Docker networks only. Privoxy itself may only open connections into the tunnel: it cannot reach your LAN, other containers, or anything on the container's loopback, the WebUI included, so do not use it to reach local services. It starts once the VPN is up, never with `VPN_ENABLED=no`, and is restarted if it exits.

## Check it

```bash
curl -x http://<docker host>:8118 https://api.ipify.org
docker exec qbittorrentvpn qbtvpn-status
```

The first prints the VPN's address, not yours. The status's privoxy section reads `listening on port 8118 (pid <pid>)`.

## Add your own rules

Privoxy's actions and filters can block, rewrite or let through requests by pattern. Put your own in `/config/privoxy/user.action` and `/config/privoxy/user.filter`; they replace the package's sample files of the same name, and are read at start, so restart the container after changing them. For example, to block a domain:

```text
{ +block{blocked by my rules} }
.ads.example.com
```

Privoxy's [actions manual](https://www.privoxy.org/user-manual/actions-file.html) describes the syntax.

## Set Privoxy options

`PRIVOXY_CONF_<option>` adds a line to Privoxy's main configuration: the option name is lowercased, and `_` reads as `-`. A multi-line value adds one line per line. For example, to log each request and its connection:

```yaml
environment:
  PRIVOXY_CONF_DEBUG: |
    1
    2
```

The log then shows each request, as in these lines from the end-to-end tests:

```text
2026-11-26 08:04:05 [info] privoxy: Request: target.e2e/cgi-bin/ip
2026-11-26 08:04:05 [info] privoxy: Connect: to target.e2e
2026-11-26 08:04:05 [info] privoxy: Connect: Connected to target.e2e[172.31.251.10]:80.
```

Privoxy checks its configuration at start: a configuration it refuses, such as one naming an actions file that does not exist, stops the container with `privoxy: the configuration was refused` and Privoxy's reason. The listen address is the one option you cannot set; it comes from `PRIVOXY_PORT`. Every option is in Privoxy's [configuration manual](https://www.privoxy.org/user-manual/config.html).
