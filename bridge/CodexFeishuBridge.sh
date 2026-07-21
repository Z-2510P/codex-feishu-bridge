#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"
shift || true

APP_ID="${FEISHU_APP_ID:-}"
APP_SECRET="${FEISHU_APP_SECRET:-}"
NO_STARTUP=0
REMOVE_DATA=0

while (($#)); do
  case "$1" in
    --app-id) APP_ID="${2:-}"; shift 2 ;;
    --app-secret) APP_SECRET="${2:-}"; shift 2 ;;
    --no-startup) NO_STARTUP=1; shift ;;
    --remove-data) REMOVE_DATA=1; shift ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" && "${CODEX_FEISHU_TEST_MODE:-0}" != "1" ]]; then
  printf 'This manager is for macOS. Use CodexFeishuBridge.ps1 on Windows.\n' >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_JS="$SCRIPT_DIR/bridge.js"
ADMIN_JS="$SCRIPT_DIR/bridge-admin.js"
DATA_ROOT="${CODEX_FEISHU_BRIDGE_DATA_ROOT:-$HOME/Library/Application Support/CodexFeishuBridge}"
LAUNCH_AGENTS_DIR="${CODEX_FEISHU_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.codex.feishu-bridge.plist"
LABEL="com.codex.feishu-bridge"
KEYCHAIN_ACCOUNT="${USER:-$(id -un)}"
APP_ID_SERVICE="CodexFeishuBridge.AppId"
APP_SECRET_SERVICE="CodexFeishuBridge.AppSecret"

mkdir -p "$DATA_ROOT" "$DATA_ROOT/logs"
chmod 700 "$DATA_ROOT" 2>/dev/null || true

find_node() {
  if [[ -n "${NODE_BIN:-}" && -x "${NODE_BIN}" ]]; then printf '%s\n' "$NODE_BIN"; return; fi
  command -v node 2>/dev/null || true
}

find_codex() {
  if [[ -n "${CODEX_EXE:-}" && -x "${CODEX_EXE}" ]]; then printf '%s\n' "$CODEX_EXE"; return; fi
  command -v codex 2>/dev/null || true
}

require_tools() {
  NODE_BIN="$(find_node)"
  CODEX_EXE="$(find_codex)"
  [[ -n "$NODE_BIN" ]] || { printf 'Node.js was not found. Install Node.js 22 or newer.\n' >&2; exit 1; }
  [[ -n "$CODEX_EXE" ]] || { printf 'The codex CLI was not found in PATH.\n' >&2; exit 1; }
  export NODE_BIN CODEX_EXE
}

keychain_set() {
  security add-generic-password -U -a "$KEYCHAIN_ACCOUNT" -s "$1" -w "$2" >/dev/null
}

keychain_get() {
  security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$1" -w
}

