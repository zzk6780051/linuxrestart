#!/usr/bin/env bash
#
# linuxrestart-guard —— 每 2 小时检查 GitHub 仓库中的 state.json：
#   power = true  ->  先把状态写回 false（记录 last_reboot_at），再重启本机；
#   power = false ->  什么也不做。
#
# 关键设计：一定先写回 false 并校验成功，才执行重启，避免重启后状态仍是 true
# 造成无限重启循环。写回失败时宁可放弃本次重启。
#
# 用法：
#   linuxrestart-guard             正常检查（cron 调用）
#   linuxrestart-guard --dry-run   只做检查/写回，不真正重启
#   linuxrestart-guard --status    只打印当前状态
#
set -uo pipefail

ENV_FILE="${LINUXRESTART_ENV:-/etc/linuxrestart/linuxrestart.env}"
if [ -r "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  . "$ENV_FILE"
fi

LOG_FILE="${LOG_FILE:-/var/log/linuxrestart.log}"
LOCK_FILE="${LOCK_FILE:-/run/linuxrestart.lock}"
API_BASE="${API_BASE:-https://api.github.com}"
GITHUB_REPO="${GITHUB_REPO:-zzk6780051/linuxrestart}"
BRANCH="${BRANCH:-main}"
STATE_PATH="${STATE_PATH:-state.json}"
REBOOT_CMD="${REBOOT_CMD:-/sbin/reboot}"
DRY_RUN="${DRY_RUN:-0}"
CURL_MAX_TIME="${CURL_MAX_TIME:-20}"

MODE="run"
for arg in "$@"; do
  case "$arg" in
    --status | -s) MODE="status" ;;
    --dry-run | -n) DRY_RUN=1 ;;
    --help | -h)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "未知参数: $arg" >&2
      exit 64
      ;;
  esac
done

now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

if [ "$MODE" = "status" ]; then
  log() { printf '%s\n' "$*"; }
else
  # shellcheck disable=SC2317
  log() {
    printf '%s %s\n' "$(date '+%F %T%z')" "$*" >>"$LOG_FILE" 2>/dev/null || true
  }
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  if [ "$MODE" = "status" ]; then
    echo "GITHUB_TOKEN 未配置（$ENV_FILE）" >&2
    exit 2
  fi
  log "skip: GITHUB_TOKEN 未配置"
  exit 0
fi

if [ "$MODE" = "run" ]; then
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  # 日志超过 512KB 时滚动一份，避免无限增长
  if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 524288 ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
  fi
  exec 9>"$LOCK_FILE" 2>/dev/null || {
    log "跳过：无法打开锁文件 $LOCK_FILE"
    exit 0
  }
  if ! flock -n 9; then
    log "跳过：已有实例在运行"
    exit 0
  fi
fi

STATE_URL="$API_BASE/repos/$GITHUB_REPO/contents/$STATE_PATH"
TMP_BODY="$(mktemp)" || exit 1
trap 'rm -f "$TMP_BODY"' EXIT

STATE_JSON="{}"
STATE_SHA=""

curl_api() { # <method> <url> [json-body]
  local method="$1" url="$2" data="${3:-}"
  local args=(
    -sS --max-time "$CURL_MAX_TIME"
    -o "$TMP_BODY" -w '%{http_code}'
    -X "$method"
    -H "Authorization: Bearer $GITHUB_TOKEN"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
    -H "User-Agent: linuxrestart-guard"
  )
  if [ -n "$data" ]; then
    args+=(-H "Content-Type: application/json" --data-binary "$data")
  fi
  curl "${args[@]}" "$url"
}

# 读取当前状态，成功时填充 STATE_JSON / STATE_SHA
fetch_state() {
  local code b64
  code="$(curl_api GET "$STATE_URL?ref=$BRANCH")" || {
    log "ERROR: GET 请求失败（网络不可达）"
    return 3
  }
  case "$code" in
    200) ;;
    404)
      STATE_JSON='{}'
      STATE_SHA=''
      log "state.json 不存在，按关闭处理"
      return 0
      ;;
    *)
      log "ERROR: GET state HTTP $code: $(head -c 300 "$TMP_BODY" 2>/dev/null)"
      return 4
      ;;
  esac
  STATE_SHA="$(jq -r '.sha // empty' "$TMP_BODY")" || return 4
  b64="$(jq -r '.content // empty' "$TMP_BODY")"
  if [ -n "$b64" ]; then
    STATE_JSON="$(printf '%s' "$b64" | tr -d '\n' | base64 -d 2>/dev/null)" || {
      log "ERROR: state.json base64 解码失败"
      return 4
    }
  fi
  [ -n "$STATE_JSON" ] || STATE_JSON='{}'
  if ! printf '%s' "$STATE_JSON" | jq -e . >/dev/null 2>&1; then
    log "ERROR: state.json 不是合法 JSON，放弃处理"
    return 4
  fi
  return 0
}

