#!/bin/sh
# 广航校园网自动认证 —— 一键安装（默认只安装，不切换出口）
#
# 用法:
#   sh install.sh <账号> <密码> [--switch] [--iface eth0.2] [--acname hhxy]
#                 [--vlan 3017] [--portal http://1.1.1.1:8888]
#
#   --switch   安装并验证通过后，把校园口切成默认出口（会同时启用看门狗）
#
# 不带 --switch 时只建接口（metric 10）、装服务、不改变现有上网路径。

set -u

USERID=""
PASSWD=""
SWITCH=0
IFACE=eth0.2
ACNAME=hhxy
VLAN=3017
PORTAL=http://1.1.1.1:8888

usage() {
    sed -n '2,12p' "$0"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --switch) SWITCH=1; shift ;;
        --iface)  IFACE=$2; shift 2 ;;
        --acname) ACNAME=$2; shift 2 ;;
        --vlan)   VLAN=$2; shift 2 ;;
        --portal) PORTAL=$2; shift 2 ;;
        -h|--help) usage ;;
        *) if [ -z "$USERID" ]; then USERID=$1
           elif [ -z "$PASSWD" ]; then PASSWD=$1
           else usage; fi
           shift ;;
    esac
done

[ -n "$USERID" ] && [ -n "$PASSWD" ] || usage

HERE=$(cd "$(dirname "$0")" && pwd)
TS=$(date +%s)

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

say "环境检查"
[ -f /etc/openwrt_release ] || die "这不是 OpenWrt 系统"
. /etc/openwrt_release
echo "  $DISTRIB_DESCRIPTION ($DISTRIB_TARGET / $DISTRIB_ARCH)"
command -v uci >/dev/null || die "缺少 uci"
[ -d "/sys/class/net/$IFACE" ] || die "接口 $IFACE 不存在，请用 --iface 指定物理 WAN 口（board.json 里 wan.device）"

say "备份 /etc/config/network"
cp /etc/config/network "/etc/config/network.bak.$TS"
echo "  -> /etc/config/network.bak.$TS"

say "安装脚本"
cp "$HERE/campus-drcom.sh"   /usr/libexec/campus-drcom.sh
cp "$HERE/campus-guard.sh"   /usr/libexec/campus-guard.sh
cp "$HERE/campus-drcom.init" /etc/init.d/campus-drcom
cp "$HERE/campus-guard.init" /etc/init.d/campus-guard
chmod 755 /usr/libexec/campus-drcom.sh /usr/libexec/campus-guard.sh \
          /etc/init.d/campus-drcom /etc/init.d/campus-guard

say "写入凭据（0600，明文）"
touch /etc/config/campus-drcom
chmod 600 /etc/config/campus-drcom
uci -q set campus-drcom.main=settings
uci -q set campus-drcom.main.enabled='1'
uci -q set campus-drcom.main.iface="$IFACE"
uci -q set campus-drcom.main.portal="$PORTAL"
uci -q set campus-drcom.main.acip='1.1.1.1'
uci -q set campus-drcom.main.acname="$ACNAME"
uci -q set campus-drcom.main.vlan="$VLAN"
uci -q set campus-drcom.main.user="$USERID"
uci -q set campus-drcom.main.password="$PASSWD"
uci -q commit campus-drcom
echo "  user=$USERID  acname=$ACNAME  vlan=$VLAN"

say "建 campus 接口（先 metric 10，不抢默认路由）"
uci -q set network.campus=interface
uci -q set network.campus.proto='dhcp'
uci -q set network.campus.device="$IFACE"
uci -q set network.campus.metric='10'
uci -q set network.campus.peerdns='1'
uci -q commit network

say "并入 wan 防火墙区"
if ! uci -q get firewall.@zone[1].network | grep -qw campus; then
    uci add_list firewall.@zone[1].network='campus'
    uci commit firewall
    echo "  已加入"
else
    echo "  已在 wan 区"
fi

say "应用网络"
nohup /etc/init.d/network reload >/tmp/install_net.log 2>&1 &
sleep 12

say "启动认证保活"
/etc/init.d/campus-drcom enable >/dev/null 2>&1
/etc/init.d/campus-drcom restart >/dev/null 2>&1
sleep 8
if pgrep -f campus-drcom.sh >/dev/null; then echo "  campus-drcom: running"; else echo "  campus-drcom: NOT running"; fi

say "认证结果"
logread | grep campus-drcom | tail -5

CIP=$(ip -4 addr show dev "$IFACE" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1)
if [ -z "$CIP" ]; then
    echo "  !! $IFACE 还没拿到地址，检查网线/端口；先不继续"
    exit 1
fi
echo "  校园口地址: $CIP"

if [ "$SWITCH" = "1" ]; then
    say "切换默认出口（带看门狗）"
    /etc/init.d/campus-guard enable >/dev/null 2>&1
    /etc/init.d/campus-guard restart >/dev/null 2>&1
    sleep 3
    uci -q set network.campus.metric='0'
    uci -q set network.wan.metric='20'
    uci -q commit network
    nohup /etc/init.d/network reload >/tmp/install_switch.log 2>&1 &
    sleep 14
    ip route show default | head -3
    code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' https://www.baidu.com)
    echo "  baidu=$code"
    if [ "$code" = "200" ]; then
        echo "  切换成功"
    else
        echo "  !! 切换失败，回滚为热点优先"
        uci -q set network.campus.metric='10'
        uci -q set network.wan.metric='0'
        uci -q commit network
        nohup /etc/init.d/network reload >/tmp/install_revert.log 2>&1 &
        sleep 10
        exit 1
    fi
else
    echo
    echo "  未切换出口（默认热点优先）。确认认证正常后执行："
    echo "    /etc/init.d/campus-guard enable && /etc/init.d/campus-guard start"
    echo "    uci set network.campus.metric='0'; uci set network.wan.metric='20'; uci commit network"
    echo "    /etc/init.d/network reload"
fi

say "完成"
echo "  日志: logread | grep -E 'campus-drcom|campus-guard'"
echo "  回滚: uci set network.campus.metric='10'; uci commit network; /etc/init.d/network reload"
