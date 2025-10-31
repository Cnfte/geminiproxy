#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

VERSION="1.3.0"
CONFIG_FILE="/etc/gemini_proxy.conf"
BACKUP_DIR="/var/backups/gemini_proxy"
LOG_FILE="/var/log/gemini_proxy.log"
NGINX_SITE="/etc/nginx/conf.d/chat.conf"
ACME_DIR="/var/www/acme-challenge"
ACME_LOC_CONF="/etc/nginx/snippets/acme_challenge.conf"

set -euo pipefail

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

install_dependencies(){
  log "${GREEN}安装依赖...${NC}"
  local install_cmd=""
  local packages=""

  case "$OS" in
    ubuntu|debian)
      apt update >/dev/null
      packages="nginx openssl curl jq bc socat lsof tar coreutils procps iproute2 cron ufw certbot python3-certbot-nginx multitail"
      DEBIAN_FRONTEND=noninteractive apt install -y $packages || log "${YELLOW}部分依赖安装失败，请手动检查${NC}"
      ;;
    centos|rhel|fedora)
      local PM=${has_command dnf && echo dnf || echo yum}
      packages="nginx openssl curl jq bc socat lsof tar coreutils procps-ng iproute epel-release cronie firewalld certbot python3-certbot-nginx multitail policycoreutils-python-utils policycoreutils-python"
      $PM install -y $packages || log "${YELLOW}部分依赖安装失败，请手动检查${NC}"
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
  tee "$NGINX_SITE" >/dev/null <<EOF
server {
    listen ${bind_ip}:${http_port};
    server_name ${domain};
    include ${ACME_LOC_CONF};
    return 301 https://\$host:${https_port}\$request_uri;
}

server {
    listen ${bind_ip}:${https_port} ssl;
    server_name ${domain};

    ssl_certificate ${cert};
    ssl_certificate_key ${key};
    ssl_session_cache shared:ssl_cache:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    client_max_body_size 20m;
    keepalive_timeout 65;
    sendfile on;
    tcp_nopush on;

    access_log /var/log/nginx/gemini_access.log;
    error_log  /var/log/nginx/gemini_error.log;

    location / {
        proxy_pass https://generativelanguage.googleapis.com/;
        proxy_ssl_server_name on;
        proxy_set_header Host generativelanguage.googleapis.com;
        proxy_http_version 1.1;
        proxy_set_header Connection '';
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 60s;
    }
}
EOF
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1 || true
    log "${GREEN}Nginx 配置已更新并重载${NC}"
  else
    log "${RED}Nginx 配置错误，请检查: $NGINX_SITE${NC}"
  fi
}

start_nginx(){
  if has_command systemctl; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl start nginx >/dev/null 2>&1 || true
    log "${GREEN}Nginx 已启动${NC}"
  else
    service nginx start >/dev/null 2>&1 || true
    log "${GREEN}Nginx 已启动 (service)${NC}"
  fi
}
restart_nginx(){
  if has_command systemctl; then
    systemctl restart nginx >/dev/null 2>&1 || true
    log "${GREEN}Nginx 已重启${NC}"
  else
    service nginx restart >/dev/null 2>&1 || true
    log "${GREEN}Nginx 已重启 (service)${NC}"
  fi
}
stop_nginx(){
  if has_command systemctl; then
    systemctl stop nginx >/dev/null 2>&1 || true
    log "${YELLOW}Nginx 已停止${NC}"
  else
    service nginx stop >/dev/null 2>&1 || true
    log "${YELLOW}Nginx 已停止 (service)${NC}"
  fi
}

ensure_acme(){
  if ! has_command acme.sh; then
    log "${YELLOW}安装 acme.sh...${NC}"
    curl -Ls https://get.acme.sh | sh -s -- --install-online
    export PATH="$PATH:~/.acme.sh"
    log "${GREEN}acme.sh 安装完成${NC}"
  fi
}

issue_certificates(){
  local domain="$1" mode="$2" webroot="$3"
  ensure_acme
  acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

  case "$mode" in
    webroot)
      log "${GREEN}使用 webroot 模式申请证书（零停机）${NC}"
      acme.sh --issue -d "$domain" -w "$webroot" --keylength ec-256 --force || acme.sh --issue -d "$domain" -w "$webroot" --force
      ;;
    standalone)
      log "${YELLOW}使用 standalone 模式申请证书，需临时释放 80/443 端口${NC}"
      if port_in_use 80; then stop_nginx; fi
      acme.sh --issue -d "$domain" --standalone --keylength ec-256 --force || acme.sh --issue -d "$domain" --standalone --force
      start_nginx
      ;;
    dns)
      if [ -z "${DNS_API:-}" ]; then
        log "${RED}错误：DNS API 变量未设置 (如 CF_Token)。无法使用 DNS-01 模式。${NC}"
        return 1
      fi
      log "${GREEN}使用 DNS-01 模式申请证书（需已配置相应 DNS API 环境变量）${NC}"
      acme.sh --issue -d "$domain" --dns "$DNS_API" --keylength ec-256 --force || acme.sh --issue -d "$domain" --dns "$DNS_API" --force
      ;;
    *)
      log "${RED}未知证书模式${NC}"
      return 1;;
  esac

  local domain_ecc_path="/root/.acme.sh/${domain}_ecc"
  local domain_rsa_path="/root/.acme.sh/${domain}"

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
  if acme.sh --install-cert -d "$domain" \
      --fullchain-file "/etc/ssl/gemini/${domain}.crt" \
      --key-file "/etc/ssl/gemini/${domain}.key" \
      --reloadcmd "systemctl reload nginx" >/dev/null 2>&1 || true; then
      CERT_PATH="/etc/ssl/gemini/${domain}.crt"
      KEY_PATH="/etc/ssl/gemini/${domain}.key"
      log "${GREEN}证书已安装到 ${CERT_PATH} / ${KEY_PATH}${NC}"
  else
      log "${RED}证书安装到固定路径失败，将使用 acme.sh 默认路径${NC}"
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
EOF
}

