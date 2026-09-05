#!/bin/bash
# 仅供学习使用请在安装24h后删除
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

VERSION="2.2.0"
CONFIG_FILE="/etc/gemini_proxy.conf"
BACKUP_DIR="/var/backups/gemini_proxy"
LOG_FILE="/var/log/gemini_proxy.log"
NGINX_SITE="/etc/nginx/conf.d/chat.conf"
ACME_DIR="/var/www/acme-challenge"
ACME_LOC_CONF="/etc/nginx/snippets/acme_challenge.conf"
HTPASSWD_FILE="/etc/nginx/.gemini_htpasswd"
ACME_BIN=""

set -euo pipefail

trap 'log "${RED}脚本在第 ${LINENO} 行执行失败（exit=$?)${NC}"' ERR

has_command() {
    local cmd="$1"
    type "$cmd" >/dev/null 2>&1
}

log(){ echo -e "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"; }

check_root(){
  if [ "$(id -u)" -ne 0 ]; then
    log "${RED}错误: 需 root 权限${NC}"
    exit 1
  fi
}

validate_domain(){
  local d="$1"
  if [[ "$d" =~ ^(\*\.)?([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    return 0
  fi
  return 1
}

validate_port(){
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

validate_ip(){
  local ip="$1"
  if [ "$ip" = "0.0.0.0" ] || [ "$ip" = "::" ]; then return 0; fi
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local IFS=.
    local -a parts=($ip)
    for part in "${parts[@]}"; do
      [ "$part" -ge 0 ] && [ "$part" -le 255 ] || return 1
    done
    return 0
  fi
  return 1
}

OS=""; OS_VERSION=""
detect_os(){
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    OS_VERSION=$VERSION_ID
  elif has_command lsb_release; then
    OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    OS_VERSION=$(lsb_release -sr)
  elif [ -f /etc/redhat-release ]; then
    OS="centos"
    OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
  elif [ -f /etc/arch-release ]; then
    OS="arch"
    OS_VERSION="rolling"
  else
    log "${RED}无法识别系统${NC}"
    exit 1
  fi
  log "${GREEN}已检测系统: $OS $OS_VERSION${NC}"
}

detect_pkg_manager(){
  if has_command dnf; then
    echo dnf
  else
    echo yum
  fi
}

init_system(){
  if has_command systemctl; then
    echo systemd
  elif has_command rc-service; then
    echo openrc
  else
    echo sysv
  fi
}

REQUIRED_CMDS=(nginx openssl curl jq bc socat lsof tar)
all_deps_present(){
  local c
  for c in "${REQUIRED_CMDS[@]}"; do
    has_command "$c" || return 1
  done
  return 0
}

install_dependencies(){
  if all_deps_present; then
    log "${GREEN}依赖已就绪，跳过安装${NC}"
    return 0
  fi
  log "${GREEN}安装依赖...${NC}"
  local packages=""

  case "$OS" in
    ubuntu|debian)
      apt update >/dev/null
      packages="nginx openssl curl jq bc socat lsof tar coreutils procps iproute2 cron ufw certbot python3-certbot-nginx multitail"
      DEBIAN_FRONTEND=noninteractive apt install -y $packages || log "${YELLOW}部分依赖安装失败，请手动检查${NC}"
      ;;
    centos|rhel|fedora|rocky|almalinux)
      local PM; PM=$(detect_pkg_manager)
      packages="nginx openssl curl jq bc socat lsof tar coreutils procps-ng iproute epel-release cronie firewalld certbot python3-certbot-nginx multitail policycoreutils-python-utils policycoreutils-python"
      "$PM" install -y $packages || log "${YELLOW}部分依赖安装失败，请手动检查${NC}"
      if has_command systemctl; then
          systemctl enable crond >/dev/null 2>&1 || true
          systemctl start crond >/dev/null 2>&1 || true
      fi
      ;;
    arch)
      packages="nginx openssl curl jq bc socat lsof tar coreutils procps-ng iproute2 cronie ufw certbot multitail"
      pacman -Sy --noconfirm $packages || log "${YELLOW}部分依赖安装失败，请手动检查${NC}"
      if has_command systemctl; then
          systemctl enable cronie >/dev/null 2>&1 || true
          systemctl start cronie >/dev/null 2>&1 || true
      fi
      ;;
    opensuse-leap|opensuse-tumbleweed|sles|opensuse)
      packages="nginx openssl curl jq bc socat lsof tar coreutils procps iproute2 cron python3-certbot python3-certbot-nginx multitail"
      zypper --non-interactive refresh >/dev/null 2>&1 || true
      zypper --non-interactive install -y $packages || log "${YELLOW}部分依赖安装失败，请手动检查${NC}"
      if has_command systemctl; then
          systemctl enable cron >/dev/null 2>&1 || true
          systemctl start cron >/dev/null 2>&1 || true
      fi
      ;;
    alpine)
      packages="bash nginx openssl curl jq bc socat lsof tar coreutils procps iproute2 dcron certbot multitail"
      apk update >/dev/null 2>&1 || true
      apk add --no-cache $packages || log "${YELLOW}部分依赖安装失败，请手动检查${NC}"
      if has_command rc-update; then
          rc-update add dcron default >/dev/null 2>&1 || true
          rc-service dcron start >/dev/null 2>&1 || true
      fi
      ;;
    *)
      log "${RED}不支持的系统: $OS${NC}"
      exit 1 ;;
  esac
  log "${GREEN}依赖安装完成${NC}"
}

