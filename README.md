# 广航校园网 × ImmortalWrt 实战笔记

> 广州航海学院（下称「广航」）校园网在 OpenWrt/ImmortalWrt 上的**自动认证 + 防共享检测**完整实践。
> 全部结论来自一台真机实测：CMCC RAX3000M（MT7981B / Filogic 820，双核 Cortex-A53）+ ImmortalWrt 21.02-SNAPSHOT。
> 
> **校园网运营商：中国移动（已实测通过）。电信尚不清楚、未验证**，见第 6 节。
> **本项目由 DSH 助力完成** —— 从抓包定位门户协议、修复 UA3F 崩溃循环，到双出口看门狗与 WiFi 排障，全部过程在对话中逐步验证落地。2026-10。
>
> **许可证：[PolyForm Noncommercial 1.0.0](LICENSE)（禁止商业用途）。** 它是 **source-available**，不是 OSI 定义的开源许可证，详见第 11 节。
> **作者保留全部商业权利**（可自行售卖、付费服务、商业授权/双许可），且该等权利**不继承**给 fork、衍生作品与下游使用者，见 [`NOTICE`](NOTICE)。
> **免责：仅供个人学习研究，请遵守学校校园网管理规定，风险自负。** 见第 7 节。

---

## ⚠️ 买路由器前必须确认（这一节能帮你省一台路由器的钱）

这套方案的地基只有三件事：**内核里有 nftables（或至少 NFQUEUE）**、**能装包**、**WAN 口是独立网口**。
缺任何一条，UA3F 要么装不上、要么一启动就崩、要么配了等于没配。

### 必须满足（按优先级）

| # | 能力 | 为什么必须 | 怎么验 |
|---|---|---|---|
| 1 | **nftables**（`CONFIG_NF_TABLES=y`）+ `nft` 命令 | UA3F 3.x 的现代后端，有它就不需要 NFQUEUE | `which nft && nft list ruleset` |
| 2 | **或** NFQUEUE（`CONFIG_NETFILTER_XT_TARGET_NFQUEUE=m/y`） | 老内核的退路：UA3F 的 `desync`/`tcpts` 靠它 | `zcat /proc/config.gz \| grep NFQUEUE` |
| 3 | `xt_TPROXY` 或 `nft_tproxy` | TPROXY 透明代理必需 | `ls /lib/modules/$(uname -r)/ \| grep -i tproxy` |
| 4 | `ipset` | UA3F 用 ipset 维护 LAN / 跳过表 | `which ipset` |
| 5 | 能用的包管理器 + 源 | 装 UA3F 及其依赖 | `opkg update` 或 `apk update` **不报错** |
| 6 | 独立 WAN 口（不是单网口） | 校园网进、LAN 出，物理隔离 | `cat /etc/board.json` 看 `wan.device` |

### 加分项

- `CONFIG_NETFILTER_XT_TARGET_TCPOPTSTRIP`：能在转发路径上直接剥 TCP 时间戳，不用像我们这样绕
- 内核 ≥ 5.10（OpenWrt 23.05+ / ImmortalWrt 24.10+），内存 ≥ 256MB（UA3F 二进制就有 15MB）
- **官方主线固件**（OpenWrt / ImmortalWrt 都能 `sysupgrade`，软件源常年可用）

### 千万别买 / 别用

- **MTK 原厂 SDK 固件**：没有 `/etc/config/wireless`，无线配置写在 `/etc/wireless/mediatek/*.dat` 里，改信道/加密必须重启，升级极其痛苦——本文这台就是，血泪
- **"精简版/加速版"固件**：netfilter 模块常被裁掉，UA3F 直接 crash loop
- **21.02 及更老分支**：没有 nftables，软件源基本全 404（本文设备就是 21.02-SNAPSHOT，`opkg update` 全军覆没）
- **单网口设备**：没法同时接校园网和 LAN

> **一句话**：下单前先看参数表；到货 7 天内 SSH 进去跑 `nft list ruleset` 和 `opkg update`，两个都通再留下，不通就退。

---

## 0. 结论速览（急着用就看这段）

| 问题                | 一句话答案                                                                    |
| ----------------- | ------------------------------------------------------------------------ |
| 学校用什么认证           | **城市热点 Dr.COM（BOSS 版）**，门户 `http://1.1.1.1:8888/`，路径 `/webauth.do`       |
| 能用深澜/ePortal 的工具吗 | **不能**。`/eportal/portal/login` 返回 404，`campus-auth-guardian` 这类插件在这没用    |
| 运营商               | **移动已实测通过**（账号就是手机号）；**电信未验证**，见第 6 节                                    |
| 认证怎么算成功           | 探测 `http://connect.rom.miui.com/generate_204`：**302 = 被门户劫持，204 = 真的通了** |
| 核心组件              | `campus-drcom`（认证保活）+ `campus-guard`（断线回退）+ `ua3f`（改 UA/TTL）             |
| 最大的坑              | 把校园口设成唯一默认出口、又没有回退机制 → 门户一挂就全网断（我们踩过，见 4.1）                              |
| 第二大的坑             | UA3F 的 `l3_rewrite_tcpts` 依赖 NFQUEUE，而这固件内核没编 → 无限崩溃循环                   |

---

## 1. 广航校园网的实际形态

### 1.1 认证系统

未认证时访问任意 HTTP 会被网关 302 到门户，地址形如：

