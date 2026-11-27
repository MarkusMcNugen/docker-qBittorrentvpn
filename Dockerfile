# syntax=docker/dockerfile:1

ARG ALPINE_VERSION=3.24

# Resolves the qBittorrent and libtorrent releases and downloads their source
# tarballs: qBittorrent checked against its OpenPGP signature, both checked
# against the SHA-256 digests GitHub publishes for release assets.
FROM alpine:${ALPINE_VERSION} AS sources
ARG QBITTORRENT_VERSION=latest
ARG LIBTORRENT_SERIES=2.1
ARG LIBTORRENT_VERSION=latest
RUN apk add --no-cache bash ca-certificates curl gnupg jq tar xz
COPY build/resolve-versions.sh build/fetch-sources.sh /build/
COPY keys/ /keys/
RUN --mount=type=secret,id=github_token,env=GITHUB_TOKEN \
    chmod 0755 /build/resolve-versions.sh /build/fetch-sources.sh \
 && /build/fetch-sources.sh /src

# Compiles libtorrent (static) and qbittorrent-nox against Alpine's Qt 6,
# Boost and OpenSSL. QT_VERSION, from build/resolve-qt.sh, pins Qt and so puts
# it in this stage's cache key: a Qt update recompiles qBittorrent.
FROM alpine:${ALPINE_VERSION} AS builder
ARG BUILD_JOBS=
ARG QT_VERSION=
RUN apk add --no-cache \
        bash \
        boost-dev \
        build-base \
        cmake \
        linux-headers \
        openssl-dev \
        pax-utils \
        pkgconf \
        "qt6-qtbase-dev${QT_VERSION:+=${QT_VERSION}}" \
        "qt6-qtbase-private-dev${QT_VERSION:+=${QT_VERSION}}" \
        qt6-qttools-dev \
        samurai \
        zlib-dev
COPY --from=sources /src /src
COPY build/build.sh /build/build.sh
RUN chmod 0755 /build/build.sh && BUILD_JOBS="${BUILD_JOBS}" /build/build.sh

FROM alpine:${ALPINE_VERSION}
ARG INSTALL_PYTHON=yes
ARG QBITTORRENT_VERSION=latest
ARG LIBTORRENT_VERSION=latest
ARG IMAGE_VERSION=dev
ARG IMAGE_REVISION=unknown
ARG IMAGE_CREATED=unknown

LABEL org.opencontainers.image.title="qbittorrentvpn" \
      org.opencontainers.image.description="qBittorrent built from source, behind an OpenVPN or WireGuard tunnel with a fail-closed firewall" \
      org.opencontainers.image.source="https://github.com/MarkusMcNugen/docker-qBittorrentvpn" \
      org.opencontainers.image.licenses="GPL-3.0-only" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      io.github.markusmcnugen.qbittorrent.version="${QBITTORRENT_VERSION}" \
      io.github.markusmcnugen.libtorrent.version="${LIBTORRENT_VERSION}"

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

COPY --from=builder /out/ /

# apk upgrade comes first so the packages the base image ships, such as zlib,
# busybox and OpenSSL's libraries, get the Alpine branch's security fixes like
# the packages added here. Publish sets IMAGE_CREATED to the build's time, so
# there this step never comes from the build cache.
# The vpn user (873) runs OpenVPN and wireguard-go with only CAP_NET_ADMIN.
# The privoxy user (874) runs Privoxy with no capabilities; it is created
# before the package, whose install script would otherwise pick its id. The
# package installs its configuration files with a .new suffix.
RUN apk upgrade --no-cache \
 && addgroup -S -g 874 privoxy \
 && adduser -S -D -H -u 874 -G privoxy -h /var/log/privoxy -s /sbin/nologin privoxy \
 && apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        icu-data-en \
        iproute2 \
        iptables \
        iptables-legacy \
        jq \
        libnatpmp \
        netcat-openbsd \
        openssl \
        openvpn \
        privoxy \
        qt6-qtbase-sqlite \
        setpriv \
        tini \
        tzdata \
        wireguard-go \
        wireguard-tools-wg \
 && xargs apk add --no-cache </usr/local/share/qbtvpn/runtime-deps \
 && if ! sha256sum -c /usr/local/share/qbtvpn/qt-core.sha256; then \
      echo "qBittorrent was compiled against a Qt this stage does not have; build with QT_VERSION from build/resolve-qt.sh" >&2; \
      exit 1; \
    fi \
 && if [ "$INSTALL_PYTHON" = yes ]; then apk add --no-cache python3; fi \
 && addgroup -S -g 873 vpn \
 && adduser -S -D -H -u 873 -G vpn -h /run/qbtvpn -s /sbin/nologin vpn \
 && for f in /etc/privoxy/*.new; do mv "$f" "${f%.new}"; done \
 && [ "$(id -u privoxy)" = 874 ] \
 && privoxy --version \
 && qbittorrent-nox --version

COPY rootfs/ /

# Build contexts from Windows carry no Unix modes, so every mode is set here.
RUN chmod 0755 /usr/local/bin/qbtvpn-entrypoint /usr/local/bin/qbtvpn-healthcheck \
        /usr/local/bin/qbtvpn-status /usr/local/lib/qbtvpn/openvpn-hook \
 && chmod 0644 /usr/local/lib/qbtvpn/*.sh /usr/local/lib/qbtvpn/*.awk \
        /usr/local/share/qbtvpn/pia-ca.rsa.4096.crt \
 && bash -n /usr/local/bin/qbtvpn-entrypoint \
 && for f in /usr/local/lib/qbtvpn/*.sh; do bash -n "$f"; done

ENV LANG=C.UTF-8

EXPOSE 8080/tcp 8118/tcp 8999/tcp 8999/udp
VOLUME ["/config", "/downloads"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD ["/usr/local/bin/qbtvpn-healthcheck"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/qbtvpn-entrypoint"]
