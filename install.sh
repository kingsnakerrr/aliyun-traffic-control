#!/bin/bash
set -e

echo "=================================================="
echo "🚀 开始安装 阿里云 CDT 双版本流控断网保活系统..."
echo "=================================================="

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

WORKDIR="/root/aliyun-cdt-traffic-control"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "📦 正在检查系统依赖..."
if [ -f /etc/debian_version ]; then
    apt-get update && apt-get install python3-venv python3-pip curl -y
elif [ -f /etc/redhat-release ]; then
    yum install python3 python3-pip curl -y
fi

RAW_URL="https://raw.githubusercontent.com/kingsnakerrr/aliyun-traffic-control/refs/heads/main"

echo "📥 正在从 GitHub 下载最新程序..."
curl -sSL "$RAW_URL/traffic_control.py" -o traffic_control.py
curl -sSL "$RAW_URL/traffic-control.service" -o /etc/systemd/system/traffic-control.service

sed -i "s|/root/aliyun-traffic-control|$WORKDIR|g" /etc/systemd/system/traffic-control.service

echo "⚙️ 正在创建 Python 虚拟环境并安装双版本完整依赖..."
python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install aliyun-python-sdk-core aliyun-python-sdk-ecs aliyun-python-sdk-bssopenapi requests python-telegram-bot==13.15

echo ""
echo "=================================================="
echo "✏️  请配置你的主程序关键参数！"
echo "=================================================="
read -p "请输入你的 阿里云 ACCESS_KEY_ID: " AK_ID
read -p "请输入你的 阿里云 ACCESS_KEY_SECRET: " AK_SECRET
read -p "请输入你要控制的 阿里云实例ID (如 i-j6cxxxxxx): " INST_ID
read -p "请输入该实例所在的 地域ID (默认: cn-hongkong): " REG_ID
REG_ID=${REG_ID:-cn-hongkong} # 如果直接敲回车，则默认使用 cn-hongkong
read -p "请输入你的 Telegram BOT_TOKEN: " TG_TOKEN
read -p "请输入你的 Telegram CHAT_ID (频道/群组ID): " TG_ID

# ✨ 完美注入所有 6 个核心控制参数与开关
sed -i "s/ACCESS_KEY_ID = .*/ACCESS_KEY_ID = '$AK_ID'/g" traffic_control.py
sed -i "s/ACCESS_KEY_SECRET = .*/ACCESS_KEY_SECRET = '$AK_SECRET'/g" traffic_control.py
sed -i "s/INSTANCE_ID = .*/INSTANCE_ID = '$INST_ID'/g" traffic_control.py
sed -i "s/REGION_ID = .*/REGION_ID = '$REG_ID'/g" traffic_control.py
sed -i "s/TELEGRAM_BOT_TOKEN = .*/TELEGRAM_BOT_TOKEN = '$TG_TOKEN'/g" traffic_control.py
sed -i "s/TELEGRAM_CHAT_ID = .*/TELEGRAM_CHAT_ID = '$TG_ID'/g" traffic_control.py
sed -i "s/BILL_REG_ID = .*/BILL_REG_ID = '$ENDPOINT_REG'/g" traffic_control.py
sed -i "s/IS_INTERNATIONAL = .*/IS_INTERNATIONAL = $SET_INTERNATIONAL/g" traffic_control.py

echo "✅ 参数配置成功！"

echo "🤖 正在启动 Telegram 机器人常驻后台服务..."
systemctl daemon-reload
systemctl enable traffic-control.service
systemctl restart traffic-control.service

echo "⏱️  正在配置 Crontab 每分钟静默保活与流量熔断检查..."
CRON_CMD="* * * * * $WORKDIR/venv/bin/python $WORKDIR/traffic_control.py --cron >> $WORKDIR/cron_run.log 2>&1"
(crontab -l 2>/dev/null | grep -Fv "traffic_control.py"; echo "$CRON_CMD") | crontab -

echo "=================================================="
echo "🎉 阿里云 CDT 系统终极全参版配置升级完成！"
echo "🛡️  180G流量硬熔断保护已开启。"
echo "📊 运行此命令查看实时流控日志: tail -f $WORKDIR/cron_run.log"
echo "=================================================="
