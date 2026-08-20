# remindkit — Build system
#
# 两个构建产物：
#   1. Binaries/fetch-remindkit     — ObjC 子二进制（ReminderKit 私有框架层）
#   2. remindkit CLI               — Swift 可执行文件（EventKit + 合并层）
#
# Usage:
#   make build           — 编译全部
#   make build-cbinary   — 仅编译 ObjC 子二进制
#   make build-cli       — 仅编译 Swift CLI（swift build）

CLANG = clang
FRAMEWORKS = -framework Foundation
REMINDKIT_SRC_DIR = Sources/CReminderKit
REMINDKIT_SRCS = $(wildcard $(REMINDKIT_SRC_DIR)/*.m)
REMINDKIT_BIN = Binaries/fetch-remindkit

.PHONY: build build-cbinary build-cli clean test test-regressions

build: build-cbinary build-cli

build-cbinary: $(REMINDKIT_BIN)

$(REMINDKIT_BIN): $(REMINDKIT_SRCS)
	mkdir -p $(dir $@)
	$(CLANG) $(FRAMEWORKS) -Wno-objc-method-access -o $@ $(REMINDKIT_SRCS)

build-cli: $(REMINDKIT_BIN)
	swift build -c release
	cp $(REMINDKIT_BIN) .build/release/fetch-remindkit
	@echo "Binary at: .build/release/remindkit"

test: build
	bash Scripts/smoke-test.sh
	bash Scripts/skill-contract-test.sh

test-regressions: build
	bash Scripts/smoke-test.sh --regressions

clean:
	rm -f $(REMINDKIT_BIN)
	swift package clean
