#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# 版本信息
VERSION="1.5.0"
CONFIG_FILE="/etc/gemini_proxy.conf"
BACKUP_DIR="/var/backups/gemini_proxy"
LOG_FILE="/var/log/gemini_proxy.log"
DASHBOARD_PORT="9797"
DASHBOARD_DIR="/opt/gemini_dashboard"
DASHBOARD_DATA="$DASHBOARD_DIR/data"
DASHBOARD_ZIP_URL="https://yes.cnfte.top/website.zip"

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 此脚本需要root权限才能运行${NC}"
        exit 1
    fi
}

# 日志记录
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# 检测系统发行版
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -sr)
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release)
    elif [ -f /etc/arch-release ]; then
        OS="arch"
        OS_VERSION="rolling"
    else
        log "${RED}无法检测操作系统${NC}"
        exit 1
    fi
}

# 安装依赖
install_dependencies() {
    local install_certbot=$1
    
    log "${GREEN}正在安装依赖...${NC}"
    case $OS in
        ubuntu|debian)
            apt update
            apt install -y nginx openssl curl jq bc python3-pip net-tools unzip
            [ "$install_certbot" = "yes" ] && apt install -y certbot
            ;;
        centos|rhel|fedora)
            yum install -y epel-release
            yum install -y nginx openssl curl jq bc python3-pip net-tools unzip
            [ "$install_certbot" = "yes" ] && yum install -y certbot
            systemctl enable firewalld
            systemctl start firewalld
            ;;
        arch)
            pacman -Sy --noconfirm nginx openssl curl jq bc python-pip net-tools unzip
            [ "$install_certbot" = "yes" ] && pacman -S --noconfirm certbot
            ;;
        *)
            log "${RED}不支持的操作系统: $OS${NC}"
            exit 1
            ;;
    esac
    
    # 安装Python依赖
    pip3 install flask psutil > /dev/null 2>&1
}

# 配置防火墙
configure_firewall() {
    case $OS in
        ubuntu|debian)
            ufw allow 80/tcp
            ufw allow 443/tcp
            ufw allow $DASHBOARD_PORT/tcp
            ufw --force enable
            ;;
        centos|rhel|fedora)
            firewall-cmd --permanent --add-service=http
            firewall-cmd --permanent --add-service=https
            firewall-cmd --permanent --add-port=$DASHBOARD_PORT/tcp
            firewall-cmd --reload
            ;;
        arch)
            iptables -A INPUT -p tcp --dport 80 -j ACCEPT
            iptables -A INPUT -p tcp --dport 443 -j ACCEPT
            iptables -A INPUT -p tcp --dport $DASHBOARD_PORT -j ACCEPT
            iptables-save > /etc/iptables/iptables.rules
            systemctl enable iptables
            ;;
    esac
    log "${GREEN}防火墙已配置，开放端口: 80, 443, $DASHBOARD_PORT${NC}"
}

# 申请SSL证书
request_ssl_cert() {
    read -p "请输入您的域名: " domain
    read -p "请输入邮箱地址(用于证书过期提醒): " email
    
    # 停止Nginx以释放80端口
    systemctl stop nginx
    
    # 申请证书
    certbot certonly --standalone --non-interactive --agree-tos -d $domain -m $email
    
    if [ $? -eq 0 ]; then
        cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
        key_path="/etc/letsencrypt/live/$domain/privkey.pem"
        
        # 保存配置
        echo "DOMAIN=$domain" > $CONFIG_FILE
        echo "CERT_PATH=$cert_path" >> $CONFIG_FILE
        echo "KEY_PATH=$key_path" >> $CONFIG_FILE
        echo "SSL_MODE=auto" >> $CONFIG_FILE
        
        log "${GREEN}SSL证书申请成功${NC}"
    else
        log "${RED}SSL证书申请失败${NC}"
        exit 1
    fi
    
    # 重启Nginx
    systemctl start nginx
}