configure_selinux_and_firewall(){
  local HTTP_PORT=$1 HTTPS_PORT=$2

  if has_command getenforce && (getenforce | grep -qE "Enforcing|Permissive"); then
    if has_command semanage; then
      semanage port -a -t http_port_t -p tcp "${HTTP_PORT}" 2>/dev/null || semanage port -m -t http_port_t -p tcp "${HTTP_PORT}" 2>/dev/null || true
      semanage port -a -t http_port_t -p tcp "${HTTPS_PORT}" 2>/dev/null || semanage port -m -t http_port_t -p tcp "${HTTPS_PORT}" 2>/dev/null || true
    fi
  fi

  if has_command ufw; then
    ufw allow "${HTTP_PORT}/tcp" >/dev/null 2>&1 || true
    ufw allow "${HTTPS_PORT}/tcp" >/dev/null 2>&1 || true
  fi
  if systemctl is-active firewalld >/dev/null 2>&1; then
    firewall-cmd --add-port="${HTTP_PORT}/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --add-port="${HTTPS_PORT}/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if has_command nft; then
    nft list ruleset 2>/dev/null | grep -q "dport ${HTTP_PORT}" || true
  fi
  if has_command iptables; then
    iptables -C INPUT -p tcp --dport "${HTTP_PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "${HTTP_PORT}" -j ACCEPT || true
    iptables -C INPUT -p tcp --dport "${HTTPS_PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "${HTTPS_PORT}" -j ACCEPT || true
  fi
}

port_in_use(){ lsof -iTCP:"$1" -sTCP:LISTEN -P -n >/dev/null 2>&1; }

ensure_acme_location(){
  mkdir -p "$ACME_DIR"
  tee "$ACME_LOC_CONF" >/dev/null <<EOF
location ^~ /.well-known/acme-challenge/ {
    root $ACME_DIR;
    default_type "text/plain";
    try_files \$uri =404;
}
EOF
}

write_nginx_conf(){
  local domain="$1" bind_ip="$2" http_port="$3" https_port="$4" cert="$5" key="$6"
  ensure_acme_location

  local access_ctrl_block=""
  if [ "${ENABLE_AUTH:-0}" = "1" ] && [ -f "$HTPASSWD_FILE" ]; then
    access_ctrl_block+=$'\n        auth_basic "Restricted";\n        auth_basic_user_file '"$HTPASSWD_FILE"';'
  fi
  if [ -n "${ALLOW_IPS:-}" ]; then
    local ip
    for ip in $ALLOW_IPS; do
      access_ctrl_block+=$'\n        allow '"$ip"';'
    done
    access_ctrl_block+=$'\n        deny all;'
  fi

  tee "$NGINX_SITE" >/dev/null <<EOF
server {
    listen ${bind_ip}:${http_port};
    server_name ${domain};
    include ${ACME_LOC_CONF};
    return 301 https://\$host:${https_port}\$request_uri;
}

server {
    listen ${bind_ip}:${https_port} ssl http2;
    server_name ${domain};

    ssl_certificate ${cert};
    ssl_certificate_key ${key};
    ssl_trusted_certificate ${cert};
    ssl_session_cache shared:ssl_cache:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_stapling on;
    ssl_stapling_verify on;

    server_tokens off;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;

    client_max_body_size 20m;
    keepalive_timeout 65;
    sendfile on;
    tcp_nopush on;

    resolver 8.8.8.8 1.1.1.1 valid=300s;
    resolver_timeout 5s;

    access_log /var/log/nginx/gemini_access.log;
    error_log  /var/log/nginx/gemini_error.log;

    location / {${access_ctrl_block}
        set \$gemini_backend "generativelanguage.googleapis.com";
        proxy_pass https://\$gemini_backend\$request_uri;
        proxy_ssl_server_name on;
        proxy_set_header Host generativelanguage.googleapis.com;
        proxy_http_version 1.1;
        proxy_set_header Connection '';
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_connect_timeout 10s;
    }
}
EOF
  if nginx -t >/dev/null 2>&1; then
    reload_nginx
    log "${GREEN}Nginx 配置已更新并重载${NC}"
  else
    log "${RED}Nginx 配置错误，请检查: $NGINX_SITE${NC}"
    nginx -t || true
  fi
}

