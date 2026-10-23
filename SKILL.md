---
name: guanghang-campus-network
description: 在 OpenWrt/ImmortalWrt 上为广航（广州航海学院）校园网做自动认证、双出口回退与防共享检测（Dr.COM webauth + UA3F）。当用户提到广航校园网、Dr.COM 认证、UA3F 崩溃、或路由器认证后断网时使用。
---

# 广航校园网自动认证（OpenWrt）

本 skill 是**可执行手册**：面向一台已能 SSH 的 OpenWrt/ImmortalWrt 路由器，把广航校园网的 Dr.COM 认证、双出口回退、UA3F 反检测一次性配好。
背景细节与踩坑解释见同目录 `README.md`；脚本在 `scripts/`。

## 第 0 步（最重要）：先确认这台设备"配不配"

**在动手之前先跑这一组检查。任何一项不满足，后面的步骤都会白做——要么 UA3F 装不上，要么一启动就崩，要么反检测形同虚设。**
如果是帮人选购，先用这张表筛设备；如果是已有设备，7 天退换期内验完再决定留不留。

```sh
# 1) 有没有 nftables（UA3F 3.x 的首选后端）
which nft && nft list ruleset >/dev/null && echo "nftables: OK" || echo "nftables: MISSING"

# 2) 没有 nftables 的话，必须至少有 NFQUEUE
zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_NF_TABLES=|CONFIG_NETFILTER_XT_TARGET_NFQUEUE'

# 3) TPROXY（透明代理必需）
ls /lib/modules/$(uname -r)/ 2>/dev/null | grep -iE 'tproxy' || \
    { which nft >/dev/null && nft list ruleset >/dev/null 2>&1 && echo "tproxy via nft: 需 nft_tproxy 模块"; }

# 4) ipset（UA3F 依赖）
which ipset || echo "ipset: MISSING"

# 5) 包管理器和源（装依赖用）
opkg update 2>&1 | tail -3      # 或 apk update
```

判定表：

| 检查结果 | 结论 |
|---|---|
| 有 nftables + nft_tproxy | ✅ 理想，UA3F 用 nft 后端，`tcpts` 也能用 |
| 无 nftables 但有 `CONFIG_NETFILTER_XT_TARGET_NFQUEUE` | ⚠️ 可用，但 `tcpts`/`desync` 会依赖 NFQUEUE，仍需谨慎 |
| 两者都没有（本文设备就是） | ❌ UA3F 只能以 `tcpts=0`、`desync=0` 运行；TCP 时间戳只能靠 `sysctl net.ipv4.tcp_timestamps=0` 绕 |
| `opkg update` 大面积 404 | ❌ 所有包只能本地 sideload，方案会麻烦很多 |
| 没有独立 WAN 口 / 没有 `nft` 也没有 `iptables` | ❌ 不建议继续 |

附加筛选条件（避免重复踩坑）：

- **避开 MTK 原厂 SDK 固件**：没有 `/etc/config/wireless`，无线配置在 `/etc/wireless/mediatek/*.dat`，改参数要重启
- **避开"精简/加速"固件**：netfilter 模块常被裁掉，UA3F 必崩
- **避开 21.02 及更老分支**：无 nftables，软件源普遍 404
- **内存 ≥ 256MB**：UA3F 二进制 15MB，运行时还要 ipsets

## 何时使用

- 用户是广航（广州航海学院）学生，想让路由器/软路由自动登录校园网
- 认证成功后路由器断网、或校园网被"多设备检测"限制
- UA3F 装不上 / 一启动就崩 / 反复重启
- 5G WiFi 能搜到但手机连不上超时

## 环境假设（先核实，不要假设）

```sh
cat /etc/openwrt_release          # ImmortalWrt 21.02-SNAPSHOT / aarch64_cortex-a53
opkg print-architecture           # aarch64_cortex-a53
cat /etc/board.json               # 找 '"wan"' → device 字段（本机 eth0.2）
swconfig dev switch0 show | grep -A2 '^Port 0:'
```

若 `opkg update` 失败（大概率，官方已删 21.02-SNAPSHOT 源），**不要重试**：所有包走本地 sideload。

## 第 1 步：确认门户参数（不要抄，要抓）

未认证时触发一次跳转，拿 302 的 Location：