configure_nginx(){
  read -rp "请输入域名: " DOMAIN
  if [ -z "$DOMAIN" ]; then
    log "${RED}域名不能为空${NC}"
    return 1
  fi

  read -rp "绑定本地IP(默认0.0.0.0): " BIND_IP; BIND_IP=${BIND_IP:-0.0.0.0}
  read -rp "HTTP端口(默认80): " HTTP_PORT; HTTP_PORT=${HTTP_PORT:-80}
  read -rp "HTTPS端口(默认443): " HTTPS_PORT; HTTPS_PORT=${HTTPS_PORT:-443}

  printf "选择证书方式：\n1) 自动申请（webroot，零停机，需公网80端口可达）\n2) 自动申请（standalone，临停nginx释放80端口）\n3) 自动申请（DNS-01，适合泛域名/NAT无80映射）\n4) 手动指定证书路径\n"
  read -rp "输入选项 [1-4]: " SSL_OPT

  CERT_PATH=""; KEY_PATH=""
  case "$SSL_OPT" in
    1)
      if [ "$HTTP_PORT" != "80" ]; then
        log "${YELLOW}警告：Let's Encrypt HTTP-01 仅走 80 端口，NAT 请保证公网80已映射到此主机${NC}"
      fi
      mkdir -p "$ACME_DIR"
      tee "$NGINX_SITE" >/dev/null <<EOF
server {
    listen ${BIND_IP}:${HTTP_PORT};
    server_name ${DOMAIN};
    include ${ACME_LOC_CONF};
    location / { return 200 'ACME ready'; add_header Content-Type text/plain; }
}
EOF
      if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || true
      else
        log "${RED}Nginx 配置错误，无法进行 ACME 验证${NC}"
        return 1
      fi
      issue_certificates "$DOMAIN" "webroot" "$ACME_DIR"
      ;;
    2)
      issue_certificates "$DOMAIN" "standalone" ""
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

uninstall_nginx(){
  stop_nginx
  local pm_cmd=""
  case "$OS" in
    ubuntu|debian) pm_cmd="apt remove --purge -y nginx && apt autoremove -y" ;;
    centos|rhel|fedora)
      local PM=${has_command dnf && echo dnf || echo yum}
      pm_cmd="$PM remove -y nginx" ;;
    arch) pm_cmd="pacman -R --noconfirm nginx" ;;
  esac
  eval "$pm_cmd" >/dev/null 2>&1 || log "${YELLOW}Nginx 卸载时可能出现错误${NC}"
  rm -f "$NGINX_SITE"
  log "${GREEN}Nginx 已卸载${NC}"
}

full_remove(){
  uninstall_nginx
  rm -rf /etc/nginx /var/log/nginx /var/cache/nginx
  rm -f "$CONFIG_FILE"
  rm -rf "$BACKUP_DIR"
  log "${GREEN}已彻底清理相关文件与配置${NC}"
}

backup_config(){
  if [ ! -f "$CONFIG_FILE" ]; then
    log "${RED}未找到配置文件${NC}"
    return
  fi
  mkdir -p "$BACKUP_DIR"
  local TS; TS=$(date +%Y%m%d%H%M%S)
  tar -czf "$BACKUP_DIR/gemini_proxy_${TS}.tar.gz" "$NGINX_SITE" "$CONFIG_FILE" "$ACME_LOC_CONF" >/dev/null 2>&1 || log "${YELLOW}备份时发生错误${NC}"
  log "${GREEN}已备份到 $BACKUP_DIR/gemini_proxy_${TS}.tar.gz${NC}"
}

