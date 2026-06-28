# aliyun-traffic-control fixed

这是按你的需求修改后的版本。

## 改动

1. 流量熔断关机通知只发一次，不再每分钟重复刷屏。
2. 关机通知增加“下次自动检测开机时间”：下个月 1 号 00:05:00 UTC+8。
3. 因流量熔断关机后，不会马上保活开机；必须等每月 1 号 00:05 UTC+8 以后，并且 CDT 流量低于阈值，例如 180GB，才自动开机。
4. 每日报告固定按北京时间 UTC+8 判断，不依赖 VPS 系统时区或 crontab 时区。
5. 安装脚本只保留每分钟 `--cron`，日报由 Python 内部按北京时间触发。
6. `cdt` 菜单增加查看系统时间和查看通知状态文件。

## 一键安装

把这些文件上传到 GitHub 原仓库 main 分支后，执行：

```bash
curl -sSL https://raw.githubusercontent.com/kingsnakerrr/aliyun-traffic-control/refs/heads/main/install.sh -o install.sh && bash install.sh
```

安装时可输入账号显示名称和每日报告推送时间。日报时间固定按 UTC+8 / 北京时间计算。

安装后输入：

```bash
cdt
```

## 重要说明

如果你是覆盖旧版本，建议重新执行安装脚本。旧的 crontab 里如果有 `--report`，新安装脚本会自动清掉，只保留每分钟 `--cron`。
