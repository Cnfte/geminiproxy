#!/bin/bash
# set -e # 在遇到错误时立即退出，提高脚本健壮性

# ==============================================================================
# Gemini API 反向代理管理脚本 (v2.2.2 - 优化 Certbot 集成)
# 作者: cnfte (整合与优化: Gemini Assistant)
# 开源地址: https://github.com/cnfte/geminiproxy (原版)
# 功能:
#   - 自动申请和续订 SSL 证书 (Let's Encrypt via Certbot)
#   - Nginx 反向代理配置
#   - 多系统支持 (Ubuntu, Debian, CentOS, RHEL, Fedora, Arch)
#   - 防火墙配置 (ufw, firewalld, iptables)
#   - 服务器所在地黑名单检测 (禁止来自特定地区的执行)
#   - Web 监控面板 (基于 Nginx 日志分析)
#   - 终端监控面板 (实时系统资源和代理状态)
#   - 服务管理 (安装, 启动, 停止, 重启, 卸载, 完全删除)
#   - 配置备份与恢复
#   - 日志查看
# ==============================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 版本信息 ---
VERSION="2.2.2" # 优化 Certbot 集成
CONFIG_FILE="/etc/gemini_proxy.conf"
BACKUP_DIR="/var/backups/gemini_proxy"
LOG_FILE="/var/log/gemini_proxy.log"
MONITOR_WEB_ROOT="/var/www/gemini_monitor"
MONITOR_WEB_PORT="8080"
MONITOR_WEB_DOMAIN="monitor.your_domain.com" # 请替换为您的域名或IP
LOG_PARSER_URL="https://github.com/go-nginx/log-parser/releases/download/v0.3.0/log-parser_linux_amd64" # go-nginx-log-parser
LOG_PARSER_BIN="/usr/local/bin/go-nginx-log-parser"
NGINX_MONITOR_CONF="/etc/nginx/conf.d/gemini_monitor.conf"
CERTBOT_OPTIONS_FILE="/etc/letsencrypt/options-ssl-nginx.conf" # Certbot 的 SSL 选项文件

# --- 黑名单地区 ---
# 注意: IP地理位置查询结果可能不完全准确，且服务可能不稳定。
# 这里的国家名称需要与 IP 查询服务返回的名称匹配。
BLACKLIST_REGIONS=("Cuba" "Iran" "North Korea" "Syria" "Sudan" "Belarus" "Ukraine" "Russia" "Somalia" "Myanmar" "Central African Republic" "Libya" "Zimbabwe" "Venezuela" "Yemen" "Afghanistan" "China" "Hong Kong")

# --- 检查root权限 ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 此脚本需要root权限才能运行${NC}"
        exit 1
    fi
}

# --- 日志记录 ---
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# --- 系统检测 ---
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -sr)
    elif [ -f /etc/redhat-release ]; then
        OS="centos" # 兼容 RHEL, Fedora
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release)
    elif [ -f /etc/arch-release ]; then
        OS="arch"
        OS_VERSION="rolling"
    else
        log "${RED}无法检测操作系统${NC}"
        exit 1
    fi
    log "${GREEN}检测到操作系统: $OS $OS_VERSION${NC}"
}

# --- 输入验证函数 ---
# 验证域名格式
validate_domain() {
    local domain_name="$1"
    # 1. 不能为空
    if [ -z "$domain_name" ]; then
        log "${RED}域名不能为空。${NC}"
        return 1
    fi
    # 2. 不包含空格或非法字符 (除了字母、数字、点、连字符)
    if [[ ! "$domain_name" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        log "${RED}域名包含非法字符。${NC}"
        return 1
    fi
    # 3. 不以点或连字符开头或结尾
    if [[ "$domain_name" =~ ^[-.] ]] || [[ "$domain_name" =~ [.-]$ ]]; then
        log "${RED}域名不能以点或连字符开头或结尾。${NC}"
        return 1
    fi
    # 4. 不包含连续的点 (空标签)
    if [[ "$domain_name" =~ \.\. ]]; then
        log "${RED}域名包含连续的点 (空标签)，例如 'example..com'。${NC}"
        return 1
    fi
    # 5. 至少包含一个点 (通常是 FQDN 的要求)
    if [[ ! "$domain_name" =~ \. ]]; then
        log "${RED}域名必须包含至少一个点 (例如 'example.com')。${NC}"
        return 1
    fi
    # 6. 支持四级域名，例如 api.proxy.example.com
    # 上面的检查已经包含了对多级域名的支持，只要符合规则即可
    return 0 # 有效
}

# 验证路径是否安全 (不包含 .. 或 /)
validate_path_segment() {
    local path_segment="$1"
    if [[ "$path_segment" =~ ^[a-zA-Z0-9._-]+$ && ! "$path_segment" =~ [\/\\] && ! "$path_segment" =~ \.\. ]]; then
        return 0 # 有效
    else
        return 1 # 无效
    fi
}

# --- 安装依赖 ---
install_dependencies() {
    log "${GREEN}正在安装基础依赖...${NC}"
    local packages=""
    local install_cmd=""
    
    case $OS in
        ubuntu|debian)
            # 确保 apt update 独立运行
            log "${CYAN}正在运行 apt update...${NC}"
            if ! apt update; then
                log "${RED}apt update 失败，请检查您的 APT 配置和网络连接。${NC}"
                return 1
            fi
            
            install_cmd="apt install -y"
            packages="nginx openssl curl jq bc certbot python3-certbot-nginx multitail"
            ;;
        centos|rhel|fedora)
            # 确保 EPEL 源已启用
            if ! rpm -q epel-release &>/dev/null; then
                log "${YELLOW}正在安装 EPEL 源...${NC}"
                yum install -y epel-release || dnf install -y epel-release
                if [ $? -ne 0 ]; then
                    log "${RED}安装 EPEL 源失败，请手动安装。${NC}"
                    return 1
                fi
            fi
            install_cmd="yum install -y"
            if [ "$OS" == "fedora" ]; then
                install_cmd="dnf install -y"
            fi
            packages="nginx openssl curl jq bc certbot python3-certbot-nginx multitail"
            ;;
        arch)
            install_cmd="pacman -Sy --noconfirm"
            packages="nginx openssl curl jq bc certbot python-certbot-nginx multitail"
            ;;
        *)
            log "${RED}不支持的操作系统: $OS${NC}"
            return 1
            ;;
    esac
    
    log "${CYAN}正在执行安装命令: $install_cmd $packages${NC}"
    if ! $install_cmd $packages; then
        log "${RED}基础依赖安装失败，请检查错误信息。${NC}"
        return 1
    fi
    log "${GREEN}基础依赖安装完成。${NC}"
    return 0
}