```
http://1.1.1.1:8888/webauth.do?wlanacip=1.1.1.1&wlanacname=hhxy&wlanuserip=<你的IP>&mac=<你的MAC>&vlan=3017&url=<原URL>
```

- `wlanacname=hhxy` —— 航海学院，**这个值是关键**，缺了它会返回「未知网关，请检查接入设备是否配置正确!」
- `vlan=3017` —— 本楼栋业务 VLAN，换楼可能变（届时重新抓一次跳转）
- 门户是 **Dr.COM 城市热点 BOSS**（页面里有 `JSESSIONID-BOSS-0`），不是深澜

### 1.2 认证动作（三步，实测有效）

```sh
# 1) 先 GET 拿会话
curl -s -c /tmp/ck "http://1.1.1.1:8888/webauth.do?<上面的参数>"
SID=$(awk '/JSESSIONID/{print $7}' /tmp/ck)

# 2) POST 登录（注意 action 里带 ;JSESSIONID-BOSS-0=<sid>）
curl -s -b /tmp/ck \
  --data-urlencode "userId=<账号>"     --data-urlencode "passwd=<密码>" \
  --data-urlencode "wlanuserip=<你的IP>" --data-urlencode "wlanacname=hhxy" \
  --data-urlencode "wlanacip=1.1.1.1"  --data-urlencode "mac=<你的MAC>" \
  --data-urlencode "vlan=3017"         --data-urlencode "pageid=-1" \
  --data-urlencode "url=http://connect.rom.miui.com/" \
  "http://1.1.1.1:8888/webauth.do;JSESSIONID-BOSS-0=$SID?<上面的参数>"

# 3) 验证：204 才是成功
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: connect.rom.miui.com' \
  http://202.69.4.32/generate_204
```

> 注意：`userId` 就是账号本身（移动线路实测是手机号，不需要自己拼 `@cmcc`）。
> 早期我们用过深澜式工具，它会自动拼成 `,0,<账号>@cmcc` 并请求 `/eportal/portal/login` —— 那个路径在本校**不存在**。

### 1.3 认证之后

- 校园 DHCP 给的是 `10.244.x.x/19`，网关 `10.244.64.1`，DNS `223.5.5.5 / 114.114.114.114`
- 认证按 **IP+MAC** 绑定；换 IP（重新 DHCP）需要重新认证
- 会话会过期/被踢，所以需要常驻保活

---

## 2. 整体架构

```
        ┌──────────── 电脑 / 手机（LAN 192.168.1.0/24）
        │
   br-lan 192.168.1.1
        │
   ┌────┴─────────────────────────────────────────┐
   │  UA3F (TPROXY :1080)                         │  ← 终结全部 TCP，改 UA、TTL=64、无 TS
   │  campus-drcom  (每 60s 探测，掉线自动重登)    │
   │  campus-guard  (每 20s 探测，校园线挂了回退)  │
   └────┬───────────────────────┬─────────────────┘
        │ eth0.2 (campus)       │ apcli0 (热点/备用)
   校园网 10.244.x              手机热点 10.242.x
   metric 0                      metric 20
```

- **主出口**：校园口 `campus`（metric 0）
- **备用出口**：手机热点 `wan`（metric 20），校园线连续 3 次探测失败时自动接管
- **反检测三件套**：UA 改写、TTL=64、出站无 TCP 时间戳（详见第 5 节）

---

## 3. 部署步骤

### 3.0 前置检查

```sh
cat /etc/openwrt_release                 # 确认是 ImmortalWrt 21.02 / aarch64_cortex-a53
opkg print-architecture                  # 确认架构
cat /etc/board.json | grep -A3 '"wan"'   # 确认物理 WAN 口对应的设备（本机是 eth0.2）
swconfig dev switch0 show | grep -A2 '^Port 0:'   # 确认 WAN 口链路
```

> **本机事实**：物理 WAN 口 = 交换机 port 0 = `eth0.2`。出厂配置里 `eth0.2` 这个设备**根本没被任何 interface 引用**，所以网线插在 WAN 口上完全没反应——这是最先要修的。

### 3.1 建 campus 接口

```sh
uci set network.campus=interface
uci set network.campus.proto='dhcp'
uci set network.campus.device='eth0.2'
uci set network.campus.metric='10'      # 先设 10，确认通了再改 0
uci set network.campus.peerdns='1'
uci commit network

# 并进 wan 防火墙区（否则不 NAT）
uci add_list firewall.@zone[1].network='campus'
uci commit firewall

/etc/init.d/network reload
```

### 3.2 装认证保活

把 `scripts/` 里的文件放到位：

```sh
cp scripts/campus-drcom.sh   /usr/libexec/campus-drcom.sh
cp scripts/campus-drcom.init /etc/init.d/campus-drcom
chmod 755 /usr/libexec/campus-drcom.sh /etc/init.d/campus-drcom

# 配置（密码明文，文件 0600）
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
uci set campus-drcom.main.interval='60'
uci commit campus-drcom

/etc/init.d/campus-drcom enable
/etc/init.d/campus-drcom start
```

### 3.3 切主出口 + 装看门狗（**顺序不能反**）

