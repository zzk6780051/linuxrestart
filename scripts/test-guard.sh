#!/usr/bin/env bash
#
# 用本地 mock GitHub API 测试 linuxrestart-guard.sh（不会重启，也不会写真实仓库）。
# 运行： bash scripts/test-guard.sh
#
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_DIR/scripts/linuxrestart-guard.sh"
WORK="$(mktemp -d)"
PORT=$((20000 + RANDOM % 20000))
PASS=0

cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

cat >"$WORK/mock_github.py" <<'PY'
import base64, json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

RESULT = sys.argv[3]


def load(path, default_text):
    try:
        with open(path) as f:
            d = json.load(f)
        return {"sha": d.get("sha", "sha-1"), "text": d["text"]}
    except Exception:
        return {"sha": "sha-1", "text": default_text}


STATE = load(sys.argv[1], json.dumps({"power": True, "updated_at": "2026-01-01T00:00:00Z"}))
NOTIFY = load(
    sys.argv[2],
    json.dumps({"notifications": [{"id": 1, "title": "旧通知", "content": "x", "date": "2026-01-01T00:00:00"}]}),
)
PUTS = {"state": 0, "notify": 0}


def b64(s):
    return base64.b64encode(s.encode()).decode()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _target(self):
        path = self.path.split("?")[0]
        if path.endswith("/contents/state.json"):
            return "state"
        if path.endswith("/contents/data.json"):
            return "notify"
        return None

    def do_GET(self):
        key = self._target()
        if key is None:
            return self._send(404, {"message": "not found"})
        store = STATE if key == "state" else NOTIFY
        self._send(200, {"sha": store["sha"], "content": b64(store["text"])})

    def do_PUT(self):
        key = self._target()
        if key is None:
            return self._send(404, {"message": "not found"})
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n))
        store = STATE if key == "state" else NOTIFY
        if body.get("sha") != store["sha"]:
            return self._send(409, {"message": "sha mismatch"})
        store["text"] = base64.b64decode(body["content"]).decode()
        PUTS[key] += 1
        store["sha"] = "sha-%s-%d" % (key, PUTS[key])
        with open(RESULT, "w") as f:
            json.dump(
                {
                    "state": json.loads(STATE["text"]),
                    "notify": json.loads(NOTIFY["text"]),
                    "puts": dict(PUTS),
                },
                f,
                ensure_ascii=False,
            )
        # 模拟真实 GitHub PUT 响应：content 对象不含文件内容
        self._send(200, {"content": {"name": "x", "sha": store["sha"]}, "commit": {"sha": "c1"}})


HTTPServer(("127.0.0.1", int(sys.argv[4])), H).serve_forever()
PY

python3 "$WORK/mock_github.py" "$WORK/state.json" "$WORK/notify.json" "$WORK/result.json" "$PORT" &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/repos/o/r/contents/state.json" && break
  sleep 0.1
done

export GITHUB_TOKEN="mock"
export NOTIFY_TOKEN="mock"
export GITHUB_REPO="o/r"
export BRANCH="main"
export STATE_PATH="state.json"
export NOTIFY_REPO="o/notify"
export NOTIFY_BRANCH="main"
export NOTIFY_PATH="data.json"
export NOTIFY_ENABLED="1"
export NOTIFY_ID="1"
export API_BASE="http://127.0.0.1:$PORT"
export LOG_FILE="$WORK/guard.log"
export LOCK_FILE="$WORK/guard.lock"
export LINUXRESTART_ENV="$WORK/none.env"
export CHECK_MOUNTS="/"
export CHECK_PORTS="2298:DSH"

check() { # <desc> <condition...>
  local desc="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
    echo "  ok - $desc"
  else
    echo "  FAIL - $desc"
    FAILED=1
  fi
}

notify_put_count() { jq -r '.puts.notify // 0' "$WORK/result.json" 2>/dev/null || echo 0; }
state_put_count() { jq -r '.puts.state // 0' "$WORK/result.json" 2>/dev/null || echo 0; }