# --- 安装 go-nginx-log-parser ---
install_log_parser() {
    if [ -f "$LOG_PARSER_BIN" ]; then
        log "${GREEN}go-nginx-log-parser 已安装。${NC}"
        return 0
    fi
    
    log "${GREEN}正在下载 go-nginx-log-parser...${NC}"
    if ! curl -L "$LOG_PARSER_URL" -o "$LOG_PARSER_BIN"; then
        log "${RED}下载 go-nginx-log-parser 失败。请手动下载并放置到 $LOG_PARSER_BIN${NC}"
        log "${YELLOW}您可以从以下地址下载: $LOG_PARSER_URL${NC}"
        return 1
    fi
    chmod +x "$LOG_PARSER_BIN"
    log "${GREEN}go-nginx-log-parser 安装成功。${NC}"
    return 0
}

# --- 配置防火墙 ---
configure_firewall() {
    log "${GREEN}正在配置防火墙...${NC}"
    local firewall_configured=false
    
    case $OS in
        ubuntu|debian)
            if command -v ufw &> /dev/null; then
                ufw allow 80/tcp comment 'HTTP'
                ufw allow 443/tcp comment 'HTTPS'
                ufw allow $MONITOR_WEB_PORT/tcp comment 'Gemini Monitor'
                ufw reload
                log "${GREEN}UFW 防火墙已配置。${NC}"
                firewall_configured=true
            fi
            ;;
        centos|rhel|fedora)
            if command -v firewall-cmd &> /dev/null; then
                systemctl enable --now firewalld
                firewall-cmd --permanent --add-service=http
                firewall-cmd --permanent --add-service=https
                firewall-cmd --permanent --add-port=$MONITOR_WEB_PORT/tcp
                firewall-cmd --reload
                log "${GREEN}Firewalld 已配置。${NC}"
                firewall_configured=true
            fi
            ;;
        arch)
            if command -v iptables &> /dev/null; then
                iptables -A INPUT -p tcp --dport 80 -j ACCEPT
                iptables -A INPUT -p tcp --dport 443 -j ACCEPT
                iptables -A INPUT -p tcp --dport $MONITOR_WEB_PORT -j ACCEPT
                # 确保 iptables-persistent 或类似服务已启用
                if command -v iptables-save &> /dev/null; then
                    iptables-save > /etc/iptables/iptables.rules
                    systemctl enable iptables
                    log "${GREEN}iptables 已配置并保存规则。${NC}"
                    firewall_configured=true
                else
                    log "${YELLOW}警告: 未检测到 iptables-save 命令，防火墙规则可能不会在重启后生效。${NC}"
                fi
            fi
            ;;
    esac
    
    if ! $firewall_configured; then
        log "${YELLOW}警告: 未能自动配置防火墙。请确保端口 80, 443, $MONITOR_WEB_PORT 已开放。${NC}"
    fi
    return 0
}

# --- 获取 Certbot 的 SSL Session Cache 大小 (仅供参考，Certbot 自动管理时无需手动设置) ---
get_certbot_ssl_cache_size() {
    if [ -f "$CERTBOT_OPTIONS_FILE" ]; then
        local size=$(grep "ssl_session_cache" "$CERTBOT_OPTIONS_FILE" 2>/dev/null | awk '{print $4}' | sed 's/;//')
        if [ -n "$size" ]; then
            echo "$size"
        else
            echo "1m" # 默认值，如果获取失败
        fi
    else
        echo "1m" # 默认值，如果文件不存在
    fi
}

