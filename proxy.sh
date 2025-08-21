#!/bin/bash
# Gemini API 反代管理脚本 - 完整版 v1.3.0
# 适配：Ubuntu/Debian/CentOS/RHEL/Fedora/Arch
# 特性：自定义IP/端口、自动申请SSL(webroot/standalone/dns)、环境自检、资源/代理监控、SELinux/防火墙/依赖自动处理
# 作者：你（发布到资源站可直接用）

set -euo pipefail

# ===== 彩色 =====
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ===== 版本/路径 =====
VERSION="1.3.0"
CONFIG_FILE="/etc/gemini_proxy.conf"
BACKUP_DIR="/var/backups/gemini_proxy"
LOG_FILE="/var/log/gemini_proxy.log"
NGINX_SITE="/etc/nginx/conf.d/chat.conf"
ACME_DIR="/var/www/acme-challenge"
ACME_LOC_CONF="/etc/nginx/snippets/acme_challenge.conf"

# ===== 日志 =====
log(){ echo -e "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"; }

# ===== 权限检测 =====
check_root(){ if [ "$(id -u)" -ne 0 ]; then echo -e "${RED}错误: 需 root 权限${NC}"; exit 1; fi; }

# ===== OS 检测 =====
OS=""; OS_VERSION=""
detect_os(){
  if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; OS_VERSION=$VERSION_ID
  elif command -v lsb_release >/dev/null 2>&1; then OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]'); OS_VERSION=$(lsb_release -sr)
  elif [ -f /etc/redhat-release ]; then OS="centos"; OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
  elif [ -f /etc/arch-release ]; then OS="arch"; OS_VERSION="rolling"
  else log "${RED}无法识别系统${NC}"; exit 1; fi
  log "${GREEN}已检测系统: $OS $OS_VERSION${NC}"
}

# ===== 安装依赖 =====
install_dependencies(){
  log "${GREEN}安装依赖...${NC}"
  case "$OS" in
    ubuntu|debian)
      apt update
      DEBIAN_FRONTEND=noninteractive apt install -y nginx openssl curl jq bc socat lsof tar coreutils procps iproute2
      apt install -y cron || true
      apt install -y ufw || true
      apt install -y certbot python3-certbot-nginx || true
      apt install -y multitail || true
      ;;
    centos|rhel|fedora)
      if command -v dnf >/dev/null 2>&1; then PM=dnf; else PM=yum; fi
      $PM install -y epel-release || true
      $PM install -y nginx openssl curl jq bc socat lsof tar coreutils procps-ng iproute
      $PM install -y cronie || true
      systemctl enable crond || true; systemctl start crond || true
      $PM install -y firewalld || true
      $PM install -y certbot python3-certbot-nginx || true
      $PM install -y multitail || true
      $PM install -y policycoreutils-python-utils || $PM install -y policycoreutils-python || true
      ;;
    arch)
      pacman -Sy --noconfirm nginx openssl curl jq bc socat lsof tar coreutils procps-ng iproute2
      pacman -Sy --noconfirm cronie || true
      systemctl enable cronie || true; systemctl start cronie || true
      pacman -Sy --noconfirm ufw || true
      pacman -Sy --noconfirm certbot || true
      pacman -Sy --noconfirm multitail || true
      ;;
    *) log "${RED}不支持的系统: $OS${NC}"; exit 1 ;;
  esac
}

# ===== SELinux & 防火墙 =====
configure_selinux_and_firewall(){
  # SELinux 放行 http/https 自定义端口
  if command -v getenforce >/dev/null 2>&1; then
    SEL=$(getenforce || true)
    if [[ "$SEL" == "Enforcing" || "$SEL" == "Permissive" ]]; then
      if command -v semanage >/dev/null 2>&1; then
        semanage port -a -t http_port_t -p tcp "${HTTP_PORT}" 2>/dev/null || semanage port -m -t http_port_t -p tcp "${HTTP_PORT}" || true
        semanage port -a -t http_port_t -p tcp "${HTTPS_PORT}" 2>/dev/null || semanage port -m -t http_port_t -p tcp "${HTTPS_PORT}" || true
      fi
    fi
  fi

  # 防火墙放行
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${HTTP_PORT}/tcp" || true
    ufw allow "${HTTPS_PORT}/tcp" || true
  fi
  if systemctl is-active firewalld >/dev/null 2>&1; then
    firewall-cmd --add-port="${HTTP_PORT}/tcp" --permanent || true
    firewall-cmd --add-port="${HTTPS_PORT}/tcp" --permanent || true
    firewall-cmd --reload || true
  fi
  # iptables 兜底（只添加一次）
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "${HTTP_PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "${HTTP_PORT}" -j ACCEPT || true
    iptables -C INPUT -p tcp --dport "${HTTPS_PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "${HTTPS_PORT}" -j ACCEPT || true
  fi
}

