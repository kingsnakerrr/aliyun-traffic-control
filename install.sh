#!/usr/bin/env bash
set -e

REPO_RAW="https://raw.githubusercontent.com/kingsnakerrr/aliyun-traffic-control/refs/heads/main"
BASE_DIR="/root/aliyun-traffic-control"
SERVICE_NAME="traffic-control.service"

[ "$(id -u)" -eq 0 ] || { echo "请使用 root 用户运行安装脚本"; exit 1; }

echo "======================================"
echo " 阿里云 CDT 流量控制一键安装"
echo "======================================"

read -r -p "状态报告账号显示名称，例如 zymsdf: " ACCOUNT_NAME
ACCOUNT_NAME=${ACCOUNT_NAME:-zymsdf}
read -r -p "阿里云 ACCESS_KEY_ID: " ACCESS_KEY_ID
read -r -p "阿里云 ACCESS_KEY_SECRET: " ACCESS_KEY_SECRET
read -r -p "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -r -p "Telegram 频道/群组 ID，例如 -100xxxx: " TELEGRAM_CHAT_ID
read -r -p "Telegram 管理员私聊 ID: " ADMIN_USER_ID
read -r -p "ECS 实例 ID: " INSTANCE_ID
read -r -p "ECS 区域，默认 cn-hongkong: " REGION_ID
REGION_ID=${REGION_ID:-cn-hongkong}
BILL_REG_ID="cn-hangzhou"
read -r -p "流量阈值GB，默认 180: " MAX_TRAFFIC_GB
MAX_TRAFFIC_GB=${MAX_TRAFFIC_GB:-180}
read -r -p "是否国际版账号？输入 y 表示国际版，默认国内版: " INTL
if [ "$INTL" = "y" ] || [ "$INTL" = "Y" ]; then
  IS_INTERNATIONAL="True"
else
  IS_INTERNATIONAL="False"
fi

read -r -p "每天日报推送时间，24小时制 HH:MM，默认 09:00。注意：固定按北京时间 UTC+8 发送: " REPORT_TIME
REPORT_TIME=${REPORT_TIME:-09:00}
if ! echo "$REPORT_TIME" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
  echo "日报时间格式错误，请用 HH:MM，例如 09:00"
  exit 1
fi

CRON_CHECK="* * * * * ${BASE_DIR}/venv/bin/python ${BASE_DIR}/traffic_control.py --cron >> ${BASE_DIR}/cron_run.log 2>&1"

if command -v apt >/dev/null 2>&1; then
  apt update
  apt install -y python3 python3-venv python3-pip curl ca-certificates cron
elif command -v yum >/dev/null 2>&1; then
  yum install -y python3 python3-pip curl ca-certificates cronie
fi

# 机器时区也尽量设置为上海，但程序内部仍强制按 UTC+8 判断日报和月初恢复。
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-timezone Asia/Shanghai || true
fi

mkdir -p "$BASE_DIR"
curl -fsSL "${REPO_RAW}/traffic_control.py.template" -o "${BASE_DIR}/traffic_control.py.template"
curl -fsSL "${REPO_RAW}/traffic-control.service" -o "/etc/systemd/system/${SERVICE_NAME}"
curl -fsSL "${REPO_RAW}/cdt" -o "/usr/local/bin/cdt"
chmod +x /usr/local/bin/cdt

export BASE_DIR ACCESS_KEY_ID ACCESS_KEY_SECRET TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID ADMIN_USER_ID INSTANCE_ID REGION_ID BILL_REG_ID IS_INTERNATIONAL MAX_TRAFFIC_GB ACCOUNT_NAME REPORT_TIME
python3 - <<'PYCONF'
from pathlib import Path
import os

base = Path(os.environ.get('BASE_DIR', '/root/aliyun-traffic-control'))
tpl = (base / 'traffic_control.py.template').read_text(encoding='utf-8')
repl = {
    '__ACCESS_KEY_ID__': os.environ['ACCESS_KEY_ID'],
    '__ACCESS_KEY_SECRET__': os.environ['ACCESS_KEY_SECRET'],
    '__TELEGRAM_BOT_TOKEN__': os.environ['TELEGRAM_BOT_TOKEN'],
    '__TELEGRAM_CHAT_ID__': os.environ['TELEGRAM_CHAT_ID'],
    '__ADMIN_USER_ID__': os.environ['ADMIN_USER_ID'],
    '__INSTANCE_ID__': os.environ['INSTANCE_ID'],
    '__REGION_ID__': os.environ['REGION_ID'],
    '__BILL_REG_ID__': os.environ['BILL_REG_ID'],
    '__IS_INTERNATIONAL__': os.environ['IS_INTERNATIONAL'],
    '__MAX_TRAFFIC_GB__': os.environ['MAX_TRAFFIC_GB'],
    '__ACCOUNT_NAME__': os.environ['ACCOUNT_NAME'],
    '__DAILY_REPORT_TIME__': os.environ['REPORT_TIME'],
}
for k, v in repl.items():
    tpl = tpl.replace(k, v)
(base / 'traffic_control.py').write_text(tpl, encoding='utf-8')
PYCONF

chmod +x "${BASE_DIR}/traffic_control.py"
python3 -m venv "${BASE_DIR}/venv"
"${BASE_DIR}/venv/bin/pip" install --upgrade pip
"${BASE_DIR}/venv/bin/pip" install aliyun-python-sdk-core aliyun-python-sdk-ecs aliyun-python-sdk-bssopenapi requests python-telegram-bot==13.15 APScheduler==3.6.3 pytz

touch "${BASE_DIR}/keepalive_enabled.flag" "${BASE_DIR}/cron_run.log"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# 只保留每分钟 cron。日报由 --cron 内部按北京时间判断发送，避免受机器/crontab 时区影响。
( crontab -l 2>/dev/null | grep -v "aliyun-traffic-control/traffic_control.py" || true; echo "$CRON_CHECK" ) | crontab -

echo "======================================"
echo "安装完成"
echo "账号显示名称：${ACCOUNT_NAME}"
echo "每日报告时间：${REPORT_TIME} UTC+8 / 北京时间"
echo "月初自动恢复：每月1号 00:05 UTC+8 后检测，流量低于阈值才开机"
echo "控制菜单命令：cdt"
echo "立即测试日报：cdt -> 8"
echo "======================================"