echo "1) --status"
out="$(DRY_RUN=0 bash "$GUARD" --status)"
echo "$out" | grep -q 'power   : true' && { PASS=$((PASS + 1)); echo "  ok - 状态读取 power=true"; } || { echo "  FAIL - 状态读取"; FAILED=1; }
echo "$out" | grep -q 'nas     : ok' && { PASS=$((PASS + 1)); echo "  ok - 显示 NAS 检查结果"; } || { echo "  FAIL - NAS 状态行"; FAILED=1; }

echo "2) --check：上报内容包含重启计划"
CHECK_PORTS="2298:DSH" DRY_RUN=0 bash "$GUARD" --check >"$WORK/check.out"
check "上报内容包含「重启计划: 已开启」" bash -c 'jq -r ".notify.notifications[] | select(.id==1) | .content" "$0" | grep -q "重启计划: 已开启"' "$WORK/result.json"
check "上报内容包含下次检查时间" bash -c 'jq -r ".notify.notifications[] | select(.id==1) | .content" "$0" | grep -q "下次检查"' "$WORK/result.json"

echo "3) --dry-run：写回 false 但不重启、不上报"
before_notify="$(notify_put_count)"
DRY_RUN=1 bash "$GUARD"
check "state.json 已写回 power=false" bash -c 'jq -e ".state.power == false" "$0" >/dev/null' "$WORK/result.json"
check "dry-run 不记录 last_reboot_at" bash -c 'jq -e ".state.last_reboot_at == null" "$0" >/dev/null' "$WORK/result.json"
check "updated_by=cron-dry-run" bash -c 'jq -e ".state.updated_by == \"cron-dry-run\"" "$0" >/dev/null' "$WORK/result.json"
check "日志包含 DRY_RUN 跳过" grep -q 'DRY_RUN=1' "$WORK/guard.log"
check "dry-run 不上报通知" test "$before_notify" = "$(notify_put_count)"

echo "4) state=off 时正常上报 NAS 在线状态"
before_state="$(state_put_count)"
DRY_RUN=0 bash "$GUARD"
check "不产生 state 写回" test "$before_state" = "$(state_put_count)"
check "通知 id=1 标题为在线正常" bash -c 'jq -e ".notify.notifications[] | select(.id==1) | .title == \"🟢 NAS 在线正常\"" "$0" >/dev/null' "$WORK/result.json"
check "通知日期为北京时间格式" bash -c 'jq -r ".notify.notifications[] | select(.id==1) | .date" "$0" | grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$"' "$WORK/result.json"
check "日志包含已上报" grep -q '已上报 NAS 状态' "$WORK/guard.log"
check "重启计划显示「未开启」" bash -c 'jq -r ".notify.notifications[] | select(.id==1) | .content" "$0" | grep -q "重启计划: 未开启"' "$WORK/result.json"

echo "5) --check 且端口不可达 -> 异常通知"
before_notify="$(notify_put_count)"
CHECK_PORTS="1:DeadPort" DRY_RUN=0 bash "$GUARD" --check >"$WORK/check.out"
check "上报次数 +1" test "$((before_notify + 1))" = "$(notify_put_count)"
check "标题为异常" bash -c 'jq -e ".notify.notifications[] | select(.id==1) | .title == \"🔴 NAS 状态异常\"" "$0" >/dev/null' "$WORK/result.json"
check "内容包含端口不可达" bash -c 'jq -r ".notify.notifications[] | select(.id==1) | .content" "$0" | grep -q "端口不可达"' "$WORK/result.json"

echo "6) NOTIFY_ENABLED=0 时不上报"
before_notify="$(notify_put_count)"
NOTIFY_ENABLED=0 DRY_RUN=0 bash "$GUARD" --check >/dev/null
check "关闭后上报次数不变" test "$before_notify" = "$(notify_put_count)"

echo "7) --check --dry-run 不上报"
CHECK_PORTS="2298:DSH" DRY_RUN=1 bash "$GUARD" --check >/dev/null
check "dry-run 不上报" test "$before_notify" = "$(notify_put_count)"

echo "8) 缺少 token 时静默退出"
GITHUB_TOKEN="" NOTIFY_TOKEN="" bash "$GUARD"
check "缺少 token 记录 skip" grep -q 'GITHUB_TOKEN 未配置' "$WORK/guard.log"

echo
if [ -n "${FAILED:-}" ]; then
  echo "有测试失败"
  exit 1
fi
echo "全部通过：$PASS 项"
