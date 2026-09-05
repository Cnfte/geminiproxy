# geminiproxy

一键部署 Gemini 反向代理，助力国内用户流畅访问，并提供完整的后续运维管理菜单。

当前版本：**v2.2.0**

### 功能概述
- **简便部署**：单一命令即可在 Linux 服务器上完成 Gemini 反向代理与 SSL 证书的搭建。
- **广泛兼容**：支持 Ubuntu、Debian、CentOS/RHEL/Fedora/Rocky/AlmaLinux、Arch、openSUSE、Alpine 等主流 Linux 发行版，自动识别系统并安装依赖（nginx、openssl、curl、jq、bc、socat、lsof、tar 等）。
- **多种证书获取方式**：支持 webroot（零停机）、standalone（临时占用80端口）、DNS-01（适合泛域名 / NAT 无80端口映射场景）、手动指定证书路径共4种方式。
- **访问控制**：内置 Basic Auth 密码保护与 IP 白名单管理，可随时开关。
- **运维管理菜单**：安装完成后可反复调用脚本，进行重启、停止、卸载、完全清理、备份/恢复配置、状态检查（含证书到期提醒）、资源与代理监控、日志查看、证书手动续期等操作。
- **自动防火墙/SELinux 适配**：安装时自动为所选端口配置 ufw / firewalld / iptables 规则及 SELinux 端口策略。

### 重要提示
- 脚本仅代理 Gemini 官方 API（`generativelanguage.googleapis.com`），**不提供 Gemini 到 OpenAI 格式的转换**。
- 脚本需要 `root` 权限运行。
- 安装完成后，请确保您的域名已正确解析至服务器的公网 IP 地址（NAT 服务器请同时完成端口映射）。
- 脚本内注明"仅供学习使用"，请知悉并自行评估使用场景与合规性。
- 配置完成后，您可以在 Chatbox 等 AI 聊天软件中填入您的域名，以便与 Gemini 进行通信。

## 安装指南

### 1. 服务器准备
支持具备公网 IP 的独立服务器或 NAT 服务器，前提是能够正常访问互联网。为获得更佳网络延迟，建议选择马来西亚、韩国、日本等亚洲地区，或欧洲的服务器。

### 2. 服务器登录
请获取您的服务器的登录凭证（通常为 root 用户及密码）。
确认您的服务器已启动并可正常访问。
使用您偏好的 SSH 客户端（如 Xshell、FinalShell）连接至服务器。

![查找登录信息和确保服务器开机](img/1.jpg)
图1：确认登录凭证及服务器运行状态

![使用SSH工具连接到服务器](img/2.jpg)
图2：通过SSH客户端连接服务器

### 3. 执行安装

- 复制部署命令：
  ![复制部署代码](img/3.jpg)
  图3：复制部署命令

- 粘贴至服务器终端并执行：
  ![粘贴代码并回车执行](img/4.jpg)
  图4：在终端粘贴命令并执行

脚本启动后会自动检测系统、安装依赖并进行环境预检，随后进入管理菜单：

```
=====================================
 Gemini API 反代管理脚本 by cnfte v2.2.0
=====================================
1) 安装/配置反代（含SSL）
2) 重启反代
3) 停止Nginx
4) 卸载Nginx
5) 完全清理（Nginx/配置/缓存）
6) 备份配置
7) 恢复配置
8) 检查服务状态（含证书到期提醒）
9) 资源与代理监控
10) 查看日志
11) 访问控制管理（Basic Auth / IP白名单）
12) 手动续期证书
0) 退出
=====================================
```

首次安装请输入 `1`，脚本会依次询问：

1. **域名**：需为合法域名格式。
2. **绑定本地 IP**（默认 `0.0.0.0`）。
3. **HTTP / HTTPS 端口**（默认 `80` / `443`，1-65535 之间的数字）。
4. **证书获取方式**（四选一）：
   - `1` webroot：自动申请，零停机，要求公网 80 端口可达；
   - `2` standalone：自动申请，会临时停止 Nginx 释放所选 HTTP 端口用于验证；若该端口非 80，需确认路由器/NAT 已将公网 80 转发到本机对应端口，否则请改用方式 3；
   - `3` DNS-01：自动申请，适合泛域名或 NAT 无80端口映射的场景，需提前导出对应 DNS 服务商的 API 环境变量（如 Cloudflare 的 `CF_Token`），并输入 DNS API 标识（如 `dns_cf`、`dns_dp`）；
   - `4` 手动指定：直接提供已有的证书（`.crt`/`.pem`）与私钥（`.key`）路径。

  ![输入安装所需信息](img/5.jpg)
  图5：按提示输入域名、端口及SSL配置

