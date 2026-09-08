#!/bin/bash

# =========================================================
# Cloudflare DDNS 一键安装脚本
# 功能：自动部署 Cloudflare DDNS 定时更新
# 适配：Debian / Ubuntu
# 快捷指令：安装后自动运行，每5分钟检查一次
# 一键安装命令：
# bash <(curl -Ls https://raw.githubusercontent.com/mimicatcn/ddns/main/install.sh)
# =========================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN} Cloudflare DDNS 全自动部署 (架构级) ${NC}"
echo -e "${GREEN}======================================${NC}"

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 root 用户运行此脚本！${NC}"
  exit 1
fi

# 检查并安装依赖
if ! command -v curl &> /dev/null || ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}检测到缺少依赖，正在尝试安装...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update -y && apt-get install curl jq -y
    elif command -v yum &> /dev/null; then
        yum install curl jq -y
    else
        echo -e "${RED}无法自动安装依赖，请手动安装 curl 和 jq 后重试！${NC}"
        exit 1
    fi
fi

echo -e "\n${RED}注意：运行前，请确保你已经在 CF 网页上手动添加了这条 A 记录！(随便填个IP即可)${NC}\n"

# 收集用户输入
read -p "1. 请输入 API Token: " CF_TOKEN
read -p "2. 请输入 Zone ID: " CF_ZONE_ID
read -p "3. 请输入你的解析域名 (例如 xx.xxxx.com): " DOMAIN
read -p "4. 是否开启 Cloudflare 代理(小黄云)? (输入 y 开启，其他任意键为仅DNS解析): " PROXIED_INPUT

if [ "$PROXIED_INPUT" == "y" ] || [ "$PROXIED_INPUT" == "Y" ]; then
    PROXIED="true"
    echo -e "${YELLOW}  ⚠️ 警告: 已开启小黄云代理！如果小火箭使用非标端口(非80/443等)，流量将被CF拦截导致无法连接！${NC}"
else
    PROXIED="false"
fi

if [ -z "$CF_TOKEN" ] || [ -z "$CF_ZONE_ID" ] || [ -z "$DOMAIN" ]; then
    echo -e "${RED}错误：Token、Zone ID 和域名都不能为空！${NC}"
    exit 1
fi

# ================= 自动获取 Record ID =================
echo -e "\n${YELLOW}正在通过 API 自动查询 $DOMAIN 的 Record ID...${NC}"