```sh
cp scripts/campus-guard.sh   /usr/libexec/campus-guard.sh
cp scripts/campus-guard.init /etc/init.d/campus-guard
chmod 755 /usr/libexec/campus-guard.sh /etc/init.d/campus-guard
/etc/init.d/campus-guard enable
/etc/init.d/campus-guard start      # 先跑起来，再切 metric

uci set network.campus.metric='0'
uci set network.wan.metric='20'
uci commit network
/etc/init.d/network reload
ip route show default               # 确认 campus 在前
curl -s -o /dev/null -w '%{http_code}\n' https://www.baidu.com   # 200 才算成功
```

### 3.4 UA3F（可选，但多设备共享必需）

```sh
# 官方 ipk 的坑：外层被 gzip 包了一层，opkg 会报 "Unknown package"
# 需要重打包成普通 tar（三个内部组件字节不变）
# 且依赖 iptables-mod-nfqueue 装不上（内核没编 NFQUEUE），只能去掉该依赖安装
opkg install --force-depends /tmp/ua3f_repacked.ipk

# 关键：关掉 tcpts，否则无限崩溃
uci set ua3f.enabled.enabled='1'
uci set ua3f.main.server_mode='TPROXY'
uci set ua3f.main.port='1080'
uci set ua3f.main.desync_reorder='0'
uci delete ua3f.main.desync_inject
uci set ua3f.main.l3_rewrite_ttl='1'
uci set ua3f.main.l3_rewrite_ttl_value='64'
uci set ua3f.main.l3_rewrite_tcpts='0'      # ★ 必须是 0
uci commit ua3f
/etc/init.d/ua3f restart
```

验证：`logread | grep -i "Rewrite User-Agent"` 能看到改写记录。

### 3.5 反检测三件套

```sh
# 1) TTL 由 UA3F 统一改写为 64（自动）
# 2) 关闭路由器 TCP 时间戳（因为 UA3F 终结了全部 TCP，出站报文都来自路由器协议栈）
echo 'net.ipv4.tcp_timestamps = 0' >> /etc/sysctl.conf
sysctl -w net.ipv4.tcp_timestamps=0
# 3) 顺手封掉 Teredo（Windows 独有，UA 伪装成手机时这是矛盾点）
```

`/etc/firewall.dsh`（注册为 firewall include）：

```sh
iptables -I FORWARD -p udp --dport 3544 -j DROP
iptables -I FORWARD -p udp --sport 3544 -j DROP
iptables -I OUTPUT  -p udp --dport 3544 -j DROP
```

```sh
uci set firewall.dsh_include=include
uci set firewall.dsh_include.type='script'
uci set firewall.dsh_include.path='/etc/firewall.dsh'
uci set firewall.dsh_include.reload='1'
uci commit firewall && /etc/init.d/firewall reload
```

### 3.6 WiFi（本机是 MTK 原厂驱动，坑最多）

**这台固件没有 `/etc/config/wireless`**！配置在：

- `/etc/wireless/l1profile.dat`（总表）
- `/etc/wireless/mediatek/mt7981.dbdc.b0.dat`（2.4G）
- `/etc/wireless/mediatek/mt7981.dbdc.b1.dat`（5G）

改完必须**重启**才生效（驱动加载时读取）。关键参数：

```
AuthMode=WPA2PSK          # 别用 WPA2/WPA3 混合，部分手机连不上
Channel=149               # 别用自动选信道，会选到 60 等 DFS 信道
AutoChannelSelect=0
VHT_BW=2                  # 80MHz
```

关 2.4G AP（保留 5G AP 和 2.4G STA）：用 `scripts/wifi24off.init`。**不要写进 `/etc/rc.local`**——那时驱动还没建出 `ra0`，命令会静默失败。

---

## 4. 踩坑清单

### 4.1 ★ 单出口 + 无回退 = 全网断（最惨的一次）

现象：把 campus 设成 metric 0 后，门户开始返回 **503**（因为在已登录状态下又强制登录了一次，触发会话/频率限制），校园口路由还在但没有网，热点只是"备用路由"——**只要 campus 默认路由存在，流量就不会回落**，于是路由器彻底断网，只能断电重启。

教训与对策：

1. 切 metric 之前，**先**把 `campus-guard` 跑起来；
2. 认证脚本**不要**死循环重试，要指数退避（10s → … → 600s）；
3. 认证状态用 `generate_204` 判断，**不要**用 ping 通不通判断（1.1.1.1 是公网 DNS，ping 得通不代表门户可达）。

### 4.2 UA3F 在这台固件上跑不起来的三个原因

| 现象                                            | 根因                                                           | 处理                   |
| --------------------------------------------- | ------------------------------------------------------------ | -------------------- |
| `Unknown package 'ua3f'`                      | 官方 ipk 外层多套了一层 gzip                                          | 重打包成普通 tar           |
| `cannot find dependency iptables-mod-nfqueue` | 内核 `# CONFIG_NETFILTER_XT_TARGET_NFQUEUE is not set`，且软件源已失效 | 去掉该依赖安装              |
| 每 5 秒崩一次，procd 判定 crash loop                  | `l3_rewrite_tcpts`（删 TCP 时间戳）**无条件**初始化 NFQUEUE 辅助模块         | 关 `tcpts`、关 `desync` |

**关键结论**：这台内核里 `TCPOPTSTRIP`、`xt_IPID`、`NET_ACT_PEDIT`、`NET_CLS_BPF` 全都没编，所以**转发路径上改不了 TCP 选项、改不了 IPID**。唯一可行的是"让报文根本不带 TS"——见 3.5。

### 4.3 软件源已死

