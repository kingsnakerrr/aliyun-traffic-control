# -*- coding: utf-8 -*-
from aliyunsdkcore.client import AcsClient
from aliyunsdkcore.request import CommonRequest
from aliyunsdkecs.request.v20140526 import StartInstancesRequest, StopInstancesRequest, DescribeInstancesRequest
from aliyunsdkbssopenapi.request.v20171214 import QueryAccountBalanceRequest, QueryBillRequest
import json
import sys
import logging
import requests
from datetime import datetime
import argparse
import time

# ================== 1. 配置 ==================
ACCESS_KEY_ID = 'YOUR_ACCESS_KEY_ID'
ACCESS_KEY_SECRET = 'YOUR_ACCESS_KEY_SECRET'
REGION_ID = 'cn-hongkong'
ECS_INSTANCE_ID = 'i-j6c0mq7hjf11h5n1m1qu'
TRAFFIC_THRESHOLD_GB = 180

TELEGRAM_BOT_TOKEN = 'YOUR_TELEGRAM_BOT_TOKEN'
TELEGRAM_CHAT_ID = 'YOUR_TELEGRAM_CHAT_ID'

# 配置日志
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s", stream=sys.stdout)
logger = logging.getLogger(__name__)

try:
    client = AcsClient(ACCESS_KEY_ID, ACCESS_KEY_SECRET, REGION_ID)
    logger.info("AcsClient 初始化成功。")
except Exception as e:
    logger.error(f"AcsClient 初始化失败: {e}")
    sys.exit(1)

# ================== 2. 核心数据查询函数 ==================
def send_telegram(chat_id, message):
    try:
        url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
        data = {"chat_id": chat_id, "parse_mode": "HTML", "text": message}
        requests.post(url, data=data, timeout=10)
    except Exception as e:
        logger.error(f"发送 TG 失败: {e}")

def get_total_traffic_gb():
    try:
        request = CommonRequest()
        request.set_domain('cdt.aliyuncs.com')
        request.set_version('2021-08-13')
        request.set_action_name('ListCdtInternetTraffic')
        request.set_method('POST')
        response = client.do_action_with_exception(request)
        data = json.loads(response.decode('utf-8'))
        total_bytes = sum(d.get('Traffic', 0) for d in data.get('TrafficDetails', []))
        return round(total_bytes / (1024 ** 3), 2)
    except Exception as e:
        logger.error(f"流量查询失败: {e}")
        return 0.0

def get_ecs_status():
    try:
        request = DescribeInstancesRequest.DescribeInstancesRequest()
        request.set_InstanceIds([ECS_INSTANCE_ID])
        response = client.do_action_with_exception(request)
        data = json.loads(response.decode('utf-8'))
        instances = data.get("Instances", {}).get("Instance", [])
        return instances[0].get("Status", "Unknown") if instances else "Unknown"
    except Exception as e:
        logger.error(f"状态查询失败: {e}")
        return "Unknown"

def get_aliyun_balance_and_cost():
    balance_str, cost_str = "未知", "未知"
    
    # 1. 实时查询账户余额
    try:
        req_b = QueryAccountBalanceRequest.QueryAccountBalanceRequest()
        res_b = json.loads(client.do_action_with_exception(req_b).decode('utf-8'))
        if res_b.get("Success"):
            avail_amount = res_b.get("Data", {}).get("AvailableAmount", "")
            if avail_amount:
                balance_str = f"{float(avail_amount.replace(',', '')):.2f}"
    except Exception as e:
        logger.error(f"查询余额接口失败: {e}")
        
    # 2. ⚡ 实时账单穿透查询（把当月产生的所有明细，包含未结算的，直接全部抓出来累加）
    try:
        req_c = QueryBillRequest.QueryBillRequest()
        req_c.set_BillingCycle(datetime.now().strftime("%Y-%m"))
        req_c.set_PageSize(100) # 确保抓完本月所有账单明细
        res_c = json.loads(client.do_action_with_exception(req_c).decode('utf-8'))
        
        if res_c.get("Success"):
            bill_items = res_c.get("Data", {}).get("Items", {}).get("Item", [])
            total_pretax_amount = 0.0
            for item in bill_items:
                # 累加本月每一项产生消费的应付金额（PretaxAmount）
                amount = item.get("PretaxAmount", 0)
                if amount:
                    total_pretax_amount += float(amount)
            cost_str = f"{total_pretax_amount:.2f}"
    except Exception as e:
        logger.error(f"通过实时明细接口查询消费失败: {e}")
        
    return balance_str, cost_str