# ===== 端口占用检测 =====
port_in_use(){ lsof -iTCP:"$1" -sTCP:LISTEN -P -n >/dev/null 2>&1; }

# ===== Nginx 基础片段：ACME 路径 =====
ensure_acme_location(){
  mkdir -p "$ACME_DIR"
  cat > "$ACME_LOC_CONF" <<EOF
location ^~ /.well-known/acme-challenge/ {
    root $ACME_DIR;
    default_type "text/plain";
    try_files \$uri =404;
}
EOF
}

# ===== 生成/更新 Nginx 配置 =====
write_nginx_conf(){
  local domain="$1" bind_ip="$2" http_port="$3" https_port="$4" cert="$5" key="$6"
  ensure_acme_location
  cat > "$NGINX_SITE" <<EOF
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

    # 基础安全/性能
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
  nginx -t
}

# ===== 安装/启动/停止 Nginx =====
start_nginx(){ systemctl enable nginx >/dev/null 2>&1 || true; systemctl start nginx; log "${GREEN}Nginx 已启动${NC}"; }
restart_nginx(){ systemctl restart nginx; log "${GREEN}Nginx 已重启${NC}"; }
stop_nginx(){ systemctl stop nginx || true; log "${YELLOW}Nginx 已停止${NC}"; }

# ===== 安装 acme.sh（若无） =====
ensure_acme(){
  if ! command -v acme.sh >/dev/null 2>&1; then
    log "${YELLOW}安装 acme.sh...${NC}"
    curl https://get.acme.sh | sh
    # shellcheck disable=SC1090
    [ -f /root/.bashrc ] && source /root/.bashrc || true
    export PATH="$PATH:/root/.acme.sh"
  fi
}

# ===== 证书申请（webroot / standalone / dns）=====
issue_certificates(){
  local domain="$1" mode="$2" webroot="$3"
  ensure_acme
  case "$mode" in
    webroot)
      log "${GREEN}使用 webroot 模式申请证书（零停机）${NC}"
      acme.sh --set-default-ca --server letsencrypt || true
      acme.sh --issue -d "$domain" -w "$webroot" --keylength ec-256 || acme.sh --issue -d "$domain" -w "$webroot"
      ;;
    standalone)
      log "${YELLOW}使用 standalone 模式申请证书，需临时释放 80/443 端口${NC}"
      if port_in_use 80; then stop_nginx; fi
      acme.sh --set-default-ca --server letsencrypt || true
      acme.sh --issue -d "$domain" --standalone --keylength ec-256 || acme.sh --issue -d "$domain" --standalone
      start_nginx
      ;;
    dns)
      log "${GREEN}使用 DNS-01 模式申请证书（需已配置相应 DNS API 环境变量）${NC}"
      # 例：Cloudflare 需提前 export CF_Token/CF_Account_ID/CF_Zone_ID 等
      acme.sh --set-default-ca --server letsencrypt || true
      acme.sh --issue -d "$domain" --dns "$DNS_API" --keylength ec-256 || acme.sh --issue -d "$domain" --dns "$DNS_API"
      ;;
    *)
      log "${RED}未知证书模式${NC}"; return 1;;
  esac

  # 证书路径（优先 ECDSA）
  if [ -d "/root/.acme.sh/${domain}_ecc" ]; then
    CERT_PATH="/root/.acme.sh/${domain}_ecc/fullchain.cer"
    KEY_PATH="/root/.acme.sh/${domain}_ecc/${domain}.key"
  else
    CERT_PATH="/root/.acme.sh/${domain}/fullchain.cer"
    KEY_PATH="/root/.acme.sh/${domain}/${domain}.key"
  fi

  if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
    log "${RED}证书签发失败：未找到证书文件${NC}"
    return 1
  fi

  # 安装证书（写入固定路径，便于 nginx 使用）
  mkdir -p /etc/ssl/gemini
  acme.sh --install-cert -d "$domain" \
    --fullchain-file "/etc/ssl/gemini/${domain}.crt" \
    --key-file "/etc/ssl/gemini/${domain}.key" \
    --reloadcmd "systemctl reload nginx" || true

  CERT_PATH="/etc/ssl/gemini/${domain}.crt"
  KEY_PATH="/etc/ssl/gemini/${domain}.key"
  log "${GREEN}证书就绪：${CERT_PATH} / ${KEY_PATH}${NC}"
}

