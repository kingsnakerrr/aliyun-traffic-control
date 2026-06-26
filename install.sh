#!/usr/bin/env bash
set -e
REPO_RAW="https://raw.githubusercontent.com/kingsnakerrr/aliyun-traffic-control/refs/heads/main"
BASE_DIR="/root/aliyun-traffic-control"
SERVICE_NAME="traffic-control.service"
CRON_LINE="* * * * * ${BASE_DIR}/venv/bin/python ${BASE_DIR}/traffic_control.py --cron >> ${BASE_DIR}/cron_run.log 2>&1"
if [ "$(id -u)" -ne 0 ]; then echo "请使用 root 用户运行安装脚本"; exit 1; fi

echo "======================================"
echo " 阿里云 CDT 流量控制一键安装"
echo "======================================"
read -r -p "阿里云 ACCESS_KEY_ID: " ACCESS_KEY_ID
read -r -p "阿里云 ACCESS_KEY_SECRET: " ACCESS_KEY_SECRET
read -r -p "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -r -p "Telegram 频道/群组 ID，例如 -100xxxx: " TELEGRAM_CHAT_ID
read -r -p "Telegram 管理员私聊 ID: " ADMIN_USER_ID
read -r -p "ECS 实例 ID: " INSTANCE_ID
read -r -p "ECS 区域，默认 cn-hongkong: " REGION_ID; REGION_ID=${REGION_ID:-cn-hongkong}
read -r -p "账单区域，默认 cn-hangzhou: " BILL_REG_ID; BILL_REG_ID=${BILL_REG_ID:-cn-hangzhou}
read -r -p "流量阈值GB，默认 180: " MAX_TRAFFIC_GB; MAX_TRAFFIC_GB=${MAX_TRAFFIC_GB:-180}
read -r -p "是否国际版账号？输入 y 表示国际版，默认国内版: " INTL
if [ "$INTL" = "y" ] || [ "$INTL" = "Y" ]; then IS_INTERNATIONAL="True"; else IS_INTERNATIONAL="False"; fi

echo "开始安装依赖..."
if command -v apt >/dev/null 2>&1; then
  apt update && apt install -y python3 python3-venv python3-pip curl ca-certificates nano cron
elif command -v yum >/dev/null 2>&1; then
  yum install -y python3 python3-pip curl ca-certificates nano cronie || true
else
  echo "未识别包管理器，请手动安装 python3 python3-venv python3-pip curl crontab"
fi
mkdir -p "$BASE_DIR"

echo "下载程序文件..."
curl -fsSL "${REPO_RAW}/traffic_control.py.template" -o "${BASE_DIR}/traffic_control.py.template"
curl -fsSL "${REPO_RAW}/traffic-control.service" -o "/etc/systemd/system/${SERVICE_NAME}"
curl -fsSL "${REPO_RAW}/cdt" -o "/usr/local/bin/cdt"
chmod +x /usr/local/bin/cdt

export ACCESS_KEY_ID ACCESS_KEY_SECRET TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID ADMIN_USER_ID INSTANCE_ID REGION_ID BILL_REG_ID IS_INTERNATIONAL MAX_TRAFFIC_GB BASE_DIR
python3 - <<'PY'
from pathlib import Path
import os
base = Path(os.environ['BASE_DIR'])
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
}
for k,v in repl.items(): tpl = tpl.replace(k,v)
(base / 'traffic_control.py').write_text(tpl, encoding='utf-8')
PY
chmod +x "${BASE_DIR}/traffic_control.py"

echo "创建 Python 虚拟环境..."
python3 -m venv "${BASE_DIR}/venv"
"${BASE_DIR}/venv/bin/pip" install --upgrade pip
"${BASE_DIR}/venv/bin/pip" install aliyun-python-sdk-core aliyun-python-sdk-ecs aliyun-python-sdk-bssopenapi requests python-telegram-bot==13.15 APScheduler==3.6.3 pytz

touch "${BASE_DIR}/keepalive_enabled.flag" "${BASE_DIR}/cron_run.log"

echo "配置 systemd..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo "配置 crontab 每分钟保活..."
(crontab -l 2>/dev/null | grep -vF "$CRON_LINE"; echo "$CRON_LINE") | crontab -

echo "安装完成。输入 cdt 打开控制菜单。"
