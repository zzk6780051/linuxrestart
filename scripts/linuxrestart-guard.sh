#!/usr/bin/env bash
#
# linuxrestart-guard —— 每 30 分钟运行一次（cron），做两件事：
#   1) 检查本机（NAS）状态：负载 / 内存 / 磁盘 / 温度 / 关键端口，把结果作为 id=1
#      的通知写入 notify 仓库的 data.json（NOTIFY_ENABLED=1 时），供「实时通知中心」展示；
#   2) 检查 GitHub 仓库中的 state.json：power = true 时先把状态写回 false（记录
#      last_reboot_at），校验通过后再重启本机。
#
# 关键设计：一定先写回 false 并校验成功，才执行重启，避免重启后状态仍是 true
# 造成无限重启循环。写回失败时宁可放弃本次重启。
#
# 用法：
#   linuxrestart-guard             正常检查（cron 调用）
#   linuxrestart-guard --check     只做 NAS 健康检查/上报
#   linuxrestart-guard --dry-run   只做检查/写回，不真正重启（也不上报通知）
#   linuxrestart-guard --status    只打印当前状态
#   linuxrestart-guard --boot      开机后（@reboot）先等待网络就绪，再跑一次 --check（失败自动重试）
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

# ---- NAS 健康检查 / 通知（notify 仓库）配置 ----
NOTIFY_ENABLED="${NOTIFY_ENABLED:-1}"
NOTIFY_REPO="${NOTIFY_REPO:-zzk6780051/notify}"
NOTIFY_BRANCH="${NOTIFY_BRANCH:-main}"
NOTIFY_PATH="${NOTIFY_PATH:-data.json}"
NOTIFY_TOKEN="${NOTIFY_TOKEN:-${GITHUB_TOKEN:-}}"
NAS_NAME="${NAS_NAME:-$(hostname 2>/dev/null || echo NAS)}"
CHECK_MOUNTS="${CHECK_MOUNTS:-/,/vol1}"
CHECK_PORTS="${CHECK_PORTS:-22:SSH,2298:DSH,5667:fnOS}"
DISK_WARN_PCT="${DISK_WARN_PCT:-90}"
MEM_WARN_PCT="${MEM_WARN_PCT:-95}"
NOTIFY_ID="${NOTIFY_ID:-1}"

# ---- 开机检查（@reboot 时运行 --boot）----
BOOT_WAIT="${BOOT_WAIT:-30}"          # 开机后等待网络就绪的秒数
BOOT_RETRIES="${BOOT_RETRIES:-5}"     # 检查失败的重试次数
BOOT_RETRY_WAIT="${BOOT_RETRY_WAIT:-60}"  # 每次重试间隔秒数
BOOT_MAX_WAIT="${BOOT_MAX_WAIT:-300}"      # 开机后等待关键端口就绪的最长秒数

MODE="run"
for arg in "$@"; do
  case "$arg" in
    --status | -s) MODE="status" ;;
    --check | -c) MODE="check" ;;
    --boot | -b) MODE="boot" ;;
    --dry-run | -n) DRY_RUN=1 ;;
    --help | -h)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "未知参数: $arg" >&2
      exit 64
      ;;
  esac
done

now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
now_beijing() { TZ='Asia/Shanghai' date '+%Y-%m-%dT%H:%M:%S'; }

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
TMP_BODY="$(mktemp)" || exit 1
cleanup_tmp() {
  rm -f "$TMP_BODY"
}
trap cleanup_tmp EXIT

if [ "$MODE" != "status" ] && [ "$MODE" != "boot" ]; then
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
NOTIFY_URL="$API_BASE/repos/$NOTIFY_REPO/contents/$NOTIFY_PATH"

curl_api_as() { # <token> <method> <url> [json-body]
  local token="$1" method="$2" url="$3" data="${4:-}"
  local args=(
    -sS --max-time "$CURL_MAX_TIME"
    -o "$TMP_BODY" -w '%{http_code}'
    -X "$method"
    -H "Authorization: Bearer $token"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
    -H "User-Agent: linuxrestart-guard"
  )
  if [ -n "$data" ]; then
    args+=(-H "Content-Type: application/json" --data-binary "$data")
  fi
  curl "${args[@]}" "$url"
}
curl_api() { curl_api_as "$GITHUB_TOKEN" "$@"; }

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

