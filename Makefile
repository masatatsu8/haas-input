PROJECT_ROOT := $(CURDIR)
XCODEGEN ?= xcodegen

.DEFAULT_GOAL := help
.PHONY: check project runtime build test clean help

check:
	@command -v xcodebuild >/dev/null || { echo "Xcode が必要です。"; exit 1; }
	@command -v "$(XCODEGEN)" >/dev/null || { echo "XcodeGen が必要です。"; exit 1; }
	@command -v python3 >/dev/null || { echo "Python 3 が必要です。"; exit 1; }

project: check
	"$(XCODEGEN)" generate --spec project.yml --project .

runtime:
	python3 scripts/prepare-haas-runtime.py

build: check
	XCODEGEN="$(XCODEGEN)" ./scripts/build-haas-app.sh

test: check
	XCODEGEN="$(XCODEGEN)" ./scripts/test-haas-app.sh

clean:
	rm -rf "$(PROJECT_ROOT)/.haas-build/dedicated-app-build" "$(PROJECT_ROOT)/.haas-build/dedicated-test-host"

help:
	@echo "make project  Xcode プロジェクトを再生成"
	@echo "make runtime  固定版の Haas 推論エンジンとモデルを準備"
	@echo "make build    Haas音声入力の候補アプリを作成"
	@echo "make test     本番と分離した TestHost でテスト"
	@echo "make clean    専用ビルドの中間生成物を削除"
