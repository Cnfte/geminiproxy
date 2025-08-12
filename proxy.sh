#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 版本信息
VERSION="1.1.0"
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
            apt install -y nginx openssl curl jq bc
            ;;
        centos|rhel|fedora)
            yum install -y epel-release
            yum install -y nginx openssl curl jq bc
            ;;
        arch)
            pacman -Sy --noconfirm nginx openssl curl jq bc
            ;;
        *)
            log "${RED}不支持的操作系统: $OS${NC}"
            exit 1
            ;;
    esac
}
# 配置Nginx
configure_nginx() {
    read -p "请输入您的域名: " domain
    read -p "请输入SSL证书路径(全路径.pem): " cert_path
    read -p "请输入SSL证书密钥路径(全路径.key): " key_path

    # 验证证书文件是否存在
    if [ ! -f "$cert_path" ] || [ ! -f "$key_path" ]; then
        log "${RED}证书文件不存在，请检查路径${NC}"
        return 1
    fi

    # 保存配置
    echo "DOMAIN=$domain" > $CONFIG_FILE
    echo "CERT_PATH=$cert_path" >> $CONFIG_FILE
    echo "KEY_PATH=$key_path" >> $CONFIG_FILE

    # 创建配置文件
    cat > /etc/nginx/conf.d/chat.conf <<EOF
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $domain;
    ssl_certificate $cert_path;
    ssl_certificate_key $key_path;
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
            apt autoremove -y
            ;;
        centos|rhel|fedora)
            yum remove -y nginx
            ;;
        arch)
            pacman -R --noconfirm nginx
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
        echo -e "证书路径: $CERT_PATH"
        echo -e "密钥路径: $KEY_PATH"
        
        # 检查证书过期时间
        if [ -f "$CERT_PATH" ]; then
            cert_expiry=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2)
            if [ -n "$cert_expiry" ]; then
                echo -e "证书过期时间: $cert_expiry"
            else
                echo -e "证书过期时间: ${RED}无法获取${NC}"
            fi
        else
            echo -e "证书过期时间: ${RED}证书文件不存在${NC}"
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
        response=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN/v1/models" -H "Content-Type: application/json" --connect-timeout 5)
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        
        if [ -z "$response" ]; then
            response="无响应"
        fi
        
        if [ "$response" -eq 200 ] 2>/dev/null; then
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
        1) 
            echo -e "${CYAN}=== Nginx访问日志 ===${NC}"
            tail -f /var/log/nginx/gemini_access.log 
            ;;
        2) 
            echo -e "${CYAN}=== Nginx错误日志 ===${NC}"
            tail -f /var/log/nginx/gemini_error.log 
            ;;
        3) 
            echo -e "${CYAN}=== 脚本日志 ===${NC}"
            tail -f $LOG_FILE 
            ;;
        4) 
            echo -e "${CYAN}=== 全部日志 (按Ctrl+C停止) ===${NC}"
            multitail -s 3 /var/log/nginx/gemini_access.log /var/log/nginx/gemini_error.log $LOG_FILE
            ;;
        *) 
            log "${RED}无效选项${NC}" 
            ;;
    esac
}

# 显示菜单
show_menu() {
    clear
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}    Gemini API 反代管理脚本 v$VERSION${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo -e "1. 安装反代"
    echo -e "2. 重启反代"
    echo -e "3. 卸载反代"
    echo -e "4. 停止Nginx程序"
    echo -e "5. 完全删除所有依赖和Nginx及相关目录文件"
    echo -e "6. 备份当前配置"
    echo -e "7. 恢复配置"
    echo -e "8. 检查服务状态"
    echo -e "9. 监控代理状态"
    echo -e "10. 查看日志"
    echo -e "0. 退出"
    echo -e "${GREEN}=====================================${NC}"
    read -p "请输入选项 [0-10]: " option
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
                install_dependencies
                configure_firewall
                if configure_nginx; then
                    start_nginx
                fi
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
                monitor_proxy
                ;;
            10)
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
