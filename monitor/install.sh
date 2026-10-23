#!/bin/sh
# 安装状态监控面板（纯 shell + uhttpd CGI，不依赖任何第三方软件包）
# 用法：把整个 monitor/ 目录传到路由器，然后 sh monitor/install.sh

set -e
SRC=$(cd "$(dirname "$0")" && pwd)

echo "== 安装文件 =="
mkdir -p /www/monitor
cp "$SRC/monitor-daemon" /usr/sbin/monitor-daemon
cp "$SRC/monitor.init"   /etc/init.d/monitor
cp "$SRC/cgi-monitor"    /www/cgi-bin/monitor
cp "$SRC/index.html"     /www/monitor/index.html
chmod 755 /usr/sbin/monitor-daemon /etc/init.d/monitor /www/cgi-bin/monitor
chmod 644 /www/monitor/index.html

echo "== 启动并开机自启 =="
/etc/init.d/monitor enable
/etc/init.d/monitor restart
sleep 3

echo "== 自检 =="
echo "  采集进程: $(pgrep -f monitor-daemon | head -1)"
echo "  JSON 大小: $(wc -c < /tmp/monitor.json 2>/dev/null) 字节"
IP=$(uci -q get network.lan.ipaddr)
echo "  CGI 状态: $(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://${IP:-127.0.0.1}/cgi-bin/monitor")"
echo "  页面状态: $(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://${IP:-127.0.0.1}/monitor/")"
echo
echo "打开：http://${IP:-<路由器IP>}/monitor/"