`mirrors.ustc.edu.cn` 上 `21.02-SNAPSHOT` 的 Packages.gz 全部 404，`opkg update` 必然失败。
→ 所有包必须**本地 sideload**，不要指望 `opkg install <名字>`。

### 4.4 城市的门户只认真实跳转参数

直接 `GET /webauth.do` 会得到「未知网关」。必须先从一次真实的未认证访问里**抓 302 的 Location**，拿到 `wlanacname/vlan` 等参数。

### 4.5 别用那个插件

`Yusakisakura/campus-auth-guardian-openwrt` 实现的是**深澜 ePortal** 协议（`POST /eportal/portal/login?callback=dr1005&user_account=,0,<号>@cmcc...`）。
广航是 **Dr.COM webauth**，该路径 404 → 插件永远认证失败。**装它纯属浪费时间**，我们最后是自己写脚本。

### 4.6 宵禁 / 夜间断网（00:00–07:00）

学校可能在凌晨 0–7 点断网。三个组件在这段时间的行为：

| 组件 | 宵禁期间的行为 |
|---|---|
| `campus-guard` | 校园口连续 3 次探测失败（约 60s）→ 自动回退热点；之后每 30s 探测一次，**网络恢复后 1 分钟内自动切回** |
| `campus-drcom` | 指数退避：10s → 20s → … → 600s；连续失败 8 次后拉长到 **1800s**（每半小时一次） |
| 空闲时 | 只做一次 `generate_204` 探测（约 1KB），不产生多余流量 |

**唯一的风险点**：如果宵禁只是"踢下线"、门户仍然返回 302，认证脚本会整夜反复 POST 密码（最坏 42 次/夜），可能触发门户风控或账号异常告警。
如果你的学校是这种情况，建议开启**夜间静默**：

```sh
uci set campus-drcom.main.quiet_start='0000'
uci set campus-drcom.main.quiet_end='0700'
uci commit campus-drcom
```

效果：这段时间**只探测、不登录**，日志里会是 `quiet hours 0000-0700, skip login`；07:00 之后第一轮就恢复正常认证，不需要人工干预。留空（默认）即关闭该功能。

两个补充说明：

- 如果夜里手机热点也关了，回退后确实没有出口——但这是"本来就没网"，不是脚本把网络弄坏了；等校园网恢复或热点重新打开，会自动回来。
- 宵禁期间 DHCP 续租可能让 netifd 把校园默认路由重新加回来，`campus-guard` 会在 60s 内再次判定并回退，期间最多闪断 1 分钟——这是可接受的抖动，不要误以为脚本坏了。


---

## 5. 反检测到底覆盖了哪些

| 检测面        | 手段                                          | 状态                              |
| ---------- | ------------------------------------------- | ------------------------------- |
| User-Agent | UA3F 改写为 Android 移动端 UA                     | ✅ 已验证                           |
| TTL        | UA3F `POSTROUTING -j TTL --ttl-set 64`      | ✅ 出站 100% 64                    |
| TCP 时间戳    | `net.ipv4.tcp_timestamps=0` + UA3F 终结全部 TCP | ✅ SYN 全部无 TS                    |
| IPID       | 无法改写（内核无 xt_IPID）                           | ⚠️ 实测每条流随机，与普通 Linux 手机一致，判定风险低 |
| UDP/QUIC   | UA3F 只管 TCP，UDP 纯 NAT                       | ⚠️ 唯一的行为破绽（多设备会产生多条 UDP 流）      |
| Teredo     | 已封                                          | ✅                               |

抓包实测（90 秒，两个设备在线）：WAN 侧只有一个源 IP、TTL 全 64、291 个 SYN 零时间戳、SYN 窗口全是 64240。

### 5.1 已知漏洞（诚实清单）

上面打勾的只是"能改的那几项"。以下是**截至 2026-10 仍然存在的破绽**，按被识别的可能性排序。
不写清楚这些，后来的人会误以为"配完就隐身了"。

| # | 破绽 | 严重度 | 现状（实测/机理） | 能不能补 |
|---|---|---|---|---|
| 1 | **UDP 完全不受控** | 高 | UA3F 只接管 TCP，UDP 是纯 NAT。90 秒实测 **238 条 UDP 流**，典型如笔记本用同一源端口 `63312` 打 42 个公网 IP 的 `3378/udp`（P2P 特征） | 只能用隧道整体封装，或别在这条线路上跑 P2P |
| 2 | **HTTPS 的 SNI / 目标域名** | 高 | TLS 是端到端的，UA3F 只转发字节。校园能看到 `steamcommunity.com`、`windowsupdate.com` 这类"PC 才会访问"的域名 | 需开 MITM（要装 CA，麻烦且影响安全）或隧道 |
| 3 | **IPv6 一旦下发就摊牌** | 高（目前未发生） | 现在 LAN 只有 `fdba:` 内网 ULA，所以没泄漏；若校园或路由器给 LAN 下发公网前缀，**每台设备一个独立 global 地址**，等于直接自报家门 | 需关闭 LAN IPv6 / RA / 前缀委派 |
| 4 | **TLS 指纹（JA3/JA4）** | 中高 | ClientHello 的 cipher/extension 顺序由客户端 OS+浏览器决定，UA3F 不改。多设备的 ClientHello 会呈现多种指纹 | 需 MITM，或统一到一个浏览器内核出口 |
| 5 | **并发连接规模** | 中 | 90 秒内 **264 个不同目的 IP、300 条 TCP 流**；单台手机很难达到这个量级 | 无解，属行为特征；减少设备/减少常驻应用能压低 |
| 6 | **WAN 侧 DHCP 指纹** | 中 | 路由器用 busybox `udhcpc` 发 DHCP，option 55 请求列表是路由器特征，不像 Android 客户端 | 可改（`reqopts`/`vendorid`），**我们没做** |
| 7 | **应用层行为** | 中 | 手机自带 SDK 会做各种探测（实测抓到手机向 5 个公网 IP 的 **TCP/7** 建连，握手完成后 FIN）；笔记本有 P2P 扇出 | 只能在设备侧关应用，路由器看不出是哪个 App |
| 8 | **IPv4 IPID** | 中低 | 内核无 `xt_IPID`、无 `NET_ACT_PEDIT`、无 `NET_CLS_BPF`，**无法改写**。实测每条流随机起跳，与普通 Linux 手机一致；TCP 侧已因 UA3F 终结而统一，残留主要在 UDP | 不可修（除非换带 xt_IPID 的固件/内核） |
| 9 | **TCP 层 DPI 对抗** | 中低 | 本机内核没编 NFQUEUE，UA3F 的 `desync` / `tcpts` 全关，没法做 TCP 行为规避 | 需换固件（nftables 内核） |