keychain_delete() {
  security delete-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$1" >/dev/null 2>&1 || true
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

write_plist() {
  require_tools
  mkdir -p "$LAUNCH_AGENTS_DIR"
  local manager path_value
  manager="$(xml_escape "$SCRIPT_DIR/CodexFeishuBridge.sh")"
  path_value="$(xml_escape "$(dirname "$NODE_BIN"):$(dirname "$CODEX_EXE"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")"
  cat >"$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$manager</string><string>run</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$path_value</string>
    <key>CODEX_EXE</key><string>$(xml_escape "$CODEX_EXE")</string>
    <key>NODE_BIN</key><string>$(xml_escape "$NODE_BIN")</string>
    <key>CODEX_FEISHU_BRIDGE_DATA_ROOT</key><string>$(xml_escape "$DATA_ROOT")</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$(xml_escape "$DATA_ROOT/logs/launchd.out.log")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$DATA_ROOT/logs/launchd.err.log")</string>
</dict>
</plist>
EOF
  chmod 600 "$PLIST_PATH"
  plutil -lint "$PLIST_PATH" >/dev/null
}

pair_action() {
  local node code
  node="$(find_node)"
  [[ -n "$node" ]] || { printf 'Node.js was not found.\n' >&2; exit 1; }
  code="$($node "$ADMIN_JS" pair "$DATA_ROOT")"
  printf '\nPairing code: %s\nSend this to the Feishu bot within 15 minutes:\n/pair %s\n\n' "$code" "$code"
}

start_action() {
  [[ -f "$PLIST_PATH" ]] || write_plist
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null
  printf 'Feishu bridge start requested.\n'
}

stop_action() {
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  if [[ -f "$DATA_ROOT/bridge.pid" ]]; then
    local pid
    pid="$(tr -dc '0-9' <"$DATA_ROOT/bridge.pid")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
    rm -f "$DATA_ROOT/bridge.pid"
  fi
  printf 'Feishu bridge stopped.\n'
}

run_action() {
  require_tools
  APP_ID="$(keychain_get "$APP_ID_SERVICE")"
  APP_SECRET="$(keychain_get "$APP_SECRET_SERVICE")"
  export FEISHU_APP_ID="$APP_ID" FEISHU_APP_SECRET="$APP_SECRET"
  export CODEX_FEISHU_BRIDGE_DATA_ROOT="$DATA_ROOT" CODEX_EXE
  exec "$NODE_BIN" "$BRIDGE_JS"
}

status_action() {
  local node status running startup credentials
  node="$(find_node)"
  running=false
  if [[ -f "$DATA_ROOT/bridge.pid" ]]; then
    local pid
    pid="$(tr -dc '0-9' <"$DATA_ROOT/bridge.pid")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then running=true; fi
  fi
  [[ -f "$PLIST_PATH" ]] && startup=true || startup=false
  if keychain_get "$APP_ID_SERVICE" >/dev/null 2>&1 && keychain_get "$APP_SECRET_SERVICE" >/dev/null 2>&1; then credentials=ready; else credentials=missing; fi
  printf 'Credentials: %s\nRunning: %s\nStartupEnabled: %s\nDataRoot: %s\n' "$credentials" "$running" "$startup" "$DATA_ROOT"
  if [[ -n "$node" && -f "$ADMIN_JS" ]]; then
    status="$($node "$ADMIN_JS" status "$DATA_ROOT")"
    $node -e 'const s=JSON.parse(process.argv[1]); console.log(`PairedUsers: ${s.pairedUsers}\nSessions: ${s.sessions}\nInbox: ${s.inbox}\nOutbox: ${s.outbox}\nDeadLetter: ${s.deadLetter}\nRuntimeStatus: ${s.runtime?.status ?? "-"}`)' "$status"
  fi
}

install_action() {
  require_tools
  if [[ -z "$APP_ID" ]]; then read -r -p 'Feishu App ID: ' APP_ID; fi
  if [[ -z "$APP_SECRET" ]]; then read -r -s -p 'Feishu App Secret: ' APP_SECRET; printf '\n'; fi
  [[ "$APP_ID" == cli_* ]] || { printf 'The Feishu App ID must start with cli_.\n' >&2; exit 1; }
  [[ -n "$APP_SECRET" ]] || { printf 'The Feishu App Secret cannot be empty.\n' >&2; exit 1; }
  keychain_set "$APP_ID_SERVICE" "$APP_ID"
  keychain_set "$APP_SECRET_SERVICE" "$APP_SECRET"
  (cd "$SCRIPT_DIR" && npm ci --omit=dev --no-audit --no-fund)
  if [[ "$NO_STARTUP" == 0 ]]; then write_plist; start_action; fi
  pair_action
  printf 'Credentials are stored in macOS Keychain.\n'
}

uninstall_action() {
  stop_action
  rm -f "$PLIST_PATH"
  keychain_delete "$APP_ID_SERVICE"
  keychain_delete "$APP_SECRET_SERVICE"
  if [[ "$REMOVE_DATA" == 1 ]]; then rm -rf "$DATA_ROOT"; fi
  printf 'Feishu bridge launch agent and Keychain credentials were removed.\n'
}

ACTION_LOWER="$(printf '%s' "$ACTION" | tr '[:upper:]' '[:lower:]')"
case "$ACTION_LOWER" in
  install) install_action ;;
  pair) pair_action ;;
  start) start_action ;;
  run) run_action ;;
  stop) stop_action ;;
  status) status_action ;;
  uninstall) uninstall_action ;;
  *) printf 'Usage: %s {install|pair|start|run|stop|status|uninstall}\n' "$0" >&2; exit 2 ;;
esac
