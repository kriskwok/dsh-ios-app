DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

.PHONY: project core-test verify ios-build

project:
	@command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen"; exit 1; }
	xcodegen generate

core-test:
	@tmp_dir="$$(mktemp -d /tmp/dsh-ios-core-test.XXXXXX)"; \
	trap 'rm -rf "$$tmp_dir"' EXIT; \
	swiftc -module-cache-path "$$tmp_dir/module-cache" DSHIOSApp/Models/DSHProtocol.swift DSHIOSApp/Models/ConversationMessage.swift DSHIOSApp/Models/AgentModels.swift DSHIOSApp/Models/ServerProfile.swift Scripts/CoreSmoke/main.swift -o "$$tmp_dir/core-test"; \
	"$$tmp_dir/core-test"

verify: core-test project
	swiftc -typecheck -module-cache-path /tmp/dsh-ios-verify-module-cache DSHIOSApp/Models/DSHProtocol.swift DSHIOSApp/Models/ConversationMessage.swift DSHIOSApp/Models/AgentModels.swift DSHIOSApp/Models/ServerProfile.swift DSHIOSApp/Models/AppThemeMode.swift DSHIOSApp/Services/KeychainStore.swift DSHIOSApp/Services/ServerStore.swift
	swiftc -frontend -parse $$(find DSHIOSApp DSHIOSAppTests Scripts -name '*.swift' -print | sort)
	plutil -lint DSHIOSApp/Info.plist DSHIOSApp/PrivacyInfo.xcprivacy
	@hash="$$(caddy hash-password --plaintext dsh-ios-smoke)"; \
	DSH_DOMAIN=dsh.example.com DSH_USER=tester DSH_PASSWORD_HASH="$$hash" \
	caddy adapt --config deploy/Caddyfile.example >/dev/null

ios-build: project
	xcodebuild -project DSHIOSApp.xcodeproj -scheme DSHIOSApp -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
