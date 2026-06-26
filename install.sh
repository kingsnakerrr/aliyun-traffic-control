#!/bin/bash
set -e

WORKDIR="/root/aliyun-cdt-traffic-control"
RAW_URL="https://raw.githubusercontent.com/kingsnakerrr/aliyun-traffic-control/refs/heads/main"

# ==================================================
# 🧹 核心：内置的一键卸载清理函数
# ==================================================
all_uninstall_process() {
    echo "=================================================="
    echo "🧹 开始彻底卸载阿里云 CDT 流控系统..."
    echo "=================================================="
    pkill -f traffic_control.py || true
    systemctl stop traffic-control.service 2>/dev/null || true
    systemctl disable traffic-control.service 2>/dev/null || true
    rm -f /etc/systemd/system/traffic-control.service
    systemctl daemon-reload
    (crontab -l 2>/dev/null | grep -Fv "traffic_control.py") | crontab -
    rm -rf /root/aliyun-traffic-control
    rm -rf "$WORKDIR"
    rm -f /usr/local/bin/cdt
    rm -f /root/install.sh
    echo "✅ 卸载完成！所有残留、定时任务、全局命令已被斩草除根。"
    echo "=================================================="
}

# 判断用户是不是直接通过命令行触发了快捷删除
if [ "$1" = "--uninstall" ]; then
    all_uninstall_process
    exit 0
fi

# ==================================================
# 🌐 核心选择：一键安装流程
# ==================================================
echo "=================================================="
echo "🚀 欢迎使用 阿里云 CDT 双版本流控断网保活系统"
echo "=================================================="
echo "💡 请选择操作："
echo "  1) 阿里云国内版 安装/重装"
echo "  2) 阿里云国际版 安装/重装"
echo "  3) 彻底卸载此系统"
read -p "请输入数字 [1-3]: " MAIN_CHOICE

if [ "$MAIN_CHOICE" = "3" ]; then
    all_uninstall_process
    exit 0
elif [ "$MAIN_CHOICE" = "2" ]; then
    echo "✅ 已选择：阿里云国际版"
    ENDPOINT_REG="ap-southeast-1"
    SET_INTERNATIONAL="True"
else
    echo "✅ 已选择：阿里云国内版"
    ENDPOINT_REG="cn-hangzhou"
    SET_INTERNATIONAL="False"
fi
echo "=================================================="

# 1. 创建工作目录
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# 2. 检查系统依赖
echo "📦 正在检查系统依赖..."
if [ -f /etc/debian_version ]; then
    apt-get update && apt-get install python3-venv python3-pip curl -y
elif [ -f /etc/redhat-release ]; then
    yum install python3 python3-pip curl -y
fi

# 3. 从 GitHub 下载主程序和 Service 模板
echo "📥 正在从 GitHub 下载最新程序..."
curl -sSL "$RAW_URL/traffic_control.py" -o traffic_control.py
curl -sSL "$RAW_URL/traffic-control.service" -o /etc/systemd/system/traffic-control.service

sed -i "s|/root/aliyun-traffic-control|$WORKDIR|g" /etc/systemd/system/traffic-control.service

# 4. 创建虚拟环境并安装 Python 依赖
echo "⚙️ 正在创建 Python 虚拟环境并安装双版本完整依赖..."
python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install aliyun-python-sdk-core aliyun-python-sdk-ecs aliyun-python-sdk-bssopenapi requests python-telegram-bot==13.15

# 5. 配置关键参数交互输入
echo ""
echo "=================================================="
echo "✏️  请配置你的主程序关键参数！"
echo "=================================================="
read -p "请输入你的 阿里云 ACCESS_KEY_ID: " AK_ID
read -p "请输入你的 阿里云 ACCESS_KEY_SECRET: " AK_SECRET
read -p "请输入你要控制的 阿里云实例ID (如 i-j6cxxxxxx): " INST_ID
read -p "请输入该实例所在的 地域ID (默认: cn-hongkong): " REG_ID
REG_ID=${REG_ID:-cn-hongkong}
read -p "请输入你的 Telegram BOT_TOKEN: " TG_TOKEN
read -p "请输入你的 Telegram CHAT_ID (频道/群组ID): " TG_ID

