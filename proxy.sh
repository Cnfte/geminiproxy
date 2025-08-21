#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 版本信息
VERSION="1.2.0"
CONFIG_FILE="/etc/gemini_proxy.conf"
BACKUP_DIR="/var/backups/gemini_proxy"
LOG_FILE="/var/log/gemini_proxy.log"

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
    log "${GREEN}正在安装依赖...${NC}"
    case $OS in
        ubuntu|debian)
            apt update
            apt install -y nginx openssl curl jq bc socat
            ;;
        centos|rhel|fedora)
            yum install -y epel-release
            yum install -y nginx openssl curl jq bc socat
            ;;
        arch)
            pacman -Sy --noconfirm nginx openssl curl jq bc socat
            ;;
        *)
            log "${RED}不支持的操作系统: $OS${NC}"
            exit 1
            ;;
    esac
}

# 自动申请 SSL 证书
auto_ssl() {
    read -p "是否自动申请SSL证书？(y/n): " auto_ssl_choice
    if [[ "$auto_ssl_choice" == "y" || "$auto_ssl_choice" == "Y" ]]; then
        echo "请选择证书申请方式："
        echo "1. 使用 certbot (推荐, 80端口可用时)"
        echo "2. 使用 acme.sh (推荐NAT/非80端口环境)"
        read -p "输入选项 [1-2]: " ssl_method

        case $ssl_method in
            1)
                if ! command -v certbot >/dev/null 2>&1; then
                    log "${YELLOW}未检测到 certbot，正在安装...${NC}"
                    case $OS in
                        ubuntu|debian)
                            apt install -y certbot python3-certbot-nginx ;;
                        centos|rhel|fedora)
                            yum install -y certbot python3-certbot-nginx ;;
                        arch)
                            pacman -Sy --noconfirm certbot ;;
                    esac
                fi
                certbot certonly --standalone -d "$domain" --agree-tos -m admin@$domain --non-interactive
                cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
                key_path="/etc/letsencrypt/live/$domain/privkey.pem"
                ;;
            2)
                if ! command -v acme.sh >/dev/null 2>&1; then
                    log "${YELLOW}未检测到 acme.sh，正在安装...${NC}"
                    curl https://get.acme.sh | sh
                    source ~/.bashrc
                fi
                ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --server letsencrypt
                cert_path="/root/.acme.sh/$domain/fullchain.cer"
                key_path="/root/.acme.sh/$domain/$domain.key"
                ;;
            *)
                log "${RED}无效选项，跳过自动申请${NC}"
                ;;
        esac
    fi
}

# 配置Nginx
configure_nginx() {
    read -p "请输入您的域名: " domain
    read -p "请输入绑定的本地IP (默认0.0.0.0): " bind_ip
    bind_ip=${bind_ip:-0.0.0.0}
    read -p "请输入HTTP端口 (默认80): " http_port
    http_port=${http_port:-80}
    read -p "请输入HTTPS端口 (默认443): " https_port
    https_port=${https_port:-443}
    read -p "请输入SSL证书路径(留空自动申请): " cert_path
    read -p "请输入SSL证书密钥路径(留空自动申请): " key_path

    if [ -z "$cert_path" ] || [ -z "$key_path" ]; then
        auto_ssl
    fi

    # 验证证书文件是否存在
    if [ ! -f "$cert_path" ] || [ ! -f "$key_path" ]; then
        log "${RED}证书文件不存在或未申请成功，请检查${NC}"
        return 1
    fi

    # 保存配置
    echo "DOMAIN=$domain" > $CONFIG_FILE
    echo "CERT_PATH=$cert_path" >> $CONFIG_FILE
    echo "KEY_PATH=$key_path" >> $CONFIG_FILE
    echo "BIND_IP=$bind_ip" >> $CONFIG_FILE
    echo "HTTP_PORT=$http_port" >> $CONFIG_FILE
    echo "HTTPS_PORT=$https_port" >> $CONFIG_FILE

    # 创建Nginx配置
    cat > /etc/nginx/conf.d/chat.conf <<EOF
server {
    listen $bind_ip:$http_port;
    server_name $domain;
    return 301 https://\$host:$https_port\$request_uri;
}

server {
    listen $bind_ip:$https_port ssl;
    server_name $domain;
    ssl_certificate $cert_path;
    ssl_certificate_key $key_path;
    ssl_session_cache shared:le_nginx_SSL:1m;
    ssl_session_timeout 1440m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

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

    # 测试Nginx配置
    nginx -t
    if [ $? -eq 0 ]; then
        log "${GREEN}Nginx配置测试成功${NC}"
        return 0
    else
        log "${RED}Nginx配置测试失败，请检查配置${NC}"
        return 1
    fi
}

# ============================
# 其余部分保持不变 (start/stop/backup/restore/menu 等)
# ============================

# 启动Nginx
start_nginx() {
    systemctl enable nginx
    systemctl start nginx
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
        ubuntu|debian) apt remove --purge -y nginx && apt autoremove -y ;;
        centos|rhel|fedora) yum remove -y nginx ;;
        arch) pacman -R --noconfirm nginx ;;
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
    rm -f $CONFIG_FILE
    rm -rf $BACKUP_DIR
    log "${GREEN}所有Nginx相关文件和配置已删除${NC}"
}