def get_status_message():
    traffic = get_total_traffic_gb()
    status = get_ecs_status()
    balance, cost = get_aliyun_balance_and_cost()
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    return f"""📊 <b>阿里云账号 zymsdf - CDT服务器</b>

🕒 时间：{now}
📈 当前流量：{traffic} GB / {TRAFFIC_THRESHOLD_GB} GB
🔄 实例状态：{status}
💰 账户余额：{balance} 元
💰 本月消费（1号至今）：{cost} 元
⚡️ 保活运行状态：正常
💡 流量控制脚本运行正常"""

# ================== 3. ECS 自动化启停控制 ==================
def ecs_start():
    if get_ecs_status() == "Running": return
    try:
        request = StartInstancesRequest.StartInstancesRequest()
        request.set_InstanceIds([ECS_INSTANCE_ID])
        client.do_action_with_exception(request)
        send_telegram(TELEGRAM_CHAT_ID, f"<b>⚠️ 实例动作通知</b>\n\n🟢 流量正常，已自动 <b>启动</b> 实例。")
    except Exception as e:
        logger.error(f"启动失败: {e}")

def ecs_stop():
    if get_ecs_status() == "Stopped": return
    try:
        request = StopInstancesRequest.StopInstancesRequest()
        request.set_InstanceIds([ECS_INSTANCE_ID])
        request.set_ForceStop(False)
        client.do_action_with_exception(request)
        send_telegram(TELEGRAM_CHAT_ID, f"<b>⚠️ 实例动作通知</b>\n\n🔴 流量已达阈值，已自动 <b>停止</b> 实例！")
    except Exception as e:
        logger.error(f"停止失败: {e}")

# ================== 4. TG Bot 监听与早 9 点定时推送 ==================
def run_tg_bot_mode():
    logger.info("=== Telegram Bot 监听与定时任务服务已启动 ===")
    offset = 0
    last_daily_report_date = ""

    while True:
        try:
            now = datetime.now()
            if now.hour == 9 and now.minute == 0 and last_daily_report_date != now.strftime("%Y-%m-%d"):
                logger.info("触发早上 9 点定时报告推送...")
                send_telegram(TELEGRAM_CHAT_ID, get_status_message())
                last_daily_report_date = now.strftime("%Y-%m-%d")

            url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/getUpdates"
            res = requests.get(url, params={"offset": offset, "timeout": 10}, timeout=15).json()
            
            if res.get("ok") and res.get("result"):
                for update in res["result"]:
                    offset = update["update_id"] + 1
                    message = update.get("message", {})
                    text = message.get("text", "")
                    chat_id = message.get("chat", {}).get("id")

                    if text in ["/status", "查流量", "状态", "/start"]:
                        logger.info(f"收到用户指令: {text}，正在生成报告...")
                        send_telegram(chat_id, get_status_message())
        except Exception as e:
            logger.error(f"Bot 运行中出现异常: {e}")
        time.sleep(2)

# ================== 5. 主程序入口 ==================
if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('--report', action='store_true')
    parser.add_argument('--bot', action='store_true')
    args = parser.parse_args()

    if args.report:
        send_telegram(TELEGRAM_CHAT_ID, get_status_message())
        print("报告已发送")
        sys.exit(0)

    if args.bot:
        run_tg_bot_mode()
        sys.exit(0)

    # 模式 C: 后台自动化保活检查
    logger.info("=== 执行保活检查 ===")
    traffic = get_total_traffic_gb()
    balance, cost = get_aliyun_balance_and_cost()
    
    logger.info(f"当前总互联网流量: {traffic} GB")
    logger.info(f"账户剩余余额: {balance} 元 | 当前实时计算消费: {cost} 元")

    if traffic >= TRAFFIC_THRESHOLD_GB:
        logger.info(f"流量 {traffic} GB ≥ 阈值 {TRAFFIC_THRESHOLD_GB} GB，执行停止。")
        ecs_stop()
    else:
        logger.info(f"流量 {traffic} GB < 阈值 {TRAFFIC_THRESHOLD_GB} GB，执行启动。")
        ecs_start()
        
    logger.info("脚本执行完毕。")