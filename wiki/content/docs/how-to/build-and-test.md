---
title: Build and test
weight: 11
---

## Build the image

```bash
git clone https://github.com/MarkusMcNugen/docker-qBittorrentvpn.git
cd docker-qBittorrentvpn
docker buildx build --build-arg "$(bash build/resolve-qt.sh)" -t qbittorrentvpn:dev .
```

The build resolves the newest qBittorrent and libtorrent releases, checks their signatures and digests, and compiles both, which takes a while on the first run; later builds reuse Docker's cache until a version changes. `build/resolve-qt.sh` pins the compile to the Qt that Alpine ships for your architecture. Every argument, such as an older libtorrent series or a fixed qBittorrent release, is in [Build arguments](../../reference/build-arguments/).

To stay clear of GitHub's API rate limit, pass a token:

```bash
GITHUB_TOKEN=<token> docker buildx build --secret id=github_token,env=GITHUB_TOKEN \
  --build-arg "$(bash build/resolve-qt.sh)" -t qbittorrentvpn:dev .
```

## Run the tests

```bash
bash tests/run.sh unit qbittorrentvpn:dev
bash tests/run.sh e2e qbittorrentvpn:dev
```

The unit tests run inside the image, so they need only Docker and an image built with Python, the default. The end-to-end tests need a Docker host with the WireGuard kernel module; they start test servers in containers and record the image's traffic with tcpdump. One scenario runs alone by name, such as `bash tests/run.sh e2e qbittorrentvpn:dev openvpn`. What each suite checks, and the output to expect, is in [Tests](../../reference/tests/).

Pull requests and every branch but `main` run the same build and both suites on amd64 and arm64 in GitHub Actions.