# ---------------- NAS 健康检查 ----------------

port_open() { # <port>
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

fmt_uptime() { # <seconds>
  local s="$1" d h m
  d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%d天%d小时%d分' "$d" "$h" "$m"
  else printf '%d小时%d分' "$h" "$m"; fi
}

# 收集本机状态，填充 NAS_OK / NAS_TITLE / NAS_CONTENT / NAS_SUMMARY
nas_check() {
  local ts uptime_s uptime_txt load1 load5 load15
  local mem_total_kb mem_avail_kb mem_used_mb mem_total_mb mem_pct
  local disk_text="" bad_disk="" m pct
  local temp_text="未知" temp_c="" temp_milli
  local svc_text="" svc_ok=0 svc_total=0 bad_svc=""
  local problems=""

  ts="$(now_beijing)"
  uptime_s="$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
  uptime_txt="$(fmt_uptime "${uptime_s:-0}")"

  read -r load1 load5 load15 _ < /proc/loadavg
  load15="${load15:-0}"

  mem_total_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  mem_total_kb="${mem_total_kb:-0}"; mem_avail_kb="${mem_avail_kb:-0}"
  if [ "$mem_total_kb" -gt 0 ]; then
    mem_used_mb=$(((mem_total_kb - mem_avail_kb) / 1024))
    mem_total_mb=$((mem_total_kb / 1024))
    mem_pct=$(((mem_total_kb - mem_avail_kb) * 100 / mem_total_kb))
  else
    mem_used_mb=0; mem_total_mb=0; mem_pct=0
  fi

  IFS=',' read -r -a _mounts <<<"$CHECK_MOUNTS"
  for m in "${_mounts[@]}"; do
    [ -n "$m" ] || continue
    pct="$(df -P "$m" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
    if [ -z "$pct" ]; then
      disk_text+="${disk_text:+ ｜ }$m 不可用"
      bad_disk+="${bad_disk:+, }$m 不可用"
      continue
    fi
    disk_text+="${disk_text:+ ｜ }$m ${pct}%"
    if [ "$pct" -ge "$DISK_WARN_PCT" ]; then
      bad_disk+="${bad_disk:+, }$m ${pct}%"
    fi
  done

  if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
    temp_milli="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
    if [ -n "$temp_milli" ]; then
      temp_c="$(awk -v t="$temp_milli" 'BEGIN {printf "%.1f", t/1000}')"
      temp_text="${temp_c}°C"
    fi
  fi

  IFS=',' read -r -a _ports <<<"$CHECK_PORTS"
  for p in "${_ports[@]}"; do
    [ -n "$p" ] || continue
    local svc_port="${p%%:*}" svc_name="${p#*:}"
    [ "$svc_name" = "$p" ] && svc_name="port-$svc_port"
    svc_total=$((svc_total + 1))
    if port_open "$svc_port"; then
      svc_ok=$((svc_ok + 1))
      svc_text+="✅ ${svc_name}(${svc_port})<br>"
    else
      svc_text+="❌ ${svc_name}(${svc_port}) 不可达<br>"
      bad_svc+="${bad_svc:+, }${svc_name}(${svc_port})"
    fi
  done

  NAS_SUMMARY="services=${svc_ok}/${svc_total} mem=${mem_pct}% disks=${disk_text// ｜ /, }"

  [ -n "$bad_disk" ] && problems+="磁盘占用超过 ${DISK_WARN_PCT}%: ${bad_disk}<br>"
  [ "$mem_pct" -ge "$MEM_WARN_PCT" ] && problems+="内存占用 ${mem_pct}%（超过 ${MEM_WARN_PCT}%）<br>"
  [ -n "$bad_svc" ] && problems+="端口不可达: ${bad_svc}<br>"

  NAS_CONTENT="🖥️ ${NAS_NAME} 状态上报 · ${ts}<br><br>"
  NAS_CONTENT+="⏱ 运行时间: ${uptime_txt}<br>"
  NAS_CONTENT+="📈 负载: ${load1} / ${load5} / ${load15}（1/5/15 分钟）<br>"
  NAS_CONTENT+="🧠 内存: ${mem_used_mb}MB / ${mem_total_mb}MB（${mem_pct}%）<br>"
  NAS_CONTENT+="💾 磁盘: ${disk_text:-未知}<br>"
  NAS_CONTENT+="🌡 温度: ${temp_text}<br><br>"
  NAS_CONTENT+="🔌 服务检查:<br>${svc_text}"

  if [ -n "$problems" ]; then
    NAS_OK=0
    NAS_TITLE="🔴 NAS 状态异常"
    NAS_CONTENT+="<br>⚠️ 异常项:<br>${problems}"
  else
    NAS_OK=1
    NAS_TITLE="🟢 NAS 在线正常"
  fi
  [ "$MODE" = "status" ] || log "NAS 检查完成: ok=${NAS_OK} ${NAS_SUMMARY}"
}

# 读取通知仓库 data.json，填充 NOTIFY_JSON / NOTIFY_SHA
fetch_notify() {
  local code b64
  code="$(curl_api_as "$NOTIFY_TOKEN" GET "$NOTIFY_URL?ref=$NOTIFY_BRANCH")" || {
    log "ERROR: GET 通知仓库失败（网络不可达）"
    return 3
  }
  case "$code" in
    200) ;;
    *)
      log "ERROR: GET $NOTIFY_REPO/$NOTIFY_PATH HTTP $code: $(head -c 300 "$TMP_BODY" 2>/dev/null)"
      return 4
      ;;
  esac
  NOTIFY_SHA="$(jq -r '.sha // empty' "$TMP_BODY")" || return 4
  b64="$(jq -r '.content // empty' "$TMP_BODY")"
  NOTIFY_JSON="$(printf '%s' "$b64" | tr -d '\n' | base64 -d 2>/dev/null)" || {
    log "ERROR: 通知 data.json base64 解码失败"
    return 4
  }
  if ! printf '%s' "$NOTIFY_JSON" | jq -e '.notifications' >/dev/null 2>&1; then
    log "ERROR: 通知 data.json 结构异常（缺少 notifications）"
    return 4
  fi
  return 0
}