配置完成后脚本会自动写入 Nginx 站点配置、按所选端口配置防火墙 / SELinux 策略、重启 Nginx，并将配置保存至 `/etc/gemini_proxy.conf`。

### 4. 开始使用

- 打开您常用的 AI 聊天客户端，例如 Chatbox 的 App 版或 Web 版。
  ![打开Chatbox应用](img/6.jpg)
  图6：启动Chatbox应用或网页版

- 进入设置界面。
  ![点击设置按钮](img/7.jpg)
  图7：访问Chatbox设置选项

- 在设置中填入您的代理域名以及 Gemini API Key（API Key 需自行通过 [Google AI Studio](https://ai.google.dev/) 获取，脚本本身不提供 Key）。
- 配置完成后，即可通过代理与 Gemini 进行流畅交流。

## 日常管理

安装完成后，再次运行脚本即可进入同一管理菜单，进行以下操作：

| 菜单项 | 说明 |
| --- | --- |
| 2 重启反代 | 重启 Nginx 服务 |
| 3 停止Nginx | 停止 Nginx 服务 |
| 4 卸载Nginx | 通过系统包管理器卸载 Nginx 并移除站点配置 |
| 5 完全清理 | 卸载 Nginx 并删除相关配置、日志、缓存与备份目录 |
| 6 备份配置 | 将 Nginx 站点配置、脚本配置、ACME 校验配置及 Basic Auth 密码文件打包备份至 `/var/backups/gemini_proxy` |
| 7 恢复配置 | 从指定的备份包中恢复以上文件（会校验包内文件路径，防止异常文件写入） |
| 8 检查服务状态 | 显示 Nginx 运行状态、配置语法、当前域名/端口/证书等配置，以及证书到期天数提醒（少于14天会高亮提示） |
| 9 资源与代理监控 | 每 5 秒刷新一次 CPU、内存、磁盘占用、当前连接数及代理接口 HTTP 状态码 |
| 10 查看日志 | 可选查看 Nginx 访问日志、错误日志、脚本日志，或（安装 multitail 时）三者聚合查看 |
| 11 访问控制管理 | 启用/关闭 Basic Auth 密码保护，设置或清除 IP 白名单 |
| 12 手动续期证书 | 通过 acme.sh 手动触发证书续期并重启 Nginx |

### 配置与日志路径
- 脚本配置文件：`/etc/gemini_proxy.conf`
- Nginx 站点配置：`/etc/nginx/conf.d/chat.conf`
- 脚本运行日志：`/var/log/gemini_proxy.log`
- Nginx 访问/错误日志：`/var/log/nginx/gemini_access.log` / `gemini_error.log`
- 配置备份目录：`/var/backups/gemini_proxy`

## 优化建议与注意事项
- 为获得更佳的网络延迟体验，建议选择马来西亚、韩国、日本等亚洲地区，或欧洲的服务器。
- 若证书剩余有效期不足 14 天，脚本会在"检查服务状态"中给出提醒，建议尽快通过菜单选项 12 续期。
- 开启 IP 白名单后，只有列表内的 IP/CIDR 可以访问代理，请确保不会把自己锁在外面。

## 安装命令（任选其一）

**方法一：下载脚本后手动执行（适合需要查看执行细节的用户）**

```shell
wget https://raw.githubusercontent.com/Cnfte/geminiproxy/refs/heads/main/proxy.sh
```
```shell
sudo bash proxy.sh
```

**方法二：下载并立即执行脚本（快速部署）**
```shell
wget https://raw.githubusercontent.com/Cnfte/geminiproxy/refs/heads/main/proxy.sh && sudo bash proxy.sh
```

**方法三：下载、执行并自动删除脚本（用完即清理）**
```shell
wget https://raw.githubusercontent.com/Cnfte/geminiproxy/refs/heads/main/proxy.sh && sudo bash proxy.sh && rm proxy.sh
```

如果可以，请给项目点个star不胜感激。