API_RESPONSE=$(curl -s --max-time 10 -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$DOMAIN" \
     -H "Authorization: Bearer $CF_TOKEN" \
     -H "Content-Type: application/json")

if echo "$API_RESPONSE" | jq -e '.success' > /dev/null 2>&1; then
    CF_RECORD_ID=$(echo "$API_RESPONSE" | jq -r '.result[0].id')
    
    if [ -z "$CF_RECORD_ID" ] || [ "$CF_RECORD_ID" == "null" ]; then
        echo -e "${RED}查询失败：找不到域名 $DOMAIN 的记录！${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ 成功获取到 Record ID: $CF_RECORD_ID${NC}"
else
    ERROR_MSG=$(echo "$API_RESPONSE" | jq -r '.errors[0].message')
    echo -e "${RED}API 调用失败！错误信息: $ERROR_MSG${NC}"
    exit 1
fi
# =======================================================

echo -e "${YELLOW}正在生成配置文件...${NC}"
# 1. 配置与逻辑分离，不再用 sed 替换代码，避免特殊字符破坏脚本
cat << EOF > /root/.ddns_config.env
CF_TOKEN="$CF_TOKEN"
CF_ZONE_ID="$CF_ZONE_ID"
CF_RECORD_ID="$CF_RECORD_ID"
DOMAIN="$DOMAIN"
PROXIED="$PROXIED"
EOF
chmod 600 /root/.ddns_config.env

echo -e "${YELLOW}正在生成核心守护脚本...${NC}"

# 生成核心 DDNS 脚本 (绝对不再修改此文件内容)
cat << 'EOF' > /root/ddns_daemon.sh
#!/bin/bash

# 确保在 cron 环境下能找到依赖命令的绝对路径
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 加载外部配置
CONFIG_FILE="/root/.ddns_config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 严重错误: 配置文件 $CONFIG_FILE 不存在！"
    exit 1
fi
source "$CONFIG_FILE"

IP_FILE="/root/.current_ip.txt"
LOCK_FILE="/tmp/ddns_daemon.lock"

# 2. 并发锁机制：防止上一次任务卡死导致多进程同时修改 DNS
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 跳过: 上一次任务尚未执行完毕"
    exit 0
fi

# 多重备用获取公网 IP
fetch_ip() {
    local urls=(
        "https://4.ipw.cn"
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://ifconfig.me"
    )
    for url in "${urls[@]}"; do
        # 优化: 使用 tr 移除所有空白字符(包含\r\n)，再提取 IP，避免隐藏换行符导致匹配失败
        local ip=$(curl -4 -s --connect-timeout 5 --max-time 8 "$url" | tr -d '[:space:]' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

NEW_IP=$(fetch_ip)

# IP 格式校验
if [[ ! "$NEW_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 失败: 获取公网IP失败或格式错误 (获取到: $NEW_IP)"
    exit 1
fi

OLD_IP=$(cat "$IP_FILE" 2>/dev/null)

# IP 未变化直接退出
if [ "$NEW_IP" = "$OLD_IP" ]; then
    exit 0
fi

# 更新 DNS 记录
RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
     -H "Authorization: Bearer $CF_TOKEN" \
     -H "Content-Type: application/json" \
     --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$NEW_IP\",\"ttl\":1,\"proxied\":$PROXIED}")

# 严谨的 JSON 状态判断
if echo "$RESPONSE" | jq -e '.success' > /dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 成功: ${OLD_IP:-无} -> $NEW_IP"
    echo "$NEW_IP" > "$IP_FILE"
else
    ERROR_MSG=$(echo "$RESPONSE" | jq -r '.errors[0].message' 2>/dev/null)
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 失败: API返回错误 - ${ERROR_MSG:-未知错误}"
    echo "  > 原始返回: $RESPONSE"
fi
EOF

chmod 700 /root/ddns_daemon.sh

echo -e "${YELLOW}正在设置定时任务...${NC}"
# 优化日志轮转
(crontab -l 2>/dev/null | grep -v "ddns_daemon"; echo "*/5 * * * * /bin/bash /root/ddns_daemon.sh >> /root/ddns.log 2>&1"; echo "0 3 * * * tail -n 1000 /root/ddns.log > /tmp/ddns_tmp && mv /tmp/ddns_tmp /root/ddns.log") | crontab -

echo -e "${YELLOW}正在执行首次同步...${NC}"
FIRST_RUN_LOG=$(/bin/bash /root/ddns_daemon.sh 2>&1)
echo "$FIRST_RUN_LOG" | tee -a /root/ddns.log

if echo "$FIRST_RUN_LOG" | grep -q "成功"; then
    CURRENT_IP=$(cat /root/.current_ip.txt 2>/dev/null)
    echo -e "\n${GREEN}======================================${NC}"
    echo -e "${GREEN}       🎉 部署大成功！架构已升级！      ${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo -e "当前解析IP: ${GREEN}${CURRENT_IP}${NC}"
    echo -e "配置文件:   ${GREEN}/root/.ddns_config.env${NC}"
    echo -e "守护脚本:   ${GREEN}/root/ddns_daemon.sh${NC}"
    echo -e "\n后续说明："
    echo -e "1. 脚本已后台静默运行，每 5 分钟自动检查并换IP。"
    echo -e "2. 查看日志输入: ${YELLOW}cat /root/ddns.log${NC}"
else
    echo -e "\n${RED}首次运行失败，请查看上方或日志文件中的报错信息。${NC}"
fi