# --- 配置 Nginx 主反代 ---
configure_nginx_proxy() {
    log "${GREEN}正在配置 Nginx 主反代...${NC}"
    
    read -p "请输入您的域名 (例如: api.example.com): " domain
    if ! validate_domain "$domain"; then
        # validate_domain 函数会打印错误信息
        return 1
    fi
    
    local cert_path=""
    local key_path=""
    local auto_ssl="n"
    
    read -p "是否自动申请 SSL 证书 (使用 Let's Encrypt)? [y/N]: " auto_ssl
    auto_ssl=$(echo "$auto_ssl" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$auto_ssl" == "y" ]]; then
        read -p "请输入您的邮箱地址 (用于 Let's Encrypt 通知): " email
        # 简单的邮箱格式验证
        if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; then
            log "${RED}邮箱地址格式无效。${NC}"
            return 1
        fi
        
        log "${GREEN}正在使用 Certbot 自动申请 SSL 证书...${NC}"
        # 确保 Nginx 正在运行并监听 80 端口，以便 Certbot 进行验证
        if ! systemctl is-active nginx &> /dev/null; then
            start_nginx
        fi
        
        # 运行 Certbot，它会尝试自动修改 Nginx 配置
        # Certbot 可能会在 /etc/nginx/conf.d/ 或 /etc/nginx/sites-available/ 创建或修改文件
        if ! certbot --nginx -d "$domain" --non-interactive --agree-tos --email "$email"; then
            log "${RED}SSL 证书申请失败，请检查 Certbot 错误信息。${NC}"
            log "${YELLOW}常见问题：域名未正确解析到此服务器，或防火墙未开放 80 端口。${NC}"
            return 1
        fi
        log "${GREEN}SSL 证书申请成功！Certbot 已尝试配置 Nginx。${NC}"
        
        # Certbot 成功后，我们尝试找到它修改的配置文件，并插入我们的反代 location
        cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
        key_path="/etc/letsencrypt/live/$domain/privkey.pem"
        
        # 保存配置到 .conf 文件
        echo "DOMAIN=$domain" > $CONFIG_FILE
        echo "CERT_PATH=$cert_path" >> $CONFIG_FILE
        echo "KEY_PATH=$key_path" >> $CONFIG_FILE
        echo "PROXY_TARGET=https://generativelanguage.googleapis.com/" >> $CONFIG_FILE
        
        local certbot_conf_path=""
        # 尝试查找 Certbot 为该域名创建的配置文件
        certbot_conf_path=$(find /etc/nginx/sites-available /etc/nginx/conf.d -maxdepth 1 -name "*.conf" -print0 2>/dev/null | xargs -0 grep -l "server_name $domain" 2>/dev/null | head -n 1)
        
        if [ -n "$certbot_conf_path" ] && [ -f "$certbot_conf_path" ]; then
            log "${GREEN}找到 Certbot 生成的 Nginx 配置文件: $certbot_conf_path${NC}"
            # 备份原始文件
            cp "$certbot_conf_path" "${certbot_conf_path}.bak_$(date +%Y%m%d%H%M%S)"
            
            # 插入 proxy_pass 配置到 Certbot 生成的 server 块中
            # 寻找 listen 443 ssl; 后的第一个 location / { ... } 块，或者直接在 server 块末尾插入
            # 这是一个简化的插入逻辑，可能需要根据 Certbot 实际生成的配置进行调整
            # 目标是找到 server { ... } 块，并在其中添加我们的 location / { ... }
            
            # 移除 Certbot 可能添加的默认 location 块，如果它与我们的冲突
            # 例如：try_files $uri $uri/ =404;
            sed -i '/^\s*location \/ {/,/^\s*}/ { /try_files \$uri \$uri\/ =404;/d }' "$certbot_conf_path"
            
            # 移除 Certbot 可能在当前文件中重复添加的 ssl_session_cache (它应该只在 options-ssl-nginx.conf 中)
            sed -i '/^\s*ssl_session_cache/d' "$certbot_conf_path"

            # 在 server 块的最后一个 '}' 之前插入我们的 location 块
            # 这是一个更通用的插入方法，但仍有边缘情况
            awk -v proxy_config='
    access_log /var/log/nginx/gemini_access.log;
    error_log /var/log/nginx/gemini_error.log;

    location / {
        proxy_pass  https://generativelanguage.googleapis.com/;
        proxy_ssl_server_name on;
        proxy_set_header Host generativelanguage.googleapis.com;
        proxy_set_header Connection "";
        proxy_http_version 1.1;
        chunked_transfer_encoding off;
        proxy_buffering off;
        proxy_cache off;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
' '
/^\s*server\s*{/ { in_server=1; print; next }
/^\s*}/ && in_server { print proxy_config; in_server=0; }
{ print }
' "$certbot_conf_path" > "${certbot_conf_path}.tmp" && mv "${certbot_conf_path}.tmp" "$certbot_conf_path"
            
            log "${GREEN}已将反代配置插入到 Certbot 生成的 Nginx 配置文件中。${NC}"
        else
            log "${YELLOW}警告: 未能找到 Certbot 为 $domain 生成的 Nginx 配置文件。${NC}"
            log "${YELLOW}您可能需要手动将以下反代配置添加到 Nginx 的 443 端口 server 块中：${NC}"
            echo -e "${CYAN}
    access_log /var/log/nginx/gemini_access.log;
    error_log /var/log/nginx/gemini_error.log;

    location / {
        proxy_pass  https://generativelanguage.googleapis.com/;
        proxy_ssl_server_name on;
        proxy_set_header Host generativelanguage.googleapis.com;
        proxy_set_header Connection '';
        proxy_http_version 1.1;
        chunked_transfer_encoding off;
        proxy_buffering off;
        proxy_cache off;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
${NC}"
            # 即使没有找到 Certbot 的文件，也尝试测试 Nginx 配置，因为 Certbot 可能已经修改了其他地方
            if ! nginx -t; then
                log "${RED}Nginx 配置测试失败，请手动检查 Nginx 配置。${NC}"
                return 1
            fi
        fi
        
        # 重新加载 Nginx 配置
        if ! restart_nginx; then
            log "${RED}Nginx 重启失败，请手动检查 Nginx 配置。${NC}"
            return 1
        fi

    else # 用户选择手动提供证书
        read -p "请输入 SSL 证书路径 (全路径, .pem 格式): " cert_path
        read -p "请输入 SSL 证书密钥路径 (全路径, .key 格式): " key_path
        
        # 验证路径是否是绝对路径且存在
        if [[ ! "$cert_path" =~ ^/ ]] || [[ ! "$key_path" =~ ^/ ]]; then
            log "${RED}证书路径和密钥路径必须是绝对路径。${NC}"
            return 1
        fi
        if [ ! -f "$cert_path" ] || [ ! -f "$key_path" ]; then
            log "${RED}证书文件不存在，请检查路径。${NC}"
            return 1
        fi
        
        # 获取 Certbot 的 SSL Session Cache 大小，以保持一致性
        local ssl_session_cache_size=$(get_certbot_ssl_cache_size)
        
        # 保存配置到 .conf 文件
        echo "DOMAIN=$domain" > $CONFIG_FILE
        echo "CERT_PATH=$cert_path" >> $CONFIG_FILE
        echo "KEY_PATH=$key_path" >> $CONFIG_FILE
        echo "PROXY_TARGET=https://generativelanguage.googleapis.com/" >> $CONFIG_FILE
        
        # 创建 Nginx 配置文件
        cat > /etc/nginx/conf.d/gemini_proxy.conf <<EOF
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain;
    
    ssl_certificate $cert_path;
    ssl_certificate_key $key_path;
    
    # SSL 优化参数 (使用 Certbot 的配置，并保持 ssl_session_cache 一致)
    ssl_session_cache shared:le_nginx_SSL:$ssl_session_cache_size;
    ssl_session_timeout 1440m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s; # 使用 Google DNS 进行 OCSP 查询
    resolver_timeout 5s;
    
    access_log /var/log/nginx/gemini_access.log;
    error_log /var/log/nginx/gemini_error.log;
    
    location / {
        proxy_pass  https://generativelanguage.googleapis.com/;
        proxy_ssl_server_name on;
        proxy_set_header Host generativelanguage.googleapis.com;
        proxy_set_header Connection '';
        proxy_http_version 1.1;
        chunked_transfer_encoding off;
        proxy_buffering off; # 提高速度
        proxy_cache off;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
        # 测试 Nginx 配置
        if ! nginx -t; then
            log "${RED}Nginx 配置测试失败，请检查配置。${NC}"
            return 1
        fi
        log "${GREEN}Nginx 配置测试成功${NC}"
    fi
    
    return 0
}

# --- 配置 Nginx 监控面板 ---
configure_nginx_monitor() {
    log "${GREEN}正在配置 Nginx 监控面板服务...${NC}"
    
    # 检查是否已配置域名
    if [ ! -f "$CONFIG_FILE" ]; then
        log "${RED}请先安装反代服务，配置好域名。${NC}"
        return 1
    fi
    source $CONFIG_FILE
    
    # 如果用户未设置 MONITOR_WEB_DOMAIN，则使用反代域名或 IP
    if [ -z "$MONITOR_WEB_DOMAIN" ] || [[ "$MONITOR_WEB_DOMAIN" == "monitor.your_domain.com" ]]; then
        if [ -n "$DOMAIN" ]; then
            MONITOR_WEB_DOMAIN="monitor.$DOMAIN" # 尝试使用主域名的子域名
            log "${YELLOW}未设置监控面板域名，将尝试使用主域名的子域名: $MONITOR_WEB_DOMAIN${NC}"
        else
            log "${RED}请在脚本中设置 MONITOR_WEB_DOMAIN 或先配置反代域名。${NC}"
            return 1
        fi
    fi
    
    # 创建监控面板根目录
    mkdir -p "$MONITOR_WEB_ROOT"
    
    # 配置 Nginx 监控面板虚拟主机
    cat > "$NGINX_MONITOR_CONF" <<EOF
server {
    listen $MONITOR_WEB_PORT;
    server_name $MONITOR_WEB_DOMAIN;
    
    root $MONITOR_WEB_ROOT;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # 安全警告: 默认情况下，此监控面板没有认证。
    # 建议您添加基本认证或IP限制来保护它。
    # 例如:
    # auth_basic "Restricted Access";
    # auth_basic_user_file /etc/nginx/.htpasswd;
    # allow 192.168.1.0/24;
    # deny all;
    
    # 可选: 添加 SSL 支持给监控面板
    # listen 443 ssl http2;
    # server_name monitor.your_domain.com;
    # ssl_certificate /etc/letsencrypt/live/$MONITOR_WEB_DOMAIN/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/$MONITOR_WEB_DOMAIN/privkey.pem;
    # ... 其他 SSL 参数 ...
}
EOF
    
    # 测试 Nginx 配置
    if ! nginx -t; then
        log "${RED}Nginx 监控面板配置测试失败，请检查配置。${NC}"
        return 1
    fi
    log "${GREEN}Nginx 监控面板配置测试成功${NC}"
    return 0
}

# --- 设置定时任务生成监控报告 ---
setup_monitor_cron() {
    log "${GREEN}正在设置定时任务生成监控报告...${NC}"
    
    # 检查是否已安装日志解析器
    if [ ! -f "$LOG_PARSER_BIN" ]; then
        log "${RED}日志解析器 ($LOG_PARSER_BIN) 未安装，无法生成监控报告。${NC}"
        return 1
    fi
    
    # 检查 Nginx 访问日志是否存在
    if [ ! -f "/var/log/nginx/gemini_access.log" ]; then
        log "${RED}Nginx 访问日志 (/var/log/nginx/gemini_access.log) 不存在，无法生成监控报告。${NC}"
        return 1
    fi
    
    # 创建日志分析脚本
    local analyze_script="/usr/local/bin/analyze_gemini_logs.sh"
    cat > "$analyze_script" <<EOF
#!/bin/bash
LOG_FILE="/var/log/nginx/gemini_access.log"
OUTPUT_DIR="/var/www/gemini_monitor"
PARSER_BIN="$LOG_PARSER_BIN"
DATE_FORMAT="%Y-%m-%d" # 日期格式

# 检查日志文件是否存在
if [ ! -f "\$LOG_FILE" ]; then
    echo "日志文件不存在: \$LOG_FILE"
    exit 1
fi

# 检查解析器是否存在
if [ ! -x "\$PARSER_BIN" ]; then
    echo "日志解析器不存在或不可执行: \$PARSER_BIN"
    exit 1
fi

# 检查输出目录是否存在
mkdir -p "\$OUTPUT_DIR"

# 生成近5天请求记录 (JSON格式)
echo "Generating recent requests..."
\$PARSER_BIN --file "\$LOG_FILE" --output-format json --output-file "\$OUTPUT_DIR/recent_requests.json" --time-range "5d" --fields "remote_addr,time_local,request,status,body_bytes_sent"

# 生成请求成功率 (文本)
echo "Generating request success rate..."
success_rate=\$($PARSER_BIN --file "\$LOG_FILE" --time-range "7d" --status-codes "2xx,3xx" --count 2>/dev/null)
total_requests=\$($PARSER_BIN --file "\$LOG_FILE" --time-range "7d" --count 2>/dev/null)
if [ -n "\$total_requests" ] && [ "\$total_requests" -gt 0 ]; then
    rate=\$(awk "BEGIN {printf \"%.2f\", (\$success_rate / \$total_requests) * 100}")
    echo -e "请求成功率 (近7天): \${rate}%" > "\$OUTPUT_DIR/success_rate.txt"
else
    echo "请求成功率 (近7天): N/A" > "\$OUTPUT_DIR/success_rate.txt"
fi

# 生成请求 IP (近12小时)
echo "Generating recent IPs..."
\$PARSER_BIN --file "\$LOG_FILE" --output-format json --output-file "\$OUTPUT_DIR/recent_ips.json" --time-range "12h" --fields "remote_addr" --unique-ips

# 生成使用流量 (近15天)
echo "Generating traffic usage..."
\$PARSER_BIN --file "\$LOG_FILE" --output-format json --output-file "\$OUTPUT_DIR/traffic_usage.json" --time-range "15d" --fields "body_bytes_sent" --aggregate-by "day"

# 生成请求总次数 (文本)
echo "Generating total request count..."
echo "请求总次数: \$total_requests" > "\$OUTPUT_DIR/total_requests.txt"

# 生成 index.html 报告
echo "Generating index.html..."
cat > "\$OUTPUT_DIR/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Gemini Proxy Monitor</title>
    <style>
        body { font-family: sans-serif; margin: 20px; background-color: #f4f4f4; color: #333; }
        .container { background-color: #fff; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1, h2 { color: #007bff; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
        .error { color: red; }
        .success { color: green; }
        pre { background-color: #eee; padding: 10px; border-radius: 4px; overflow-x: auto; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Gemini Proxy Monitor</h1>
        <p>最后更新时间: $(date '+%Y-%m-%d %H:%M:%S')</p>
        
        <h2>关键指标</h2>
        <table>
            <tr><th>指标</th><th>数值</th></tr>
            <tr><td>请求总次数 (近7天)</td><td>$(cat $OUTPUT_DIR/total_requests.txt 2>/dev/null | awk '{print $3}')</td></tr>
            <tr><td>请求成功率 (近7天)</td><td>$(cat $OUTPUT_DIR/success_rate.txt 2>/dev/null)</td></tr>
        </table>
        
        <h2>近12小时请求 IP</h2>
        <p>唯一 IP 数量: $(jq '. | length' $OUTPUT_DIR/recent_ips.json 2>/dev/null || echo "N/A")</p>
        <pre>$(jq -c '.[]' $OUTPUT_DIR/recent_ips.json 2>/dev/null | paste -sd ' ')</pre>
        
        <h2>近5天请求记录</h2>
        <table>
            <tr><th>IP 地址</th><th>时间</th><th>请求</th><th>状态码</th><th>流量 (Bytes)</th></tr>
            $(jq -r '.[] | "<tr><td>\(.remote_addr)</td><td>\(.time_local)</td><td>\(.request)</td><td>\(.status)</td><td>\(.body_bytes_sent)</td></tr>"' $OUTPUT_DIR/recent_requests.json 2>/dev/null || echo "<tr><td colspan='5'>无法加载数据</td></tr>")
        </table>
        
        <h2>近15天流量统计 (按天)</h2>
        <table>
            <tr><th>日期</th><th>总流量 (Bytes)</th></tr>
            $(jq -r '.[] | "<tr><td>\(.day)</td><td>\(.body_bytes_sent)</td></tr>"' $OUTPUT_DIR/traffic_usage.json 2>/dev/null || echo "<tr><td colspan='2'>无法加载数据</td></tr>")
        </table>
    </div>
</body>
</html>
EOF

echo "监控报告生成完成。"
exit 0
EOF
    
    chmod +x "$analyze_script"
    
    # 添加 cron 任务
    # 每天生成两次报告，例如凌晨 0 点和中午 12 点
    # 使用 crontab -e 可能会导致交互问题，直接修改 crontab 更可靠
    if command -v crontab &>/dev/null; then
        if ! crontab -l 2>/dev/null | grep -q "$analyze_script"; then
            (crontab -l 2>/dev/null; echo "0 0,12 * * * $analyze_script > /dev/null 2>&1") | crontab -
            log "${GREEN}定时任务已设置。监控报告将生成在 $MONITOR_WEB_ROOT${NC}"
        else
            log "${YELLOW}定时任务已存在，未重复添加。${NC}"
        fi
    else
        log "${RED}警告: crontab 命令不可用，无法设置定时任务。请手动设置。${NC}"
    fi
    return 0
}

# --- 启动 Nginx ---
start_nginx() {
    if ! systemctl is-active nginx &>/dev/null; then
        systemctl enable nginx
        systemctl start nginx
        if [ $? -eq 0 ]; then
            log "${GREEN}Nginx 已启动${NC}"
        else
            log "${RED}启动 Nginx 失败。${NC}"
            return 1
        fi
    else
        log "${YELLOW}Nginx 服务已在运行。${NC}"
    fi
    return 0
}

# --- 重启 Nginx ---
restart_nginx() {
    if systemctl is-active nginx &>/dev/null; then
        systemctl restart nginx
        if [ $? -eq 0 ]; then
            log "${GREEN}Nginx 已重启${NC}"
        else
            log "${RED}重启 Nginx 失败。${NC}"
            return 1
        fi
    else
        log "${YELLOW}Nginx 服务未运行，尝试启动。${NC}"
        start_nginx
    fi
    return 0
}

# --- 停止 Nginx ---
stop_nginx() {
    if systemctl is-active nginx &>/dev/null; then
        systemctl stop nginx
        if [ $? -eq 0 ]; then
            log "${YELLOW}Nginx 已停止${NC}"
        else
            log "${RED}停止 Nginx 失败。${NC}"
            return 1
        fi
    else
        log "${YELLOW}Nginx 服务未运行。${NC}"
    fi
    return 0
}

# --- 卸载 Nginx ---
uninstall_nginx() {
    stop_nginx
    
    case $OS in
        ubuntu|debian)
            apt remove --purge -y nginx
            apt autoremove -y
            ;;
        centos|rhel|fedora)
            yum remove -y nginx
            ;;
        arch)
            pacman -R --noconfirm nginx
            ;;
    esac
    
    rm -f /etc/nginx/conf.d/gemini_proxy.conf
    rm -f "$NGINX_MONITOR_CONF"
    # 尝试移除 Certbot 可能修改的配置文件中的反代部分
    if [ -f "$CONFIG_FILE" ]; then
        source $CONFIG_FILE
        local certbot_conf_path=""
        # 尝试查找 Certbot 为该域名创建的配置文件
        certbot_conf_path=$(find /etc/nginx/sites-available /etc/nginx/conf.d -maxdepth 1 -name "*.conf" -print0 2>/dev/null | xargs -0 grep -l "server_name $DOMAIN" 2>/dev/null | head -n 1)
        
        if [ -n "$certbot_conf_path" ] && [ -f "$certbot_conf_path" ]; then
            log "${GREEN}尝试从 Certbot 配置文件 $certbot_conf_path 中移除反代配置。${NC}"
            # 移除我们添加的 location 块和 access_log/error_log
            # 使用更安全的 sed 命令，避免误删
            sed -i '/^\s*location \/ {/,/^\s*}/ { /proxy_pass/d; /proxy_ssl_server_name/d; /proxy_set_header Host/d; /proxy_set_header Connection/d; /proxy_http_version/d; /chunked_transfer_encoding/d; /proxy_buffering/d; /proxy_cache/d; /proxy_set_header X-Forwarded-For/d; /proxy_set_header X-Forwarded-Proto/d; }' "$certbot_conf_path"
            sed -i '/access_log \/var\/log\/nginx\/gemini_access.log;/d' "$certbot_conf_path"
            sed -i '/error_log \/var\/log\/nginx\/gemini_error.log;/d' "$certbot_conf_path"
            
            # 恢复 Certbot 默认的 try_files，如果它被删除了
            # 查找 listen 443 ssl; 块，并在其后插入 try_files
            if ! grep -q "try_files \$uri \$uri/ =404;" "$certbot_conf_path"; then
                sed -i '/^\s*listen 443 ssl/a\    try_files $uri $uri/ =404;' "$certbot_conf_path"
            fi
            
            nginx -t && restart_nginx # 尝试测试并重启 Nginx
        fi
    fi
    log "${GREEN}Nginx 已卸载${NC}"
}

# --- 完全删除所有相关文件和配置 ---
full_remove() {
    log "${YELLOW}正在执行完全删除操作，这将移除所有 Nginx 和 Gemini Proxy 相关文件！${NC}"
    read -p "您确定要继续吗? [y/N]: " confirm_remove
    confirm_remove=$(echo "$confirm_remove" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$confirm_remove" != "y" ]]; then
        log "${GREEN}操作已取消。${NC}"
        return
    fi
    
    uninstall_nginx
    rm -rf /etc/nginx
    rm -rf /var/log/nginx
    rm -rf /var/cache/nginx
    rm -f $CONFIG_FILE
    rm -rf $BACKUP_DIR
    rm -f "$LOG_PARSER_BIN"
    rm -f "/usr/local/bin/analyze_gemini_logs.sh"
    
    # 移除 cron 任务
    if command -v crontab &>/dev/null; then
        (crontab -l 2>/dev/null | grep -v "/usr/local/bin/analyze_gemini_logs.sh") | crontab -
        log "${GREEN}监控报告定时任务已移除。${NC}"
    fi
    
    log "${GREEN}所有 Nginx 和 Gemini Proxy 相关文件和配置已删除${NC}"
}

# --- 备份配置 ---
backup_config() {
    if [ ! -f $CONFIG_FILE ]; then
        log "${RED}未找到配置文件，请先安装反代。${NC}"
        return
    fi
    
    mkdir -p $BACKUP_DIR
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    local backup_archive="$BACKUP_DIR/gemini_proxy_config_$TIMESTAMP.tar.gz"
    
    # 确保要备份的文件存在
    local files_to_backup=""
    if [ -f "/etc/nginx/conf.d/gemini_proxy.conf" ]; then
        files_to_backup+="/etc/nginx/conf.d/gemini_proxy.conf "
    fi
    if [ -f "$CONFIG_FILE" ]; then
        files_to_backup+="$CONFIG_FILE"
    fi

    if [ -z "$files_to_backup" ]; then
        log "${YELLOW}没有找到可备份的配置文件。${NC}"
        return 0
    fi

    if tar -czf "$backup_archive" $files_to_backup 2>/dev/null; then
        log "${GREEN}配置已备份到 $backup_archive${NC}"
    else
        log "${RED}备份配置失败。${NC}"
    fi
}

# --- 恢复配置 ---
restore_config() {
    echo -e "${CYAN}可用的备份文件:${NC}"
    local backup_files=$(ls -l $BACKUP_DIR/*.tar.gz 2>/dev/null | awk '{print $9}')
    
    if [ -z "$backup_files" ]; then
        log "${RED}没有找到备份文件${NC}"
        return
    fi
    
    echo "$backup_files"
    read -p "请输入要恢复的备份文件路径: " backup_file_input
    
    # 安全检查: 确保用户输入的路径在 BACKUP_DIR 内部，防止路径遍历
    if [[ ! "$backup_file_input" =~ ^"$BACKUP_DIR"/gemini_proxy_config_[0-9]{14}\.tar\.gz$ ]]; then
        log "${RED}无效的备份文件路径。请选择 $BACKUP_DIR 下的有效备份文件。${NC}"
        return 1
    fi

    if [ ! -f "$backup_file_input" ]; then
        log "${RED}指定的备份文件不存在: $backup_file_input${NC}"
        return 1
    fi

    local temp_restore_dir="/tmp/gemini_restore_$(date +%s%N)"
    mkdir -p "$temp_restore_dir"
    
    log "${GREEN}正在将备份文件解压到临时目录: $temp_restore_dir${NC}"
    # 使用 --strip-components=1 确保解压后的目录结构扁平化
    if ! tar -xzf "$backup_file_input" -C "$temp_restore_dir" --strip-components=1; then
        log "${RED}解压备份文件失败。${NC}"
        rm -rf "$temp_restore_dir"
        return 1
    fi

    log "${GREEN}正在从临时目录恢复配置...${NC}"
    local restored_proxy_conf="$temp_restore_dir/etc/nginx/conf.d/gemini_proxy.conf"
    local restored_script_conf="$temp_restore_dir/etc/gemini_proxy.conf"

    if [ -f "$restored_proxy_conf" ]; then
        cp "$restored_proxy_conf" "/etc/nginx/conf.d/gemini_proxy.conf"
        log "${GREEN}Nginx 反代配置已恢复。${NC}"
    else
        log "${YELLOW}备份中未找到 Nginx 反代配置文件。${NC}"
    fi

    if [ -f "$restored_script_conf" ]; then
        cp "$restored_script_conf" "$CONFIG_FILE"
        log "${GREEN}脚本配置文件已恢复。${NC}"
    else
        log "${YELLOW}备份中未找到脚本配置文件。${NC}"
    fi

    rm -rf "$temp_restore_dir" # 清理临时目录

    # 重新加载 Nginx 配置
    if systemctl is-active nginx &> /dev/null; then
        if ! restart_nginx; then
            log "${RED}Nginx 重启失败，请手动检查配置。${NC}"
            return 1
        fi
    else
        log "${YELLOW}Nginx 服务未运行，请手动启动。${NC}"
    fi
    log "${GREEN}配置恢复完成。${NC}"
    return 0
}

# --- 检查服务状态 ---
check_status() {
    echo -e "${CYAN}=== 服务状态 ===${NC}"
    
    # Nginx 主服务状态
    nginx_status=$(systemctl is-active nginx 2>/dev/null || echo "inactive")
    echo -e "Nginx 主服务: $nginx_status"
    
    # Nginx 监控面板服务状态
    if [ -f "$NGINX_MONITOR_CONF" ]; then
        # Nginx 监控面板使用同一个服务，检查是否监听端口
        if command -v ss &>/dev/null && ss -tulnp | grep -q ":$MONITOR_WEB_PORT"; then
            echo -e "Nginx 监控面板服务: 运行中 (监听端口: $MONITOR_WEB_PORT)"
        else
            echo -e "Nginx 监控面板服务: 未运行或未监听端口 $MONITOR_WEB_PORT"
        fi
    else
        echo -e "Nginx 监控面板服务: 未配置"
    fi
    
    # Certbot 续订定时器状态
    if command -v systemctl &> /dev/null && systemctl list-timers 2>/dev/null | grep -q certbot; then
        certbot_timer_status=$(systemctl status certbot.timer 2>/dev/null | grep "Active:" | awk '{print $2}')
        echo -e "Certbot 续订定时器: $certbot_timer_status"
    else
        echo -e "Certbot 续订定时器: 未找到或未启用"
    fi
    
    # Cron 任务状态
    if command -v crontab &>/dev/null && crontab -l 2>/dev/null | grep -q "/usr/local/bin/analyze_gemini_logs.sh"; then
        echo -e "监控报告定时任务: 已设置"
    else
        echo -e "监控报告定时任务: 未设置"
    fi
    
    if [ -f $CONFIG_FILE ]; then
        source $CONFIG_FILE
        echo -e "\n${CYAN}=== 当前配置 ===${NC}"
        echo -e "域名: $DOMAIN"
        echo -e "证书路径: $CERT_PATH"
        echo -e "密钥路径: $KEY_PATH"
        
        # 检查证书过期时间
        if [ -f "$CERT_PATH" ]; then
            cert_expiry_ts=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2 | date -f - +%s 2>/dev/null)
            if [ -n "$cert_expiry_ts" ]; then
                current_ts=$(date +%s)
                days_left=$(( (cert_expiry_ts - current_ts) / 86400 ))
                if [ "$days_left" -lt 0 ]; then
                    echo -e "证书状态: ${RED}已过期 ${days_left} 天${NC}"
                elif [ "$days_left" -lt 30 ]; then
                    echo -e "证书过期时间: $(date -d @$cert_expiry_ts '+%Y-%m-%d') (${YELLOW}剩余 $days_left 天${NC})"
                else
                    echo -e "证书过期时间: $(date -d @$cert_expiry_ts '+%Y-%m-%d') (剩余 $days_left 天)"
                fi
            else
                echo -e "证书状态: ${RED}无法获取过期时间${NC}"
            fi
        else
            echo -e "证书状态: ${RED}证书文件不存在${NC}"
        fi
    fi
    
    # 显示最近访问日志
    echo -e "\n${CYAN}=== 最近访问日志 (最后5行) ===${NC}"
    if [ -f /var/log/nginx/gemini_access.log ]; then
        tail -n 5 /var/log/nginx/gemini_access.log
    else
        echo "无访问日志"
    fi
}

# --- 监控代理状态 (终端) ---
monitor_proxy_terminal() {
    if [ ! -f $CONFIG_FILE ]; then
        log "${RED}未找到配置文件，请先安装反代。${NC}"
        return 1
    fi
    source $CONFIG_FILE
    
    log "${CYAN}开始监控代理状态 (按Ctrl+C停止)...${NC}"
    
    trap 'log "${CYAN}代理状态监控已停止${NC}"; return' INT
    
    while true; do
        # 检查黑名单地区
        if ! check_geo_blacklist; then
            log "${RED}服务器所在地位于黑名单区域，禁止执行监控。${NC}"
            return 1
        fi
        
        # 检查 Nginx 是否运行
        if ! systemctl is-active nginx &> /dev/null; then
            echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}Nginx 服务未运行${NC}"
        else
            # 尝试访问代理目标
            response=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN/v1/models" -H "Content-Type: application/json" --connect-timeout 5)
            timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            
            if [ -z "$response" ]; then
                response="无响应"
                echo -e "[$timestamp] ${RED}代理异常 (无响应)${NC}"
            elif [ "$response" -eq 200 ] 2>/dev/null; then
                echo -e "[$timestamp] ${GREEN}代理正常 (HTTP $response)${NC}"
            else
                echo -e "[$timestamp] ${RED}代理异常 (HTTP $response)${NC}"
            fi
        fi
        sleep 5
    done
}

# --- 终端监控面板 ---
monitor_terminal_dashboard() {
    log "${CYAN}开始终端监控面板 (按Ctrl+C停止)...${NC}"
    
    trap 'log "${CYAN}终端监控面板已停止${NC}"; return' INT
    
    while true; do
        clear
        echo -e "${GREEN}=====================================${NC}"
        echo -e "${GREEN}    Gemini API 服务器状态监控 v$VERSION${NC}"
        echo -e "${GREEN}=====================================${NC}"
        
        # 检查黑名单地区
        if ! check_geo_blacklist; then
            log "${RED}服务器所在地位于黑名单区域，禁止执行监控。${NC}"
            return 1
        fi
        
        # CPU 占用
        cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%.* to.*/\1/" | awk '{print 100 - $1}')
        echo -e "${CYAN}CPU 占用: ${RED}${cpu_usage}%${NC}"
        
        # 内存占用
        mem_info=$(free -h | grep Mem:)
        mem_total=$(echo $mem_info | awk '{print $2}')
        mem_used=$(echo $mem_info | awk '{print $3}')
        mem_percent=$(echo $mem_info | awk '{print $4}')
        echo -e "${CYAN}内存占用: ${GREEN}${mem_used}/${mem_total} (${mem_percent})${NC}"
        
        # 流量统计和请求总次数 (基于 Nginx 日志)
        if [ -f "/var/log/nginx/gemini_access.log" ]; then
            request_count=$(wc -l < /var/log/nginx/gemini_access.log)
            echo -e "${CYAN}请求总次数: ${GREEN}${request_count}${NC}"
            
            # 访问日志大小作为近似流量
            log_size_bytes=$(du -b /var/log/nginx/gemini_access.log | cut -f1)
            log_size_human=$(numfmt --to=iec --suffix=B $log_size_bytes)
            echo -e "${CYAN}访问日志大小: ${GREEN}${log_size_human}${NC}"
        else
            echo -e "${CYAN}请求总次数: ${RED}N/A (无访问日志)${NC}"
            echo -e "${CYAN}访问日志大小: ${RED}N/A${NC}"
        fi
        
        echo -e "${GREEN}=====================================${NC}"
        
        sleep 5 # 每5秒刷新一次
    done
}

# --- Web 监控面板 ---
monitor_web_panel() {
    log "${GREEN}正在启动 Web 监控面板服务...${NC}"
    
    # 检查是否已安装日志解析器
    if [ ! -f "$LOG_PARSER_BIN" ]; then
        log "${RED}日志解析器 ($LOG_PARSER_BIN) 未安装，请先安装。${NC}"
        return 1
    fi
    
    # 配置 Nginx 监控面板服务
    if ! configure_nginx_monitor; then
        log "${RED}Nginx 监控面板服务配置失败。${NC}"
        return 1
    fi
    
    # 设置定时任务生成报告
    if ! setup_monitor_cron; then
        log "${RED}设置监控报告定时任务失败。${NC}"
        return 1
    fi
    
    # 启动 Nginx 服务 (如果未运行)
    if ! start_nginx; then
        log "${RED}启动 Nginx 服务失败，无法启动监控面板。${NC}"
        return 1
    fi
    
    log "${GREEN}Web 监控面板已启动，请访问: http://$MONITOR_WEB_DOMAIN:$MONITOR_WEB_PORT${NC}"
    log "${YELLOW}安全警告: 默认情况下，此监控面板没有认证。建议您添加 Nginx 基本认证或防火墙 IP 限制来保护它。${NC}"
    
    return 0
}

# --- 查看日志 ---
view_logs() {
    echo -e "${CYAN}选择要查看的日志:${NC}"
    echo "1. Nginx 访问日志 (/var/log/nginx/gemini_access.log)"
    echo "2. Nginx 错误日志 (/var/log/nginx/gemini_error.log)"
    echo "3. 脚本日志 ($LOG_FILE)"
    echo "4. 所有日志 (使用 multitail)"
    echo "0. 返回主菜单"
    read -p "请输入选项 [0-4]: " log_choice
    
    case $log_choice in
        1) 
            echo -e "${CYAN}=== Nginx 访问日志 (按 Ctrl+C 停止) ===${NC}"
            tail -f /var/log/nginx/gemini_access.log 
            ;;
        2) 
            echo -e "${CYAN}=== Nginx 错误日志 (按 Ctrl+C 停止) ===${NC}"
            tail -f /var/log/nginx/gemini_error.log 
            ;;
        3) 
            echo -e "${CYAN}=== 脚本日志 (按 Ctrl+C 停止) ===${NC}"
            tail -f $LOG_FILE 
            ;;
        4) 
            if command -v multitail &> /dev/null; then
                echo -e "${CYAN}=== 所有日志 (按 Ctrl+C 停止) ===${NC}"
                multitail -s 3 /var/log/nginx/gemini_access.log /var/log/nginx/gemini_error.log $LOG_FILE
            else
                log "${RED}multitail 未安装，请安装 (例如: sudo apt install multitail)。${NC}"
            fi
            ;;
        0) 
            return 0
            ;;
        *) 
            log "${RED}无效选项${NC}" 
            ;;
    esac
    return 0
}

