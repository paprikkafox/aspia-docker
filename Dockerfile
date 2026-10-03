# syntax=docker/dockerfile:1
#
# Aspia 3.x — Router + Relay container image
# =====================================================================================
# This image does NOT compile Aspia. It installs the official, pre-built Linux packages
# (.deb) published on the dchapyshev/aspia GitHub releases and runs the bundled
# `aspia_router` and `aspia_relay` binaries.
#
# The expected SHA-256 of every package is read from the GitHub release metadata at build
# time and checked after download; the hashes can be pinned explicitly instead (see the
# build args below). No source build, no vcpkg, no toolchain.
#
# Native Linux packages are published for x86_64 only, therefore this image is
# linux/amd64. The third-party libraries (Qt, OpenSSL, protobuf, ...) are statically
# linked into the binaries; only the C/C++ runtime, dbus and PAM are needed at runtime.
#
# The upstream Linux build is tested on Ubuntu 22.04 (glibc 2.35). Debian 12 (glibc 2.36)
# is used here as a smaller, ABI-compatible base. If a future build ever needs the exact
# runtime toolchain, switch DEBIAN_VERSION to a base carrying the same glibc/Libstdc++.
# =====================================================================================

ARG DEBIAN_VERSION=12


# -------------------------------------------------------------------------------------
# Stage 1 — fetch and verified-unpack the official release packages
# -------------------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION}-slim AS fetch

# Version of the release to install (without the leading "v").
ARG ASPIA_VERSION=3.0.23

ARG ASPIA_RELEASES_URL=https://github.com/dchapyshev/aspia/releases/download
ARG ASPIA_API_URL=https://api.github.com

# Optional: pin the expected SHA-256 of each package (hex, without the "sha256:" prefix).
# When left empty the digest is taken from the GitHub release metadata for ASPIA_VERSION.
# Either way the downloaded file is verified against the value that is used.
ARG ROUTER_DEB_SHA256=""
ARG RELAY_DEB_SHA256=""

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl jq; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /pkgs /rootfs; \
    base="${ASPIA_RELEASES_URL}/v${ASPIA_VERSION}"; \
    router_name="aspia-router-${ASPIA_VERSION}-x86_64.deb"; \
    relay_name="aspia-relay-${ASPIA_VERSION}-x86_64.deb"; \
    router_sha="${ROUTER_DEB_SHA256}"; \
    relay_sha="${RELAY_DEB_SHA256}"; \
    if [ -z "$router_sha" ] || [ -z "$relay_sha" ]; then \
        api="${ASPIA_API_URL}/repos/dchapyshev/aspia/releases/tags/v${ASPIA_VERSION}"; \
        curl -fsSL -H "Accept: application/vnd.github+json" "$api" -o /pkgs/release.json; \
        if [ -z "$router_sha" ]; then \
            router_sha="$(jq -r --arg n "$router_name" \
                '.assets[] | select(.name==$n) | .digest // empty' /pkgs/release.json)"; \
        fi; \
        if [ -z "$relay_sha" ]; then \
            relay_sha="$(jq -r --arg n "$relay_name" \
                '.assets[] | select(.name==$n) | .digest // empty' /pkgs/release.json)"; \
        fi; \
    fi; \
    router_sha="${router_sha#sha256:}"; \
    relay_sha="${relay_sha#sha256:}"; \
    [ -n "$router_sha" ] || { echo "ERROR: no SHA-256 for $router_name in the release metadata; pass ROUTER_DEB_SHA256" >&2; exit 1; }; \
    [ -n "$relay_sha" ]  || { echo "ERROR: no SHA-256 for $relay_name in the release metadata; pass RELAY_DEB_SHA256" >&2; exit 1; }; \
    curl -fsSL -o /pkgs/router.deb "${base}/${router_name}"; \
    curl -fsSL -o /pkgs/relay.deb  "${base}/${relay_name}"; \
    echo "${router_sha}  /pkgs/router.deb" | sha256sum -c -; \
    echo "${relay_sha}  /pkgs/relay.deb"  | sha256sum -c -; \
    dpkg-deb --extract /pkgs/router.deb /rootfs; \
    dpkg-deb --extract /pkgs/relay.deb  /rootfs; \
    test -x /rootfs/usr/bin/aspia_router; \
    test -x /rootfs/usr/bin/aspia_relay


# -------------------------------------------------------------------------------------
# Stage 2 — minimal runtime
# -------------------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION}-slim AS runtime

ARG ASPIA_VERSION=3.0.23

LABEL org.opencontainers.image.title="Aspia Router + Relay" \
      org.opencontainers.image.description="Aspia 3.x Router and Relay NAT-traversal servers" \
      org.opencontainers.image.version="${ASPIA_VERSION}" \
      org.opencontainers.image.url="https://aspia.org/" \
      org.opencontainers.image.source="https://github.com/dchapyshev/aspia" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

# Runtime dependencies needed by the statically linked binaries (see the upstream
# installer/linux/build_packages.sh dependency calculation): the C/C++ runtime, dbus and
# PAM. gosu drops privileges, tini reaps and forwards signals, netcat powers HEALTHCHECK.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libstdc++6 \
        libgcc-s1 \
        libdbus-1-3 \
        libpam0g \
        ca-certificates \
        tini \
        gosu \
        netcat-openbsd; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --gid 1000 aspia; \
    useradd  --uid 1000 --gid aspia --no-create-home --home-dir /var/lib/aspia \
             --shell /usr/sbin/nologin aspia; \
    install -d -o aspia -g aspia -m 0750 /etc/aspia /var/lib/aspia /var/log/aspia /run/aspia

# Binaries are placed where the upstream packages install them.
COPY --from=fetch /rootfs/usr/bin/aspia_router /usr/bin/aspia_router
COPY --from=fetch /rootfs/usr/bin/aspia_relay  /usr/bin/aspia_relay

COPY docker-entrypoint.sh   /usr/local/bin/docker-entrypoint.sh
COPY docker-healthcheck.sh  /usr/local/bin/docker-healthcheck.sh
RUN chmod 0755 /usr/bin/aspia_router /usr/bin/aspia_relay \
               /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-healthcheck.sh

# Container-friendly defaults: log to the container's stdout instead of files. These are
# image defaults; the service configuration itself lives in /etc/aspia and never requires
# any environment variable (see docker-entrypoint.sh).
ENV ASPIA_VERSION="${ASPIA_VERSION}" \
    ASPIA_ROLE="all" \
    ASPIA_LOG_TO_STDOUT="1" \
    ASPIA_LOG_TO_FILE="0" \
    ASPIA_LOG_LEVEL="1" \
    LANG="C.UTF-8"

# Router: 8060/8061 hosts (legacy/v3), 8062 clients, 8063 relays, 8065/udp STUN.
# Relay: 8070 peers.
EXPOSE 8060/tcp 8061/tcp 8062/tcp 8063/tcp 8065/udp 8070/tcp

STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["/usr/local/bin/docker-healthcheck.sh"]

# tini is PID 1; the entrypoint prepares config, drops privileges and starts the service(s).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["all"]
