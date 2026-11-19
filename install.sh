#!/usr/bin/env bash
#
# linuxrestart 一键安装 / 重装脚本
#
# 作用（可重复执行，幂等）：
#   1. 备份现有安装（脚本、配置、cron）到 /etc/linuxrestart/backups/
#   2. 安装守护脚本到 /usr/local/sbin/linuxrestart-guard
#   3. 初始化（或保留）配置 /etc/linuxrestart/linuxrestart.env（600，仅 root）
#   4. 安装 cron：每 30 分钟检查 + 每次开机检查
#   5. 可选：写入 GitHub Token、运行自检
#   6. 校验安装结果并打印摘要
#
# 用法：
#   sudo bash /vol2/1000/应用/应用/install.sh
#   sudo bash /vol2/1000/应用/应用/install.sh --token <GitHub PAT>
#   sudo bash /vol2/1000/应用/应用/install.sh --skip-test     # 跳过自检
#
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$SELF")" && pwd)"
LOW_LEVEL="$REPO_DIR/scripts/install.sh"
GUARD_SRC="$REPO_DIR/scripts/linuxrestart-guard.sh"
GUARD_DST="/usr/local/sbin/linuxrestart-guard"
ENV_DIR="/etc/linuxrestart"
ENV_FILE="$ENV_DIR/linuxrestart.env"
BACKUP_DIR="$ENV_DIR/backups"
CRON_FILE="/etc/cron.d/linuxrestart"
BOOT_CRON_FILE="/etc/cron.d/linuxrestart-boot"
LOG_FILE="/var/log/linuxrestart.log"

TOKEN=""
SKIP_TEST=0
ORIG_ARGS=("$@")

usage() {
  sed -n '3,18p' "$SELF" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --token) TOKEN="${2:-}"; shift 2 ;;
    --token=*) TOKEN="${1#*=}"; shift ;;
    --skip-test) SKIP_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1（用 --help 查看用法）" >&2; exit 64 ;;
  esac
done

# ---- root 检查（可自动 sudo 提权）----
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "==> 需要 root 权限，改用 sudo 重新执行"
    exec sudo -E bash "$SELF" "${ORIG_ARGS[@]}"
  fi
  echo "请用 root 运行： sudo bash $SELF" >&2
  exit 1
fi

[ -f "$GUARD_SRC" ] || { echo "错误：缺少 $GUARD_SRC" >&2; exit 1; }
[ -f "$LOW_LEVEL" ] || { echo "错误：缺少 $LOW_LEVEL" >&2; exit 1; }

# ---- 备份现有安装 ----
TS="$(date '+%Y%m%d-%H%M%S')"
install -d -m 700 "$BACKUP_DIR"
backup_file() {
  [ -f "$1" ] || return 0
  cp -a "$1" "$BACKUP_DIR/$(basename "$1").$TS"
  chmod 600 "$BACKUP_DIR/$(basename "$1").$TS" 2>/dev/null || true
}
echo "==> 备份现有安装到 $BACKUP_DIR（$TS）"
backup_file "$GUARD_DST"
backup_file "$ENV_FILE"
backup_file "$CRON_FILE"
backup_file "$BOOT_CRON_FILE"
# 只保留最近 10 组备份
ls -1t "$BACKUP_DIR"/* 2>/dev/null | tail -n +21 | xargs -r rm -f

# ---- 安装（复用 scripts/install.sh）----
echo
echo "==> 安装守护脚本、配置、cron、日志"
bash "$LOW_LEVEL"

# ---- Token：--token 优先；否则配置里为空且是终端时提示输入 ----
set_token() {
  local tk="$1"
  awk -v tok="$tk" '
    BEGIN { done = 0 }
    /^GITHUB_TOKEN=/ { print "GITHUB_TOKEN=" tok; done = 1; next }
    { print }
    END { if (!done) print "GITHUB_TOKEN=" tok }
  ' "$ENV_FILE" >"$ENV_FILE.tmp"
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

current_token() {
  sed -n 's/^GITHUB_TOKEN=//p' "$ENV_FILE" 2>/dev/null | head -n1
}

if [ -n "$TOKEN" ]; then
  echo "==> 写入 GITHUB_TOKEN（来自 --token）"
  set_token "$TOKEN"
elif [ -z "$(current_token)" ]; then
  if [ -t 0 ]; then
    printf '请输入 GitHub Token（Contents: Read and write，留空跳过）: '
    read -rs token_input
    echo
    if [ -n "$token_input" ]; then
      echo "==> 写入 GITHUB_TOKEN（来自交互输入）"
      set_token "$token_input"
    else
      echo "    跳过：未输入 Token"
    fi
  else
    echo "    提示：未配置 GITHUB_TOKEN，安装完成后请编辑 $ENV_FILE 填入"
  fi
else
  echo "==> 已存在 GITHUB_TOKEN，保持不动"
fi

# ---- 校验安装 ----
echo
echo "==> 校验安装"
src_md5="$(md5sum "$GUARD_SRC" | cut -d' ' -f1)"
dst_md5="$(md5sum "$GUARD_DST" | cut -d' ' -f1)"
if [ "$src_md5" != "$dst_md5" ]; then
  echo "错误：安装副本与仓库脚本不一致（$dst_md5 != $src_md5）" >&2
  exit 1
fi
echo "    守护脚本一致：$dst_md5"
bash -n "$GUARD_DST" && echo "    语法检查通过"
grep -q '^\*/30 \* \* \* \* root /usr/local/sbin/linuxrestart-guard' "$CRON_FILE" \
  && echo "    cron 已配置：每 30 分钟（:00 / :30）"
