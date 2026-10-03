#!/usr/bin/env bash
#
# Aspia Router / Relay container entrypoint.
#
# Design goals
# ------------
#   * Zero-configuration-by-volume: the .conf files under /etc/aspia are the source of
#     truth. They are NEVER modified unless the matching environment variable is set, so
#     you can keep router.conf/relay.conf (and the database) on an external volume and run
#     the container without passing a single ENV.
#   * Env-driven bootstrap: on a first start with no configuration, --create-config runs
#     and the values from the environment (if any) are written into the fresh files.
#   * Drop privileges to the unprivileged "aspia" user before starting the service(s).
#
# Roles (first argument, or ASPIA_ROLE):
#   router  run the Router only
#   relay   run the Relay only
#   all     run both in one container (default)
#
# Any other first argument is passed to aspia_router (e.g. `--version`). Extra arguments
# after a single role go to that role's binary (e.g. `relay --help`, `router --create-config`).
#
set -euo pipefail

# These paths match the defaults compiled into the binaries (BasePaths). Mount external
# volumes here; do not relocate them.
CONFIG_DIR="/etc/aspia"
DATA_DIR="/var/lib/aspia"
LOG_DIR="/var/log/aspia"

RUN_USER="${ASPIA_USER:-aspia}"
ROUTER_BIN="${ASPIA_ROUTER_BIN:-/usr/bin/aspia_router}"
RELAY_BIN="${ASPIA_RELAY_BIN:-/usr/bin/aspia_relay}"

ROUTER_CONF="$CONFIG_DIR/router.conf"
RELAY_CONF="$CONFIG_DIR/relay.conf"

GOSU="$(command -v gosu || true)"