# 把通知 id=NOTIFY_ID 更新为指定标题/内容；成功返回 0
notify_upsert() { # <title> <content>
  local title="$1" content="$2" attempt code payload new_json new_b64 ts
  [ "$NOTIFY_ENABLED" = "1" ] || {
    log "NOTIFY_ENABLED=0，跳过通知上报"
    return 0
  }
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1，跳过通知上报（$title）"
    return 0
  fi
  ts="$(now_beijing)"
  for attempt in 1 2 3; do
    if ! fetch_notify; then
      return 1
    fi
    new_json="$(printf '%s' "$NOTIFY_JSON" | jq -c \
      --arg t "$title" --arg c "$content" --arg d "$ts" --argjson nid "$NOTIFY_ID" '
        .notifications = ((.notifications // []) |
          if any(.[]; .id == $nid) then
            map(if .id == $nid then (.title = $t | .content = $c | .date = $d) else . end)
          else
            . + [{id: $nid, title: $t, content: $c, date: $d}]
          end)')" || {
      log "ERROR: 生成通知数据失败（jq）"
      return 1
    }
    new_b64="$(printf '%s' "$new_json" | base64 -w0)"
    payload="$(jq -n -c \
      --arg message "🤖 NAS 定时上报: $title" \
      --arg content "$new_b64" \
      --arg sha "$NOTIFY_SHA" \
      --arg branch "$NOTIFY_BRANCH" \
      '{message: $message, content: $content, sha: $sha, branch: $branch}')"
    code="$(curl_api_as "$NOTIFY_TOKEN" PUT "$NOTIFY_URL" "$payload")" || {
      log "ERROR: PUT 通知失败（网络不可达）"
      continue
    }
    if [ "$code" = "200" ] || [ "$code" = "201" ]; then
      # 重新 GET 校验标题已更新
      if fetch_notify && printf '%s' "$NOTIFY_JSON" | jq -e --arg t "$title" --argjson nid "$NOTIFY_ID" \
        'any(.notifications[]?; (.id == $nid and .title == $t))' >/dev/null 2>&1; then
        log "已上报 NAS 状态到 $NOTIFY_REPO（$title）"
        return 0
      fi
      log "ERROR: 通知上报后校验失败"
      return 1
    fi
    if [ "$code" = "409" ] || [ "$code" = "422" ]; then
      log "WARN: 通知写入冲突 HTTP $code，重试 ($attempt/3)"
      sleep "$((attempt * 2))"
      continue
    fi
    log "ERROR: PUT 通知 HTTP $code: $(head -c 300 "$TMP_BODY" 2>/dev/null)"
    return 1
  done
  log "ERROR: 多次重试后仍无法上报通知"
  return 1
}

