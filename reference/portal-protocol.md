# 广航门户协议实录（Dr.COM / 城市热点 BOSS）

> 本文是 2026-10 在一台 CMCC RAX3000M（ImmortalWrt 21.02, 内核 5.4.284）上的实测记录。
> 目的：以后门户若改版，照着这里的"证据"重新比对，能快速判断改了哪一环。

## 1. 未认证时的跳转

从校园口（源 IP `10.244.x.x`）访问任意 HTTP，网关返回 302：

```
HTTP/1.1 302 Moved Temporarily
Location: http://1.1.1.1:8888/webauth.do?wlanacip=1.1.1.1&wlanacname=hhxy&wlanuserip=10.244.x.x&mac=aa:bb:cc:dd:ee:ff&vlan=3017&url=http://connect.rom.miui.com/
```

响应体是用 JS 再跳一次的 HTML（`location.replace("http://1.1.1.1:8888/webauth.do?...")`），
所以用 `curl -D -` 看 Header 最省事。

关键参数：

| 参数 | 含义 | 备注 |
|---|---|---|
| `wlanacip=1.1.1.1` | 网关（AC）地址 | 固定 |
| `wlanacname=hhxy` | 航海学院 | **缺了会报"未知网关"** |
| `wlanuserip` | 客户端 IP | 会变（DHCP 后重抓） |
| `mac` | 客户端 MAC | 小写冒号 |
| `vlan=3017` | 业务 VLAN | 与楼栋相关，换楼重抓 |
| `url` | 原访问地址 | 可填任意 http 地址 |

## 2. 门户是什么系统

- 根路径 `http://1.1.1.1:8888/` 返回 1137 字节的跳转页：`host === '1.1.1.1'` 时跳 `/webdisconnweb.do`（下线页），否则跳 `/login.do`
- 带正确参数访问 `/webauth.do` 返回约 75 KB 的登录页，表单 id 为 `goLoginForm`，账号/密码字段名是 `userId` / `passwd`
- 会话 Cookie 名为 **`JSESSIONID-BOSS-0`** → 城市热点 BOSS 版
- 页面里有 `/httpservice/checkUserPwd.do`、`/user/checkMacRepeat.do` 等 `.do` 端点

## 3. 认证请求（可用 curl 复现）

```
GET  http://1.1.1.1:8888/webauth.do?<上面的参数>
     → 200，Set-Cookie: JSESSIONID-BOSS-0=<sid>

POST http://1.1.1.1:8888/webauth.do;JSESSIONID-BOSS-0=<sid>?<上面的参数>
     Content-Type: application/x-www-form-urlencoded
     userId=<账号>&passwd=<密码>&wlanuserip=<IP>&wlanacname=hhxy&
     wlanacip=1.1.1.1&mac=<MAC>&vlan=3017&pageid=-1&url=<原URL>
     → 200，约 68 KB 的"欢迎/已在线"页面
```

判定成功**不要看响应内容**（页面里一堆 JS，容易误判），用下面的探针。

## 4. 认证状态探针（唯一可信判据）

```sh
# 探测地址 = connect.rom.miui.com 的 A 记录（实测 202.69.4.32）
ip route replace 202.69.4.32/32 via <校园网关> dev <WAN接口>
curl -s -o /dev/null -w '%{http_code}\n' \
     -H 'Host: connect.rom.miui.com' http://202.69.4.32/generate_204
```

| 返回 | 含义 |
|---|---|
| **204** | 已认证，真正能上网 |
| **302** | 被门户劫持，需要认证 |
| 000 / 超时 | 链路不通（网线、DHCP、VLAN 问题），不是认证问题 |

> 为什么不用 `ping 1.1.1.1`：1.1.1.1 同时是 Cloudflare 的公网 DNS，从别处 ping 得通，
> 与"本机所在校园网是否已认证"毫无关系。早期就是因为这个误判绕了半天。

## 5. 为什么深澜/ePortal 类工具在这里无效

实测：

```
GET http://1.1.1.1:8888/eportal/portal/login
→ 404 (nginx 错误页)

GET http://1.1.1.1:8888/webauth.do（不带参数）
→ 200，页面正文："未知网关，请检查接入设备是否配置正确!"
```

深澜式客户端（如 `campus-auth-guardian-openwrt`）会拼成：

```
POST /eportal/portal/login?callback=dr1005&login_method=1
     &user_account=%2C0%2C<账号>%40cmcc&user_password=***
     &wlan_user_ip=...&wlan_user_mac=000000000000
```

本门户没有这个接口 → 永远 404。**这条路走不通，别再试。**

## 6. 运营商情况

| 运营商 | 状态 | 说明 |
|---|---|---|
| **移动** | ✅ 已实测 | 账号就是手机号（如 `134xxxxxxxx`），POST 里**不需要**加 `@cmcc`；门户页面按普通账号处理 |
| 电信 | ❓ 未验证 | 若账号体系不同，可能需要后缀（如 `@telecom`）或在门户页选择运营商；需要实测后补充 |

验证方法（电信同学）：

1. 先用手机连校园网，浏览器打开任意 http 网站，确认跳转到同一个 `1.1.1.1:8888`；
2. 在门户页正常登录一次，F12 → Network，看 `webauth.do` 那条 POST 的 `userId` 具体长什么样；
3. 把它原样填进 `uci set campus-drcom.main.user='...'` 即可。

## 7. 其他实测细节

- 校园 DHCP 段：`10.244.64.0/19`，网关 `10.244.64.1`，DNS `223.5.5.5 / 114.114.114.114`
- 认证按 **IP + MAC** 绑定；重新 DHCP 换 IP 后需要重新认证
- 同一账号在已登录状态下**重复强制登录**，门户会返回 **503**，并可能触发风控 → 认证脚本必须指数退避，不要死循环
- WAN 口上游是**共享二层段**：抓包能看到同网段其他主机（如 `10.244.y.y`）的单播帧，属正常现象，不是自己泄漏
