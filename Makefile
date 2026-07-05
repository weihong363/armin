.PHONY: emulator-start emulator-ready emulator-check-network emulator-install emulator-smoke-test emulator-reset emulator-seed
.PHONY: analyze test test-fast coverage ci-check integration-test approval-workflow-gate

# ── Static Analysis ──────────────────────────────────────────────

analyze:
	flutter analyze

# ── Tests ─────────────────────────────────────────────────────────

test:
	flutter test --exclude-tags real_ssh

test-fast:
	flutter test --exclude-tags real_ssh,slow

# ── Coverage ──────────────────────────────────────────────────────

coverage:
	flutter test --coverage --exclude-tags real_ssh
	@echo "Coverage report: coverage/lcov.info"

# ── CI Check (local) ──────────────────────────────────────────────

ci-check: analyze test-fast
	@echo "✅ CI checks passed"

# ── Emulator ──────────────────────────────────────────────────────

emulator-start:
	./scripts/emulator/start.sh

emulator-ready:
	./scripts/emulator/wait-ready.sh

emulator-check-network:
	./scripts/emulator/check-network.sh

emulator-install:
	./scripts/emulator/install-armin.sh

emulator-smoke-test:
	./scripts/emulator/run-smoke-test.sh

emulator-reset:
	./scripts/emulator/reset.sh

emulator-seed:
	DEVICE_ID=emulator-5554 ./scripts/emulator/seed-config.sh

# ── Integration Test ───────────────────────────────────────────────

integration-test: emulator-seed
	flutter drive \
		--driver=test_driver/integration_test.dart \
		--target=integration_test/app_test.dart \
		-d emulator-5554
	flutter drive \
		--driver=test_driver/integration_test.dart \
		--target=integration_test/runtime_gate_test.dart \
		-d emulator-5554

approval-workflow-gate: emulator-seed
	flutter drive \
		--driver=test_driver/integration_test.dart \
		--target=integration_test/approval_workflow_gate_test.dart \
		-d emulator-5554