nginx_is_running(){
  pgrep -x nginx >/dev/null 2>&1
}

start_nginx(){
  case "$(init_system)" in
    systemd)
      systemctl enable nginx >/dev/null 2>&1 || true
      systemctl start nginx >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-update add nginx default >/dev/null 2>&1 || true
      rc-service nginx start >/dev/null 2>&1 || true
      ;;
    *)
      service nginx start >/dev/null 2>&1 || true
      ;;
  esac
  sleep 1
  if nginx_is_running; then
    log "${GREEN}Nginx 已启动${NC}"
  else
    log "${YELLOW}服务管理器未能启动 Nginx，尝试直接调用 nginx 二进制...${NC}"
    nginx >/dev/null 2>&1 || true
    sleep 1
    if nginx_is_running; then
      log "${GREEN}Nginx 已启动（直接调用）${NC}"
    else
      log "${RED}Nginx 启动失败，请手动检查 (nginx -t / journalctl)${NC}"
    fi
  fi
}
restart_nginx(){
  case "$(init_system)" in
    systemd) systemctl restart nginx >/dev/null 2>&1 || true ;;
    openrc)  rc-service nginx restart >/dev/null 2>&1 || true ;;
    *)       service nginx restart >/dev/null 2>&1 || true ;;
  esac
  sleep 1
  if nginx_is_running; then
    log "${GREEN}Nginx 已重启${NC}"
  else
    log "${YELLOW}服务管理器未能重启 Nginx，尝试 stop+start...${NC}"
    stop_nginx
    start_nginx
  fi
}
stop_nginx(){
  case "$(init_system)" in
    systemd) systemctl stop nginx >/dev/null 2>&1 || true ;;
    openrc)  rc-service nginx stop >/dev/null 2>&1 || true ;;
    *)       service nginx stop >/dev/null 2>&1 || true ;;
  esac
  sleep 1
  if nginx_is_running; then
    log "${YELLOW}服务管理器未能停止 Nginx，尝试直接发送信号终止...${NC}"
    pkill -TERM -x nginx >/dev/null 2>&1 || true
    sleep 1
    nginx_is_running && { pkill -KILL -x nginx >/dev/null 2>&1 || true; sleep 1; }
  fi
  if nginx_is_running; then
    log "${RED}Nginx 未能完全停止，可能有其他进程持有该端口${NC}"
  else
    log "${GREEN}Nginx 已停止${NC}"
  fi
}

wait_for_port_free(){
  local port="$1" timeout="${2:-10}" waited=0
  while port_in_use "$port"; do
    sleep 1
    waited=$((waited+1))
    [ "$waited" -ge "$timeout" ] && return 1
  done
  return 0
}
reload_nginx(){
  case "$(init_system)" in
    systemd) systemctl reload nginx >/dev/null 2>&1 || true ;;
    openrc)  rc-service nginx reload >/dev/null 2>&1 || true ;;
    *)       service nginx reload >/dev/null 2>&1 || true ;;
  esac
}

nginx_reload_cmd(){
  case "$(init_system)" in
    systemd) echo "systemctl reload nginx" ;;
    openrc)  echo "rc-service nginx reload" ;;
    *)       echo "service nginx reload" ;;
  esac
}

ensure_acme(){
  local acme_home="${HOME:-/root}/.acme.sh"
  if [ -x "${acme_home}/acme.sh" ]; then
    ACME_BIN="${acme_home}/acme.sh"
    return 0
  fi
  if has_command acme.sh; then
    ACME_BIN="acme.sh"
    return 0
  fi
  log "${YELLOW}安装 acme.sh...${NC}"
  if ! curl -Ls https://get.acme.sh | sh -s -- --install-online; then
    log "${RED}acme.sh 安装失败，请检查网络${NC}"
    return 1
  fi
  if [ -x "${acme_home}/acme.sh" ]; then
    ACME_BIN="${acme_home}/acme.sh"
  else
    log "${RED}未找到 acme.sh 可执行文件${NC}"
    return 1
  fi
  log "${GREEN}acme.sh 安装完成: ${ACME_BIN}${NC}"
}