# 把 power 置为 false 写回仓库；成功返回 0
write_off() {
  local attempt code payload new_json new_b64
  local ts; ts="$(now_iso)"
  for attempt in 1 2 3; do
    if ! fetch_state; then
      return 1
    fi
    local last_at="" actor="cron"
    if [ "$DRY_RUN" = "1" ]; then actor="cron-dry-run"; else last_at="$ts"; fi
    new_json="$(printf '%s' "$STATE_JSON" | jq -c --arg ts "$ts" --arg last "$last_at" --arg who "$actor" \
      '. + {power: false, updated_at: $ts, updated_by: $who, last_reboot_at: (if $last == "" then null else $last end)}')" || {
      log "ERROR: 生成新状态失败"
      return 1
    }
    new_b64="$(printf '%s' "$new_json" | base64 -w0)"
    payload="$(jq -n -c \
      --arg message "linuxrestart: $([ "$DRY_RUN" = "1" ] && echo dry-run || echo reboot) on $(hostname) at $ts" \
      --arg content "$new_b64" \
      --arg sha "$STATE_SHA" \
      --arg branch "$BRANCH" \
      '{message: $message, content: $content, branch: $branch} + (if $sha == "" then {} else {sha: $sha} end)')"
    code="$(curl_api PUT "$STATE_URL" "$payload")" || {
      log "ERROR: PUT 请求失败（网络不可达）"
      continue
    }
    if [ "$code" = "200" ] || [ "$code" = "201" ]; then
      local commit_sha
      commit_sha="$(jq -r '.commit.sha // "-"' "$TMP_BODY" 2>/dev/null)"
      # GitHub 的 PUT 响应里 content 对象不含文件内容，必须重新 GET 校验
      if fetch_state && [ "$(printf '%s' "$STATE_JSON" | jq -r 'if .power == true then "true" else "false" end' 2>/dev/null)" != "true" ]; then
        log "已将 state.json 的 power 写回 false 并校验通过（commit ${commit_sha:-unknown}）"
        return 0
      fi
      log "ERROR: 写回后校验失败，放弃重启"
      return 1
    fi
    if [ "$code" = "409" ] || [ "$code" = "422" ]; then
      log "WARN: 写入冲突 HTTP $code，重试 ($attempt/3)"
      sleep "$((attempt * 2))"
      continue
    fi
    log "ERROR: PUT state HTTP $code: $(head -c 300 "$TMP_BODY" 2>/dev/null)"
    return 1
  done
  log "ERROR: 多次重试后仍无法写回状态，放弃重启"
  return 1
}

if ! fetch_state; then
  exit 0
fi

POWER="$(printf '%s' "$STATE_JSON" | jq -r 'if .power == true then "true" else "false" end')"
UPDATED="$(printf '%s' "$STATE_JSON" | jq -r '.updated_at // "-"')"
LAST_REBOOT="$(printf '%s' "$STATE_JSON" | jq -r '.last_reboot_at // "-"')"

if [ "$MODE" = "status" ]; then
  printf 'repo    : %s (%s)\n' "$GITHUB_REPO" "$BRANCH"
  printf 'power   : %s\n' "$POWER"
  printf 'updated : %s\n' "$UPDATED"
  printf 'reboot  : %s\n' "$LAST_REBOOT"
  printf 'dry_run : %s\n' "$DRY_RUN"
  exit 0
fi

if [ "$POWER" != "true" ]; then
  log "state=off，无需操作（updated_at=$UPDATED）"
  exit 0
fi

log "检测到 power=true（updated_at=$UPDATED），开始写回关闭状态"
if ! write_off; then
  log "写回失败，本次不重启；状态保持 power=true，等待下一轮检查"
  exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1，跳过实际重启"
  exit 0
fi

log "准备重启：sync 后执行 $REBOOT_CMD"
sync
if [ -x "$REBOOT_CMD" ] || command -v "$REBOOT_CMD" >/dev/null 2>&1; then
  "$REBOOT_CMD" >>"$LOG_FILE" 2>&1 || {
    log "ERROR: 重启命令执行失败: $REBOOT_CMD"
    exit 1
  }
else
  log "ERROR: 重启命令不存在: $REBOOT_CMD"
  exit 1
fi

log "重启命令已提交"
exit 0
