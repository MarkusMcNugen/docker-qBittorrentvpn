---
title: Tests
weight: 7
---

`tests/run.sh` runs both suites against an image. GitHub Actions runs them on amd64 and arm64 for every branch but `main`, and again before any image is published.

```bash
bash tests/run.sh unit [IMAGE]
bash tests/run.sh e2e [IMAGE] [SCENARIO...]
```

`IMAGE` defaults to `qbittorrentvpn:dev`. Each exits with status 0 when every test passes and 1 otherwise. How to build an image to test is in [Build and test](../../how-to/build-and-test/).

## Unit tests

85 tests in `tests/unit/`, run inside the image so they use its own bash, busybox, awk, iptables and Privoxy. Each test runs in a separate bash process, and `harness.sh` proves the runner fails a test whose first assertion fails.

| File | Tests | What it covers |
|---|---|---|
| `common.sh` | 7 | Booleans, lists, `_FILE` secrets and address arithmetic, the arithmetic checked against Python's `ipaddress` |
| `config.sh` | 7 | Defaults, the 1.x spellings, list parsing, refusals, `_FILE` secrets, Privoxy's options |
| `firewall.sh` | 14 | The rendered rulesets line by line, and the kernel's `iptables-restore --test` accepting every one, with Privoxy off and on |
| `harness.sh` | 1 | The runner itself |
| `ini.sh` | 8 | Editing qBittorrent.conf |
| `network.sh` | 4 | Telling whether a new interface can take IPv6 |
| `openvpn.sh` | 2 | Routing IPv6 into the tunnel |
| `openvpn_config.sh` | 12 | Sanitizing and pinning OpenVPN configurations |
| `portforward.sh` | 10 | NAT-PMP through the image's `natpmpc`, and PIA's API from PIA's published examples |
| `privoxy.sh` | 6 | Privoxy's configuration, checked by Privoxy itself, and its log lines |
| `qbittorrent.sh` | 10 | qBittorrent.conf as the container writes it for 5.3 and for earlier releases, migration from 1.x, `QBT_CONF_` against the enforced keys, the WebUI password hash checked against Python's `hashlib`, and the WebAPI key |
| `wireguard.sh` | 4 | Parsing WireGuard configurations, checked by `wg` |

Output, from the run that checked release 2.1.1:

```text
ok    common.sh test_bool_value_spellings
ok    common.sh test_cidr_contains_matches_python
ok    common.sh test_cidr_normalize_matches_python
...
ok    privoxy.sh test_conf_options_come_after_the_defaults
ok    privoxy.sh test_default_config_uses_the_package_files_and_listens_on_every_address
ok    privoxy.sh test_prepare_passes_privoxys_own_check_and_names_the_firewall_user
...
ok    wireguard.sh test_wg_accepts_the_stripped_configuration

85 passed, 0 failed
```

## End-to-end tests

`tests/e2e/run.sh` needs a Docker host with the WireGuard kernel module. A test double, built from `tests/e2e/server`, plays the VPN provider and the internet: WireGuard and OpenVPN servers on a `lan` network and a `wan` network, with NAT, DNS inside the tunnel and a NAT-PMP responder, and a web server on each network. The image runs on `lan` only. tcpdump on the `lan` bridge records every packet; a packet from the container that is neither VPN transport to the server nor a WebUI or Privoxy reply fails the run as a leak.

| Scenario | Checks | What it proves |
|---|---|---|
| `wireguard` | 49 | Traffic, DNS and IPv6 only through the tunnel, each refusal next to a control showing the same request answered without the firewall; the WebUI login; qBittorrent's binding and privileges; NAT-PMP port forwarding; Privoxy's traffic through the tunnel and its refusals; `wg0` deleted and recreated in place; the server down and back; the health check turning unhealthy, then the exit after `VPN_RECOVERY_TIMEOUT` in shutdown order |
| `openvpn` | 39 | The same traffic and DNS checks over OpenVPN, IPv6 assigned by the server routed into the tunnel, OpenVPN's user and capability, Privoxy off by default, OpenVPN killed and restarted in place, the server down and back, and a clean `docker stop` |
| `openvpn_no_ipv6` | 10 | OpenVPN connecting in a container with IPv6 switched off while the server pushes IPv6, with no IPv6 on `tun0` |

Every scenario also fails on any warning or error in the container's log or the test server's. Before its refusal checks, a scenario proves that the wrapper they use fails a command that succeeds, so a refusal check cannot pass without running; a deleted `wg0` and a killed OpenVPN are each confirmed by the line the container logs when it repairs them. Names given after the image run only those scenarios.

`E2E_LOG_DIR=<directory>` keeps each scenario's container log and `qbtvpn-status` output there; the wiki's sample output comes from those files.

Output, from the run that checked release 2.1.1:

```text
08:40:19 building the test double
08:40:22 == WireGuard
08:40:34 PASS WireGuard client became healthy
08:40:35 qbtvpn-healthcheck: ok: wireguard handshake age 5
08:40:35 PASS control: fails_quickly does not pass a command that succeeds
08:40:35 PASS egress goes through the tunnel (target sees 172.31.251.2)
08:40:35 PASS resolv.conf points at the tunnel DNS 10.13.0.1
...
08:46:46 PASS docker stop exits cleanly
08:46:47 PASS no packet left outside the tunnel
08:46:48 98 passed, 0 failed
```
