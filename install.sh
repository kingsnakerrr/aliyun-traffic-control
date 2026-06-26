#!/bin/bash
# ====================================================================
# 阿里云 CDT 流量控制系统 - 纯净交互式安装脚本 (无硬编码隐私)
# ====================================================================

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本！"
  exit 1
fi

TARGET_DIR="/root/aliyun-cdt-traffic-control"
SCRIPT_FILE="$TARGET_DIR/traffic_control.py"

echo "===================================================================="
echo " 📥 欢迎使用阿里云 CDT 流量监控安装脚本 (请输入您的配置信息) "
echo "===================================================================="

# 1. 严格交互式获取敏感参数（不设默认别名，必须输入）
read -p "🔑 请输入阿里云 ACCESS_KEY_ID: " ACCESS_KEY_ID
read -p "🔑 请输入阿里云 ACCESS_KEY_SECRET: " ACCESS_KEY_SECRET
read -p "🖥️ 请输入阿里云 ECS 实例 ID: " INSTANCE_ID
read -p "🤖 请输入 Telegram 机器人 TOKEN: " TELEGRAM_BOT_TOKEN
read -p "📢 请输入 Telegram 频道/群组 ID: " TELEGRAM_CHAT_ID
read -p "👤 请输入您的管理员 TG 私聊用户 ID: " ADMIN_USER_ID

# 2. 针对非敏感的区域设置，提供默认值提示，回车即可
read -p "🌐 请输入阿里云 ECS 区域 REGION_ID [默认: cn-hongkong]: " INPUT_REGION
REGION_ID=${INPUT_REGION:-"cn-hongkong"}

echo "--------------------------------------------------------------------"
echo "⏱️ 1. 正在清理旧的服务与进程..."
systemctl stop traffic-control.service 2>/dev/null
systemctl disable traffic-control.service 2>/dev/null
rm -f /etc/systemd/system/traffic-control.service
systemctl daemon-reload
pkill -f "traffic_control.py" || true
crontab -l 2>/dev/null | grep -v "traffic_control" | crontab -
rm -f /usr/local/bin/cdt

echo "⏱️ 2. 正在初始化工作目录: $TARGET_DIR"
mkdir -p "$TARGET_DIR"

echo "⏱️ 3. 正在动态生成专属于您的 Python 主程序..."
# 此时生成的 Python 文件里，会替换成刚才用户在控制台打字输入的真实参数值
cat << EOF > "$SCRIPT_FILE"
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import json
import logging
import datetime
import requests

from aliyunsdkcore.client import AcsClient
from aliyunsdkcore.request import CommonRequest
from aliyunsdkbssopenapi.request.v20171214 import QueryBillOverviewRequest
from aliyunsdkbssopenapi.request.v20171214 import QueryAccountBalanceRequest
from aliyunsdkecs.request.v20140526 import StartInstanceRequest
from aliyunsdkecs.request.v20140526 import StopInstanceRequest
from aliyunsdkecs.request.v20140526 import DescribeInstancesRequest

from telegram import Update
from telegram.ext import Updater, CommandHandler, CallbackContext
from telegram.ext.dispatcher import run_async

# ====================================================================
# 基础配置 (由安装脚本安装时动态注入)
# ====================================================================
ACCESS_KEY_ID = '$ACCESS_KEY_ID'
ACCESS_KEY_SECRET = '$ACCESS_KEY_SECRET'
TELEGRAM_BOT_TOKEN = '$TELEGRAM_BOT_TOKEN'
TELEGRAM_CHAT_ID = '$TELEGRAM_CHAT_ID'
ADMIN_USER_ID = '$ADMIN_USER_ID'
INSTANCE_ID = '$INSTANCE_ID'
REGION_ID = '$REGION_ID'

BILL_REG_ID = 'cn-hangzhou'
IS_INTERNATIONAL = False
MAX_TRAFFIC_GB = 180.0
KEEPALIVE_FLAG_FILE = '/root/aliyun-cdt-traffic-control/keepalive_enabled.flag'
LAST_NOTIFY_FILE = '/root/aliyun-cdt-traffic-control/last_notify_state.json'

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
clt_ecs = AcsClient(ACCESS_KEY_ID, ACCESS_KEY_SECRET, REGION_ID)
clt_bill = AcsClient(ACCESS_KEY_ID, ACCESS_KEY_SECRET, BILL_REG_ID)