```sh
# 确保默认路由暂时走校园口，或给探测 IP 加一条指向校园网关的 host 路由
ip route replace <探测IP>/32 via <校园网关> dev eth0.2
curl -s -D - -o /dev/null -H 'Host: connect.rom.miui.com' http://<探测IP>/
```

期望看到：

```
Location: http://1.1.1.1:8888/webauth.do?wlanacip=1.1.1.1&wlanacname=hhxy&wlanuserip=<IP>&mac=<MAC>&vlan=<VLAN>&url=...
```

- `wlanacname` 必须是 `hhxy`（缺了会返回"未知网关"）
- `vlan` 与楼栋有关（记录里见 3017），换楼要重抓
- 门户是 **Dr.COM 城市热点 BOSS**，`/eportal/portal/login` 一定 404

## 第 2 步：判断认证状态（唯一可信判据）

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://connect.rom.miui.com/generate_204
# 204 = 已认证可上网；302 = 被门户劫持（需认证）；000/timeout = 链路不通
```

**永远不要用 `ping 1.1.1.1` 判断**——那是公网 DNS，通不通与门户无关，会误判。

## 第 3 步：装认证保活

```sh
cp scripts/campus-drcom.sh /usr/libexec/campus-drcom.sh
cp scripts/campus-drcom.init /etc/init.d/campus-drcom
chmod 755 /usr/libexec/campus-drcom.sh /etc/init.d/campus-drcom

touch /etc/config/campus-drcom && chmod 600 /etc/config/campus-drcom
uci set campus-drcom.main=settings
uci set campus-drcom.main.enabled='1'
uci set campus-drcom.main.iface='eth0.2'
uci set campus-drcom.main.portal='http://1.1.1.1:8888'
uci set campus-drcom.main.acip='1.1.1.1'
uci set campus-drcom.main.acname='hhxy'
uci set campus-drcom.main.vlan='3017'
uci set campus-drcom.main.user='<账号>'
uci set campus-drcom.main.password='<密码>'
uci commit campus-drcom

/etc/init.d/campus-drcom enable && /etc/init.d/campus-drcom start
logread | grep campus-drcom        # 期望 "authenticated OK (probe 204)"
```

脚本行为：GET 拿 JSESSIONID → POST `userId/passwd/wlanuserip/wlanacname/wlanacip/mac/vlan/pageid/url` → 用 204 判定；失败指数退避至 600s，连续失败 8 次后拉长到 1800s；**每轮重读 UCI**，所以用户改密码无需重启服务。

**若学校有宵禁（如 00:00–07:00 断网）**，开启夜间静默，避免整夜反复 POST 密码触发门户风控：

```sh
uci set campus-drcom.main.quiet_start='0000'
uci set campus-drcom.main.quiet_end='0700'
uci commit campus-drcom
```

该时段只探测（约每 5 分钟一次）、不登录；07:00 后第一轮自动恢复认证。留空即关闭。

## 第 4 步：双出口 + 看门狗（顺序强制）

```sh
cp scripts/campus-guard.sh /usr/libexec/campus-guard.sh
cp scripts/campus-guard.init /etc/init.d/campus-guard
chmod 755 /usr/libexec/campus-guard.sh /etc/init.d/campus-guard
/etc/init.d/campus-guard enable && /etc/init.d/campus-guard start   # ★ 先看门狗

uci set network.campus=interface
uci set network.campus.proto='dhcp'
uci set network.campus.device='eth0.2'
uci set network.campus.metric='0'          # 校园主出口
uci set network.wan.metric='20'            # 热点备用
uci commit network
uci add_list firewall.@zone[1].network='campus'; uci commit firewall
/etc/init.d/network reload

ip route show default                        # campus 在前
curl -s -o /dev/null -w '%{http_code}\n' https://www.baidu.com   # 200
```

**红线：没有看门狗之前，绝对不要把 campus 设成唯一默认出口。** 曾因此全网断，只能断电重启。

看门狗逻辑：默认出口探测连续 3 次非 204/302 → `ip route del` 掉 campus 默认路由（热点接管）→ 每 30s 用 pinned 路由探测校园口，恢复 204 后自动切回。

## 第 5 步：UA3F（多设备共享必需）

已知约束：本机内核 `# CONFIG_NETFILTER_XT_TARGET_NFQUEUE is not set`；官方 ipk 外层是 gzip，opkg 不认；依赖 `iptables-mod-nfqueue` 装不上。

