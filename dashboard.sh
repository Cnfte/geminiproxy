#!/bin/bash

DASHBOARD_DIR="/opt/gemini_dashboard"
DASHBOARD_DATA="$DASHBOARD_DIR/data"
LOG_FILE="/var/log/nginx/gemini_access.log"

# 创建数据目录
mkdir -p $DASHBOARD_DATA

# 生成HTML文件
generate_html() {
    # 获取系统信息
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    mem_total=$(free -m | awk '/Mem:/ {print $2}')
    mem_used=$(free -m | awk '/Mem:/ {print $3}')
    mem_percent=$(awk "BEGIN {printf \"%.1f\", $mem_used/$mem_total*100}")
    disk_total=$(df -h / | awk 'NR==2 {print $2}')
    disk_used=$(df -h / | awk 'NR==2 {print $3}')
    disk_percent=$(df / | awk 'NR==2 {print $5}')
    
    # 获取网络信息
    public_ip=$(curl -s ifconfig.me)
    domain=$(grep "server_name" /etc/nginx/conf.d/chat.conf 2>/dev/null | awk '{print $2}' | tr -d ';' || echo "未配置")
    
    # 获取请求信息
    if [ -f $LOG_FILE ]; then
        # 总请求数
        total_requests=$(wc -l < $LOG_FILE)
        
        # 最近24小时访问IP
        recent_ips=$(awk -vDate="$(date -d '24 hours ago' +[%d/%b/%Y:%H:%M:%S)" '$4 > Date {print $1}' $LOG_FILE | sort | uniq -c | sort -nr | head -n 10)
        
        # 今日访问趋势 (每5分钟)
        access_data=$(awk -vDate="$(date -d '24 hours ago' +[%d/%b/%Y:%H:%M:%S)" '$4 > Date {print $4}' $LOG_FILE | 
            cut -d: -f1-2 | 
            sed 's/\[//; s/:/ /' | 
            awk '{
                hour = $2;
                min = $3;
                # 转换为5分钟间隔
                interval = int(min/5)*5;
                printf "%s:%02d\n", hour, interval
            }' | 
            sort | uniq -c)
    else
        total_requests="0"
        recent_ips="无访问日志"
        access_data=""
    fi
    
    # 生成HTML
    cat > $DASHBOARD_DIR/index.html <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="refresh" content="300">
    <title>Gemini 反代监控面板</title>
    <style>
        :root {
            --primary: #4361ee;
            --secondary: #3f37c9;
            --success: #4cc9f0;
            --danger: #f72585;
            --warning: #f8961e;
            --info: #4895ef;
            --light: #f8f9fa;
            --dark: #212529;
            --gray: #6c757d;
            --bg: #f5f7fb;
            --card-bg: #ffffff;
            --border: #e0e0e0;
        }
        
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
        }
        
        body {
            background-color: var(--bg);
            color: var(--dark);
            line-height: 1.6;
            padding: 20px;
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
        }
        
        header {
            text-align: center;
            margin-bottom: 30px;
            padding: 20px 0;
            border-bottom: 1px solid var(--border);
        }
        
        header h1 {
            color: var(--primary);
            margin-bottom: 10px;
        }
        
        .subtitle {
            color: var(--gray);
            font-size: 1.1rem;
        }
        
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        
        .card {
            background: var(--card-bg);
            border-radius: 12px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.05);
            padding: 25px;
            transition: transform 0.3s ease, box-shadow 0.3s ease;
        }
        
        .card:hover {
            transform: translateY(-5px);
            box-shadow: 0 8px 20px rgba(0,0,0,0.1);
        }
        
        .card h2 {
            font-size: 1.3rem;
            margin-bottom: 20px;
            color: var(--primary);
            padding-bottom: 10px;
            border-bottom: 2px solid var(--border);
        }
        
        .metric {
            font-size: 2.2rem;
            font-weight: 700;
            margin: 10px 0;
            color: var(--primary);
        }
        
        .metric-label {
            font-size: 0.9rem;
            color: var(--gray);
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        
        .metric-container {
            display: flex;
            justify-content: space-between;
            margin-bottom: 15px;
            padding-bottom: 15px;
            border-bottom: 1px solid var(--border);
        }
        
        .metric-item {
            text-align: center;
            flex: 1;
        }
        
        .progress-container {
            margin: 15px 0;
        }
        
        .progress-label {
            display: flex;
            justify-content: space-between;
            margin-bottom: 5px;
        }
        
        .progress-bar {
            height: 10px;
            background-color: #e9ecef;
            border-radius: 5px;
            overflow: hidden;
        }
        
        .progress-fill {
            height: 100%;
            background-color: var(--primary);
            border-radius: 5px;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 15px;
        }
        
        th, td {
            padding: 12px 15px;
            text-align: left;
            border-bottom: 1px solid var(--border);
        }
        
        th {
            background-color: #f8f9fa;
            font-weight: 600;
            color: var(--gray);
        }
        
        tr:hover {
            background-color: rgba(67, 97, 238, 0.03);
        }
        
        .log-panel {
            background: var(--card-bg);
            border-radius: 12px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.05);
            padding: 25px;
            margin-bottom: 30px;
        }
        
        .log-panel h2 {
            font-size: 1.3rem;
            margin-bottom: 15px;
            color: var(--primary);
            padding-bottom: 10px;
            border-bottom: 2px solid var(--border);
        }
        
        .log-content {
            height: 300px;
            overflow-y: auto;
            background: #1e1e1e;
            color: #d4d4d4;
            padding: 15px;
            border-radius: 8px;
            font-family: 'Courier New', monospace;
            font-size: 0.9rem;
            line-height: 1.5;
        }
        
        .log-entry {
            margin-bottom: 5px;
            padding: 3px 0;
            border-bottom: 1px solid #2d2d2d;
        }
        
        .log-entry:last-child {
            border-bottom: none;
        }
        
        .footer {
            text-align: center;
            padding: 20px 0;
            color: var(--gray);
            font-size: 0.9rem;
            border-top: 1px solid var(--border);
            margin-top: 20px;
        }
        
        @media (max-width: 768px) {
            .grid {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>Gemini API 反代监控面板</h1>
            <p class="subtitle">实时监控服务器状态与代理请求</p>
        </header>
        
        <div class="grid">
            <div class="card">
                <h2>系统状态</h2>
                <div class="metric-container">
                    <div class="metric-item">
                        <div class="metric">${cpu_usage}%</div>
                        <div class="metric-label">CPU 使用率</div>
                    </div>
                    <div class="metric-item">
                        <div class="metric">${mem_percent}%</div>
                        <div class="metric-label">内存使用率</div>
                    </div>
                    <div class="metric-item">
                        <div class="metric">${disk_percent}</div>
                        <div class="metric-label">磁盘使用率</div>
                    </div>
                </div>
                
                <div class="progress-container">
                    <div class="progress-label">
                        <span>内存: ${mem_used}M / ${mem_total}M</span>
                    </div>
                    <div class="progress-bar">
                        <div class="progress-fill" style="width: ${mem_percent}%"></div>
                    </div>
                </div>
                
                <div class="progress-container">
                    <div class="progress-label">
                        <span>磁盘: ${disk_used} / ${disk_total}</span>
                    </div>
                    <div class="progress-bar">
                        <div class="progress-fill" style="width: ${disk_percent%\%}%"></div>
                    </div>
                </div>
            </div>
            
            <div class="card">
                <h2>网络信息</h2>
                <div class="metric">${public_ip}</div>
                <div class="metric-label">服务器公网IP</div>
                
                <div class="metric">${domain}</div>
                <div class="metric-label">反代绑定域名</div>
                
                <div class="metric">443</div>
                <div class="metric-label">代理端口</div>
                
                <div class="metric">${DASHBOARD_PORT}</div>
                <div class="metric-label">监控面板端口</div>
            </div>
            
            <div class="card">
                <h2>请求统计</h2>
                <div class="metric">${total_requests}</div>
                <div class="metric-label">总请求次数</div>
                
                <table>
                    <thead>
                        <tr>
                            <th>次数</th>
                            <th>IP地址</th>
                        </tr>
                    </thead>
                    <tbody>
                        $(echo "$recent_ips" | awk '{print "<tr><td>"$1"</td><td>"$2"</td></tr>"}')
                    </tbody>
                </table>
            </div>
        </div>
        
        <div class="log-panel">
            <h2>最近访问日志 (24小时内)</h2>
            <div class="log-content">
                $(if [ -f "$LOG_FILE" ]; then
                    grep "$(date -d '24 hours ago' '+[%d/%b/%Y:%H:%M:%S')" "$LOG_FILE" | tail -n 50 | while read -r line; do
                        echo "<div class=\"log-entry\">$line</div>"
                    done
                else
                    echo "<div class=\"log-entry\">无访问日志</div>"
                fi)
            </div>
        </div>
        
        <div class="footer">
            <p>最后更新: $(date '+%Y-%m-%d %H:%M:%S') | 每5分钟自动刷新</p>
            <p>Gemini API 反代监控面板 v1.0</p>
        </div>
    </div>
</body>
</html>
EOF
}

# 主循环
while true; do
    generate_html
    sleep 5
done