# 手动配置SSL证书
manual_ssl_cert() {
    read -p "请输入您的域名: " domain
    read -p "请输入SSL证书路径(全路径): " cert_path
    read -p "请输入SSL证书密钥路径(全路径): " key_path
    
    # 验证证书文件
    if [ ! -f "$cert_path" ] || [ ! -f "$key_path" ]; then
        log "${RED}证书文件或密钥文件不存在，请检查路径${NC}"
        exit 1
    fi
    
    # 保存配置
    echo "DOMAIN=$domain" > $CONFIG_FILE
    echo "CERT_PATH=$cert_path" >> $CONFIG_FILE
    echo "KEY_PATH=$key_path" >> $CONFIG_FILE
    echo "SSL_MODE=manual" >> $CONFIG_FILE
    
    log "${GREEN}SSL证书配置已保存${NC}"
}

# 配置Nginx
configure_nginx() {
    if [ ! -f $CONFIG_FILE ]; then
        log "${YELLOW}SSL证书配置${NC}"
        echo "1. 自动申请Let's Encrypt证书(需要域名已解析)"
        echo "2. 手动配置现有证书"
        read -p "请选择SSL证书配置方式 [1-2]: " ssl_choice
        
        case $ssl_choice in
            1) 
                install_dependencies "yes"
                request_ssl_cert 
                ;;
            2) 
                install_dependencies "no"
                manual_ssl_cert 
                ;;
            *)
                log "${RED}无效选项${NC}"
                exit 1
                ;;
        esac
    fi
    
    source $CONFIG_FILE
    
    # 创建配置文件
    if [ "$SSL_MODE" = "auto" ]; then
        cat > /etc/nginx/conf.d/chat.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    ssl_session_cache shared:le_nginx_SSL:1m;
    ssl_session_timeout 1440m;
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers TLS13-AES-256-GCM-SHA384:TLS13-CHACHA20-POLY1305-SHA256:TLS13-AES-128-GCM-SHA256:TLS13-AES-128-CCM-8-SHA256:TLS13-AES-128-CCM-SHA256:EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+ECDSA+AES128:EECDH+aRSA+AES128:RSA+AES128:EECDH+ECDSA+AES256:EECDH+aRSA+AES256:RSA+AES256:EECDH+ECDSA+3DES:EECDH+aRSA+3DES:RSA+3DES:!MD5;
    
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
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
}
EOF
    else
        cat > /etc/nginx/conf.d/chat.conf <<EOF
server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1440m;
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers TLS13-AES-256-GCM-SHA384:TLS13-CHACHA20-POLY1305-SHA256:TLS13-AES-128-GCM-SHA256:TLS13-AES-128-CCM-8-SHA256:TLS13-AES-128-CCM-SHA256:EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+ECDSA+AES128:EECDH+aRSA+AES128:RSA+AES128:EECDH+ECDSA+AES256:EECDH+aRSA+AES256:RSA+AES256:EECDH+ECDSA+3DES:EECDH+aRSA+3DES:RSA+3DES:!MD5;
    
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
}
EOF
    fi

    # 测试Nginx配置
    nginx -t
    if [ $? -eq 0 ]; then
        log "${GREEN}Nginx配置测试成功${NC}"
    else
        log "${RED}Nginx配置测试失败，请检查配置${NC}"
        exit 1
    fi
}

# 启动Nginx
start_nginx() {
    case $OS in
        ubuntu|debian|centos|rhel|fedora|arch)
            systemctl enable nginx
            systemctl start nginx
            ;;
    esac
    log "${GREEN}Nginx已启动${NC}"
}

# 重启Nginx
restart_nginx() {
    systemctl restart nginx
    log "${GREEN}Nginx已重启${NC}"
}

# 停止Nginx
stop_nginx() {
    systemctl stop nginx
    log "${YELLOW}Nginx已停止${NC}"
}