```sh
# 1) 重打包成普通 tar（内部 debian-binary/control.tar.gz/data.tar.gz 字节不变）
# 2) 去掉 control 里的 iptables-mod-nfqueue 依赖
opkg install --force-depends /tmp/ua3f_repacked.ipk

uci set ua3f.enabled.enabled='1'
uci set ua3f.main.server_mode='TPROXY'
uci set ua3f.main.port='1080'
uci set ua3f.main.desync_reorder='0'
uci delete ua3f.main.desync_inject
uci set ua3f.main.l3_rewrite_ttl='1'
uci set ua3f.main.l3_rewrite_ttl_value='64'
uci set ua3f.main.l3_rewrite_tcpts='0'     # ★ 设 1 必然 crash loop（NFQUEUE）
uci commit ua3f && /etc/init.d/ua3f restart
```

验证：`logread | grep "Rewrite User-Agent"`；`iptables -t mangle -S UA3F | tail` 应见 TPROXY → :1080。
UA3F 停止时会自己清规则（29 条），不会留下指向死端口的断网隐患。

## 第 6 步：反检测收尾

```sh
echo 'net.ipv4.tcp_timestamps = 0' >> /etc/sysctl.conf   # UA3F 终结全部 TCP，出站即无 TS
sysctl -w net.ipv4.tcp_timestamps=0
cp scripts/firewall.dsh /etc/firewall.dsh && chmod 755 /etc/firewall.dsh
uci set firewall.dsh_include=include; uci set firewall.dsh_include.type='script'
uci set firewall.dsh_include.path='/etc/firewall.dsh'; uci set firewall.dsh_include.reload='1'
uci commit firewall && /etc/init.d/firewall reload
```

验证：`tcpdump -i <wan> -c 5 -nn -vv 'tcp[tcpflags]&tcp-syn!=0'` 里不应出现 `timestamp`，且 TTL=64。
IPID 无法改写（内核无 `xt_IPID`/`NET_ACT_PEDIT`），实测每条流随机，与普通手机一致，可接受。

## 第 7 步：WiFi（MTK 原厂驱动才有这些问题）

本机没有 `/etc/config/wireless`，配置在 `/etc/wireless/mediatek/mt7981.dbdc.b{0,1}.dat`，改完**必须重启**。

```
AuthMode=WPA2PSK        # 混合 WPA2/WPA3 会让部分手机"能搜到、连不上"
Channel=149             # 自动选信道会落到 60 等 DFS 信道，同样连不上
AutoChannelSelect=0
```

关 2.4G AP：`scripts/wifi24off.init`（等 `ra0` 出现再 `ifconfig ra0 down`）。
**不要写 `/etc/rc.local`**——执行太早，驱动还没建出 `ra0`，命令静默失败。

## 第 8 步：收敛暴露面（必做，比伪装更重要）

伪装只解决"流量像不像手机"；**端口扫描解决"你是不是一台路由器"**。先查一遍：

```sh
iptables -S zone_wan_input | tail -2          # 结尾是 ACCEPT 就说明 WAN 入站敞着
netstat -lntp | awk '/0\.0\.0\.0:|:::/'       # 0.0.0.0 上的服务 = 对校园网可见
uci show firewall | grep -E "input=" | head   # defaults / wan zone 的 input 策略
uci -q get network.campus.hostname            # 空 = 会上报系统名（ImmortalWrt）
```

只要 `zone_wan_input` 以 `src_ACCEPT` 结尾，就按下面全部收掉（改前先备份 `/etc/config/{firewall,uhttpd,network}`）：

```sh
uci set firewall.@defaults[0].input='REJECT'
uci set firewall.@zone[1].input='REJECT'
uci commit firewall

uci set uhttpd.main.listen_http='192.168.1.1:80'
uci set uhttpd.main.listen_https='192.168.1.1:443'
uci commit uhttpd

/etc/init.d/wsdd2 stop   ; /etc/init.d/wsdd2 disable      # WS-Discovery 会广播硬件型号
/etc/init.d/haproxy stop ; /etc/init.d/haproxy disable    # 发行版示例配置，纯占端口

sed -i '/^\[server\]/a allow-interfaces=br-lan' /etc/avahi/avahi-daemon.conf
/etc/init.d/avahi-daemon restart                          # 否则 mDNS 宣告 ImmortalWrt.local

uci set network.campus.hostname='*'                       # '*' = 不发 hostname 选项
uci commit network

/etc/init.d/firewall reload && /etc/init.d/uhttpd restart
```

