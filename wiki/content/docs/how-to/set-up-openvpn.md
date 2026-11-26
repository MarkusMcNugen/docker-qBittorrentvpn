---
title: Set up OpenVPN
weight: 1
---

## Use your provider's file

Download an OpenVPN configuration from your provider, usually a `.ovpn` file per server, and put it in `/config/openvpn`. Files ending in `.conf` work too. Certificates and keys the file names by a relative path go next to it.

When the folder holds several files, the container uses the first by name and logs which. Choose one with `VPN_CONFIG`:

```yaml
environment:
  VPN_CONFIG: ch-zurich.ovpn
```

or let it pick one at random at every start with `VPN_CONFIG_RANDOM: "yes"`.

## Log in

Most providers ask for a username and password, which are often not your account's own; the provider's site names them "OpenVPN" or "service" credentials.

```yaml
environment:
  VPN_USERNAME: your-vpn-username
  VPN_PASSWORD: your-vpn-password
```

They can come from [Docker secrets](../use-docker-secrets/) instead. Setups from 1.x that keep them in `/config/openvpn/credentials.conf`, one per line, with `auth-user-pass credentials.conf` in the file, keep working. A file that asks for a password when neither is given stops the container with `the configuration requires a username and password`.

## What the container changes

Your file is never edited. The container works on a private copy, and logs every change it makes there:

- Each `remote` is resolved once and pinned to its addresses, so reconnects need no DNS outside the tunnel. `proto udp6` and `tcp6` are used over IPv4, the family the firewall pins.
- Options the container sets itself are removed: the device, the script hooks, logging, the management interface, and the user to run as. OpenVPN runs as its own user with only `CAP_NET_ADMIN`.
- `redirect-gateway` and `redirect-private` are removed, in the file and when the server pushes them. The container routes all IPv4 into the tunnel itself, and IPv6 too when the server assigns an address.
- Options OpenVPN 2.7 no longer has (`keysize`, `ncp-disable`, `key-method` and others) and Windows-only ones are dropped; `ns-cert-type` and `tls-remote` are translated to their replacements.

`<connection>` blocks are refused: write each server as its own `remote` line. Static-key (`secret`) configurations are refused, as OpenVPN 2.7 refuses them.

## Add OpenVPN options

`VPN_OPTIONS` adds command-line options, after all of the container's:

```yaml
environment:
  VPN_OPTIONS: --mssfix 1400 --sndbuf 524288
```

## Check it

```bash
docker logs qbittorrentvpn | grep openvpn:
docker exec qbittorrentvpn qbtvpn-status
```

The log names the configuration, each pinned server and `openvpn: connected`; the status's tunnel section ends with `openvpn: CONNECTED`. When the connection does not come within `VPN_CONNECT_TIMEOUT`, see [Troubleshoot](../troubleshoot/).
