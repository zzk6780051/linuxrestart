#!/usr/bin/env bash
#
# 用本地 mock GitHub API 测试 linuxrestart-guard.sh 的逻辑（DRY_RUN=1，不会重启）。
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

STATE = {"sha": "sha-1", "text": json.dumps({"power": True, "updated_at": "2026-01-01T00:00:00Z"})}
PUTS = []

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

    def do_GET(self):
        if "/contents/state.json" not in self.path:
            return self._send(404, {"message": "not found"})
        self._send(200, {
            "sha": STATE["sha"],
            "content": base64.b64encode(STATE["text"].encode()).decode(),
        })

    def do_PUT(self):
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n))
        PUTS.append(body)
        if body.get("sha") != STATE["sha"]:
            return self._send(409, {"message": "sha mismatch"})
        STATE["text"] = base64.b64decode(body["content"]).decode()
        STATE["sha"] = "sha-%d" % (len(PUTS) + 1)
        with open(sys.argv[1], "w") as f:
            json.dump({"state": json.loads(STATE["text"]), "puts": len(PUTS)}, f)
        # 模拟真实 GitHub PUT 响应：content.content 为写入后的 base64 内容
        self._send(200, {
            "content": {
                "name": "state.json",
                "path": "state.json",
                "sha": STATE["sha"],
                "content": base64.b64encode(STATE["text"].encode()).decode(),
            },
            "commit": {"sha": "c1"},
        })

HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY

python3 "$WORK/mock_github.py" "$WORK/result.json" "$PORT" &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/contents/state.json" && break
  sleep 0.1
done

export GITHUB_TOKEN="mock"
export GITHUB_REPO="o/r"
export BRANCH="main"
export STATE_PATH="state.json"
export API_BASE="http://127.0.0.1:$PORT"
export LOG_FILE="$WORK/guard.log"
export LOCK_FILE="$WORK/guard.lock"
export LINUXRESTART_ENV="$WORK/none.env"

check() { # <desc> <condition...>
  local desc="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1))
    echo "  ok - $desc"
  else
    echo "  FAIL - $desc"; FAILED=1
  fi
}

echo "1) --status"
out="$(DRY_RUN=0 bash "$GUARD" --status)"
echo "$out" | grep -q 'power   : true' && { PASS=$((PASS + 1)); echo "  ok - 状态读取 power=true"; } || { echo "  FAIL - 状态读取"; FAILED=1; }

echo "2) --dry-run：写回 false 但不重启"
DRY_RUN=1 bash "$GUARD"
cat "$WORK/result.json" >/dev/null 2>&1
check "state.json 已写回 power=false" bash -c 'jq -e ".state.power == false" "$0" >/dev/null' "$WORK/result.json"
check "dry-run 不记录 last_reboot_at" bash -c 'jq -e ".state.last_reboot_at == null" "$0" >/dev/null' "$WORK/result.json"
check "updated_by=cron-dry-run" bash -c 'jq -e ".state.updated_by == \"cron-dry-run\"" "$0" >/dev/null' "$WORK/result.json"
check "日志包含 DRY_RUN 跳过" grep -q 'DRY_RUN=1' "$WORK/guard.log"

echo "3) 再次运行：状态为 off，不做写回"
before=$(jq -r '.puts' "$WORK/result.json")
DRY_RUN=1 bash "$GUARD"
after=$(jq -r '.puts' "$WORK/result.json")
check "未产生额外写回" test "$before" = "$after"

echo "4) 缺少 token 时静默退出"
GITHUB_TOKEN="" bash "$GUARD"
check "缺少 token 记录 skip" grep -q 'GITHUB_TOKEN 未配置' "$WORK/guard.log"

echo
if [ -n "${FAILED:-}" ]; then
  echo "有测试失败"; exit 1
fi
echo "全部通过：$PASS 项"