grep -q '^@reboot root /usr/local/sbin/linuxrestart-guard --boot' "$BOOT_CRON_FILE" \
  && echo "    cron 已配置：开机检查（@reboot）"
[ -f "$LOG_FILE" ] && echo "    日志文件：$LOG_FILE"
if [ -n "$(current_token)" ]; then
  echo "    配置检查："
  "$GUARD_DST" --status | sed 's/^/      /' || true
else
  echo "    跳过状态检查：未配置 GITHUB_TOKEN"
fi

# ---- 可选自检 ----
if [ "$SKIP_TEST" -eq 0 ]; then
  echo
  if command -v node >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    echo "==> 运行自检（可用 --skip-test 跳过）"
    if bash "$REPO_DIR/scripts/test-guard.sh" >/tmp/linuxrestart-test-guard.log 2>&1; then
      echo "    $(tail -n1 /tmp/linuxrestart-test-guard.log)"
    else
      echo "    警告：test-guard.sh 未通过，详见 /tmp/linuxrestart-test-guard.log" >&2
    fi
    if node "$REPO_DIR/scripts/test-api.mjs" >/tmp/linuxrestart-test-api.log 2>&1; then
      echo "    $(tail -n1 /tmp/linuxrestart-test-api.log)"
    else
      echo "    警告：test-api.mjs 未通过，详见 /tmp/linuxrestart-test-api.log" >&2
    fi
  else
    echo "==> 跳过自检（未找到 node / python3）"
  fi
fi

# ---- 摘要 ----
echo
echo "========== 安装完成 =========="
echo "守护脚本 : $GUARD_DST"
echo "配置文件 : $ENV_FILE"
echo "日志文件 : $LOG_FILE"
echo "cron     : 每 30 分钟整点（:00 / :30）检查；每次开机后检查一次"
echo "备份目录 : $BACKUP_DIR"
echo
echo "常驻命令："
echo "  $GUARD_DST --status    # 查看状态（含重启计划、下次检查时间）"
echo "  $GUARD_DST --check     # 立即做一次 NAS 检查并上报 notify"
echo "  $GUARD_DST --boot      # 模拟开机检查（会等待服务就绪）"
echo "  $GUARD_DST --dry-run   # 只写回不重启（联调用）"
echo
if [ -z "$(current_token)" ]; then
  echo "⚠ 还差一步：编辑 $ENV_FILE 填入 GITHUB_TOKEN，再执行 $GUARD_DST --check 验证"
else
  echo "✓ GITHUB_TOKEN 已配置。网页开关打开后，最长 30 分钟内本机重启。"
fi