log() { printf '%s [entrypoint] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
is_root() { [ "$(id -u)" -eq 0 ]; }

# -------------------------------------------------------------------------------------
# ini_get <file> <section> <key>
#   Print the value of key inside [section], or nothing if absent.
# -------------------------------------------------------------------------------------
ini_get() {
    local file="$1" section="$2" key="$3"
    [ -f "$file" ] || return 0
    awk -v section="$section" -v key="$key" '
        /^[[:space:]]*\[.*\][[:space:]]*$/ {
            name=$0
            sub(/^[[:space:]]*\[/, "", name)
            sub(/\][[:space:]]*$/, "", name)
            in_section=(name==section)
            next
        }
        in_section {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            if (line ~ ("^" key "[[:space:]]*=")) {
                sub(/^[^=]*=[[:space:]]*/, "", line)
                sub(/[[:space:]]*$/, "", line)
                print line
                exit
            }
        }
    ' "$file"
}

# -------------------------------------------------------------------------------------
# ini_set <file> <section> <key> <value>
#   Idempotently set key=value inside [section], preserving the rest of the file.
#   If nothing changes, the file is left untouched (owner, permissions and mtime kept).
# -------------------------------------------------------------------------------------
ini_set() {
    local file="$1" section="$2" key="$3" value="$4"
    local tmp
    tmp="$(mktemp)"

    if [ ! -f "$file" ]; then
        printf '[%s]\n%s=%s\n' "$section" "$key" "$value" > "$file"
        rm -f "$tmp"
        return
    fi

    awk -v section="$section" -v key="$key" -v value="$value" '
        function flush_pending() { if (in_section && !done) { print key "=" value; done=1 } }
        /^[[:space:]]*\[.*\][[:space:]]*$/ {
            flush_pending()
            name=$0
            sub(/^[[:space:]]*\[/, "", name)
            sub(/\][[:space:]]*$/, "", name)
            in_section=(name==section)
            if (in_section) found=1
            print
            next
        }
        {
            if (in_section) {
                line=$0
                sub(/^[[:space:]]*/, "", line)
                if (line ~ ("^" key "[[:space:]]*=")) {
                    if (!done) { print key "=" value; done=1 }
                    next
                }
            }
            print
        }
        END {
            flush_pending()
            if (!found) { print ""; print "[" section "]"; print key "=" value }
        }
    ' "$file" > "$tmp"

    if cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        return
    fi

    # Rewrite in place so ownership and permissions of the original file are kept.
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

run_as_user() {
    if is_root; then
        [ -n "$GOSU" ] || die "gosu not found and the entrypoint runs as root"
        gosu "$RUN_USER" "$@"
    else
        "$@"
    fi
}

exec_as_user() {
    if is_root; then
        [ -n "$GOSU" ] || die "gosu not found and the entrypoint runs as root"
        exec gosu "$RUN_USER" "$@"
    else
        exec "$@"
    fi
}

prepare_dirs() {
    if is_root; then
        install -d -o "$RUN_USER" -g "$RUN_USER" -m 0750 "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" /run/aspia
        # Friendly to volumes/bind mounts that arrive root-owned: make sure the service can write.
        chown -R "$RUN_USER:$RUN_USER" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" 2>/dev/null || true
    else
        mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" /run/aspia 2>/dev/null || true
    fi
}

# -------------------------------------------------------------------------------------
# Router
# -------------------------------------------------------------------------------------
init_router() {
    if [ ! -f "$ROUTER_CONF" ]; then
        log "no Router configuration found, creating the initial one (--create-config)"
        run_as_user "$ROUTER_BIN" --create-config >&2
        log "initial Router configuration, database and keys created"
    else
        log "using existing Router configuration: $ROUTER_CONF"
    fi

    apply_router_config
}

# Only writes a value when the matching environment variable is set; otherwise the file is
# left exactly as it is.
apply_router_config() {
    local f="$ROUTER_CONF"

    [ -n "${ASPIA_ROUTER_HOST_PORT:-}" ]        && ini_set "$f" host   port        "$ASPIA_ROUTER_HOST_PORT"
    [ -n "${ASPIA_ROUTER_LEGACY_HOST_PORT:-}" ] && ini_set "$f" host   legacy_port "$ASPIA_ROUTER_LEGACY_HOST_PORT"
    [ -n "${ASPIA_ROUTER_CLIENT_PORT:-}" ]      && ini_set "$f" client port        "$ASPIA_ROUTER_CLIENT_PORT"
    [ -n "${ASPIA_ROUTER_RELAY_PORT:-}" ]       && ini_set "$f" relay  port        "$ASPIA_ROUTER_RELAY_PORT"
    [ -n "${ASPIA_STUN_ENABLED:-}" ]            && ini_set "$f" stun   enabled     "$ASPIA_STUN_ENABLED"
    [ -n "${ASPIA_STUN_PORT:-}" ]               && ini_set "$f" stun   port        "$ASPIA_STUN_PORT"

    [ -n "${ASPIA_ROUTER_HOST_LISTEN_INTERFACE:-}" ]   && ini_set "$f" host   listen_interface "$ASPIA_ROUTER_HOST_LISTEN_INTERFACE"
    [ -n "${ASPIA_ROUTER_CLIENT_LISTEN_INTERFACE:-}" ] && ini_set "$f" client listen_interface "$ASPIA_ROUTER_CLIENT_LISTEN_INTERFACE"
    [ -n "${ASPIA_ROUTER_RELAY_LISTEN_INTERFACE:-}" ]  && ini_set "$f" relay  listen_interface "$ASPIA_ROUTER_RELAY_LISTEN_INTERFACE"

    [ -n "${ASPIA_ROUTER_HOST_WHITE_LIST:-}" ]   && ini_set "$f" host   white_list "$ASPIA_ROUTER_HOST_WHITE_LIST"
    [ -n "${ASPIA_ROUTER_CLIENT_WHITE_LIST:-}" ] && ini_set "$f" client white_list "$ASPIA_ROUTER_CLIENT_WHITE_LIST"
    [ -n "${ASPIA_ROUTER_RELAY_WHITE_LIST:-}" ]  && ini_set "$f" relay  white_list "$ASPIA_ROUTER_RELAY_WHITE_LIST"

    return 0
}

# -------------------------------------------------------------------------------------
# Relay
# -------------------------------------------------------------------------------------
# The Router writes its Relay public key to <config>/relay.pub. When the Relay shares the
# config volume it is read from there; otherwise set ASPIA_RELAY_ROUTER_PUBLIC_KEY or
# ASPIA_RELAY_ROUTER_PUBKEY_FILE, or provision public_key in relay.conf yourself.
resolve_router_public_key() {
    local pub_file="${ASPIA_RELAY_ROUTER_PUBKEY_FILE:-$CONFIG_DIR/relay.pub}"
    local timeout="${ASPIA_RELAY_PUBKEY_WAIT_TIMEOUT:-60}"
    local waited=0

    while [ ! -s "$pub_file" ]; do
        if [ "$waited" -ge "$timeout" ]; then
            die "Router public key not found at '$pub_file' after ${timeout}s. Mount the Router \
configuration directory (which contains relay.pub), set ASPIA_RELAY_ROUTER_PUBLIC_KEY, or set \
ASPIA_RELAY_ROUTER_PUBKEY_FILE."
        fi
        log "waiting for the Router public key ($pub_file)"
        sleep 2
        waited=$((waited + 2))
    done

    # The file holds the hex-encoded key; strip any surrounding whitespace/newline.
    tr -d '[:space:]' < "$pub_file"
}

init_relay() {
    if [ ! -f "$RELAY_CONF" ]; then
        log "no Relay configuration found, creating the initial one (--create-config)"
        run_as_user "$RELAY_BIN" --create-config >&2
    else
        log "using existing Relay configuration: $RELAY_CONF"
    fi

    apply_relay_config
}

apply_relay_config() {
    local f="$RELAY_CONF"

    # Router public key: env > existing file value > relay.pub (shared volume).
    local public_key="${ASPIA_RELAY_ROUTER_PUBLIC_KEY:-}"
    [ -n "$public_key" ] || public_key="$(ini_get "$f" router public_key)"
    if [ -z "$public_key" ]; then
        public_key="$(resolve_router_public_key)"
    fi
    [ -n "$public_key" ] || die "the Router public key is not set and relay.pub was not found"
    ini_set "$f" router public_key "$public_key"

    # Peer public address: env > existing file value (there is no way to guess it).
    local public_address="${ASPIA_RELAY_PEER_PUBLIC_ADDRESS:-}"
    [ -n "$public_address" ] || public_address="$(ini_get "$f" peer public_address)"
    [ -n "$public_address" ] || die "peer public_address is not set in $RELAY_CONF and \
ASPIA_RELAY_PEER_PUBLIC_ADDRESS is empty; set one of them to the address peers (Hosts and \
Clients) use to reach this Relay"
    ini_set "$f" peer public_address "$public_address"

    # Everything else is optional: applied only when the environment variable is set.
    [ -n "${ASPIA_RELAY_ROUTER_ADDRESS:-}" ]        && ini_set "$f" router address  "$ASPIA_RELAY_ROUTER_ADDRESS"
    [ -n "${ASPIA_RELAY_ROUTER_PORT:-}" ]           && ini_set "$f" router port     "$ASPIA_RELAY_ROUTER_PORT"
    [ -n "${ASPIA_RELAY_PEER_PORT:-}" ]             && ini_set "$f" peer   port     "$ASPIA_RELAY_PEER_PORT"
    [ -n "${ASPIA_RELAY_MAX_COUNT:-}" ]             && ini_set "$f" peer   max_count "$ASPIA_RELAY_MAX_COUNT"
    [ -n "${ASPIA_RELAY_IDLE_TIMEOUT:-}" ]          && ini_set "$f" peer   idle_timeout "$ASPIA_RELAY_IDLE_TIMEOUT"
    [ -n "${ASPIA_RELAY_PEER_LISTEN_INTERFACE:-}" ] && ini_set "$f" peer   listen_interface "$ASPIA_RELAY_PEER_LISTEN_INTERFACE"

    return 0
}

# -------------------------------------------------------------------------------------
# Entry point
# -------------------------------------------------------------------------------------
role="${1:-${ASPIA_ROLE:-all}}"
shift || true

case "$role" in
    router|relay|all) ;;
    *)
        # Not a role: treat the first argument as a command for the router binary,
        # e.g. `docker run … aspia-router-relay:3.0.23 --version`.
        exec "$ROUTER_BIN" "$role" "$@"
        ;;