**不要**删 `Allow-Ping`：手机也回 ICMP，完全不回 ping 反而更可疑。dnsmasq 仍监听 WAN IP 但已被防火墙挡住，需要的话再绑 LAN。

验证：`zone_wan_input` 结尾应为 `src_REJECT`；`0.0.0.0` 监听应消失（只剩 `192.168.1.1` / `127.0.0.1`）；`ip maddr show dev <WAN> | grep -c 224.0.0.251` 为 0。
改完确认 `probe=204`、`baidu=200`、UA3F 规则数不变。

顺手看一眼 **CA 信任库时效**（只影响路由器自己发起的 HTTPS，不影响手机电脑）：

```sh
opkg list-installed | grep ca-bundle
# ca-bundle - 20230311-1     ← 版本里的日期 > 18 个月就该考虑更新
```

更新优先靠 `sysupgrade`；不能刷机就 sideload `ca-bundle` / `ca-certificates`（`Architecture: all`，不挑架构）。
两条红线：**不要手工往 `/etc/ssl/certs` 塞来路不明的根证书**；**不要轻易给 UA3F 开 `--mitm`**——那等于自己造一张 CA，所有终端都要信任它。

**某个 CA 被攻破时要能立刻止血**（2026-10 的 eMudhra/emSign 就是这么处理的）：

```sh
# 1) 先确认锚点是谁 —— 不要 grep PEM，base64 里没有可读名字
openssl crl2pkcs7 -nocrl -certfile /etc/ssl/certs/ca-certificates.crt \
  | openssl pkcs7 -print_certs -noout | grep -i emsign

# 2) 干跑 → 执行（自动备份 bundle，可重复执行）
sh tools/distrust-ca.sh emSign
sh tools/distrust-ca.sh emSign --apply

# 3) 验证：应从 200 变成证书校验失败
curl -sS https://dv-g3b-emudhra.we-have-a-problem.com/
```

**别为了"干净"去删交叉签名的老根**（如 `AAA Certificate Services`）——半个互联网挂在它下面。
经它签发的中间 CA 只能等 CA 自己吊销，OpenSSL 默认不查 CRL，这种情况如实记为已知风险。
固件升级或重装 `ca-bundle` 会把证书装回来，升级后复查一次。

## 第 9 步（可选）：2.4G 做透明 AP，让同学各自认证

场景：用户想把自己的路由器当 AP，让其他有校园账号的人连 2.4G 后**各自在门户登录**，不共享账号、不走本机 NAT/UA3F。

**先验证端口允许多 MAC**（不做这步后面全是白工）：

```sh
ip link add link eth0.2 name mactest0 type macvlan mode bridge
ip link set mactest0 address aa:bb:cc:dd:ee:55
ip link set mactest0 up
udhcpc -i mactest0 -n -q -t 3 -T 4 -s /bin/true    # 拿到 10.x.x.x 才可行
ip link del mactest0
```

拿到租约后再动手，**顺序不能反**：

```sh
# 1) 先让守进程/看门狗自适应接口（脚本已读 ubus l3_device，无需改）
# 2) 开放 SSID（.dat，必须重启生效；多数 MTK 固件 iwpriv 被禁）
sed -i 's/^SSID1=.*/SSID1=<开放SSID>/'      /etc/wireless/mediatek/mt7981.dbdc.b0.dat
sed -i 's/^AuthMode=.*/AuthMode=OPEN/'     /etc/wireless/mediatek/mt7981.dbdc.b0.dat
sed -i 's/^EncrypType=.*/EncrypType=NONE/' /etc/wireless/mediatek/mt7981.dbdc.b0.dat

# 3) 建桥
uci set network.br_campus=device; uci set network.br_campus.name='br-campus'
uci set network.br_campus.type='bridge'; uci add_list network.br_campus.ports='eth0.2'
uci set network.campus.device='br-campus'; uci commit network

# 4) 钩子 + 自动回退（这两个是硬性要求，见 pitfalls）
cp scripts/apbridge.init /etc/init.d/apbridge && chmod 755 /etc/init.d/apbridge && /etc/init.d/apbridge enable
cp /etc/config/network /etc/config/network.good      # 必须先存"已验证能上网"的那份
cp scripts/netguard.init /etc/init.d/netguard && chmod 755 /etc/init.d/netguard && /etc/init.d/netguard enable
/etc/init.d/wifi24off disable
reboot
```

