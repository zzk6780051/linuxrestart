#!/usr/bin/env bash
#
# 在本机（NAS）安装 linuxrestart 定时任务（每小时执行一次）：
#   - /usr/local/sbin/linuxrestart-guard            守护脚本（重启检查 + NAS 状态上报）
#   - /etc/linuxrestart/linuxrestart.env            密钥与配置（600，root only）
#   - /etc/cron.d/linuxrestart                      每小时整点执行一次
#   - /etc/cron.d/linuxrestart-boot                 每次开机（@reboot）自动上报一次 NAS 状态
#
# 用法： sudo ./scripts/install.sh
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行： sudo $0" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD_SRC="$REPO_DIR/scripts/linuxrestart-guard.sh"
GUARD_DST="/usr/local/sbin/linuxrestart-guard"
ENV_DIR="/etc/linuxrestart"
ENV_FILE="$ENV_DIR/linuxrestart.env"
CRON_FILE="/etc/cron.d/linuxrestart"
BOOT_CRON_FILE="/etc/cron.d/linuxrestart-boot"

echo "==> 安装守护脚本到 $GUARD_DST"
install -d -m 755 /usr/local/sbin
install -m 755 "$GUARD_SRC" "$GUARD_DST"

echo "==> 准备配置目录 $ENV_DIR"
install -d -m 700 "$ENV_DIR"
if [ ! -f "$ENV_FILE" ]; then
  umask 077
  cat >"$ENV_FILE" <<'EOF'
# linuxrestart 守护脚本配置（仅 root 可读）
# GitHub fine-grained PAT：Repository permissions -> Contents: Read and write
GITHUB_TOKEN=
GITHUB_REPO=zzk6780051/linuxrestart
BRANCH=main
STATE_PATH=state.json
# 1 = 只写回状态不真重启（首次联调建议先设 1）
DRY_RUN=0
# 重启命令，默认 /sbin/reboot
REBOOT_CMD=/sbin/reboot

# ---- NAS 状态上报（notify 仓库）----
# 1 = 每小时把本机状态写入 notify 仓库 data.json 中 id=1 的通知
NOTIFY_ENABLED=1
NOTIFY_REPO=zzk6780051/notify
NOTIFY_BRANCH=main
NOTIFY_PATH=data.json
NOTIFY_ID=1
# 通知里显示的机器名（默认 hostname）
NAS_NAME=
# 检查的磁盘挂载点（逗号分隔）与占用告警阈值
CHECK_MOUNTS=/,/vol1
DISK_WARN_PCT=90
# 检查的端口（端口:名称，逗号分隔）
CHECK_PORTS=22:SSH,2298:DSH,5667:fnOS
MEM_WARN_PCT=95
# ---- 开机检查（@reboot）----
# 开机后等待网络就绪的秒数，及失败重试次数/间隔
BOOT_WAIT=30
BOOT_RETRIES=5
BOOT_RETRY_WAIT=60
# 开机后等待关键端口就绪的最长秒数（避免服务没起来就误报异常）
BOOT_MAX_WAIT=300
EOF
  chmod 600 "$ENV_FILE"
  echo "    已创建 $ENV_FILE（请填入 GITHUB_TOKEN）"
else
  chmod 600 "$ENV_FILE"
  echo "    已存在 $ENV_FILE，保持不动"
fi

echo "==> 安装 cron（每小时整点执行）"
cat >"$CRON_FILE" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 * * * * root /usr/local/sbin/linuxrestart-guard
EOF
chmod 644 "$CRON_FILE"

echo "==> 安装开机检查 cron（每次重启后自动上报一次）"
cat >"$BOOT_CRON_FILE" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
@reboot root /usr/local/sbin/linuxrestart-guard --boot
EOF
chmod 644 "$BOOT_CRON_FILE"

echo "==> 检查日志文件"
install -m 640 /dev/null /var/log/linuxrestart.log
if command -v logrotate >/dev/null 2>&1 && [ -d /etc/logrotate.d ]; then
  cat >/etc/logrotate.d/linuxrestart <<'EOF'
/var/log/linuxrestart.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    copytruncate
}
EOF
  chmod 644 /etc/logrotate.d/linuxrestart
  echo "    已安装 logrotate 配置"
fi

systemctl enable cron >/dev/null 2>&1 || true
systemctl restart cron 2>/dev/null || systemctl start cron 2>/dev/null || true

echo
echo "完成。下一步："
echo "  1) 编辑 $ENV_FILE 填入 GITHUB_TOKEN（Contents: Read and write）"
echo "  2) 联调： $GUARD_DST --status"
echo "  3) 联调： $GUARD_DST --check     （只做 NAS 检查/上报）"
echo "     联调： $GUARD_DST --boot      （模拟开机检查，会先等待 BOOT_WAIT 秒）"
echo "  4) 联调： $GUARD_DST --dry-run   （只写回不重启、不上报）"
echo "  5) 确认无误后把 DRY_RUN 改成 0，并触发一次真实测试"
