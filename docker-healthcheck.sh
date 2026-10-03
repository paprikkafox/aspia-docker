#!/usr/bin/env bash
#
# Container health check for the Aspia Router/Relay image.
#
# Verifies that the listener of the running component accepts TCP connections:
#   router -> the Clients listener
#   relay  -> the peers listener
#   all    -> both
#
# The port comes from the environment when set, otherwise it is read from the .conf files,
# so the check also works in the "no ENV, config on a volume" mode.
#
set -euo pipefail

CONFIG_DIR="/etc/aspia"
ROUTER_CONF="$CONFIG_DIR/router.conf"
RELAY_CONF="$CONFIG_DIR/relay.conf"

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

role="${ASPIA_ROLE:-}"
if [ -f /run/aspia/role ]; then
    role="$(cat /run/aspia/role)"
fi
role="${role:-all}"

check_tcp() {
    nc -z -w 2 127.0.0.1 "$1"
}

router_port() {
    local port="${ASPIA_ROUTER_CLIENT_PORT:-}"
    [ -n "$port" ] || port="$(ini_get "$ROUTER_CONF" client port)"
    printf '%s' "${port:-8062}"
}

relay_port() {
    local port="${ASPIA_RELAY_PEER_PORT:-}"
    [ -n "$port" ] || port="$(ini_get "$RELAY_CONF" peer port)"
    printf '%s' "${port:-8070}"
}

case "$role" in
    router) check_tcp "$(router_port)" ;;
    relay)  check_tcp "$(relay_port)" ;;
    all)    check_tcp "$(router_port)"; check_tcp "$(relay_port)" ;;
    *)      exit 0 ;;
esac