**为什么补不全**：UA3F 的本质是「TCP 代理 + HTTP 头改写」，不是「整机虚拟化」。
它能让校园看到的 **TCP 连接**看起来像一台安卓手机，但改变不了：
UDP 的存在、TLS 里的域名与指纹、以及"一个 IP 上突然出现多少种服务"这件事本身。

真正彻底的做法只有一条：**把整机流量封进隧道**（WireGuard 到自己的服务器），校园网只看到一条 UDP 流。
代价是需要一台公网服务器、多一跳延迟，而且部分校园网会限速/封 UDP 大流量。

**自己怎么复查**（copy 即可）：

```sh
# 1) UDP 流数量与扇出（按目的地址统计，看有没有一个端口打一堆 IP）
tcpdump -i <WAN> -nn -c 500 'udp' | awk '{print $5}' | sort | uniq -c | sort -rn | head

# 2) TLS 里的 SNI（ClientHello 是明文，能直接看出访问了哪些站）
tcpdump -i <WAN> -nn -A -s0 'tcp port 443' 2>/dev/null \
  | grep -aoE '[a-z0-9][a-z0-9.-]{3,}\.(com|cn|net|org|io|edu)' | sort -u | head -20

# 3) 并发规模（单位时间内新建多少个 TCP 连接）
tcpdump -i <WAN> -nn 'tcp[tcpflags] & tcp-syn != 0' | wc -l
```

---

### 5.2 别把自己暴露成一台路由器（主动探测面）

前面讲的是"流量像不像手机"，这一节讲**"端口扫描看你像不像路由器"**——后者更容易被抓，而且一次 nmap 就够了。

**2026-10-22 在一台实际在用的设备上查出来的问题**（全部实测）：

| 问题 | 后果 |
|---|---|
| `firewall.@defaults[0].input='ACCEPT'` + `zone wan input='ACCEPT'` | WAN 入站**完全不设防**，等于防火墙对校园网敞开 |
| uhttpd 监听 `0.0.0.0:80/443` | LuCI 登录页对校园网可见，realm 直接写着 `ImmortalWrt` |
| haproxy 监听 `0.0.0.0:81/444/60000` | 发行版自带的示例配置（后端指向不存在的 `192.168.1.x`），白白开了三个口 |
| wsdd2 监听 `0.0.0.0:3702/5355` | WS-Discovery 里宣告 `vendor:sn,model:X3002-MB/SN_R1` —— **硬件型号直接广播** |
| dnsmasq 监听 `10.244.x.x:53` | 同网段可达 → 变成校园网里的开放解析器 |
| DHCP 未设 `hostname` | `dhcp.sh` 默认回落到系统名，把 **`ImmortalWrt`** 报给校园 DHCP |
| avahi 在所有接口发 mDNS | 对外宣告 **`ImmortalWrt.local`** |

对应的加固（已在实际设备上验证；全部可回滚，改前会自动备份 `/etc/config/*.bak.<时间戳>`）：

```sh
# 1) 收紧 WAN 入站（lan 不动，不影响上网）
uci set firewall.@defaults[0].input='REJECT'
uci set firewall.@zone[1].input='REJECT'
uci commit firewall

# 2) LuCI 只绑 LAN
uci set uhttpd.main.listen_http='192.168.1.1:80'
uci set uhttpd.main.listen_https='192.168.1.1:443'
uci commit uhttpd

# 3) 停用 Samba 网络发现（会把型号广播出去）
/etc/init.d/wsdd2 stop; /etc/init.d/wsdd2 disable

# 4) 停用 haproxy（发行版示例配置，无真实后端）
/etc/init.d/haproxy stop; /etc/init.d/haproxy disable

# 5) mDNS 只走 LAN
sed -i '/^\[server\]/a allow-interfaces=br-lan' /etc/avahi/avahi-daemon.conf
/etc/init.d/avahi-daemon restart

# 6) DHCP 不上报主机名（'*' = 不发 hostname 选项）
uci set network.campus.hostname='*'
uci commit network

/etc/init.d/firewall reload
/etc/init.d/uhttpd restart
```