notify_reboot() {
  notify_upsert "🔄 NAS 即将重启" \
    "🔄 收到远程重启指令 · $(now_beijing)<br><br>已从 GitHub 读取到 power=true 并写回 false，机器将在几秒内重启。<br>🔄 重启计划: 已触发 — 本机马上重启<br><br>重启完成后，下一轮整点检查会自动上报「🟢 NAS 在线正常」。<br><br>🤖 由 NAS 定时任务上报" ||
    log "WARN: 重启前通知上报失败（不影响重启）"
}

NAS_OK=1
NAS_TITLE=""
NAS_CONTENT=""
NAS_SUMMARY=""
POWER="unknown"
UPDATED="-"
LAST_REBOOT="-"

# 下一次检查时间：cron 在 :00 和 :30 触发
next_check_time() {
  local hh mm
  hh="$(date '+%H')"
  mm="$(date '+%M')"
  if [ "$((10#$mm))" -lt 30 ]; then
    printf '%s:30' "$hh"
  else
    printf '%02d:00' "$(((10#$hh + 1) % 24))"
  fi
}

# 重启计划行：根据 state.json 的 power 生成提示，并附下次检查时间
build_reboot_plan() {
  case "$POWER" in
    true) REBOOT_PLAN_LINE="🔄 重启计划: 已开启 — 本机将在本轮检查中重启（约 1 小时内）" ;;
    false) REBOOT_PLAN_LINE="⏸️ 重启计划: 未开启 — 不会重启" ;;
    *) REBOOT_PLAN_LINE="❔ 重启计划: 未知 — 读取 state.json 失败" ;;
  esac
  local next_check
  next_check="$(next_check_time)"
  REBOOT_PLAN_LINE+="<br>⏰ 下次检查: ${next_check}（每 30 分钟）"
}

plan_plain() { printf '%s' "$REBOOT_PLAN_LINE" | sed 's/<br>/ ／ /g'; }

