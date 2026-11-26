---
title: qBittorrent VPN
layout: hextra-home
---

{{< hextra/hero-headline >}}
qBittorrent VPN
{{< /hextra/hero-headline >}}

{{< hextra/hero-subtitle >}}
qBittorrent built from source, reachable only through an OpenVPN or WireGuard tunnel behind a firewall that is closed before the VPN starts and stays closed if it drops.
{{< /hextra/hero-subtitle >}}

{{< hextra/hero-button text="Get started" link="docs/tutorials/getting-started/" >}}

{{< hextra/feature-grid >}}
  {{< hextra/feature-card title="Always current" subtitle="Every image compiles the newest qBittorrent and libtorrent releases from source, the qBittorrent tarball checked against its signature. A new release is published within a day." >}}
  {{< hextra/feature-card title="No leaks" subtitle="Torrent traffic, DNS and IPv6 leave only through the tunnel. The end-to-end tests record every packet and fail on any that does not." >}}
  {{< hextra/feature-card title="OpenVPN and WireGuard" subtitle="OpenVPN 2.7 and WireGuard, with a userspace WireGuard for kernels without the module. A dropped tunnel recovers in place." >}}
  {{< hextra/feature-card title="Port forwarding" subtitle="ProtonVPN and other NAT-PMP providers, Private Internet Access and fixed ports, applied to qBittorrent while it runs." >}}
  {{< hextra/feature-card title="Least privilege" subtitle="qBittorrent and Privoxy run with no Linux capabilities, and OpenVPN with only CAP_NET_ADMIN, each as its own user." >}}
  {{< hextra/feature-card title="Configured by environment" subtitle="Every setting comes from a Docker environment variable, and any qBittorrent or Privoxy option can be set the same way." >}}
{{< /hextra/feature-grid >}}
