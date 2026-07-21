#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$SCRIPT_DIR/Payload"

printf '\nCodex Feishu Bridge macOS installer\n\n'
chmod +x "$PAYLOAD/Install.sh" "$PAYLOAD/bridge/CodexFeishuBridge.sh"
"$PAYLOAD/Install.sh"

printf '\nInstallation finished. You may close this Terminal window.\n'
read -r -p 'Press Return to exit... ' _

