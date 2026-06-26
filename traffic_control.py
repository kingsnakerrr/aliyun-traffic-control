#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import json
import requests
import datetime
import logging
from aliyunsdkcore.client import AcsClient
from aliyunsdkcore.request import CommonRequest
from aliyunsdkbssopenapi.request.v20171214 import QueryBillOverviewRequest
from aliyunsdkbssopenapi.request.v20171214 import QueryAccountBalanceRequest
from aliyunsdkecs.request.v20140526 import StopInstanceRequest, StartInstanceRequest, DescribeInstanceStatusRequest
from telegram import Update
from telegram.ext import Updater, CommandHandler, CallbackContext
from telegram.ext.dispatcher import run_async

# 设置基础日志格式
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# ==========================================
# ⚙️ 基础配置区域 (由一键脚本自动注入)
# ==========================================
ACCESS_KEY_ID = '你的ACCESS_KEY_ID'
ACCESS_KEY_SECRET = '你的ACCESS_KEY_SECRET'
TELEGRAM_BOT_TOKEN = '你的TELEGRAM_BOT_TOKEN'
TELEGRAM_CHAT_ID = '你的TELEGRAM_CHAT_ID'
INSTANCE_ID = '你的INSTANCE_ID'
REGION_ID = 'cn-hongkong'

BILL_REG_ID = 'cn-hangzhou'
IS_INTERNATIONAL = False
MAX_TRAFFIC_GB = 180.0

# 初始化客户端
clt_ecs = AcsClient(ACCESS_KEY_ID, ACCESS_KEY_SECRET, REGION_ID)
clt_bill = AcsClient(ACCESS_KEY_ID, ACCESS_KEY_SECRET, BILL_REG_ID)

def get_billing_cycle():
    return datetime.datetime.now().strftime('%Y-%m')

def get_vps_status():
    if not INSTANCE_ID or '你的' in INSTANCE_ID:
        return "Unknown"
    try:
        request = DescribeInstanceStatusRequest.DescribeInstanceStatusRequest()
        request.set_InstanceId([INSTANCE_ID])
        response = clt_ecs.do_action_with_exception(request)
        data = json.loads(response.decode('utf-8'))
        status = data.get('InstanceStatuses', {}).get('InstanceStatus', [{}])[0].get('Status', 'Unknown')
        return status.capitalize()
    except Exception:
        return "Unknown"

def start_vps_safety():
    if not INSTANCE_ID or '你的' in INSTANCE_ID:
        return
    try:
        request = StartInstanceRequest.StartInstanceRequest()
        request.set_InstanceId(INSTANCE_ID)
        clt_ecs.do_action_with_exception(request)
        logging.info("🚀 流量正常，已成功发送实例开机保活指令。")
    except Exception as e:
        logging.error(f"自动开机失败: {str(e)}")

def stop_vps_safety():
    if not INSTANCE_ID or '你的' in INSTANCE_ID:
        return "❌ 触发流控关机失败"
    try:
        request = StopInstanceRequest.StopInstanceRequest()
        request.set_InstanceId(INSTANCE_ID)
        request.set_ForceStop(True)
        clt_ecs.do_action_with_exception(request)
        
        alert_msg = f"🚨【⚠️流量熔断警告】\n您的阿里云实例({INSTANCE_ID})本月 CDT 流量已触发 {MAX_TRAFFIC_GB} GB 安全阈值！为了保护您的钱包，系统已成功执行【强制关机断网】保护！"
        requests.post(f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage", data={
            "chat_id": TELEGRAM_CHAT_ID, "text": alert_msg
        }, timeout=5)
        return f"🛑 已成功执行强行关机"
    except Exception as e:
        return f"❌ 关机 API 调用失败: {str(e)}"

