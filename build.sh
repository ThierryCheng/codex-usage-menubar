#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/'Codex Usage.app'/Contents/MacOS
codex_usage_target="$(uname -m)-apple-macos13.0"
swiftc -swift-version 5 -target "$codex_usage_target" -O Quota.swift main.swift -o build/CodexUsage.new -framework AppKit -framework ServiceManagement
mv build/CodexUsage.new build/'Codex Usage.app'/Contents/MacOS/CodexUsage
cp Info.plist build/'Codex Usage.app'/Contents/Info.plist
xattr -dr com.apple.FinderInfo build/'Codex Usage.app' 2>/dev/null || true
codesign --force --sign - build/'Codex Usage.app'
swiftc -swift-version 5 -target "$codex_usage_target" Quota.swift Tests.swift -o build/quota-tests.new
mv build/quota-tests.new build/quota-tests
build/quota-tests