issue_certificates(){
  local domain="$1" mode="$2" webroot="$3" http_port="${4:-80}"
  ensure_acme || return 1
  "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

  case "$mode" in
    webroot)
      log "${GREEN}使用 webroot 模式申请证书（零停机）${NC}"
      local issue_rc=0
      "$ACME_BIN" --issue -d "$domain" -w "$webroot" --keylength ec-256 --force \
        || "$ACME_BIN" --issue -d "$domain" -w "$webroot" --force \
        || issue_rc=$?
      [ "$issue_rc" -eq 0 ] || { log "${RED}证书签发失败 (webroot)${NC}"; return 1; }
      ;;
    standalone)
      log "${YELLOW}使用 standalone 模式申请证书，需临时释放 ${http_port}/tcp 端口${NC}"
      if [ "$http_port" != "80" ]; then
        log "${YELLOW}注意：Let's Encrypt 始终从公网 80 端口发起验证，--httpport 仅让 acme.sh 监听本机的 ${http_port}。这要求你的路由器/NAT 已经把公网 80 转发到本机 ${http_port}，否则验证必然失败，请改用 DNS-01 模式（选项3）。${NC}"
      fi
      if port_in_use "$http_port"; then
        stop_nginx
        if ! wait_for_port_free "$http_port" 10; then
          log "${RED}端口 ${http_port} 在停止 Nginx 后仍被占用，无法继续申请证书${NC}"
          start_nginx
          return 1
        fi
      fi
      local httpport_arg=()
      [ "$http_port" != "80" ] && httpport_arg=(--httpport "$http_port")
      local issue_rc=0
      "$ACME_BIN" --issue -d "$domain" --standalone "${httpport_arg[@]}" --keylength ec-256 --force \
        || "$ACME_BIN" --issue -d "$domain" --standalone "${httpport_arg[@]}" --force \
        || issue_rc=$?
      start_nginx
      [ "$issue_rc" -eq 0 ] || { log "${RED}证书签发失败 (standalone)${NC}"; return 1; }
      ;;
    dns)
      if [ -z "${DNS_API:-}" ]; then
        log "${RED}错误：DNS API 变量未设置 (如 CF_Token)。无法使用 DNS-01 模式。${NC}"
        return 1
      fi
      log "${GREEN}使用 DNS-01 模式申请证书（需已配置相应 DNS API 环境变量）${NC}"
      local issue_rc=0
      "$ACME_BIN" --issue -d "$domain" --dns "$DNS_API" --keylength ec-256 --force \
        || "$ACME_BIN" --issue -d "$domain" --dns "$DNS_API" --force \
        || issue_rc=$?
      [ "$issue_rc" -eq 0 ] || { log "${RED}证书签发失败 (DNS-01)${NC}"; return 1; }
      ;;
    *)
      log "${RED}未知证书模式${NC}"
      return 1;;
  esac

  local acme_home="${HOME:-/root}/.acme.sh"
  local domain_ecc_path="${acme_home}/${domain}_ecc"
  local domain_rsa_path="${acme_home}/${domain}"

  if [ -d "$domain_ecc_path" ]; then
    CERT_PATH="${domain_ecc_path}/fullchain.cer"
    KEY_PATH="${domain_ecc_path}/${domain}.key"
  else
    CERT_PATH="${domain_rsa_path}/fullchain.cer"
    KEY_PATH="${domain_rsa_path}/${domain}.key"
  fi

  if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
    log "${RED}证书签发失败：未找到证书文件${NC}"
    return 1
  fi

  mkdir -p /etc/ssl/gemini
  if "$ACME_BIN" --install-cert -d "$domain" \
      --fullchain-file "/etc/ssl/gemini/${domain}.crt" \
      --key-file "/etc/ssl/gemini/${domain}.key" \
      --reloadcmd "$(nginx_reload_cmd)" >/dev/null 2>&1; then
      CERT_PATH="/etc/ssl/gemini/${domain}.crt"
      KEY_PATH="/etc/ssl/gemini/${domain}.key"
      log "${GREEN}证书已安装到 ${CERT_PATH} / ${KEY_PATH}${NC}"
  else
      log "${RED}证书安装到固定路径失败，将使用 acme.sh 默认路径${NC}"
  fi
}

renew_certificate(){
  if [ ! -f "$CONFIG_FILE" ]; then
    log "${RED}未找到配置文件，先完成安装${NC}"
    return 1
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  if [ -z "${DOMAIN:-}" ]; then
    log "${RED}配置中没有域名${NC}"
    return 1
  fi
  ensure_acme || return 1
  if "$ACME_BIN" --renew -d "$DOMAIN" --force; then
    restart_nginx
    log "${GREEN}证书续期完成${NC}"
  else
    log "${RED}证书续期失败${NC}"
    return 1
  fi
}