验收：`l3_device=br-campus`、`br-campus` 成员含 `eth0.2 ra0`、`iwinfo ra0` 显示开放 SSID、`generate_204=204`；
再用 macvlan 挂在 `br-campus` 上跑 `udhcpc`，能拿到 `10.x.x.x` 就说明桥后面的客户端可用。

**三个必踩的坑（都已修，别改回去）**：

1. **守进程比接口早一步** → 它把"没有 IP"当失败，退避 120 秒，表现为"开机后两分钟没网"。
   必须在循环里 `if [ -z "$(iface_ip)" ]; then sleep 10; continue; fi`。
2. **apbridge 不能用 procd**：一次性任务 `exit 0` 会被反复拉起，6 次后 crash loop。用 `start() { ( ... ) & }`。
3. **必须装 netguard**：开机 3 分钟仍无网就恢复 `network.good`。否则改错一次，人不在现场就只能拔电。

回退：

```sh
cp /etc/config/network.good /etc/config/network
uci set campus-drcom.main.iface='eth0.2'; uci commit campus-drcom; uci commit network
/etc/init.d/apbridge disable
brctl delif br-campus ra0 2>/dev/null; brctl addif br-lan ra0 2>/dev/null
/etc/init.d/network reload
```

**提醒用户**：开放 SSID = 对整栋楼开放；2.4G 客户端不受 UA3F 保护（这正是 AP 模式的意义）；一旦学校做端口 MAC 绑定，2.4G 客户端会集体失效。

## 验收清单

- [ ] `generate_204` = 204
- [ ] `ip route show default` 首条是校园口
- [ ] `https://www.baidu.com` 200
- [ ] `pgrep -f campus-drcom`、`campus-guard`、`ua3f` 都在
- [ ] `iptables -S FORWARD | grep 3544` 有 DROP
- [ ] 抓包：单一源 IP、TTL 全 64、SYN 无 TS
- [ ] `zone_wan_input` 结尾是 `src_REJECT`，`0.0.0.0` 上无管理端口暴露（第 8 步）
- [ ] `network.campus.hostname='*'`，`ip maddr show dev <WAN>` 不含 `224.0.0.251`
- [ ] `ca-bundle` 版本日期不超过 18 个月，`/etc/ssl/certs` 里没有手工塞进去的根证书
- [ ] 已知被攻破的 CA 已撤销：`curl https://dv-g3b-emudhra.we-have-a-problem.com/` 必须**失败**
- [ ] **已向用户说明剩余破绽**（UDP / HTTPS SNI / IPv6 / TLS 指纹 / 并发规模，见 `README.md` §5.1），不要让用户误以为已经"隐身"
- [ ] 若做了 AP 模式：`l3_device=br-campus`、成员含 `eth0.2 ra0`、桥后 macvlan 能拿到校园 IP、`netguard` 已启用
- [ ] 断电重启后以上全部自动恢复

## 回滚

```sh
uci set network.campus.metric='10'; uci set network.wan.metric='0'; uci commit network
/etc/init.d/network reload
/etc/init.d/campus-drcom stop; /etc/init.d/campus-guard stop
```

`/etc/config/network.bak.*` 里保留了多个时间点备份。

## 绝对不要做

- 在没有看门狗时把校园口设为唯一默认出口
- 在已认证状态下反复强制登录（门户会 503，并可能风控）
- 用 `ping 1.1.1.1` 判断认证状态
- 在没确认 `ra0` 存在时用 `rc.local` 关 WiFi
- 修改用户的账号密码、SSH/LuCI 认证配置
- 恢复出厂设置（配置全丢）

## 友情链接

- **UA3F**（核心组件）：https://github.com/SunBK201/UA3F
- **UA3F Releases**（下载 ipk/apk，注意后缀与架构）：https://github.com/SunBK201/UA3F/releases
- **OpenWrt**（上游、Wiki、硬件支持）：https://openwrt.org/
- **OpenWrt 固件选择器**（买设备前查是否有官方支持）：https://firmware-selector.openwrt.org/
- **ImmortalWrt**（国内常用分支）：https://immortalwrt.org/
- **ImmortalWrt 下载**（建议 24.10+，自带 nftables）：https://downloads.immortalwrt.org/

> 本文由 DSH 协助整理。若门户改版导致参数变化，先看 `reference/portal-protocol.md` 的抓包证据，再重新抓一次 302 的 Location。