# 卸载Nginx
uninstall_nginx() {
    stop_nginx
    
    case $OS in
        ubuntu|debian)
            apt remove --purge -y nginx
            grep -q "SSL_MODE=auto" $CONFIG_FILE 2>/dev/null && apt remove --purge -y certbot
            apt autoremove -y
            ;;
        centos|rhel|fedora)
            yum remove -y nginx
            grep -q "SSL_MODE=auto" $CONFIG_FILE 2>/dev/null && yum remove -y certbot
            ;;
        arch)
            pacman -R --noconfirm nginx
            grep -q "SSL_MODE=auto" $CONFIG_FILE 2>/dev/null && pacman -R --noconfirm certbot
            ;;
    esac
    
    rm -f /etc/nginx/conf.d/chat.conf
    log "${GREEN}Nginx已卸载${NC}"
}

# 完全删除所有相关文件和配置
full_remove() {
    uninstall_nginx
    rm -rf /etc/nginx
    rm -rf /var/log/nginx
    rm -rf /var/cache/nginx
    grep -q "SSL_MODE=auto" $CONFIG_FILE 2>/dev/null && rm -rf /etc/letsencrypt
    rm -f $CONFIG_FILE
    log "${GREEN}所有Nginx相关文件和配置已删除${NC}"
}

# 备份配置
backup_config() {
    mkdir -p $BACKUP_DIR
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    tar -czf "$BACKUP_DIR/gemini_proxy_$TIMESTAMP.tar.gz" /etc/nginx/conf.d/chat.conf $CONFIG_FILE /etc/letsencrypt/live/$DOMAIN 2>/dev/null
    log "${GREEN}配置已备份到 $BACKUP_DIR/gemini_proxy_$TIMESTAMP.tar.gz${NC}"
}