save_config(){
  tee "$CONFIG_FILE" >/dev/null <<EOF
DOMAIN=${DOMAIN:-}
BIND_IP=${BIND_IP:-}
HTTP_PORT=${HTTP_PORT:-}
HTTPS_PORT=${HTTPS_PORT:-}
CERT_PATH=${CERT_PATH:-}
KEY_PATH=${KEY_PATH:-}
ENABLE_AUTH=${ENABLE_AUTH:-0}
ALLOW_IPS=${ALLOW_IPS:-}
EOF
  chmod 600 "$CONFIG_FILE"
}

configure_nginx(){
  read -rp "请输入域名: " DOMAIN
  if [ -z "$DOMAIN" ]; then
    log "${RED}域名不能为空${NC}"
    return 1
  fi
  if ! validate_domain "$DOMAIN"; then
    log "${RED}域名格式不合法: $DOMAIN${NC}"
    return 1
  fi

  read -rp "绑定本地IP(默认0.0.0.0): " BIND_IP; BIND_IP=${BIND_IP:-0.0.0.0}
  if ! validate_ip "$BIND_IP"; then
    log "${RED}IP 格式不合法: $BIND_IP${NC}"
    return 1
  fi

  read -rp "HTTP端口(默认80): " HTTP_PORT; HTTP_PORT=${HTTP_PORT:-80}
  read -rp "HTTPS端口(默认443): " HTTPS_PORT; HTTPS_PORT=${HTTPS_PORT:-443}
  if ! validate_port "$HTTP_PORT" || ! validate_port "$HTTPS_PORT"; then
    log "${RED}端口必须是 1-65535 的数字${NC}"
    return 1
  fi
  ENABLE_AUTH="${ENABLE_AUTH:-0}"
  ALLOW_IPS="${ALLOW_IPS:-}"

  printf "选择证书方式：\n1) 自动申请（webroot，零停机，需公网80端口可达）\n2) 自动申请（standalone，临停nginx释放80端口）\n3) 自动申请（DNS-01，适合泛域名/NAT无80映射）\n4) 手动指定证书路径\n"
  read -rp "输入选项 [1-4]: " SSL_OPT

  CERT_PATH=""; KEY_PATH=""
  case "$SSL_OPT" in
    1)
      if [ "$HTTP_PORT" != "80" ]; then
        log "${YELLOW}警告：Let's Encrypt HTTP-01 仅走 80 端口，NAT 请保证公网80已映射到此主机${NC}"
      fi
      mkdir -p "$ACME_DIR"
      ensure_acme_location
      tee "$NGINX_SITE" >/dev/null <<EOF
server {
    listen ${BIND_IP}:${HTTP_PORT};
    server_name ${DOMAIN};
    include ${ACME_LOC_CONF};
    location / { return 200 'ACME ready'; add_header Content-Type text/plain; }
}
EOF
      if nginx -t >/dev/null 2>&1; then
        reload_nginx
      else
        log "${RED}Nginx 配置错误，无法进行 ACME 验证${NC}"
        return 1
      fi
      issue_certificates "$DOMAIN" "webroot" "$ACME_DIR"
      ;;
    2)
      issue_certificates "$DOMAIN" "standalone" "" "$HTTP_PORT"
      ;;
    3)
      read -rp "输入 DNS API 标识（如 dns_cf、dns_dp 等）: " DNS_API
      export DNS_API
      log "${YELLOW}确保已导出对应 DNS API 的环境变量（如 CF_Token 等）${NC}"
      issue_certificates "$DOMAIN" "dns" ""
      ;;
    4)
      read -rp "SSL证书路径(.crt/.pem): " CERT_PATH
      read -rp "SSL私钥路径(.key): " KEY_PATH
      if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
        log "${RED}证书文件不存在${NC}"
        return 1
      fi
      ;;
    *)
      log "${RED}无效选项${NC}"
      return 1 ;;
  esac

  if [ -z "${CERT_PATH:-}" ] || [ -z "${KEY_PATH:-}" ]; then
      log "${RED}证书路径未正确设置，无法完成配置${NC}"
      return 1
  fi

  write_nginx_conf "$DOMAIN" "$BIND_IP" "$HTTP_PORT" "$HTTPS_PORT" "$CERT_PATH" "$KEY_PATH"
  configure_selinux_and_firewall "$HTTP_PORT" "$HTTPS_PORT"
  restart_nginx
  save_config
  log "${GREEN}Nginx + SSL 配置完成${NC}"
}