**验证**（三行就够）：

```sh
iptables -S zone_wan_input | tail -1
# -A zone_wan_input ... -j zone_wan_src_REJECT      ← 必须是 REJECT/ DROP

netstat -lntp | awk '/0\.0\.0\.0:|:::/'
# 应该只剩 127.0.0.1 / 192.168.1.1 上的服务，不再有 0.0.0.0:80/443/81/444/3702/5355

ip maddr show dev <WAN接口> | grep -c 224.0.0.251
# 0
```

几点说明：

- **别把 `Allow-Ping` 删掉**：手机也会回 ICMP，一个完全不回 ping 的 IP 反而更可疑。
- dnsmasq 仍然监听在 WAN IP 上（`10.244.x.x:53`），但已经被防火墙挡住；想更彻底可以再把它绑到 LAN。
- 改完 LuCI 只能在 `http://192.168.1.1` 打开；如果你之前用校园网 IP 访问过，记得改书签。
- 这些改动**不影响**认证保活、看门狗、UA3F：实测 `probe=204`、`baidu=200`、UA3F 的 29 条规则完好。

> **一句话**：伪装流量是"别让它觉得你在共享"，收敛端口是"别让它知道你是谁"。后者优先级更高。

### 5.3 证书信任库别放到发霉

5.2 收的是"别被扫到"，这一条收的是"别信错人"。

路由器本身不解密 TLS，所以 CA 库陈旧**不影响手机电脑**，只影响**路由器自己发起的 HTTPS**（固件/包下载、将来的 DoH、脚本里的 API 调用）。但只要你还在这台机器上装东西，它就值得看一眼——**每当有 CA 因安全事故被吊销或从信任库移除，旧库仍然信任它**，库越旧，"本该不信任却还在信任"的窗口就越大。

查一眼（只读）：

```sh
opkg list-installed | grep -E 'ca-bundle|ca-certificates'
# ca-bundle - 20230311-1        ← 版本里的日期 = 信任库快照时间
grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt
```

判断标准：

- 版本日期 **超过 18 个月** 就该更新；
- 同时看一眼设备上有没有**手工装过**的根证书（抓包/MITM 工具留下的），有就删。

怎么更新：

- 首选 **升级固件**（`sysupgrade` 会带上新库）；
- 不能刷机就手动 sideload `ca-bundle` / `ca-certificates` 的 `.ipk`。这两个包是 `Architecture: all`，不挑架构，从同分支的 packages 源取即可。

两个别做：

- **别手工往 `/etc/ssl/certs` 里塞来路不明的根证书**；
- **别轻易给 UA3F 开 `--mitm`**：那等于自己在路由器上装一张自签 CA，所有终端都要信任它，一旦这张证书泄露，**全屋流量都可被解密**——风险比"库旧了"高一个量级。

> 一句话：库旧不等于马上出事，但它决定了"真出事时你还会不会继续相信骗子"。

### 5.4 实战：撤销对 eMudhra / emSign 的信任（2026-10）

起因：流传的一则通知说印度 CA **eMudhra** 的中间证书出问题。核实后属实——官方说明页在 `https://emudhra.we-have-a-problem.com/`（标题 *eMudhra Intermediate CA Compromise*），页面提供自测：

```sh
curl https://dv-g3b-emudhra.we-have-a-problem.com/
# 返回 "Your client successfully connected to the site. That's bad!"
#   说明你的客户端仍然信任这条链 —— 这是坏消息
```

**为什么路由器的静态信任库必然中招**：这条链是

```
leaf → EM DV TLS CA - G3B → emSign Root TLS CA - G3 → emSign ECC Root CA - G3（锚点）
```

锚点是 `emSign ECC Root CA - G3`，而它就在 2023 年的 `ca-bundle` 里。浏览器靠厂商推送的根证书更新来撤销，**路由器没有这个通道**，所以只能手工删。

移除（一行，自动备份、可回滚）：

```sh
sh tools/distrust-ca.sh emSign          # 干跑：只列出会被删的证书
sh tools/distrust-ca.sh emSign --apply  # 执行
```

实测结果（本机，2026-10-22）：

| 测试域名 | 移除前 | 移除后 |
|---|---|---|
| `dv-g3b/dv-g3c/ov-g3b/ov-g3c/ev-g3b/ev-g3c-emudhra.…`（emSign 链） | 200 | **验证失败（000）** ✅ |
| `*-aaa-emudhra.…`（经 AAA 交叉签名的链） | 200 | **仍然 200** ⚠️ |
| baidu / qq / aliyun / mirrors.ustc | 200 | 200 |

移除的 4 张根证书：`emSign ECC Root CA - C3`、`emSign ECC Root CA - G3`、`emSign Root CA - C1`、`emSign Root CA - G1`（bundle 从 140 张降到 136 张）。

**必须知道的限制**：`*-aaa-*` 那批仍然可信，因为它们的锚点是 `AAA Certificate Services`（Sectigo 的老根）。**这个根不能删**——半个互联网的证书都挂在它下面，删了会连带弄坏正常网站。这种"交叉签名"路径只能等 CA 自己吊销中间证书（CRL/OCSP 生效），而 OpenSSL 默认不做 CRL 检查。

两个操作要点：

