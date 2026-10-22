#!/bin/sh
# Dr.COM (城市热点) webauth auto-login keeper for this campus portal.
# Verified live against http://1.1.1.1:8888/webauth.do
#   1) GET  /webauth.do?<gateway params>          -> JSESSIONID cookie
#   2) POST /webauth.do;JSESSIONID-BOSS-0=<sid>?<gateway params>
#      with userId / passwd / wlanuserip / wlanacname / wlanacip / mac / vlan
#   3) success == captive-portal probe returns 204 instead of 302
# The portal route is pinned via the campus interface, so this works even when
# the default route currently points at the hotspot.
# Credentials are re-read from UCI every cycle, so changing them in
# /etc/config/campus-drcom takes effect within one interval - no restart needed.

NAME=campus-drcom

get() { uci -q get "$NAME.main.$1"; }

load_creds() {
    IFACE=$(get iface);            IFACE=${IFACE:-eth0.2}
    PORTAL=$(get portal);          PORTAL=${PORTAL:-http://1.1.1.1:8888}
    ACIP=$(get acip);              ACIP=${ACIP:-1.1.1.1}
    ACNAME=$(get acname);          ACNAME=${ACNAME:-hhxy}
    VLAN=$(get vlan);              VLAN=${VLAN:-3017}
    USERID=$(get user)
    PASSWORD=$(get password)
    CHECK=$(get check_url);        CHECK=${CHECK:-http://connect.rom.miui.com/generate_204}
    INTERVAL=$(get interval);      INTERVAL=${INTERVAL:-60}
    RETURN_URL=$(get return_url);  RETURN_URL=${RETURN_URL:-http://connect.rom.miui.com/}
    ENABLED=$(get enabled);        ENABLED=${ENABLED:-1}
    # 宵禁/夜间断网：在这段时间内不尝试登录（避免整夜重试触发门户风控），
    # 只做连通性探测，时间一到立刻恢复正常节奏。格式 HHMM，留空 = 不启用。
    QUIET_START=$(get quiet_start)
    QUIET_END=$(get quiet_end)
    # 连续失败多少次之后，把重试上限拉长到 30 分钟
    MAX_FAIL=$(get max_fail);      MAX_FAIL=${MAX_FAIL:-8}
}

log() {
    logger -t "$NAME" "$*"
    echo "$(date '+%F %T') $*"
}

# "HHMM" -> minutes since midnight (avoids the 08 octal trap in ash)
hhmm_min() {
    local hh mm
    hh=$(echo "$1" | cut -c1-2 | sed 's/^0*//');  [ -z "$hh" ] && hh=0
    mm=$(echo "$1" | cut -c3-4 | sed 's/^0*//');  [ -z "$mm" ] && mm=0
    echo $((hh * 60 + mm))
}

in_quiet_hours() {
    [ -z "$QUIET_START" ] || [ -z "$QUIET_END" ] && return 1
    local now start end
    now=$(hhmm_min "$(date +%H%M)")
    start=$(hhmm_min "$QUIET_START")
    end=$(hhmm_min "$QUIET_END")
    if [ "$start" -le "$end" ]; then
        [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ] && return 0
    else
        { [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]; } && return 0
    fi
    return 1
}

iface_ip() {
    ip -4 addr show dev "$IFACE" 2>/dev/null \
        | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1
}

iface_mac() { cat "/sys/class/net/$IFACE/address" 2>/dev/null; }

iface_gw() {
    ubus call network.interface.campus status 2>/dev/null \
        | sed -n 's/.*"nexthop": "\([0-9.]*\)".*/\1/p' | head -1
}

probe() {
    curl -s -m 8 -o /dev/null -w '%{http_code}' "$CHECK" 2>/dev/null
}

# keep the portal reachable through the campus port, whatever the default route is
pin_portal_route() {
    local gw pip
    gw=$(iface_gw)
    pip=$(echo "$PORTAL" | sed -n 's|^https\?://\([0-9.]*\).*|\1|p')
    [ -n "$gw" ] && [ -n "$pip" ] && \
        ip route replace "$pip/32" via "$gw" dev "$IFACE" 2>/dev/null
}

login() {
    local ip mac qs ck sid code p
    ip=$(iface_ip)
    if [ -z "$ip" ]; then
        log "no IPv4 on $IFACE yet, skip"
        return 1
    fi
    if [ -z "$USERID" ] || [ -z "$PASSWORD" ]; then
        log "account/password empty in /etc/config/campus-drcom"
        return 1
    fi
    mac=$(iface_mac)
    pin_portal_route
    qs="wlanacip=$ACIP&wlanacname=$ACNAME&wlanuserip=$ip&mac=$mac&vlan=$VLAN&url=$RETURN_URL"
    ck=/tmp/$NAME.ck
    rm -f "$ck"

    if ! curl -s -m 10 -c "$ck" -o /dev/null "$PORTAL/webauth.do?$qs"; then
        log "portal unreachable at $PORTAL"
        return 1
    fi
    sid=$(awk '/JSESSIONID/{print $7}' "$ck" 2>/dev/null | head -1)

    code=$(curl -s -m 15 -b "$ck" -o /tmp/$NAME.last -w '%{http_code}' \
        --data-urlencode "userId=$USERID" \
        --data-urlencode "passwd=$PASSWORD" \
        --data-urlencode "wlanuserip=$ip" \
        --data-urlencode "wlanacname=$ACNAME" \
        --data-urlencode "wlanacip=$ACIP" \
        --data-urlencode "mac=$mac" \
        --data-urlencode "vlan=$VLAN" \
        --data-urlencode "pageid=-1" \
        --data-urlencode "url=$RETURN_URL" \
        "$PORTAL/webauth.do;JSESSIONID-BOSS-0=$sid?$qs" 2>/dev/null)

    log "login attempt: user=$USERID ip=$ip http=${code:-none}"
    sleep 3
    p=$(probe)
    if [ "$p" = "204" ]; then
        log "authenticated OK (probe 204)"
        return 0
    fi
    log "still blocked after login (probe ${p:-timeout})"
    return 1
}

load_creds

if [ "$1" = "once" ]; then
    p=$(probe)
    log "once: probe ${p:-timeout}"
    login && exit 0
    exit 1
fi

force=0
[ "$1" = "force" ] && force=1
backoff=$INTERVAL
fails=0

log "started: iface=$IFACE portal=$PORTAL acname=$ACNAME vlan=$VLAN interval=${INTERVAL}s"
[ -n "$QUIET_START" ] && log "quiet hours: ${QUIET_START}-${QUIET_END} (no login attempts)"

while :; do
    load_creds

    if [ "$ENABLED" != "1" ]; then
        log "disabled in config, idling"
        sleep 60
        continue
    fi

    p=$(probe)
    if [ "$p" = "204" ] && [ "$force" = "0" ]; then
        fails=0
        backoff=$INTERVAL
        sleep "$INTERVAL"
        continue
    fi

    # 宵禁时段：只探测，不登录。校区恢复后下一轮就会正常认证。
    if [ "$force" = "0" ] && in_quiet_hours; then
        log "quiet hours ${QUIET_START}-${QUIET_END}, skip login (probe ${p:-timeout})"
        sleep 300
        continue
    fi

    [ "$force" = "1" ] && log "forced login (probe ${p:-timeout})"
    if login; then
        fails=0
        backoff=$INTERVAL
    else
        fails=$((fails + 1))
        backoff=$((backoff * 2))
        [ "$backoff" -gt 600 ] && backoff=600
        # 连续失败太多次（例如断网/宵禁/账号异常），拉长到 30 分钟一次
        if [ "$fails" -ge "$MAX_FAIL" ]; then
            backoff=1800
        fi
        log "next retry in ${backoff}s (consecutive failures: $fails)"
    fi
    force=0
    sleep "$backoff"
done