restore_config(){
  printf "可用备份：\n"
  ls -l "$BACKUP_DIR"/*.tar.gz 2>/dev/null | awk '{print $9}'
  read -rp "输入要恢复的备份文件路径: " BK
  if [ -f "$BK" ]; then
    tar -xzf "$BK" -C / >/dev/null 2>&1 || log "${RED}恢复时发生错误${NC}"
    if nginx -t >/dev/null 2>&1; then
      restart_nginx
      log "${GREEN}恢复完成${NC}"
    else
      log "${RED}Nginx 配置恢复后出现错误，请手动检查${NC}"
    fi
  else
    log "${RED}备份文件不存在${NC}"
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

  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE" || log "${YELLOW}无法加载配置文件 $CONFIG_FILE${NC}"
    printf "${CYAN}=== 当前配置 ===${NC}\n"
    printf "域名: %s\n" "${DOMAIN:-未设置}"
    printf "绑定IP: %s\n" "${BIND_IP:-未设置}"
    printf "HTTP端口: %s\n" "${HTTP_PORT:-未设置}"
    printf "HTTPS端口: %s\n" "${HTTPS_PORT:-未设置}"
    printf "证书: %s\n" "${CERT_PATH:-未设置}"
    printf "私钥: %s\n" "${KEY_PATH:-未设置}"
    if [ -f "${CERT_PATH:-}" ]; then
      local exp_date
      exp_date=$(openssl x509 -enddate -noout -in "${CERT_PATH}" 2>/dev/null | cut -d= -f2 || echo "未知")
      printf "证书到期: %s\n" "$exp_date"
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
  source "$CONFIG_FILE" || { log "${RED}无法加载配置文件 $CONFIG_FILE${NC}"; return; }
  log "${CYAN}开始监控（Ctrl+C 退出）${NC}"
  trap 'log "${CYAN}监控结束${NC}"; exit 0' INT

  local prev_cpu_total=0 prev_idle_total=0
  get_cpu_usage() { # <-- 这里去掉了 local
    local cpu_line=$(grep "^cpu " /proc/stat)
    local total_time=$(echo $cpu_line | awk '{for(i=2;i<=NF;i++) sum+=$i} END {print sum}')
    local idle_time=$(echo $cpu_line | awk '{print $5}')
    local usage=0
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
    local HTTP_CODE="000"
    if [ -n "${DOMAIN:-}" ]; then
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN}/v1/models" --connect-timeout 5 || echo "000")
    fi
    printf "[%s] CPU:%s%% MEM:%s DISK:%s PROXY:%s\n" "$TS" "$CPU" "$MEM" "$DISK" "$HTTP_CODE"
    sleep 5
  done
}

view_logs(){
  printf "${CYAN}选择日志:${NC}\n"
  printf "1) Nginx 访问\n2) Nginx 错误\n3) 脚本日志\n4) 全部\n"
  read -rp "选项[1-4]: " c
  case "$c" in
    1)
      if has_command tail; then tail -f /var/log/nginx/gemini_access.log; fi
      ;;
    2)
      if has_command tail; then tail -f /var/log/nginx/gemini_error.log; fi
      ;;
    3)
      if has_command tail; then tail -f "$LOG_FILE"; fi
      ;;
    4)
      if has_command multitail; then
        multitail -s 3 /var/log/nginx/gemini_access.log /var/log/nginx/gemini_error.log "$LOG_FILE"
      else
        log "${YELLOW}未安装 multitail，使用并行 tail 代替${NC}"
        find /var/log/nginx/gemini_access.log /var/log/nginx/gemini_error.log "$LOG_FILE" -type f -exec tail -f {} +
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

  if ! nginx -t >/dev/null 2>&1; then
    log "${YELLOW}提示：Nginx 配置文件存在语法错误。安装流程会自动生成配置，但可能需要手动修复。${NC}"
  fi

  if port_in_use 80; then log "${YELLOW}提示：80端口被占用（正常情况是nginx占用）${NC}"; fi
  if port_in_use 443; then log "${YELLOW}提示：443端口被占用（正常情况是nginx占用）${NC}"; fi
  log "${GREEN}预检完成${NC}"
}

show_menu(){
  clear
  printf "${GREEN}=====================================\n"
  printf " Gemini API 反代管理脚本 v${VERSION} \n"
  printf "=====================================\n"
  printf "1) 安装/配置反代（含SSL）\n"
  printf "2) 重启反代\n"
  printf "3) 卸载Nginx\n"
  printf "4) 停止Nginx\n"
  printf "5) 完全清理（Nginx/配置/缓存）\n"
  printf "6) 备份配置\n"
  printf "7) 恢复配置\n"
  printf "8) 检查服务状态\n"
  printf "9) 资源与代理监控\n"
  printf "10) 查看日志\n"
  printf "0) 退出\n"
  printf "=====================================\n${NC}"
  read -rp "请输入选项 [0-10]: " option
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
      1)
        configure_nginx
        ;;
      2)
        restart_nginx
        ;;
      3)
        uninstall_nginx
        ;;
      4)
        stop_nginx
        ;;
      5)
        full_remove
        ;;
      6)
        backup_config
        ;;
      7)
        restore_config
        ;;
      8)
        check_status
        ;;
      9)
        monitor_all
        ;;
      10)
        view_logs
        ;;
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