- **判断是否还信任，不要 `grep` PEM 文件**：PEM 是 base64，里面没有可读的 CA 名字。要用
  `openssl crl2pkcs7 -nocrl -certfile /etc/ssl/certs/ca-certificates.crt | openssl pkcs7 -print_certs -noout | grep -i emsign`
- **固件升级或重装 `ca-bundle` 会把证书装回来**，升级后要复查一次；`tools/distrust-ca.sh` 可以重复执行，已删过的不会再报错。

> 这类"CA 被攻破"的处置原则：**先确认锚点是谁**，能删的删，删不得的（如 AAA）就明确记录为已知风险，别为了看起来干净去删一个承担半个互联网的根。

---

## 6. 已知限制 / 未验证

1. **电信线路未验证**：本校移动实测通过（账号=手机号，直接填即可）。电信可能需要账号后缀（如 `@telecom`）或在门户上选运营商，**需要有人实测后补充本节**。
2. **防检测还有 9 处已知漏洞**：UDP、HTTPS SNI、IPv6、TLS 指纹、并发规模等，详见 **5.1 已知漏洞（诚实清单）**。
3. **门户协议可能变**：学校升级门户后 `wlanacname/vlan/路径` 都可能变，届时重新抓一次 302 即可。
4. **`vlan=3017` 是楼栋相关的**，换宿舍/教学楼要重新抓。
5. **本方案不保证"隐身"**：它只是把能被改的信号改掉，并把剩余风险列清楚；是否够用取决于学校实际用什么策略（这一点只能靠长期观察）。

---

## 7. 安全与合规

- 校园网账号密码在 `/etc/config/campus-drcom` 里是**明文**（0600，仅 root 可读）。备份、截图、发日志时注意。
- 本方案只解决"自己的设备少走弯路"，**不要**用来给室友开共享、倒卖账号或绕过学校的计费策略。
- 学校明确禁止多设备共享，请遵守校规；本文的技术细节仅作学习记录。
- 改动路由器前务必备份 `/etc/config/network`，并保留一条**物理可达**的恢复路径（LAN 口 + 有线）。
- **公开发布不等于学校认可**：仓库里的校名、`wlanacname`、VLAN 等参数只是技术记录。若学校要求下架，请配合删除。
- 许可证禁止商业用途（见第 11 节）；转载、二次分发请保留版权声明与许可证全文。

---

## 8. 文件清单

```
gh-campus-network/
├── README.md                      # 本文
├── SKILL.md                       # 给 AI agent 的可执行手册
├── LICENSE                        # PolyForm Noncommercial 1.0.0（禁止商用）
├── LICENSE.zh-CN.md               # 许可证中文说明（非正式译本）
├── NOTICE                         # 作者保留商业权利 + 权利不继承
├── .gitignore                     # 排除凭据、抓包、备份、打包产物
├── .gitattributes                 # 强制 LF（脚本带 CRLF 到路由器会跑不起来）
├── scripts/
│   ├── campus-drcom.sh            # 认证保活（每轮重读配置，改密码无需重启）
│   ├── campus-drcom.init          # procd 包装
│   ├── campus-guard.sh            # 出口看门狗（3 次失败回退热点，恢复后自动切回）
│   ├── campus-guard.init          # procd 包装
│   ├── wifi24off.init             # 关 2.4G AP（等 ra0 出现再 down）
│   ├── firewall.dsh               # 封 Teredo
│   └── install.sh                 # 一键安装（默认不切换出口）
├── reference/
│   └── portal-protocol.md         # 门户协议与抓包证据
└── tools/
    ├── privacy-audit.py           # 发布前自检：手机号/MAC/内网IP/口令/令牌/私钥/身份证/本地路径
    ├── privacy-allowlist.txt      # 允许的「基础设施地址」清单
    └── distrust-ca.sh             # 按关键字撤销某个 CA（重建 bundle，自动备份）
```

### 8.1 脱敏说明（公开发布前已处理）

本文档从真实设备整理而来，**示例中的账号、密码、MAC、客户端 IP 全部已替换为占位符**：

- 账号/密码从不写入文档，只出现在路由器本地的 `/etc/config/campus-drcom`（0600）
- 抓包示例里的 MAC 统一写成 `aa:bb:cc:dd:ee:ff`，客户端 IP 写成 `10.244.x.x`
- 同网段其他同学的 IP 已打码为 `10.244.y.y`
- 保留下来的 `10.244.64.0/19`、`10.244.64.1`、`192.168.1.1` 属于**校园网/系统的基础设施地址**，不是个人信息
- 版权人写的是 `gh-campus-network contributors`（匿名），没有真名、学号、邮箱、QQ/微信或本机路径
- 仓库里**不含** `.7z` 打包件、抓包文件、路由器配置备份；`.gitignore` 已默认排除

贡献代码或文档前，请先跑一遍自检（发现即返回非 0，可直接进 CI）：

```sh
python3 tools/privacy-audit.py .
# CLEAN — no personal data found
```

## 9. 变更记录

