#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

if pgrep -x CodexUsage >/dev/null; then
    print -u2 '请先在 Codex 额度菜单中选择“退出”，再运行安装脚本。'
    exit 1
fi

if [[ ! -x 'build/Codex Usage.app/Contents/MacOS/CodexUsage' ]]; then
    print -u2 '请先运行 zsh build.sh。'
    exit 1
fi

codex_usage_destination="$HOME/Applications/Codex Usage.app"
if [[ -d "$codex_usage_destination" ]]; then
    codex_usage_existing_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$codex_usage_destination/Contents/Info.plist")
    if [[ "$codex_usage_existing_id" != com.local.codex-usage ]]; then
        print -u2 "目标位置已有其他应用：$codex_usage_destination"
        exit 1
    fi
fi

mkdir -p "$HOME/Applications"
ditto --norsrc --noextattr 'build/Codex Usage.app' "$codex_usage_destination"
codesign --verify --verbose=2 "$codex_usage_destination"
open -g "$codex_usage_destination"
print "已安装并启动：$codex_usage_destination"