# 精准注入 Python
sed -i "s/ACCESS_KEY_ID = .*/ACCESS_KEY_ID = '$AK_ID'/g" traffic_control.py
sed -i "s/ACCESS_KEY_SECRET = .*/ACCESS_KEY_SECRET = '$AK_SECRET'/g" traffic_control.py
sed -i "s/INSTANCE_ID = .*/INSTANCE_ID = '$INST_ID'/g" traffic_control.py
sed -i "s/REGION_ID = .*/REGION_ID = '$REG_ID'/g" traffic_control.py
sed -i "s/TELEGRAM_BOT_TOKEN = .*/TELEGRAM_BOT_TOKEN = '$TG_TOKEN'/g" traffic_control.py
sed -i "s/TELEGRAM_CHAT_ID = .*/TELEGRAM_CHAT_ID = '$TG_ID'/g" traffic_control.py
sed -i "s/BILL_REG_ID = .*/BILL_REG_ID = '$ENDPOINT_REG'/g" traffic_control.py
sed -i "s/IS_INTERNATIONAL = .*/IS_INTERNATIONAL = $SET_INTERNATIONAL/g" traffic_control.py

# 6. ⚙️ 生成全局无敌快捷控制脚本 /usr/local/bin/cdt
cat << 'EOF' > /usr/local/bin/cdt
#!/bin/bash
WORKDIR="/root/aliyun-cdt-traffic-control"

show_menu() {
    echo "=================================================="
    echo "🛠️  阿里云 CDT 流控保活系统控制面板"
    echo "=================================================="
    echo "  1) 🟢 启动/重启 TG机器人保活监听"
    echo "  2) 🔴 停止 TG机器人保活监听"
    echo "  3) 📊 查看每分钟流控与熔断日志"
    echo "  4) 🧹 彻底卸载并清理残留"
    echo "  5) 🚪 退出面板"
    echo "=================================================="
    read -p "请选择操作 [1-5]: " PANEL_CHOICE
    case $PANEL_CHOICE in
        1) systemctl restart traffic-control.service && echo "✅ 机器人后台监听已重新启动！" ;;
        2) systemctl stop traffic-control.service && echo "🛑 机器人后台监听已停止！" ;;
        3) tail -n 20 "$WORKDIR/cron_run.log" ; echo "" ; read -p "按回车继续..." ;;
        4) bash "$WORKDIR/install.sh" --uninstall ; exit 0 ;;
        *) exit 0 ;;
    esac
}

if [ "$1" = "--uninstall" ]; then
    bash "$WORKDIR/install.sh" --uninstall
else
    show_menu
fi
EOF
chmod +x /usr/local/bin/cdt
# 同时把安装脚本复制一份备份到工作目录，用于以后的卸载支撑
cp "$0" "$WORKDIR/install.sh" || true

echo "✅ 全局控制指令 cdt 已成功植入系统！"

# 7. 启动常驻服务
echo "🤖 正在启动 Telegram 机器人常驻后台服务..."
systemctl daemon-reload
systemctl enable traffic-control.service
systemctl restart traffic-control.service

# 8. 挂载 Crontab
echo "⏱️  正在配置 Crontab 每分钟静默保活与流量熔断检查..."
CRON_CMD="* * * * * $WORKDIR/venv/bin/python $WORKDIR/traffic_control.py --cron >> $WORKDIR/cron_run.log 2>&1"
(crontab -l 2>/dev/null | grep -Fv "traffic_control.py"; echo "$CRON_CMD") | crontab -

echo "=================================================="
echo "🎉 阿里云 CDT 全功能终极控制系统部署完毕！"
echo "🛡️  180G 流量硬熔断守护中。"
echo "💡 提示：您现在可以在任何路径，直接输入以下命令管理系统："
echo "     👉 输入 cdt            : 呼出可视化控制面板 (启动/停止/看日志/卸载)"
echo "     👉 输入 cdt --uninstall: 瞬间全自动一键秒卸载"
echo "=================================================="