- 2026-10-21 首版：完成认证打通、UA3F 修复、双出口看门狗、WiFi 5G 修复、反检测三件套与抓包验证。
- 2026-10-21 补充：开头新增「买路由器前必须确认的能力清单」，结尾新增友情链接。
- 2026-10-21 补充：新增 **§5.1 已知漏洞（诚实清单）**——UDP / HTTPS SNI / IPv6 / TLS 指纹 / 并发规模 / DHCP 指纹 / IPID / TCP DPI 共 9 项，附自查命令。
- 2026-10-21 开源准备：全文脱敏（账号/密码/MAC/客户端 IP/第三方 IP），新增 `LICENSE`、`tools/privacy-audit.py` 与自检说明。
- 2026-10-21 补充：新增 **§4.6 宵禁 / 夜间断网**；`campus-drcom` 增加 `quiet_start`/`quiet_end`（夜间静默）与 `max_fail`（连续失败后拉长到 30 分钟）两个选项。
- 2026-10-22 补充：新增 **§5.2 主动探测面**。实测发现 WAN 入站策略是 ACCEPT、LuCI/haproxy/wsdd2/dnsmasq 对校园网可见、DHCP 上报主机名、mDNS 广播 `ImmortalWrt.local`；已全部收敛并验证（UA3F 与认证不受影响）。
- 2026-10-22 发布准备：许可证由 MIT 换成 **PolyForm Noncommercial 1.0.0（禁止商业用途）**，版权人匿名；新增 `LICENSE.zh-CN.md` 与 `.gitignore`；补充合规声明；`tools/privacy-audit.py` 增加访问令牌 / 私钥 / 身份证号检测。
- 2026-10-22 权利补充：新增 [`NOTICE`](NOTICE)，明确**作者保留全部商业权利**（售卖 / 付费服务 / 商业授权 / 双许可 / 转让），且**商业权利不继承**给 fork、衍生作品与下游；`LICENSE` 的 `Required Notice` 同步写入保留声明，随分发自动传播。
- 2026-10-22 补充：新增 **§5.3 证书信任库别放到发霉**——`ca-bundle` 版本超过 18 个月应更新、离线升级方式，以及"别塞来路不明的根证书 / 别轻易开 UA3F MITM"两条红线。
- 2026-10-22 事件处置：新增 **§5.4 撤销 eMudhra / emSign 信任**。实测本机 `curl https://dv-g3b-emudhra.…` 返回 "successfully connected — that's bad!"，说明 2023 年的信任库仍锚定 `emSign ECC Root CA - G3`；已用 `tools/distrust-ca.sh` 删除 4 张 emSign 根证书（140→136），6 个测试域名全部验证失败，正常站点不受影响；经 AAA 交叉签名的链路仍可连，已记录为已知限制。

---

## 10. 友情链接

| 项目 | 地址 | 说明 |
|---|---|---|
| **UA3F** | https://github.com/SunBK201/UA3F | 本文的核心组件：HTTP 头重写 / 反共享检测，作者 SunBK201 |
| UA3F Releases | https://github.com/SunBK201/UA3F/releases | 下载 ipk/apk 的地方；注意先看后缀和架构 |
| **OpenWrt** | https://openwrt.org/ | 上游项目，文档、Wiki、硬件支持列表 |
| OpenWrt 固件选择器 | https://firmware-selector.openwrt.org/ | 按型号查官方固件，买设备前可以先查"有没有官方支持" |
| **ImmortalWrt** | https://immortalwrt.org/ | 国内常用的 OpenWrt 分支，中文软件包更全 |
| ImmortalWrt 下载 | https://downloads.immortalwrt.org/ | 按 target 找固件；建议选 24.10 及以上（自带 nftables） |

> 鸣谢：UA3F 让"宿舍路由器 + 校园网"这件事变得可行；OpenWrt / ImmortalWrt 提供了可折腾的底座。
> 本文档由 DSH 协助整理，献给广航后来的同学——少踩一个坑，就是省一晚上。

---

## 11. 许可证

本项目采用 **[PolyForm Noncommercial License 1.0.0](LICENSE)**，版权人写作 `gh-campus-network contributors`（匿名）。
中文说明见 [`LICENSE.zh-CN.md`](LICENSE.zh-CN.md)，**以英文 `LICENSE` 为准**。

| | 允许 | 不允许 |
|---|---|---|
| 个人学习 / 实验 / 毕设课程作业 | ✅ | |
| 学校、公益、公立科研机构内部使用 | ✅ | |
| 修改、fork、非商业转发（附许可证） | ✅ | |
| **作者本人**售卖 / 付费服务 / 商业授权 / 双许可 | ✅（作者保留） | |
| 其他人的商业使用、付费服务、引流变现 | | ❌ |
| fork / 衍生作品 / 下游分发者继承商业权利 | | ❌ |
| 去掉版权声明 / 改换成 MIT、GPL 等 | | ❌ |

三点必须说清楚：

1. **作者不适用"非商业"限制**。版权人保留全部商业权利：可以售卖、做付费服务、发放商业许可或双许可，也可以整体转让项目。详见 [`NOTICE`](NOTICE)。
2. **"禁止商用"不等于 OSI 开源**。GitHub 上应称为 **source-available**，仓库描述建议写 `source-available · noncommercial`，不要挂 `open-source` 话题标签。
3. **非商业许可与 GPL / MIT 不兼容**。别人不能把本项目代码并入 GPL/MIT 项目；引用 UA3F 等第三方组件时，遵守它们各自的许可证（UA3F 为 MIT）。

**商业权利不继承。** fork、衍生作品、下游分发者及其接收者，只拿到 `LICENSE` 规定的非商业许可，不因持有代码而获得商用资格，也不能把项目改成商业许可。
除版权人本人外，任何主体商用都需另行取得书面授权（当前仓库未提供联系方式）。

