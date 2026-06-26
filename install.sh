#!/bin/bash
# ====================================================================
# 阿里云 CDT 流量控制与 TG 机器人系统 - 一键安装与环境对齐脚本 (完美版)
# ====================================================================

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本！"
  exit 1
fi

echo "⏱️ 1. 正在清理老机器上的旧进程与旧服务项..."
systemctl stop traffic-control.service 2>/dev/null
systemctl disable traffic-control.service 2>/dev/null
rm -f /etc/systemd/system/traffic-control.service
systemctl daemon-reload
pkill -f "traffic_control.py" || true

# 清理旧的 crontab 定时任务（防止路径和参数冲突）
crontab -l 2>/dev/null | grep -v "traffic_control" | crontab -

echo "⏱️ 2. 正在创建全新代码对应的标准工作目录..."
TARGET_DIR="/root/aliyun-cdt-traffic-control"
mkdir -p "$TARGET_DIR"

# 检查当前目录下是否有用户放好的 traffic_control.py
if [ -f "./traffic_control.py" ]; then
    cp "./traffic_control.py" "$TARGET_DIR/traffic_control.py"
    echo "✅ 已成功将当前的 traffic_control.py 移至工作目录。"
elif [ -f "$TARGET_DIR/traffic_control.py" ]; then
    echo "ℹ️ 工作目录中已存在 traffic_control.py，将直接使用。"
else
    echo "⚠️ 未在当前目录找到 traffic_control.py！请确保该文件稍后被正确放置在 $TARGET_DIR/traffic_control.py"
fi

echo "⏱️ 3. 正在构建 Python 虚拟环境并安装全新依赖库..."
cd "$TARGET_DIR"
python3 -m venv venv
source venv/bin/activate

# 升级 pip 并精准安装新旧组合依赖，特别加上新版必需的 python-telegram-bot 库
pip install --upgrade pip
pip install aliyun-python-sdk-core aliyun-python-sdk-ecs aliyun-python-sdk-bssopenapi requests python-telegram-bot==13.15

echo "⏱️ 4. 正在自动生成并配置最新的系统常驻服务 (traffic-control.service)..."
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

echo "⏱️ 5. 正在自动配置新版带有 --cron 参数的每分钟定时流控检查..."
(crontab -l 2>/dev/null | grep -v "traffic_control" ; echo "* * * * * /root/aliyun-cdt-traffic-control/venv/bin/python /root/aliyun-cdt-traffic-control/traffic_control.py --cron >> /root/aliyun-cdt-traffic-control/cron_run.log 2>&1") | crontab -

echo "⏱️ 6. 正在刷新系统服务并拉起全新的机器人程序..."
systemctl daemon-reload
systemctl enable traffic-control.service
systemctl start traffic-control.service

echo "===================================================================="
echo "🟢 恭喜！全新的 CDT 流量控制系统与 TG 常驻机器人已全部部署完毕。"
echo "📂 代码与运行环境路径: $TARGET_DIR"
echo "🔍 你可以使用命令查看机器人状态: systemctl status traffic-control.service"
echo "===================================================================="