# 备份配置
backup_config() {
    if [ ! -f $CONFIG_FILE ]; then
        log "${RED}未找到配置文件，请先安装反代${NC}"
        return
    fi
    mkdir -p $BACKUP_DIR
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    tar -czf "$BACKUP_DIR/gemini_proxy_$TIMESTAMP.tar.gz" /etc/nginx/conf.d/chat.conf $CONFIG_FILE 2>/dev/null
    log "${GREEN}配置已备份到 $BACKUP_DIR/gemini_proxy_$TIMESTAMP.tar.gz${NC}"
}

# 恢复配置
restore_config() {
    echo "可用的备份文件:"
    ls -l $BACKUP_DIR/*.tar.gz 2>/dev/null | awk '{print $9}'
    if [ -z "$(ls -A $BACKUP_DIR/*.tar.gz 2>/dev/null)" ]; then
        log "${RED}没有找到备份文件${NC}"
        return
    fi
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
    echo -e "${CYAN}=== 服务状态 ===${NC}"
    echo -e "Nginx: $nginx_status"
    if [ -f $CONFIG_FILE ]; then
        source $CONFIG_FILE
        echo -e "\n${CYAN}=== 当前配置 ===${NC}"
        echo -e "域名: $DOMAIN"
        echo -e "绑定IP: $BIND_IP"
        echo -e "HTTP端口: $HTTP_PORT"
        echo -e "HTTPS端口: $HTTPS_PORT"
        echo -e "证书路径: $CERT_PATH"
        echo -e "密钥路径: $KEY_PATH"
    fi
}

# 菜单
show_menu() {
    clear
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN} Gemini API 反代管理脚本 v$VERSION ${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo -e "1. 安装反代"
    echo -e "2. 重启反代"
    echo -e "3. 卸载反代"
    echo -e "4. 停止Nginx程序"
    echo -e "5. 完全删除所有依赖和配置"
    echo -e "6. 备份当前配置"
    echo -e "7. 恢复配置"
    echo -e "8. 检查服务状态"
    echo -e "0. 退出"
    echo -e "${GREEN}=====================================${NC}"
    read -p "请输入选项 [0-8]: " option
}

main() {
    check_root
    detect_os
    mkdir -p $(dirname $LOG_FILE)
    touch $LOG_FILE

    while true; do
        show_menu
        case $option in
            1) install_dependencies; if configure_nginx; then start_nginx; fi ;;
            2) restart_nginx ;;
            3) uninstall_nginx ;;
            4) stop_nginx ;;
            5) full_remove ;;
            6) backup_config ;;
            7) restore_config ;;
            8) check_status ;;
            0) log "${GREEN}退出脚本${NC}"; exit 0 ;;
            *) log "${RED}无效选项，请重新输入${NC}" ;;
        esac
        read -p "按Enter键继续..."
    done
}

main
