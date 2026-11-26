---
title: Forward a port
weight: 4
---

Peers can only connect to you when the VPN provider forwards a port to the container. With one, qBittorrent can upload to and download from peers that also sit behind NAT, which is most of them.

The forwarded port is opened on the tunnel and given to qBittorrent while it runs, through its WebAPI with an API key the container creates (shown in the WebUI under Options, WebUI). Nothing restarts. The default `VPN_PORT_FORWARDING=auto` uses PIA's port API for PIA's OpenVPN files and otherwise sends one NAT-PMP request, which ProtonVPN answers.

## ProtonVPN

Use a P2P server. For OpenVPN, add `+pmp` to the username (`VPN_USERNAME=name+pmp`). For WireGuard, download the configuration with NAT-PMP turned on. `auto` finds the port; `protonvpn` forces it.

## Private Internet Access

Use a region that allows port forwarding; PIA lists them, and US regions do not. `auto` recognizes PIA's OpenVPN files and calls PIA's port API with `VPN_USERNAME` and `VPN_PASSWORD`. The signed port is kept in `/config/openvpn/.pia-portforward.json`, so restarts reuse it until PIA expires it. Over WireGuard, set `VPN_PORT_FORWARDING=pia`, `PIA_PF_HOSTNAME` (the server's name) and `PIA_PF_GATEWAY` (its tunnel gateway).

## Other NAT-PMP providers

Set `VPN_PORT_FORWARDING=natpmp`, and `VPN_PORT_FORWARDING_GATEWAY` if the gateway is not the tunnel's. The container asks the gateway to map qBittorrent's listen port, and renews the mapping every `NATPMP_RENEW_INTERVAL` seconds.

`natpmpc` refuses a gateway that reports a private, shared (`100.64.0.0/10`) or documentation address as its public address; the log then names `invalid Public IP address`.

## A fixed port from the provider's dashboard

Set `INCOMING_PORT` to the port the provider assigned, and `VPN_PORT_FORWARDING=off`. The port is opened on the tunnel and written to qBittorrent's settings at start.

## Check it

```bash
docker exec qbittorrentvpn qbtvpn-status
```

The port forwarding section shows the forwarded port, and the firewall section shows it open on the tunnel; see [Commands](../../reference/commands/#qbtvpn-status). qBittorrent's connection status icon turns green once peers connect in.

The log names the port when it is mapped, as in this line from the end-to-end tests:

```text
2026-11-26 08:03:50 [info] nat-pmp: forwarded port 40123 from 10.13.0.1
```

When a NAT-PMP mapping fails, the log gives `natpmpc`'s reason once, and again only when the reason changes or a working mapping is lost. The container retries every 10 seconds; `DEBUG=yes` logs every attempt with `natpmpc`'s full output.