# ===== 保存配置 =====
save_config(){
  cat > "$CONFIG_FILE" <<EOF
DOMAIN=${DOMAIN}
BIND_IP=${BIND_IP}
HTTP_PORT=${HTTP_PORT}
HTTPS_PORT=${HTTPS_PORT}
CERT_PATH=${CERT_PATH}
KEY_PATH=${KEY_PATH}
EOF
}

# ===== 交互配置 Nginx + 证书 =====
configure_nginx(){
  read -rp "请输入域名: " DOMAIN
  read -rp "绑定本地IP(默认0.0.0.0): " BIND_IP; BIND_IP=${BIND_IP:-0.0.0.0}
  read -rp "HTTP端口(默认80): " HTTP_PORT; HTTP_PORT=${HTTP_PORT:-80}
  read -rp "HTTPS端口(默认443): " HTTPS_PORT; HTTPS_PORT=${HTTPS_PORT:-443}

  echo "选择证书方式："
  echo "1) 自动申请（webroot，零停机，需公网80端口可达）"
  echo "2) 自动申请（standalone，临停nginx释放80端口）"
  echo "3) 自动申请（DNS-01，适合泛域名/NAT无80映射）"
  echo "4) 手动指定证书路径"
  read -rp "输入选项 [1-4]: " SSL_OPT

  CERT_PATH=""; KEY_PATH=""
  case "$SSL_OPT" in
    1)
      if [ "$HTTP_PORT" != "80" ]; then
        log "${YELLOW}警告：Let's Encrypt HTTP-01 仅走 80 端口，NAT 请保证公网80已映射到此主机${NC}"
      fi
      mkdir -p "$ACME_DIR"
      # 写入一个临时不带SSL的 http server 仅用于验证（避免现有占用问题）
      cat > "$NGINX_SITE" <<EOF
server {
    listen ${BIND_IP}:${HTTP_PORT};
    server_name ${DOMAIN};
    include ${ACME_LOC_CONF};
    location / { return 200 'ACME ready'; add_header Content-Type text/plain; }
}
EOF
      nginx -t && systemctl reload nginx || true
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
        log "${RED}证书文件不存在${NC}"; return 1
      fi
      ;;
    *) log "${RED}无效选项${NC}"; return 1 ;;
  esac

  write_nginx_conf "$DOMAIN" "$BIND_IP" "$HTTP_PORT" "$HTTPS_PORT" "$CERT_PATH" "$KEY_PATH"
  configure_selinux_and_firewall
  restart_nginx
  save_config
  log "${GREEN}Nginx + SSL 配置完成${NC}"
}

# ===== 卸载/清理 =====
uninstall_nginx(){
  stop_nginx
  case "$OS" in
    ubuntu|debian) apt remove --purge -y nginx || true; apt autoremove -y || true ;;
    centos|rhel|fedora) if command -v dnf >/dev/null 2>&1; then dnf remove -y nginx || true; else yum remove -y nginx || true; fi ;;
    arch) pacman -R --noconfirm nginx || true ;;
  esac
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

# ===== 备份/恢复 =====
backup_config(){
  if [ ! -f "$CONFIG_FILE" ]; then log "${RED}未找到配置文件${NC}"; return; fi
  mkdir -p "$BACKUP_DIR"
  local TS; TS=$(date +%Y%m%d%H%M%S)
  tar -czf "$BACKUP_DIR/gemini_proxy_${TS}.tar.gz" "$NGINX_SITE" "$CONFIG_FILE" "$ACME_LOC_CONF" 2>/dev/null || true
  log "${GREEN}已备份到 $BACKUP_DIR/gemini_proxy_${TS}.tar.gz${NC}"
}