def get_cdt_traffic():
    """✨ 核心进化：采用教程中纯正的 CDT 实时产品线接口获取最真实流量"""
    request = CommonRequest()
    request.set_domain('cdt.aliyuncs.com')
    request.set_version('2021-08-13')
    request.set_action_name('ListCdtInternetTraffic')
    request.set_method('POST')
    try:
        # 使用当前区域客户端（如 cn-hongkong）直接抓取
        response = clt_ecs.do_action_with_exception(request)
        response_json = json.loads(response.decode('utf-8'))
        
        total_bytes = sum(d.get('Traffic', 0) for d in response_json.get('TrafficDetails', []))
        total_gb = total_bytes / (1024 ** 3)
        return round(total_gb, 2)
    except Exception as e:
        logging.error(f"原生CDT流量实时拉取失败: {str(e)}")
        return 0.0

def get_aliyun_data():
    try:
        request_bal = QueryAccountBalanceRequest.QueryAccountBalanceRequest()
        request_bal.set_accept_format('json')
        res_bal = clt_bill.do_action_with_exception(request_bal)
        data_bal = json.loads(res_bal.decode('utf-8'))
        balance = data_bal['Data'].get('AvailableAmount', '0.00') if data_bal.get('Success') else '0.00'
        
        request_bill = QueryBillOverviewRequest.QueryBillOverviewRequest()
        request_bill.set_accept_format('json')
        request_bill.set_BillingCycle(get_billing_cycle())
        res_bill = clt_bill.do_action_with_exception(request_bill)
        data_bill = json.loads(res_bill.decode('utf-8'))
        cost = 0.0
        if data_bill.get('Success') and data_bill.get('Data'):
            cost = sum(float(item.get('PretaxAmount', 0)) for item in data_bill['Data']['Items']['Item'])
        
        if IS_INTERNATIONAL:
            return f"💰 账户现金余额: 信用卡后付费\n💵 本月消费 (1号至今)：${cost:.2f}"
        return f"💰 账户现金余额：{balance} 元\n💵 本月消费 (1号至今) ：{cost:.2f} 元"
    except Exception:
        return "💰 账户现金余额：暂无数据\n💵 本月消费 (1号至今) ：0.00"

def check_cron_job():
    traffic = get_cdt_traffic()
    logging.info(f"当前流量消耗: {traffic} GB / 阈值: {MAX_TRAFFIC_GB} GB")
    if traffic >= MAX_TRAFFIC_GB:
        result = stop_vps_safety()
        logging.warning(result)
    else:
        start_vps_safety()
    logging.info("脚本执行完毕。")

@run_async
def status_command(update: Update, context: CallbackContext):
    if str(update.effective_chat.id) != TELEGRAM_CHAT_ID:
        return
    try:
        now_time = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        traffic = get_cdt_traffic()
        instance_status = get_vps_status()
        financial_info = get_aliyun_data()
        
        text = (
            "📊 **阿里云账号 zymsdf - CDT服务器**\n\n"
            "----------------------------------\n"
            f"🕒 时间：{now_time}\n"
            f"📈 当前流量：{traffic} GB / {MAX_TRAFFIC_GB} GB\n"
            f"🔄 实例状态：{instance_status}\n"
            f"{financial_info}\n"
            "⚡ 保活运行状态：正常\n"
            "💡 流量控制脚本运行正常\n"
            "----------------------------------"
        )
        update.message.reply_text(text, parse_mode='Markdown')
    except Exception as e:
        logging.error(f"发送消息异常: {str(e)}")

def main():
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == '--cron':
        check_cron_job()
        return

    if TELEGRAM_BOT_TOKEN == '你的TELEGRAM_BOT_TOKEN':
        return
    
    updater = Updater(TELEGRAM_BOT_TOKEN, workers=4, request_kwargs={'read_timeout': 10, 'connect_timeout': 10})
    dispatcher = updater.dispatcher
    dispatcher.add_handler(CommandHandler("status", status_command))
    updater.start_polling(clean=True)
    updater.idle()

if __name__ == '__main__':
    main()