# --- IP 地理位置黑名单检查 ---
check_geo_blacklist() {
    # 检查是否已安装 jq
    if ! command -v jq &> /dev/null; then
        log "${YELLOW}警告: jq 未安装，无法进行精确的 IP 地理位置解析。请安装 jq (例如: sudo apt install jq)。${NC}"
        # 如果 jq 不存在，则无法进行精确解析，直接返回成功，但给出警告
        return 0
    fi
    
    # 检查是否已配置黑名单
    if [ ${#BLACKLIST_REGIONS[@]} -eq 0 ]; then
        log "${GREEN}黑名单为空，跳过检查。${NC}"
        return 0
    fi
    
    log "${CYAN}正在检查服务器所在地是否在黑名单内...${NC}"
    
    # 使用 ip-api.com 获取服务器的 IP 信息
    # 注意: 此 API 可能有速率限制或需要付费。
    geo_info=$(curl -s "http://ip-api.com/json")
    
    if [ -z "$geo_info" ]; then
        log "${YELLOW}警告: 无法获取服务器地理位置信息，跳过黑名单检查。${NC}"
        return 0 # 允许继续，但给出警告
    fi
    
    local country=""
    if command -v jq &> /dev/null; then
        country=$(echo "$geo_info" | jq -r '.country')
    else
        # 如果 jq 不存在，这里无法可靠地解析 JSON，直接返回警告
        log "${YELLOW}警告: jq 未安装，无法解析 IP 地理位置信息。${NC}"
        return 0
    fi

    if [ -z "$country" ]; then
        log "${YELLOW}警告: 从地理位置信息中未能解析出国家，跳过黑名单检查。${NC}"
        return 0
    fi
    
    log "${CYAN}服务器所在地: $country${NC}"
    
    # 检查国家是否在黑名单中
    for region in "${BLACKLIST_REGIONS[@]}"; do
        if [[ "$country" == "$region" ]]; then
            log "${RED}错误: 服务器所在地 '$country' 在禁止执行的黑名单内！${NC}"
            return 1 # 返回失败，表示在黑名单内
        fi
    done
    
    log "${GREEN}服务器所在地不在黑名单内。${NC}"
    return 0 # 返回成功，表示不在黑名单内
}

# --- 更新脚本 ---
update_script() {
    log "${CYAN}正在检查脚本更新...${NC}"
    # 假设这是最新版本地址，请根据实际情况修改
    local latest_script_url="https://raw.githubusercontent.com/cnfte/geminiproxy/main/proxy.sh" 
    local current_script_path=$(realpath "$0")
    
    # 尝试下载最新脚本内容
    local latest_script_content=$(curl -s "$latest_script_url")
    
    if [ -z "$latest_script_content" ]; then
        log "${RED}无法获取最新脚本内容，请检查网络或 URL。${NC}"
        return 1
    fi
    
    # 比较当前脚本和最新脚本 (简单比较版本号)
    local current_version=$(grep "^VERSION=" "$current_script_path" | cut -d'=' -f2 | tr -d '"')
    local latest_version=$(echo "$latest_script_content" | grep "^VERSION=" | cut -d'=' -f2 | tr -d '"')
    
    if [ "$current_version" == "$latest_version" ]; then
        log "${GREEN}脚本已是最新版本 (v$current_version)。${NC}"
        return 0
    fi
    
    log "${YELLOW}发现新版本脚本 (v$latest_version)。当前版本 (v$current_version)。${NC}"
    read -p "是否要更新脚本? [y/N]: " confirm_update
    confirm_update=$(echo "$confirm_update" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$confirm_update" == "y" ]]; then
        echo "$latest_script_content" > "$current_script_path.tmp"
        if [ $? -eq 0 ]; then
            mv "$current_script_path.tmp" "$current_script_path"
            chmod +x "$current_script_path"
            log "${GREEN}脚本已成功更新到 v$latest_version。请重新运行脚本以应用更改。${NC}"
            exit 0 # 退出当前脚本，让用户重新运行
        else
            log "${RED}更新脚本失败，请检查权限。${NC}"
            rm -f "$current_script_path.tmp"
            return 1
        fi
    else
        log "${GREEN}脚本更新已取消。${NC}"
        return 0
    fi
}

# --- 显示菜单 ---
show_menu() {
    clear
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}    Gemini API 反代管理脚本 v$VERSION${NC}"
    echo -e "${YELLOW}    作者: cnfte (整合与优化: Gemini Assistant)${NC}"
    echo -e "${RED}    开源地址: https://github.com/cnfte/geminiproxy${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo -e "  --- 服务管理 ---"
    echo -e "  1. 安装反代服务 (含 SSL 自动申请)"
    echo -e "  2. 重启反代服务"
    echo -e "  3. 停止反代服务"
    echo -e "  4. 卸载反代服务"
    echo -e "  5. 完全删除所有相关文件和配置"
    echo -e "  --- 配置管理 ---"
    echo -e "  6. 备份当前配置"
    echo -e "  7. 恢复配置"
    echo -e "  --- 监控与日志 ---"
    echo -e "  8. 检查服务状态"
    echo -e "  9. 终端监控面板 (实时系统资源)"
    echo -e " 10. 代理状态监控 (终端, 检查 API 可达性)"
    echo -e " 11. Web 监控面板 (生成日志报告)"
    echo -e " 12. 查看日志"
    echo -e "  --- 系统操作 ---"
    echo -e " 13. 更新脚本到最新版本"
    echo -e "  0. 退出脚本"
    echo -e "${GREEN}=====================================${NC}"
    read -p "请输入选项 [0-13]: " option
}

# --- 主函数 ---
main() {
    check_root
    
    # 初始化日志文件和目录
    mkdir -p $(dirname $LOG_FILE)
    touch $LOG_FILE
    
    # 首次运行或安装前检查黑名单
    if [ ! -f "$CONFIG_FILE" ]; then
        if ! check_geo_blacklist; then
            log "${RED}由于服务器所在地在黑名单内，脚本将退出。${NC}"
            exit 1
        fi
    fi
    
    detect_os
    
    while true; do
        show_menu
        case $option in
            1) # 安装反代服务
                if ! check_geo_blacklist; then log "${RED}安装失败：服务器所在地在黑名单内。${NC}"; break; fi
                if install_dependencies && configure_nginx_proxy; then
                    # 尝试安装日志解析器和配置监控面板
                    install_log_parser
                    configure_nginx_monitor
                    setup_monitor_cron
                    # 确保 Nginx 服务已启动并加载了所有配置
                    if ! start_nginx; then
                        log "${RED}启动 Nginx 服务失败，安装可能不完整。${NC}"
                    else
                        log "${GREEN}反代服务安装完成。${NC}"
                        log "${GREEN}Web 监控面板地址: http://$MONITOR_WEB_DOMAIN:$MONITOR_WEB_PORT${NC}"
                    fi
                else
                    log "${RED}反代服务安装失败。${NC}"
                fi
                ;;
            2) # 重启反代服务
                if ! check_geo_blacklist; then log "${RED}重启失败：服务器所在地在黑名单内。${NC}"; break; fi
                restart_nginx
                ;;
            3) # 停止反代服务
                stop_nginx
                ;;
            4) # 卸载反代服务
                if ! check_geo_blacklist; then log "${RED}卸载失败：服务器所在地在黑名单内。${NC}"; break; fi
                uninstall_nginx
                ;;
            5) # 完全删除
                if ! check_geo_blacklist; then log "${RED}删除失败：服务器所在地在黑名单内。${NC}"; break; fi
                full_remove
                ;;
            6) # 备份配置
                backup_config
                ;;
            7) # 恢复配置
                if ! check_geo_blacklist; then log "${RED}恢复失败：服务器所在地在黑名单内。${NC}"; break; fi
                restore_config
                ;;
            8) # 检查服务状态
                check_status
                ;;
            9) # 终端监控面板
                monitor_terminal_dashboard
                ;;
            10) # 代理状态监控 (终端)
                monitor_proxy_terminal
                ;;
            11) # Web 监控面板
                if ! check_geo_blacklist; then log "${RED}启动监控面板失败：服务器所在地在黑名单内。${NC}"; break; fi
                monitor_web_panel
                ;;
            12) # 查看日志
                view_logs
                ;;
            13) # 更新脚本
                update_script
                ;;
            0) # 退出脚本
                log "${GREEN}退出脚本${NC}"
                exit 0
                ;;
            *)
                log "${RED}无效选项，请重新输入${NC}"
                ;;
        esac
        read -p "按 Enter 键继续..."
    done
}

main