# ---------------- 开机检查（每次重启后自动跑一次）----------------
# cron @reboot 调用 --boot：等网络和关键端口就绪后再上报一次 --check，
# 避免开机瞬间服务还没起来就误报「NAS 状态异常」；上报失败会重试。
if [ "$MODE" = "boot" ]; then
  log "开机检查：等待 ${BOOT_WAIT}s 让网络就绪"
  sleep "$BOOT_WAIT"

  log "开机检查：等待关键端口就绪（最多 ${BOOT_MAX_WAIT}s）"
  ready=0
  deadline=$((SECONDS + BOOT_MAX_WAIT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    ready=1
    IFS=',' read -r -a boot_specs <<<"$CHECK_PORTS"
    for boot_spec in "${boot_specs[@]}"; do
      [ -z "$boot_spec" ] && continue
      if ! port_open "${boot_spec%%:*}"; then
        ready=0
        break
      fi
    done
    [ "$ready" = "1" ] && break
    sleep 5
  done
  if [ "$ready" = "1" ]; then
    log "开机检查：端口已就绪"
  else
    log "WARN: 等待端口超时，仍按当前状态上报"
  fi

  attempt=0
  while [ "$attempt" -lt "$BOOT_RETRIES" ]; do
    attempt=$((attempt + 1))
    log "开机检查：第 ${attempt}/${BOOT_RETRIES} 次上报"
    if "$0" --check >>"$LOG_FILE" 2>&1; then
      log "开机检查完成（第 ${attempt} 次）"
      exit 0
    fi
    if [ "$attempt" -lt "$BOOT_RETRIES" ]; then
      log "开机检查失败，${BOOT_RETRY_WAIT}s 后重试"
      sleep "$BOOT_RETRY_WAIT"
    fi
  done
  log "WARN: 开机检查多次失败，放弃（下一次整点 cron 检查仍会执行）"
  exit 0
fi

# ---------------- 主流程 ----------------

# 1) NAS 健康检查（本地采集）
nas_check

# 2) 读取重启开关状态（读取失败时仍会上报 NAS 状态）
if fetch_state; then
  POWER="$(printf '%s' "$STATE_JSON" | jq -r 'if .power == true then "true" else "false" end')"
  UPDATED="$(printf '%s' "$STATE_JSON" | jq -r '.updated_at // "-"')"
  LAST_REBOOT="$(printf '%s' "$STATE_JSON" | jq -r '.last_reboot_at // "-"')"
else
  log "WARN: 读取 state.json 失败，本次不做重启判断"
fi

build_reboot_plan
NAS_CONTENT+="<br>${REBOOT_PLAN_LINE}<br>🤖 由 NAS 定时任务每 30 分钟自动上报"

if [ "$MODE" = "check" ]; then
  printf 'nas     : %s\n' "$([ "$NAS_OK" = "1" ] && echo ok || echo failed)"
  printf 'detail  : %s\n' "$NAS_SUMMARY"
  printf 'title   : %s\n' "$NAS_TITLE"
  printf 'plan    : %s\n' "$(plan_plain)"
  printf 'notify  : %s\n' "$([ "$NOTIFY_ENABLED" = "1" ] && echo "on ($NOTIFY_REPO)" || echo off)"
  if [ "$NOTIFY_ENABLED" = "1" ] && [ "$DRY_RUN" != "1" ]; then
    if notify_upsert "$NAS_TITLE" "$NAS_CONTENT"; then
      printf '上报    : ok\n'
      exit 0
    fi
    printf '上报    : failed\n'
    exit 1
  fi
  printf '上报    : skipped（DRY_RUN=1 或 NOTIFY_ENABLED=0）\n'
  exit 0
fi

if [ "$MODE" = "status" ]; then
  printf 'repo    : %s (%s)\n' "$GITHUB_REPO" "$BRANCH"
  printf 'power   : %s\n' "$POWER"
  printf 'plan    : %s\n' "$(plan_plain)"
  printf 'updated : %s\n' "$UPDATED"
  printf 'reboot  : %s\n' "$LAST_REBOOT"
  printf 'dry_run : %s\n' "$DRY_RUN"
  printf 'notify  : %s\n' "$([ "$NOTIFY_ENABLED" = "1" ] && echo "$NOTIFY_REPO ($NOTIFY_PATH)" || echo disabled)"
  printf 'nas     : %s\n' "$([ "$NAS_OK" = "1" ] && echo ok || echo failed)"
  exit 0
fi

# 3) 需要重启：先写回，再上报，最后重启
if [ "$POWER" = "true" ]; then
  log "检测到 power=true（updated_at=$UPDATED），开始写回关闭状态"
  if ! write_off; then
    log "写回失败，本次不重启；状态保持 power=true，等待下一轮检查"
    log "state=power 未变，上报 NAS 状态（含重启计划）"
    notify_upsert "$NAS_TITLE" "$NAS_CONTENT" || log "WARN: NAS 状态上报失败（不影响主流程）"
    exit 1
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1，跳过实际重启"
    exit 0
  fi

  notify_reboot

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
fi

# 4) 状态为关闭/未知：正常上报 NAS 状态（含是否将会重启）
log "state=${POWER}（updated_at=$UPDATED），上报 NAS 状态"
notify_upsert "$NAS_TITLE" "$NAS_CONTENT" || log "WARN: NAS 状态上报失败（不影响主流程）"
exit 0