def get_billing_cycle(): return datetime.datetime.now().strftime('%Y-%m')
def now_text(): return datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')

def send_tg(chat_id, text, parse_mode=None):
    try:
        data = {"chat_id": chat_id, "text": text}
        if parse_mode: data["parse_mode"] = parse_mode
        res = requests.post(f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage", data=data, timeout=10)
        return res.ok
    except Exception as e:
        logging.error(f"发送TG失败: {str(e)}")
        return False

def is_admin(update: Update):
    user_id = update.effective_user.id if update.effective_user else None
    return str(user_id) == str(ADMIN_USER_ID)

def get_chat_id(update: Update):
    return update.effective_chat.id if update.effective_chat else ADMIN_USER_ID

def keepalive_enabled(): return os.path.exists(KEEPALIVE_FLAG_FILE)
def set_keepalive_enabled(enabled: bool):
    if enabled:
        with open(KEEPALIVE_FLAG_FILE, 'w') as f: f.write('enabled\n')
    else:
        if os.path.exists(KEEPALIVE_FLAG_FILE): os.remove(KEEPALIVE_FLAG_FILE)

def load_notify_state():
    try:
        if not os.path.exists(LAST_NOTIFY_FILE): return {}
        with open(LAST_NOTIFY_FILE, 'r') as f: return json.load(f)
    except Exception: return {}

def save_notify_state(state):
    try:
        with open(LAST_NOTIFY_FILE, 'w') as f: json.dump(state, f)
    except Exception as e: logging.error(f"保存通知状态失败: {str(e)}")

def notify_once(key, text):
    state = load_notify_state()
    if state.get(key): return
    if send_tg(TELEGRAM_CHAT_ID, text):
        state[key] = now_text()
        save_notify_state(state)

def clear_notify_key(key):
    state = load_notify_state()
    if key in state:
        del state[key]
        save_notify_state(state)

def set_pending_keepalive(status):
    state = load_notify_state()
    state["keepalive_pending"] = {"time": now_text(), "status": status}
    save_notify_state(state)

def get_pending_keepalive(): return load_notify_state().get("keepalive_pending")
def clear_pending_keepalive():
    state = load_notify_state()
    if "keepalive_pending" in state:
        del state["keepalive_pending"]
        save_notify_state(state)

def get_vps_status():
    try:
        request = DescribeInstancesRequest.DescribeInstancesRequest()
        request.set_InstanceIds([INSTANCE_ID])
        response = clt_ecs.do_action_with_exception(request)
        instances = json.loads(response.decode('utf-8')).get("Instances", {}).get("Instance", [])
        return instances[0].get("Status", "Unknown") if instances else "Unknown"
    except Exception as e: return "Unknown"

def start_vps_safety():
    try:
        status = get_vps_status().lower()
        if status == "running": return True, "✅ 实例已经是 Running，无需开机"
        if status in ["starting", "stopping"]: return True, f"⏳ 实例当前是 {status}，等待恢复 Running"
        request = StartInstanceRequest.StartInstanceRequest()
        request.set_InstanceId(INSTANCE_ID)
        clt_ecs.do_action_with_exception(request)
        return True, "🚀 StartInstance() 调用成功，实例正在启动"
    except Exception as e: return False, f"❌ 开机失败：{str(e)}"

def stop_vps_safety():
    try:
        status = get_vps_status().lower()
        if status == "stopped": return True, "✅ 实例已经是 Stopped，无需关机"
        if status == "stopping": return True, f"⏳ 实例当前是 {status}，正在关机中"
        request = StopInstanceRequest.StopInstanceRequest()
        request.set_InstanceId(INSTANCE_ID)
        request.set_ForceStop(True)
        clt_ecs.do_action_with_exception(request)
        return True, "🛑 StopInstance() 调用成功，实例正在关机"
    except Exception as e: return False, f"❌ 关机失败：{str(e)}"

def get_cdt_traffic():
    request = CommonRequest()
    request.set_domain('cdt.aliyuncs.com')
    request.set_version('2021-08-13')
    request.set_action_name('ListCdtInternetTraffic')
    request.set_method('POST')
    try:
        response = clt_ecs.do_action_with_exception(request)
        total_bytes = sum(d.get('Traffic', 0) for d in json.loads(response.decode('utf-8')).get('TrafficDetails', []))
        return round(total_bytes / (1024 ** 3), 2)
    except Exception: return 0.0

def get_aliyun_data():
    try:
        balance = '0.00'
        request_bal = QueryAccountBalanceRequest.QueryAccountBalanceRequest()
        request_bal.set_accept_format('json')
        res_bal = clt_bill.do_action_with_exception(request_bal)
        data_bal = json.loads(res_bal.decode('utf-8'))
        if data_bal.get('Success'): balance = data_bal.get('Data', {}).get('AvailableAmount', '0.00')
        request_bill = QueryBillOverviewRequest.QueryBillOverviewRequest()
        request_bill.set_accept_format('json')
        request_bill.set_BillingCycle(get_billing_cycle())
        res_bill = clt_bill.do_action_with_exception(request_bill)
        items = json.loads(res_bill.decode('utf-8')).get('Data', {}).get('Items', {}).get('Item', [])
        cost = sum(float(item.get('PretaxAmount', 0)) for item in items)
        return f"💰 账户现金余额：{balance} 元\n💵 本月消费（1号至今）：{cost:.2f} 元"
    except Exception: return "💰 账户现金余额：暂无数据\n💵 本月消费（1号至今）：0.00"

def build_status_text():
    return (
        "📊 阿里云账号 zymsdf - CDT服务器\n"
        "----------------------------------\n"
        f"🕒 时间：{now_text()}\n"
        f"📈 当前流量：{get_cdt_traffic()} GB / {MAX_TRAFFIC_GB} GB\n"
        f"🔄 实例状态：{get_vps_status()}\n"
        f"{get_aliyun_data()}\n"
        f"⚡ 保活运行状态：{'正常' if keepalive_enabled() else '已暂停'}\n"
        "💡 流量控制脚本运行正常\n"
        "----------------------------------"
    )

def build_help_text():
    return "🤖 命令：\n/status - 状态\n/traffic - 流量\n/bill - 账单\n/startvps - 开机\n/stopvps - 关机\n/keepon - 开启保活\n/keepoff - 暂停保活\n/report - 发送报告到频道"

def check_cron_job():
    traffic = get_cdt_traffic()
    status_before = get_vps_status()
    status_l = status_before.lower()
    if traffic >= MAX_TRAFFIC_GB:
        ok, result = stop_vps_safety()
        notify_once("traffic_stop", f"🔴【流量熔断关机通知】\n\n流量: {traffic}GB\n结果: {result}")
        return
    clear_notify_key("traffic_stop")
    if not keepalive_enabled(): return
    if status_l == "running":
        pending = get_pending_keepalive()
        if pending:
            send_tg(TELEGRAM_CHAT_ID, f"🟢【保活恢复成功】\n\n之前状态: {pending.get('status')}\n当前: Running\n流量: {traffic}GB")
            clear_pending_keepalive()
            clear_notify_key("keepalive_action")
        return
    if status_l in ["starting", "stopping"]:
        set_pending_keepalive(status_before)
        return
    ok, result = start_vps_safety()
    if ok:
        set_pending_keepalive(status_before)
        notify_once("keepalive_action", f"🟡【保活已触发】\n\n状态: {status_before}\n流量: {traffic}GB\n结果: {result}")

@run_async
def status_command(update, context):
    if is_admin(update): context.bot.send_message(chat_id=get_chat_id(update), text=build_status_text())
@run_async
def help_command(update, context):
    if is_admin(update): context.bot.send_message(chat_id=get_chat_id(update), text=build_help_text())
@run_async
def traffic_command(update, context):
    if is_admin(update): context.bot.send_message(chat_id=get_chat_id(update), text=f"📈 流量：{get_cdt_traffic()} GB / {MAX_TRAFFIC_GB} GB")
@run_async
def bill_command(update, context):
    if is_admin(update): context.bot.send_message(chat_id=get_chat_id(update), text=get_aliyun_data())
@run_async
def startvps_command(update, context):
    if is_admin(update): context.bot.send_message(chat_id=get_chat_id(update), text=start_vps_safety()[1])
@run_async
def stopvps_command(update, context):
    if is_admin(update): context.bot.send_message(chat_id=get_chat_id(update), text=stop_vps_safety()[1])
@run_async
def keepon_command(update, context):
    if is_admin(update):
        set_keepalive_enabled(True)
        context.bot.send_message(chat_id=get_chat_id(update), text="✅ 自动保活已开启。")
@run_async
def keepoff_command(update, context):
    if is_admin(update):
        set_keepalive_enabled(False)
        context.bot.send_message(chat_id=get_chat_id(update), text="⏸ 自动保活已暂停。")
@run_async
def report_command(update, context):
    if is_admin(update):
        send_tg(TELEGRAM_CHAT_ID, build_status_text(), parse_mode="HTML")
        context.bot.send_message(chat_id=get_chat_id(update), text="✅ 已发送报告到频道。")

def send_daily_report(context):
    try: send_tg(TELEGRAM_CHAT_ID, build_status_text(), parse_mode="HTML")
    except Exception: pass

def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--cron':
        check_cron_job()
        return
    if len(sys.argv) > 1 and sys.argv[1] == '--cmd-report':
        print(build_status_text())
        return
    if not os.path.exists(KEEPALIVE_FLAG_FILE): set_keepalive_enabled(True)
    updater = Updater(TELEGRAM_BOT_TOKEN, workers=4, request_kwargs={'read_timeout': 10, 'connect_timeout': 10})
    d = updater.dispatcher
    d.add_handler(CommandHandler("help", help_command))
    d.add_handler(CommandHandler("status", status_command))
    d.add_handler(CommandHandler("traffic", traffic_command))
    d.add_handler(CommandHandler("bill", bill_command))
    d.add_handler(CommandHandler("startvps", startvps_command))
    d.add_handler(CommandHandler("stopvps", stopvps_command))
    d.add_handler(CommandHandler("keepon", keepon_command))
    d.add_handler(CommandHandler("keepoff", keepoff_command))
    d.add_handler(CommandHandler("report", report_command))
    updater.job_queue.run_daily(send_daily_report, time=datetime.time(hour=9, minute=0, second=0))
    updater.start_polling(clean=True)
    updater.idle()

if __name__ == '__main__': main()
EOF

chmod +x "$SCRIPT_FILE"

echo "⏱️ 4. 正在构建 Python 虚拟环境并安装依赖库..."
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install aliyun-python-sdk-core aliyun-python-sdk-ecs aliyun-python-sdk-bssopenapi requests python-telegram-bot==13.15

echo "⏱️ 5. 正在自动生成 Systemd 系统常驻服务..."
cat << 'EOF' > /etc/systemd/system/traffic-control.service
[Unit]
Description=Aliyun CDT Traffic Control + Telegram Bot Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/aliyun-cdt-traffic-control
ExecStart=/root/aliyun-cdt-traffic-control/venv/bin/python traffic_control.py
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

echo "⏱️ 6. 正在自动配置每分钟 Crontab 流控定时检查..."
(crontab -l 2>/dev/null | grep -v "traffic_control" ; echo "* * * * * /root/aliyun-cdt-traffic-control/venv/bin/python /root/aliyun-cdt-traffic-control/traffic_control.py --cron >> /root/aliyun-cdt-traffic-control/cron_run.log 2>&1") | crontab -

echo "⏱️ 7. 正在自动注入终端快捷命令 'cdt'..."
cat << 'EOF' > /usr/local/bin/cdt
#!/bin/bash
/root/aliyun-cdt-traffic-control/venv/bin/python /root/aliyun-cdt-traffic-control/traffic_control.py --cmd-report
EOF
chmod +x /usr/local/bin/cdt

echo "⏱️ 8. 正在启动机器人常驻服务..."
systemctl daemon-reload
systemctl enable traffic-control.service
systemctl restart traffic-control.service

echo "===================================================================="
echo "🟢 恭喜！CDT 流控系统与 TG 机器人已成功部署！"
echo "💡 提示：本安装脚本在仓库中绝对安全，无任何隐私泄露风险。"
echo "💡 您现在可以在系统任意位置输入快捷命令： cdt 查看流量报告了。"
echo "===================================================================="
