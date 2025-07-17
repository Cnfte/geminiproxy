#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color
echo 建议在新系统安装以免造成冲突
echo 本项目开源在github进入博客看更多有用的脚本
# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}非root用户运行请sudo bash proxy.sh或sudo su && bash proxy.sh${NC}"
        exit 1
    fi
}

# 检测系统发行版
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    elif [ -f /etc/arch-release ]; then
        OS="arch"
    else
        echo -e "${RED}无法检测当前操作系统请更换至Ubuntu、Debian、CentOS、ArchLinux等发行linux再试${NC}"
        exit 1
    fi
}

# 安装依赖
install_dependencies() {
    echo -e "${GREEN}正在安装依赖...${NC}"
    case $OS in
        ubuntu|debian)
            apt update
            apt install -y nginx openssl curl
            ;;
        centos|rhel|fedora)
            yum install -y epel-release
            yum install -y nginx openssl curl
            ;;
        arch)
            pacman -Sy --noconfirm nginx openssl curl
            ;;
        *)
            echo -e "${RED}不支持的操作系统: $OS${NC}"
            exit 1
            ;;
    esac
}

# 配置Nginx
configure_nginx() {
    read -p "请输入您的域名(后续需要A记录或AAAA记录到您主机的公网ip): " domain
    read -p "请输入SSL证书路径，格式.pem后缀(绝对路径，例：/root/a.pem): " cert_path
    read -p "请输入SSL证书密钥路，格式.key后缀(绝对路径，例：/root/a.key): " key_path

    # 创建配置文件
    cat > /etc/nginx/conf.d/chat.conf <<EOF
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
        echo -e "${GREEN}Nginx配置测试成功${NC}"
    else
        echo -e "${RED}Nginx配置测试失败，请检查配置${NC}"
        exit 1
    fi
}

# 启动Nginx
start_nginx() {
    case $OS in
        ubuntu|debian)
            systemctl enable nginx
            systemctl start nginx
            ;;
        centos|rhel|fedora)
            systemctl enable nginx
            systemctl start nginx
            ;;
        arch)
            systemctl enable nginx
            systemctl start nginx
            ;;
    esac
    echo -e "${GREEN}Nginx已启动${NC}"
}

# 重启Nginx
restart_nginx() {
    systemctl restart nginx
    echo -e "${GREEN}Nginx已重启${NC}"
}

# 停止Nginx
stop_nginx() {
    systemctl stop nginx
    echo -e "${YELLOW}Nginx已停止${NC}"
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
    echo -e "${GREEN}Nginx已卸载${NC}"
}

# 完全删除所有相关文件和配置
full_remove() {
    uninstall_nginx
    rm -rf /etc/nginx
    rm -rf /var/log/nginx
    rm -rf /var/cache/nginx
    echo -e "${GREEN}所有Nginx相关文件和配置已删除${NC}"
}

# 显示菜单
show_menu() {
    clear
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}    Gemini API 反代管理脚本${NC}"
    echo -e "${GREEN}    作者：CNFTE${NC}"
    echo -e "${GREEN}    博客地址：http://cnfte.top/${NC}"
    echo -e "${GREEN}    本项目地址：https://github.com/Cnfte/geminiproxy${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo -e "1. 安装反向代理"
    echo -e "2. 重启反向代理"
    echo -e "3. 卸载反向代理"
    echo -e "4. 停止Nginx程序"
    echo -e "5. 完全删除所有依赖和Nginx及相关目录文件"
    echo -e "0. 退出"
    echo -e "${GREEN}=====================================${NC}"
    read -p "请输入选项 [0-5]: " option
}

# 主函数
main() {
    check_root
    detect_os
    
    while true; do
        show_menu
        case $option in
            1)
                install_dependencies
                configure_nginx
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
            0)
                echo -e "${GREEN}退出脚本${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入${NC}"
                ;;
        esac
        read -p "按Enter(回车)键继续..."
    done
}

main