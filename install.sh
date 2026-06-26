#!/bin/bash

# 确保脚本遇到错误立刻停止
set -e

echo "=================================================="
echo "🚀 开始安装 阿里云 CDT 实例保活与断网保护系统..."
echo "=================================================="

# ==================================================
# 🌐 核心选择：国内版 VS 国际版
# ==================================================
echo "💡 请选择您的阿里云账户版本："
echo "  1) 阿里云国内版 (Aliyun.com - 账户显示人民币余额)"
echo "  2) 阿里云国际版 (Alibabacloud.com - 绑定信用卡后付费/美元结算)"
read -p "请输入数字 [1-2]: " ALIYUN_VERSION

if [ "$ALIYUN_VERSION" = "2" ]; then
    echo "✅ 已选择：阿里云国际版"
    ENDPOINT_REG="ap-southeast-1"
    SET_INTERNATIONAL="True"
else
    echo "✅ 已选择：阿里云国内版"
    ENDPOINT_REG="cn-hangzhou"
    SET_INTERNATIONAL="False"
fi
echo "=================================================="

# 1. 创建全新的规范化工作目录并进入
WORKDIR="/root/aliyun-cdt-traffic-control"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# 2. 检查并安装系统依赖
echo "📦 正在检查系统依赖..."
if [ -f /etc/debian_version ]; then
    apt-get update && apt-get install python3-venv python3-pip curl -y
elif [ -f /etc/redhat-release ]; then
    yum install python3 python3-pip curl -y
fi

# 3. 从 GitHub 下载你最新的核心文件
RAW_URL="https://raw.githubusercontent.com/kingsnakerrr/aliyun-traffic-control/refs/heads/main"

echo "📥 正在从 GitHub 下载最新程序..."
curl -sSL "$RAW_URL/traffic_control.py" -o traffic_control.py
curl -sSL "$RAW_URL/traffic-control.service" -o /etc/systemd/system/traffic-control.service

# 4. ⚡ 自动修正：Service 文件路径动态替换
sed -i "s|/root/aliyun-traffic-control|$WORKDIR|g" /etc/systemd/system/traffic-control.service

# 5. 创建 Python 虚拟环境并安装阿里云 SDK
echo "⚙️ 正在创建 Python 虚拟环境并安装阿里云 SDK..."
python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install aliyun-python-sdk-core aliyun-python-sdk-ecs aliyun-python-sdk-bssopenapi requests

# ==================================================
# 🎯 第二步：配置主程序参数（动态交互输入）
# ==================================================
echo ""
echo "=================================================="
echo "✏️  请配置你的主程序关键参数！"
echo "=================================================="
read -p "请输入你的 阿里云 ACCESS_KEY_ID: " AK_ID
read -p "请输入你的 阿里云 ACCESS_KEY_SECRET: " AK_SECRET
read -p "请输入你的 Telegram BOT_TOKEN: " TG_TOKEN
read -p "请输入你的 Telegram CHAT_ID (频道/群组ID): " TG_ID

# 动态将变量与版本开关写入 Python 脚本
sed -i "s/ACCESS_KEY_ID = .*/ACCESS_KEY_ID = '$AK_ID'/g" traffic_control.py
sed -i "s/ACCESS_KEY_SECRET = .*/ACCESS_KEY_SECRET = '$AK_SECRET'/g" traffic_control.py
sed -i "s/TELEGRAM_BOT_TOKEN = .*/TELEGRAM_BOT_TOKEN = '$TG_TOKEN'/g" traffic_control.py
sed -i "s/TELEGRAM_CHAT_ID = .*/TELEGRAM_CHAT_ID = '$TG_ID'/g" traffic_control.py
sed -i "s/REG_ID = .*/REG_ID = '$ENDPOINT_REG'/g" traffic_control.py
sed -i "s/IS_INTERNATIONAL = .*/IS_INTERNATIONAL = $SET_INTERNATIONAL/g" traffic_control.py

echo "✅ 参数配置与双版本完美适配成功！"

# 6. 配置 Systemd 服务并开机自启
echo "🤖 正在启动 Telegram 机器人常驻后台服务..."
systemctl daemon-reload
systemctl enable traffic-control.service
systemctl restart traffic-control.service

# 7. 配置 Crontab 每分钟定时轮询熔断机制
echo "⏱️  正在配置 Crontab 每分钟静默保活与流量熔断检查..."
CRON_CMD="* * * * * $WORKDIR/venv/bin/python $WORKDIR/traffic_control.py --cron >> $WORKDIR/cron_run.log 2>&1"
(crontab -l 2>/dev/null | grep -Fv "traffic_control.py"; echo "$CRON_CMD") | crontab -

echo "=================================================="
echo "🎉 阿里云 CDT 双版本自适应流控断网系统安装完成！"
echo "🤖 TG 机器人已在后台常驻监听"
echo "🛡️ 180G流量熔断与实例状态已挂载至 Crontab 每分钟轮询"
echo "📊 运行此命令查看实时流控日志: tail -f $WORKDIR/cron_run.log"
echo "=================================================="