manage_access_control(){
  if [ ! -f "$CONFIG_FILE" ]; then
    log "${RED}请先完成安装配置${NC}"
    return 1
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  printf "${CYAN}=== 访问控制管理 ===${NC}\n"
  printf "1) 启用 Basic Auth 密码保护\n2) 关闭 Basic Auth 密码保护\n3) 设置 IP 白名单\n4) 清除 IP 白名单\n0) 返回\n"
  read -rp "选项: " a
  case "$a" in
    1)
      read -rp "设置用户名: " AUTH_USER
      read -rsp "设置密码: " AUTH_PASS; echo
      if [ -z "$AUTH_USER" ] || [ -z "$AUTH_PASS" ]; then
        log "${RED}用户名密码不能为空${NC}"
        return 1
      fi
      local hash
      hash=$(openssl passwd -apr1 "$AUTH_PASS")
      echo "${AUTH_USER}:${hash}" > "$HTPASSWD_FILE"
      chmod 600 "$HTPASSWD_FILE"
      ENABLE_AUTH="1"
      log "${GREEN}Basic Auth 已启用${NC}"
      ;;
    2)
      ENABLE_AUTH="0"
      log "${GREEN}Basic Auth 已关闭${NC}"
      ;;
    3)
      read -rp "输入允许访问的 IP/CIDR（多个用空格分隔）: " ALLOW_IPS
      log "${GREEN}IP 白名单已设置${NC}"
      ;;
    4)
      ALLOW_IPS=""
      log "${GREEN}IP 白名单已清除${NC}"
      ;;
    0) return 0 ;;
    *) log "${RED}无效选项${NC}"; return 1 ;;
  esac

  save_config
  if [ -n "${DOMAIN:-}" ]; then
    write_nginx_conf "$DOMAIN" "$BIND_IP" "$HTTP_PORT" "$HTTPS_PORT" "$CERT_PATH" "$KEY_PATH"
    restart_nginx
  fi
}

uninstall_nginx(){
  read -rp "确认卸载 Nginx？[y/N]: " confirm
  [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || { log "${YELLOW}已取消${NC}"; return 0; }
  stop_nginx
  local pm_cmd=""
  case "$OS" in
    ubuntu|debian) pm_cmd="apt remove --purge -y nginx && apt autoremove -y" ;;
    centos|rhel|fedora|rocky|almalinux)
      local PM; PM=$(detect_pkg_manager)
      pm_cmd="$PM remove -y nginx" ;;
    arch) pm_cmd="pacman -R --noconfirm nginx" ;;
    opensuse-leap|opensuse-tumbleweed|sles|opensuse) pm_cmd="zypper --non-interactive remove nginx" ;;
    alpine) pm_cmd="apk del nginx" ;;
  esac
  eval "$pm_cmd" >/dev/null 2>&1 || log "${YELLOW}Nginx 卸载时可能出现错误${NC}"
  rm -f "$NGINX_SITE"
  log "${GREEN}Nginx 已卸载${NC}"
}