# 恢复配置
restore_config() {
    echo "可用的备份文件:"
    ls -l $BACKUP_DIR/*.tar.gz 2>/dev/null | awk '{print $9}'
    
    read -p "请输入要恢复的备份文件路径: " backup_file
    
    if [ -f "$backup_file" ]; then
        tar -xzf "$backup_file" -C /
        log "${GREEN}配置已从 $backup_file 恢复${NC}"
        restart_nginx
    else
        log "${RED}指定的备份文件不存在${NC}"
    fi
}

# 检查服务状态
check_status() {
    nginx_status=$(systemctl is-active nginx)
    certbot_status=$(systemctl is-active certbot 2>/dev/null || echo "inactive")
    dashboard_status=$(systemctl is-active gemini-dashboard 2>/dev/null || echo "inactive")
    
    echo -e "${CYAN}=== 服务状态 ===${NC}"
    echo -e "Nginx: $nginx_status"
    [ -f $CONFIG_FILE ] && grep -q "SSL_MODE=auto" $CONFIG_FILE && echo -e "Certbot: $certbot_status"
    echo -e "监控面板: $dashboard_status"
    
    if [ -f $CONFIG_FILE ]; then
        source $CONFIG_FILE
        echo -e "\n${CYAN}=== 当前配置 ===${NC}"
        echo -e "域名: $DOMAIN"
        echo -e "证书路径: $CERT_PATH"
        echo -e "密钥路径: $KEY_PATH"
        echo -e "SSL模式: $SSL_MODE"
        
        # 检查证书过期时间
        if [ -f "$CERT_PATH" ]; then
            cert_expiry=$(openssl x509 -enddate -noout -in $CERT_PATH | cut -d= -f2)
            echo -e "证书过期时间: $cert_expiry"
        fi
    fi
    
    # 显示最近访问日志
    echo -e "\n${CYAN}=== 最近访问日志 (最后5行) ===${NC}"
    tail -n 5 /var/log/nginx/gemini_access.log 2>/dev/null || echo "无访问日志"
    
    # 显示公网IP
    public_ip=$(curl -s ifconfig.me)
    echo -e "\n${CYAN}=== 服务器信息 ===${NC}"
    echo -e "公网IP: $public_ip"
    echo -e "监控面板URL: http://$public_ip:$DASHBOARD_PORT"
}

# 更新证书
renew_cert() {
    if [ -f $CONFIG_FILE ] && grep -q "SSL_MODE=auto" $CONFIG_FILE; then
        certbot renew --quiet --post-hook "systemctl reload nginx"
        log "${GREEN}SSL证书已更新${NC}"
    else
        log "${RED}未找到自动证书配置，无法更新证书${NC}"
    fi
}

# 监控代理状态
monitor_proxy() {
    if [ ! -f $CONFIG_FILE ]; then
        log "${RED}未找到配置文件，请先安装反代${NC}"
        return
    fi
    
    source $CONFIG_FILE
    log "${CYAN}开始监控代理状态 (按Ctrl+C停止)...${NC}"
    
    trap 'log "${CYAN}监控已停止${NC}"; return' INT
    
    while true; do
        response=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN/v1/models" -H "Content-Type: application/json")
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        
        if [ "$response" -eq 200 ]; then
            echo -e "[$timestamp] ${GREEN}代理正常 (HTTP $response)${NC}"
        else
            echo -e "[$timestamp] ${RED}代理异常 (HTTP $response)${NC}"
        fi
        
        sleep 5
    done
}

# 查看日志
view_logs() {
    echo -e "${CYAN}选择要查看的日志:${NC}"
    echo "1. Nginx访问日志"
    echo "2. Nginx错误日志"
    echo "3. 脚本日志"
    echo "4. 全部日志"
    read -p "请输入选项 [1-4]: " log_choice
    
    case $log_choice in
        1) tail -f /var/log/nginx/gemini_access.log ;;
        2) tail -f /var/log/nginx/gemini_error.log ;;
        3) tail -f $LOG_FILE ;;
        4) 
            echo -e "${CYAN}=== Nginx访问日志 ===${NC}"
            tail -n 10 /var/log/nginx/gemini_access.log
            echo -e "\n${CYAN}=== Nginx错误日志 ===${NC}"
            tail -n 10 /var/log/nginx/gemini_error.log
            echo -e "\n${CYAN}=== 脚本日志 ===${NC}"
            tail -n 10 $LOG_FILE
            ;;
        *) log "${RED}无效选项${NC}" ;;
    esac
}

# 安装监控面板
install_dashboard() {
    log "${GREEN}正在安装监控面板...${NC}"
    
    # 创建目录
    mkdir -p $DASHBOARD_DIR
    mkdir -p $DASHBOARD_DATA
    
    # 下载面板文件
    log "${YELLOW}正在下载监控面板文件...${NC}"
    if wget -q $DASHBOARD_ZIP_URL -O $DASHBOARD_DIR/website.zip; then
        log "${GREEN}监控面板下载成功${NC}"
    else
        log "${RED}监控面板下载失败${NC}"
        return 1
    fi
    
    # 解压文件
    unzip -q -o $DASHBOARD_DIR/website.zip -d $DASHBOARD_DIR
    rm -f $DASHBOARD_DIR/website.zip
    
    # 设置权限
    chmod +x $DASHBOARD_DIR/dashboard.sh
    
    # 创建日志轮转配置
    cat > /etc/logrotate.d/gemini_access <<EOF
/var/log/nginx/gemini_access.log {
    daily
    rotate 1
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        /usr/sbin/nginx -s reopen >/dev/null 2>&1
    endscript
}
EOF
    
    # 创建systemd服务
    cat > /etc/systemd/system/gemini-dashboard.service <<EOL
[Unit]
Description=Gemini Proxy Dashboard
After=network.target

[Service]
User=root
WorkingDirectory=$DASHBOARD_DIR
ExecStart=$DASHBOARD_DIR/dashboard.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

    # 启用并启动服务
    systemctl daemon-reload
    systemctl enable gemini-dashboard
    systemctl start gemini-dashboard
    
    # 获取公网IP
    public_ip=$(curl -s ifconfig.me)
    
    log "${GREEN}监控面板已安装并启动!${NC}"
    log "${YELLOW}访问地址: http://${public_ip}:$DASHBOARD_PORT${NC}"
    log "${YELLOW}服务状态: systemctl status gemini-dashboard${NC}"
}

# 启动监控面板
start_dashboard() {
    if [ ! -f /etc/systemd/system/gemini-dashboard.service ]; then
        install_dashboard
    else
        systemctl start gemini-dashboard
        log "${GREEN}监控面板已启动${NC}"
        public_ip=$(curl -s ifconfig.me)
        log "${YELLOW}访问地址: http://${public_ip}:$DASHBOARD_PORT${NC}"
    fi
}

# 停止监控面板
stop_dashboard() {
    systemctl stop gemini-dashboard
    log "${YELLOW}监控面板已停止${NC}"
}

# 重启监控面板
restart_dashboard() {
    systemctl restart gemini-dashboard
    log "${GREEN}监控面板已重启${NC}"
}

# 卸载监控面板
uninstall_dashboard() {
    systemctl stop gemini-dashboard
    systemctl disable gemini-dashboard
    rm -f /etc/systemd/system/gemini-dashboard.service
    rm -rf $DASHBOARD_DIR
    rm -f /etc/logrotate.d/gemini_access
    systemctl daemon-reload
    log "${GREEN}监控面板已卸载${NC}"
}

# 显示菜单
show_menu() {
    clear
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}    Gemini API 反代管理脚本 v$VERSION${NC}"
    echo -e "${RED}    作者：Cnfte${NC}"
    echo -e "${BLUE}    项目地址：http://github.com/Cnfte/geminiproxy${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo -e "1. 安装反代"
    echo -e "2. 重启反代"
    echo -e "3. 卸载反代"
    echo -e "4. 停止Nginx程序"
    echo -e "5. 完全删除所有依赖和Nginx及相关目录文件"
    echo -e "${PURPLE}6. 安装监控面板${NC}"
    echo -e "${PURPLE}7. 启动监控面板${NC}"
    echo -e "${PURPLE}8. 停止监控面板${NC}"
    echo -e "${PURPLE}9. 重启监控面板${NC}"
    echo -e "${PURPLE}10. 卸载监控面板${NC}"
    echo -e "11. 备份当前配置"
    echo -e "12. 恢复配置"
    echo -e "13. 检查服务状态"
    echo -e "14. 更新SSL证书"
    echo -e "15. 监控代理状态"
    echo -e "16. 查看日志"
    echo -e "0. 退出"
    echo -e "${GREEN}=====================================${NC}"
    read -p "请输入选项 [0-16]: " option
}

# 主函数
main() {
    check_root
    detect_os
    
    # 创建日志目录
    mkdir -p $(dirname $LOG_FILE)
    touch $LOG_FILE
    
    while true; do
        show_menu
        case $option in
            1)
                configure_nginx
                configure_firewall
                start_nginx
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
                install_dashboard
                ;;
            7)
                start_dashboard
                ;;
            8)
                stop_dashboard
                ;;
            9)
                restart_dashboard
                ;;
            10)
                uninstall_dashboard
                ;;
            11)
                backup_config
                ;;
            12)
                restore_config
                ;;
            13)
                check_status
                ;;
            14)
                renew_cert
                ;;
            15)
                monitor_proxy
                ;;
            16)
                view_logs
                ;;
            0)
                log "${GREEN}退出脚本${NC}"
                exit 0
                ;;
            *)
                log "${RED}无效选项，请重新输入${NC}"
                ;;
        esac
        read -p "按Enter键继续..."
    done
}

main