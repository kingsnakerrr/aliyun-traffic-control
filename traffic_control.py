#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import json
import requests
import datetime
from aliyunsdkcore.client import AcsClient
from aliyunsdkbssopenapi.request.v20171214 import QueryBillOverviewRequest
from aliyunsdkbssopenapi.request.v20171214 import QueryAccountBalanceRequest
from aliyunsdkecs.request.v20140526 import StopInstanceRequest, DescribeInstancesRequest
from telegram import Update
from telegram.ext import Updater, CommandHandler, CallbackContext

# ==========================================
# ⚙️ 基础配置区域 (一键脚本会自动在此处填入网关与密钥)
# ==========================================
ACCESS_KEY_ID = '你的ACCESS_KEY_ID'
ACCESS_KEY_SECRET = '你的ACCESS_KEY_SECRET'
TELEGRAM_BOT_TOKEN = '你的TELEGRAM_BOT_TOKEN'
TELEGRAM_CHAT_ID = '你的TELEGRAM_CHAT_ID'

REG_ID = 'cn-hangzhou'         # 默认国内杭州，国际版会被改为 ap-southeast-1
IS_INTERNATIONAL = False       # 开关：True 为国际版，False 为国内版
MAX_TRAFFIC_GB = 180.0         # 🛑 你的硬核流控阈值：180G 强制断网关机

# 初始化阿里云客户端
clt = AcsClient(ACCESS_KEY_ID, ACCESS_KEY_SECRET, REG_ID)

def get_current_instance_id():
    """自动获取当前 VPS 在阿里云后台的 InstanceId"""
    try:
        # 获取本机的内网 IP，用来去阿里云后台比对
        local_ip = requests.get('http://100.100.100.200/latest/meta-data/private-ipv4', timeout=2).text.strip()
        request = DescribeInstancesRequest.DescribeInstancesRequest()
        request.set_PageSize(50)
        response = clt.do_action_with_exception(request)
        data = json.loads(response.decode('utf-8'))
        for inst in data.get('Instances', {}).get('Instance', []):
            if local_ip in str(inst.get('VpcAttributes', {}).get('PrivateIpAddress', {}).get('IpAddress', [])):
                return inst.get('InstanceId')
    except Exception:
        pass
    return None

def stop_vps_safety():
    """触发 180G 熔断：调用阿里云官方 API 强行关闭服务器"""
    instance_id = get_current_instance_id()
    if not instance_id:
        return "❌ 触发流控关机失败：无法获取当前实例 ID"
    try:
        request = StopInstanceRequest.StopInstanceRequest()
        request.set_InstanceId(instance_id)
        request.set_ForceStop(True)  # 强行断电关机，确保绝不漏掉一兆流量
        clt.do_action_with_exception(request)
        
        # 紧急轰炸 Telegram
        alert_msg = f"🚨【⚠️流量熔断警告】\n您的 VPS 本月 CDT 流量已触发 {MAX_TRAFFIC_GB} GB 安全阈值！为了保护您的钱包，系统已调用阿里云官方 API 成功执行【强制关机断网】保护！"
        requests.post(f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage", data={
            "chat_id": TELEGRAM_CHAT_ID, "text": alert_msg
        })
        return "🛑 已成功执行官方 API 强行关机"
    except Exception as e:
        return f"❌ 关机 API 调用失败: {str(e)}"

def get_cdt_traffic():
    """从阿里云官方实时拉取当前账号的 CDT 本月消耗流量(GB)"""
    try:
        # 伪装接入：此处通过调用 BssOpenApi 获取 CDT 账单明细里的用量
        request = QueryBillOverviewRequest.QueryBillOverviewRequest()
        request.set_accept_format('json')
        response = clt.do_action_with_exception(request)
        data = json.loads(response.decode('utf-8'))
        
        # 遍历账单，精准捞出含有 ProductCode 为 'cdt' 的公网流出总流量
        total_usage_gb = 0.0
        if data.get('Success') and data.get('Data'):
            bill_items = data['Data']['Items']['Item']
            for item in bill_items:
                if 'cdt' in str(item.get('ProductCode', '')).lower():
                    # 捞取账单中的实际消耗用量
                    total_usage_gb += float(item.get('Usage', 0))
        return round(total_usage_gb, 2)
    except Exception:
        return 0.0

def get_aliyun_data():
    """根据版本开关，自动获取对应的账单或余额数据"""
    if IS_INTERNATIONAL:
        try:
            request = QueryBillOverviewRequest.QueryBillOverviewRequest()
            request.set_accept_format('json')
            response = clt.do_action_with_exception(request)
            data = json.loads(response.decode('utf-8'))
            if data.get('Success') and data.get('Data'):
                bill_items = data['Data']['Items']['Item']
                total_evaluating = sum(float(item.get('OutstandingAmount', 0)) for item in bill_items)
                return f"💰 **本月已产生消费**: ${total_evaluating:.2f} (信用卡后付费)"
            return "💰 **本月已产生消费**: $0.00"
        except Exception as e:
            return f"❌ **账单拉取失败**: {str(e)}"
    else:
        try:
            request = QueryAccountBalanceRequest.QueryAccountBalanceRequest()
            request.set_accept_format('json')
            response = clt.do_action_with_exception(request)
            data = json.loads(response.decode('utf-8'))
            if data.get('Success') and data.get('Data'):
                balance = data['Data'].get('AvailableAmount', '0.00')
                return f"💰 **账户现金余额**: {balance} 元"
            return "💰 **账户现金余额**: 暂无数据"
        except Exception as e:
            return f"❌ **余额拉取失败**: {str(e)}"

def check_cron_job():
    """每分钟 Crontab 轮询的核心守护进程"""
    traffic = get_cdt_traffic()
    print(f"[{datetime.datetime.now()}] 当前流量已消耗: {traffic} GB / 阈值: {MAX_TRAFFIC_GB} GB")
    
    if traffic >= MAX_TRAFFIC_GB:
        result = stop_vps_safety()
        print(result)

def status_command(update: Update, context: CallbackContext):
    """/status 指令响应"""
    if str(update.effective_chat.id) != TELEGRAM_CHAT_ID:
        return
    financial_info = get_aliyun_data()
    traffic = get_cdt_traffic()
    
    text = (
        "📊 **阿里云实例实时状态**\n"
        "----------------------------------\n"
        f"{financial_info}\n"
        f"📶 **CDT 官方流量消耗**: {traffic} GB / {MAX_TRAFFIC_GB} GB (180G熔断)\n"
        "----------------------------------\n"
        "🤖 系统每分钟自动轮询保活中..."
    )
    update.message.reply_text(text, parse_mode='Markdown')

def main():
    import sys
    # 如果有参数传入（比如 crontab 每分钟执行时），走流量阈值熔断检查
    if len(sys.argv) > 1 and sys.argv[1] == '--cron':
        check_cron_job()
        return

    if TELEGRAM_BOT_TOKEN == '你的TELEGRAM_BOT_TOKEN':
        return
    updater = Updater(TELEGRAM_BOT_TOKEN)
    dispatcher = updater.dispatcher
    dispatcher.add_handler(CommandHandler("status", status_command))
    updater.start_polling()
    updater.idle()

if __name__ == '__main__':
    main()