full_remove(){
  read -rp "此操作会删除 Nginx、日志、配置与备份，确认？[y/N]: " confirm
  [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || { log "${YELLOW}已取消${NC}"; return 0; }
  uninstall_nginx
  rm -rf /etc/nginx /var/log/nginx /var/cache/nginx
  rm -f "$CONFIG_FILE" "$HTPASSWD_FILE"
  rm -rf "$BACKUP_DIR"
  log "${GREEN}已彻底清理相关文件与配置${NC}"
}

backup_config(){
  if [ ! -f "$CONFIG_FILE" ]; then
    log "${RED}未找到配置文件${NC}"
    return
  fi
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  local TS; TS=$(date +%Y%m%d%H%M%S)
  local files=("$NGINX_SITE" "$CONFIG_FILE" "$ACME_LOC_CONF")
  [ -f "$HTPASSWD_FILE" ] && files+=("$HTPASSWD_FILE")
  local archive="$BACKUP_DIR/gemini_proxy_${TS}.tar.gz"
  tar -czf "$archive" "${files[@]}" >/dev/null 2>&1 || log "${YELLOW}备份时发生错误${NC}"
  chmod 600 "$archive"
  log "${GREEN}已备份到 ${archive}${NC}"
}

restore_config(){
  printf "可用备份：\n"
  ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "（无）"
  read -rp "输入要恢复的备份文件路径: " BK
  if [ ! -f "$BK" ]; then
    log "${RED}备份文件不存在${NC}"
    return 1
  fi

  local allowed_regex
  allowed_regex="^/?($(echo "${NGINX_SITE#/}" | sed 's/[.[\*^$]/\\&/g')|$(echo "${CONFIG_FILE#/}" | sed 's/[.[\*^$]/\\&/g')|$(echo "${ACME_LOC_CONF#/}" | sed 's/[.[\*^$]/\\&/g')|$(echo "${HTPASSWD_FILE#/}" | sed 's/[.[\*^$]/\\&/g'))$"

  local members
  members=$(tar -tzf "$BK" 2>/dev/null) || { log "${RED}无法读取备份包${NC}"; return 1; }

  local m
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    if [[ "$m" == *".."* ]] || ! [[ "$m" =~ $allowed_regex ]]; then
      log "${RED}备份包内含未预期的文件（${m}），出于安全考虑已终止恢复${NC}"
      return 1
    fi
  done <<< "$members"

  tar -xzf "$BK" -C / --no-same-owner >/dev/null 2>&1 || { log "${RED}恢复时发生错误${NC}"; return 1; }
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  [ -f "$HTPASSWD_FILE" ] && chmod 600 "$HTPASSWD_FILE"

  if nginx -t >/dev/null 2>&1; then
    restart_nginx
    log "${GREEN}恢复完成${NC}"
  else
    log "${RED}Nginx 配置恢复后出现错误，请手动检查${NC}"
  fi
}

check_status(){
  local ns="unknown"
  if has_command systemctl; then
    ns=$(systemctl is-active nginx || echo "inactive")
  else
    ns=$(service nginx status 2>/dev/null | grep "is running" && echo "active" || echo "inactive")
  fi
  printf "${CYAN}=== 服务状态 ===${NC}\n"
  printf "Nginx: %s\n" "$ns"
  if nginx -t >/dev/null 2>&1; then
    printf "配置语法: ${GREEN}正常${NC}\n"
  else
    printf "配置语法: ${RED}有误${NC}\n"
  fi

  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" || log "${YELLOW}无法加载配置文件 $CONFIG_FILE${NC}"
    printf "${CYAN}=== 当前配置 ===${NC}\n"
    printf "域名: %s\n" "${DOMAIN:-未设置}"
    printf "绑定IP: %s\n" "${BIND_IP:-未设置}"
    printf "HTTP端口: %s\n" "${HTTP_PORT:-未设置}"
    printf "HTTPS端口: %s\n" "${HTTPS_PORT:-未设置}"
    printf "证书: %s\n" "${CERT_PATH:-未设置}"
    printf "私钥: %s\n" "${KEY_PATH:-未设置}"
    printf "Basic Auth: %s\n" "$([ "${ENABLE_AUTH:-0}" = "1" ] && echo 已启用 || echo 未启用)"
    printf "IP白名单: %s\n" "${ALLOW_IPS:-未设置}"
    if [ -f "${CERT_PATH:-}" ]; then
      local exp_date days_left exp_epoch now_epoch
      exp_date=$(openssl x509 -enddate -noout -in "${CERT_PATH}" 2>/dev/null | cut -d= -f2 || echo "")
      if [ -n "$exp_date" ]; then
        printf "证书到期: %s\n" "$exp_date"
        exp_epoch=$(date -d "$exp_date" +%s 2>/dev/null || echo "")
        now_epoch=$(date +%s)
        if [ -n "$exp_epoch" ]; then
          days_left=$(( (exp_epoch - now_epoch) / 86400 ))
          if [ "$days_left" -lt 14 ]; then
            printf "${RED}剩余 %s 天，建议尽快续期（菜单选项 12）${NC}\n" "$days_left"
          else
            printf "剩余 %s 天\n" "$days_left"
          fi
        fi
      fi
    fi
  fi
  printf "${CYAN}=== 最近访问日志(5行) ===${NC}\n"
  if [ -f /var/log/nginx/gemini_access.log ]; then
    tail -n 5 /var/log/nginx/gemini_access.log
  else
    echo "无访问日志"
  fi
}

monitor_all(){
  if [ ! -f "$CONFIG_FILE" ]; then
    log "${RED}未找到配置文件${NC}"
    return
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_FILE" || { log "${RED}无法加载配置文件 $CONFIG_FILE${NC}"; return; }
  log "${CYAN}开始监控（Ctrl+C 退出）${NC}"
  trap 'log "${CYAN}监控结束${NC}"; exit 0' INT

  local prev_cpu_total=0 prev_idle_total=0
  get_cpu_usage() {
    local cpu_line total_time idle_time usage=0
    cpu_line=$(grep "^cpu " /proc/stat)
    total_time=$(echo "$cpu_line" | awk '{for(i=2;i<=NF;i++) sum+=$i} END {print sum}')
    idle_time=$(echo "$cpu_line" | awk '{print $5}')
    if [ "$prev_cpu_total" -gt 0 ]; then
        local diff_total=$((total_time - prev_cpu_total))
        local diff_idle=$((idle_time - prev_idle_total))
        usage=$(awk "BEGIN { printf \"%.1f\", (100 * (1 - $diff_idle / $diff_total)) }")
    fi
    prev_cpu_total=$total_time
    prev_idle_total=$idle_time
    echo "$usage"
  }

  while true; do
    local TS; TS=$(date '+%F %T')
    local CPU; CPU=$(get_cpu_usage)
    local MEM; MEM=$(free -m | awk '/Mem:/{printf("%dM/%dM(%.0f%%)", $3,$2,$3*100/$2)}')
    local DISK; DISK=$(df -h / | awk 'NR==2{print $3"/"$2"("$5")"}')
    local CONN="n/a"
    has_command ss && CONN=$(ss -tan state established '( dport = :'"${HTTPS_PORT:-443}"' or sport = :'"${HTTPS_PORT:-443}"' )' 2>/dev/null | tail -n +2 | wc -l)
    local HTTP_CODE="000"
    if [ -n "${DOMAIN:-}" ]; then
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN}/v1/models" --connect-timeout 5 || echo "000")
    fi
    printf "[%s] CPU:%s%% MEM:%s DISK:%s 连接数:%s PROXY:%s\n" "$TS" "$CPU" "$MEM" "$DISK" "$CONN" "$HTTP_CODE"
    sleep 5
  done
}

view_logs(){
  printf "${CYAN}选择日志:${NC}\n"
  printf "1) Nginx 访问\n2) Nginx 错误\n3) 脚本日志\n4) 全部\n"
  read -rp "选项[1-4]: " c
  case "$c" in
    1)
      [ -f /var/log/nginx/gemini_access.log ] && tail -f /var/log/nginx/gemini_access.log || log "${YELLOW}日志不存在${NC}"
      ;;
    2)
      [ -f /var/log/nginx/gemini_error.log ] && tail -f /var/log/nginx/gemini_error.log || log "${YELLOW}日志不存在${NC}"
      ;;
    3)
      tail -f "$LOG_FILE"
      ;;
    4)
      if has_command multitail; then
        multitail -s 3 /var/log/nginx/gemini_access.log /var/log/nginx/gemini_error.log "$LOG_FILE"
      else
        log "${YELLOW}未安装 multitail，使用并行 tail 代替${NC}"
        tail -f /var/log/nginx/gemini_access.log /var/log/nginx/gemini_error.log "$LOG_FILE" 2>/dev/null
      fi
      ;;
    *)
      log "${RED}无效选项${NC}" ;;
  esac
}

