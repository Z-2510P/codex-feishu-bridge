#!/usr/bin/env bash
set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { printf 'SKIP: macOS only\n'; exit 0; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-feishu-mac-test.XXXXXX")"
REAL_NODE="$(command -v node)"
trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"
KEYCHAIN="$ROOT/keychain"
mkdir -p "$BIN" "$KEYCHAIN"

cat >"$BIN/security" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
action="${1:-}"
shift || true
service=""
value=""
while (($#)); do
  case "$1" in
    -s) service="${2:-}"; shift 2 ;;
    -w)
      if [[ "$action" == "add-generic-password" ]]; then value="${2:-}"; shift 2; else shift; fi
      ;;
    -a|-U) if [[ "$1" == "-a" ]]; then shift 2; else shift; fi ;;
    *) shift ;;
  esac
done
file="$CODEX_FEISHU_TEST_KEYCHAIN/$service"
case "$action" in
  add-generic-password) printf '%s' "$value" >"$file" ;;
  find-generic-password) cat "$file" ;;
  delete-generic-password) rm -f "$file" ;;
  *) exit 2 ;;
esac
EOF

cat >"$BIN/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$BIN/npm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$BIN/security" "$BIN/codex" "$BIN/npm" "$BIN/launchctl"

export HOME="$ROOT/home"
export USER="test-user"
export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export NODE_BIN="$REAL_NODE"
export CODEX_FEISHU_TEST_MODE=1
export CODEX_FEISHU_TEST_KEYCHAIN="$KEYCHAIN"
export CODEX_FEISHU_BRIDGE_DATA_ROOT="$ROOT/data"
export CODEX_FEISHU_LAUNCH_AGENTS_DIR="$ROOT/LaunchAgents"

MANAGER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/CodexFeishuBridge.sh"
output="$($MANAGER install --app-id cli_test123 --app-secret test-secret)"
grep -q 'Pairing code:' <<<"$output"
[[ -f "$KEYCHAIN/CodexFeishuBridge.AppId" ]]
[[ -f "$KEYCHAIN/CodexFeishuBridge.AppSecret" ]]
plist="$CODEX_FEISHU_LAUNCH_AGENTS_DIR/com.codex.feishu-bridge.plist"
[[ -f "$plist" ]]
! grep -q 'test-secret' "$plist"

status="$($MANAGER status)"
grep -q 'Credentials: ready' <<<"$status"
grep -q 'StartupEnabled: true' <<<"$status"

$MANAGER uninstall --remove-data >/dev/null
[[ ! -f "$plist" ]]
[[ ! -d "$CODEX_FEISHU_BRIDGE_DATA_ROOT" ]]
[[ ! -f "$KEYCHAIN/CodexFeishuBridge.AppSecret" ]]

printf 'macOS manager tests passed.\n'