restore_config(){
  echo "可用备份："; ls -l "$BACKUP_DIR"/*.tar.gz 2>/dev/null | awk '{print $9}'
  read -rp "输入要恢复的备份文件路径: " BK
  if [ -f "$BK" ]; then
    tar -xzf "$BK" -C /
    nginx -t && restart_nginx || true
    log "${GREEN}恢复完成${NC}"
  else
    log "${RED}备份文件不存在${NC}"
  fi
}

# ===== 状态/监控 =====
check_status(){
  local ns; ns=$(systemctl is-active nginx || true)
  echo -e "${CYAN}=== 服务状态 ===${NC}"
  echo "Nginx: $ns"
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    echo -e "${CYAN}=== 当前配置 ===${NC}"
    echo "域名: $DOMAIN"
    echo "绑定IP: $BIND_IP"
    echo "HTTP端口: $HTTP_PORT"
    echo "HTTPS端口: $HTTPS_PORT"
    echo "证书: $CERT_PATH"
    echo "私钥: $KEY_PATH"
    if [ -f "$CERT_PATH" ]; then
      echo -n "证书到期: "
      openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2 || echo "未知"
    fi
  fi
  echo -e "${CYAN}=== 最近访问日志(5行) ===${NC}"
  [ -f /var/log/nginx/gemini_access.log ] && tail -n 5 /var/log/nginx/gemini_access.log || echo "无访问日志"
}

monitor_all(){
  if [ ! -f "$CONFIG_FILE" ]; then log "${RED}未找到配置文件${NC}"; return; fi
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  log "${CYAN}开始监控（Ctrl+C 退出）${NC}"
  trap 'log "${CYAN}监控结束${NC}"; exit 0' INT
  while true; do
    TS=$(date '+%F %T')
    CPU=$(awk -v FS=" " '/cpu /{u=$2+$4;s=$5;tot=$2+$4+$5; if(prev){ printf("%.1f", (1- (tot-prev_tot ? (s-prev_s)/(tot-prev_tot):0))*100) } prev=$2+$4; prev_s=$5; prev_tot=tot }' /proc/stat <(sleep 1; cat /proc/stat) | tail -n1 2>/dev/null || echo "?")
    MEM=$(free -m | awk '/Mem:/{printf("%dM/%dM(%.0f%%)", $3,$2,$3*100/$2)}')
    DISK=$(df -h / | awk 'NR==2{print $3"/"$2"("$5")"}')
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN}/v1/models" --connect-timeout 5 || echo "000")
    echo -e "[$TS] CPU:${CPU}% MEM:${MEM} DISK:${DISK} PROXY:${HTTP_CODE}"
    sleep 5
  done
}

view_logs(){
  echo -e "${CYAN}选择日志:${NC}"
  echo "1) Nginx 访问"
  echo "2) Nginx 错误"
  echo "3) 脚本日志"
  echo "4) 全部"
  read -rp "选项[1-4]: " c
  case "$c" in
    1) tail -f /var/log/nginx/gemini_access.log ;;
    2) tail -f /var/log/nginx/gemini_error.log ;;
    3) tail -f "$LOG_FILE" ;;
    4)
      if command -v multitail >/dev/null 2>&1; then
        multitail -s 3 /var/log/nginx/gemini_access.log /var/log/nginx/gemini_error.log "$LOG_FILE"
      else
        log "${YELLOW}未安装 multitail，使用并行 tail 代替${NC}"
        tail -f /var/log/nginx/gemini_access.log & tail -f /var/log/nginx/gemini_error.log & tail -f "$LOG_FILE" & wait
      fi
      ;;
    *) log "${RED}无效选项${NC}" ;;
  esac
}

# ===== 预检 =====
preflight(){
  log "${CYAN}进行环境预检...${NC}"
  for bin in nginx curl openssl jq bc; do
    command -v "$bin" >/dev/null 2>&1 || { log "${RED}缺少依赖: $bin${NC}"; exit 1; }
  done
  # Nginx 语法
  nginx -t >/dev/null 2>&1 || log "${YELLOW}提示：Nginx 尚未配置或未启动，安装流程会自动生成配置${NC}"
  # 端口提示
  if port_in_use 80; then log "${YELLOW}提示：80端口被占用（正常情况是nginx占用）${NC}"; fi
  if port_in_use 443; then log "${YELLOW}提示：443端口被占用（正常情况是nginx占用）${NC}"; fi
  log "${GREEN}预检完成${NC}"
}

# ===== 菜单 =====
show_menu(){
  clear
  echo -e "${GREEN}=====================================${NC}"
  echo -e "${GREEN} Gemini API 反代管理脚本 v${VERSION} ${NC}"
  echo -e "${GREEN}=====================================${NC}"
  echo "1) 安装/配置反代（含SSL）"
  echo "2) 重启反代"
  echo "3) 卸载Nginx"
  echo "4) 停止Nginx"
  echo "5) 完全清理（Nginx/配置/缓存）"
  echo "6) 备份配置"
  echo "7) 恢复配置"
  echo "8) 检查服务状态"
  echo "9) 资源与代理监控"
  echo "10) 查看日志"
  echo "0) 退出"
  echo -e "${GREEN}=====================================${NC}"
  read -rp "请输入选项 [0-10]: " option
}

# ===== 主流程 =====
main(){
  check_root
  detect_os
  mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"
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
        log "${GREEN}退出脚本${NC}"; exit 0 ;;
      *)
        log "${RED}无效选项${NC}" ;;
    esac
    read -rp "按 Enter 继续..."
  done
}

main