preflight(){
  log "${CYAN}进行环境预检...${NC}"
  local essential_bins="nginx curl openssl jq bc"
  for bin in $essential_bins; do
    if ! has_command "$bin"; then
      log "${RED}缺少依赖: $bin${NC}"
      exit 1
    fi
  done

  if [ -f "$NGINX_SITE" ] && ! nginx -t >/dev/null 2>&1; then
    log "${YELLOW}提示：Nginx 配置文件存在语法错误。安装流程会自动生成配置，但可能需要手动修复。${NC}"
  fi

  if port_in_use 80; then log "${YELLOW}提示：80端口被占用（正常情况是nginx占用）${NC}"; fi
  if port_in_use 443; then log "${YELLOW}提示：443端口被占用（正常情况是nginx占用）${NC}"; fi
  log "${GREEN}预检完成${NC}"
}

show_menu(){
  clear
  printf "${GREEN}=====================================\n"
  printf " Gemini API 反代管理脚本 by cnfte v${VERSION} \n"
  printf "=====================================\n"
  printf "1) 安装/配置反代（含SSL）\n"
  printf "2) 重启反代\n"
  printf "3) 停止Nginx\n"
  printf "4) 卸载Nginx\n"
  printf "5) 完全清理（Nginx/配置/缓存）\n"
  printf "6) 备份配置\n"
  printf "7) 恢复配置\n"
  printf "8) 检查服务状态（含证书到期提醒）\n"
  printf "9) 资源与代理监控\n"
  printf "10) 查看日志\n"
  printf "11) 访问控制管理（Basic Auth / IP白名单）\n"
  printf "12) 手动续期证书\n"
  printf "0) 退出\n"
  printf "=====================================\n${NC}"
  read -rp "请输入选项 [0-12]: " option
}

main(){
  check_root
  detect_os
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 644 "$LOG_FILE"

  install_dependencies
  preflight

  while true; do
    show_menu
    case "$option" in
      1) configure_nginx ;;
      2) restart_nginx ;;
      3) stop_nginx ;;
      4) uninstall_nginx ;;
      5) full_remove ;;
      6) backup_config ;;
      7) restore_config ;;
      8) check_status ;;
      9) monitor_all ;;
      10) view_logs ;;
      11) manage_access_control ;;
      12) renew_certificate ;;
      0)
        log "${GREEN}退出脚本${NC}"
        exit 0 ;;
      *)
        log "${RED}无效选项${NC}" ;;
    esac
    if [ "$option" != "0" ]; then
      read -rp "按 Enter 继续..."
    fi
  done
}

main
