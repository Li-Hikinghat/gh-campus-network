#!/bin/sh
# Keeps the campus uplink usable:
#   - campus line answers but portal blocks  -> let the keeper authenticate
#   - campus line stops answering (3 strikes) -> drop its default route so the
#     hotspot (metric 20) takes over; keep probing and restore when it is back.
# Only the campus default route is touched; config stays unchanged.

CHECK_HOST=connect.rom.miui.com
CHECK_PATH=/generate_204
CAMPUS_IF=eth0.2          # 每轮会被 netifd 的实际 l3_device 覆盖
STATE=/tmp/campus-guard.state
INTERVAL=20
FALLBACK_INTERVAL=30
DEAD_LIMIT=3
AUTH_COOLDOWN=180

LAST_AUTH=0

log() { logger -t campus-guard "$*"; }

campus_gw() {
    ubus call network.interface.campus status 2>/dev/null \
        | sed -n 's/.*"nexthop": "\([0-9.]*\)".*/\1/p' | head -1
}

probe_default() {
    curl -s -m 6 -o /dev/null -w '%{http_code}' "http://$CHECK_HOST$CHECK_PATH" 2>/dev/null
}

# probe the campus port even when it is not the default route
probe_campus() {
    local gw pip
    gw=$(campus_gw)
    [ -z "$gw" ] && { echo nogw; return; }
    pip=$(nslookup "$CHECK_HOST" 223.5.5.5 2>/dev/null \
        | sed -n 's/^Address [0-9]*: *\([0-9.]*\)/\1/p' | tail -1)
    if [ -z "$pip" ]; then
        pip=$(nslookup "$CHECK_HOST" 2>/dev/null \
            | sed -n 's/^Address [0-9]*: *\([0-9.]*\)/\1/p' | tail -1)
    fi
    [ -z "$pip" ] && { echo nodns; return; }
    ip route replace "$pip/32" via "$gw" dev "$CAMPUS_IF" 2>/dev/null
    curl -s -m 6 -o /dev/null -w '%{http_code}' \
        -H "Host: $CHECK_HOST" "http://$pip$CHECK_PATH"
}

attempt_auth() {
    local now
    now=$(date +%s)
    [ $((now - LAST_AUTH)) -lt $AUTH_COOLDOWN ] && return
    LAST_AUTH=$now
    log "campus line alive but blocked -> asking keeper to authenticate"
    /usr/libexec/campus-drcom.sh once >/dev/null 2>&1
}

do_fallback() {
    local gw
    gw=$(campus_gw)
    [ -n "$gw" ] && ip route del default via "$gw" dev "$CAMPUS_IF" 2>/dev/null
    echo fallback > "$STATE"
    log "FALLBACK: campus line unreachable, hotspot takes over"
}

do_restore() {
    local gw
    gw=$(campus_gw)
    [ -n "$gw" ] && ip route replace default via "$gw" dev "$CAMPUS_IF" 2>/dev/null
    rm -f "$STATE"
    log "RESTORE: campus uplink is primary again"
}

dead=0
log "started on $CAMPUS_IF (interval ${INTERVAL}s, fallback after ${DEAD_LIMIT} strikes)"

while :; do
    # 跟随 netifd 实际把校园网 L3 挂在哪（eth0.2 或桥接后的 br-campus）
    L3=$(ubus call network.interface.campus status 2>/dev/null \
        | sed -n 's/.*"l3_device": "\([^"]*\)".*/\1/p' | head -1)
    [ -n "$L3" ] && CAMPUS_IF=$L3

    if [ -f "$STATE" ]; then
        code=$(probe_campus)
        case "$code" in
            204) do_restore; dead=0 ;;
            302|200) attempt_auth ;;
            *) : ;;
        esac
        sleep "$FALLBACK_INTERVAL"
    else
        code=$(probe_default)
        case "$code" in
            204)
                dead=0
                ;;
            302|200)
                # line is alive, portal is hijacking; keeper deals with the login
                dead=0
                ;;
            *)
                dead=$((dead + 1))
                log "probe=${code:-timeout} strike $dead/$DEAD_LIMIT"
                if [ "$dead" -ge "$DEAD_LIMIT" ] && \
                   ip route show default 2>/dev/null | grep -q "dev $CAMPUS_IF"; then
                    do_fallback
                    dead=0
                fi
                ;;
        esac
        sleep "$INTERVAL"
    fi
done