esac

prepare_dirs

# Extra arguments for a single-component role are handled by the binary itself instead of
# starting the service (e.g. `docker run … aspia-router-relay:3.0.23 relay --help`,
# `… router --create-config`).
if [ "$#" -gt 0 ]; then
    case "$role" in
        router) exec_as_user "$ROUTER_BIN" "$@" ;;
        relay)  exec_as_user "$RELAY_BIN" "$@" ;;
        all)    die "extra arguments are not supported with ASPIA_ROLE=all" ;;
    esac
fi

printf '%s' "$role" > /run/aspia/role 2>/dev/null || true

case "$role" in
    router)
        init_router
        log "starting aspia_router"
        exec_as_user "$ROUTER_BIN"
        ;;
    relay)
        init_relay
        log "starting aspia_relay"
        exec_as_user "$RELAY_BIN"
        ;;
    all)
        # One container hosting both components: the Router must create relay.pub before the
        # Relay can be configured, so the Router is initialised first.
        init_router
        log "starting aspia_router"
        run_as_user "$ROUTER_BIN" &
        router_pid=$!

        init_relay
        log "starting aspia_relay"
        run_as_user "$RELAY_BIN" &
        relay_pid=$!

        children="$router_pid $relay_pid"

        stop_children() {
            log "stopping services"
            # shellcheck disable=SC2086
            kill -TERM $children 2>/dev/null || true
        }
        trap 'stop_children; wait; exit 0' TERM INT

        # Exit as soon as either service dies, tearing the other one down with it.
        if wait -n; then
            status=0
        else
            status=$?
        fi
        log "a service exited (status $status); stopping the other"
        stop_children
        wait || true
        exit "$status"
        ;;
esac
