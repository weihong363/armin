.PHONY: emulator-start emulator-ready emulator-check-network emulator-install emulator-smoke-test emulator-reset emulator-seed
.PHONY: analyze test test-fast coverage ci-check integration-test approval-workflow-gate
.PHONY: release-gate release-device-gate release-ios-gate

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

release-gate:
	flutter test test/runtime/bridge_runtime_test.dart \
		test/core/armin_app_state_task_control_test.dart \
		test/history/task_detail_screen_approval_test.dart \
		test/features/voice/services/task_speech_policy_test.dart \
		test/tasks/task_deliverable_source_test.dart \
		test/tasks/scheduled_task_wake_service_test.dart \
		test/tasks/system_calendar_service_test.dart \
		test/ai/native_slm_client_test.dart
	flutter analyze
	flutter build apk --debug
	@echo "Release code gates passed"

release-ios-gate:
	flutter build ios --simulator --debug
	@echo "iOS simulator build gate passed"

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

# Requires an already configured emulator. Intentionally does not seed/reset.
release-device-gate:
	flutter drive \
		--driver=test_driver/integration_test.dart \
		--target=integration_test/productization_device_gate_test.dart \
		-d emulator-5554
	@PASSWORD="$$(security find-generic-password -s armin-host-host-local-mac -w)"; \
	test -n "$$PASSWORD"; \
	flutter drive \
		--driver=test_driver/integration_test.dart \
		--target=integration_test/runtime_gate_test.dart \
		-d emulator-5554 \
		--dart-define=ARMINTEST_SSH_PASSWORD="$$PASSWORD"
	@PASSWORD="$$(security find-generic-password -s armin-host-host-local-mac -w)"; \
	test -n "$$PASSWORD"; \
	flutter drive \
		--driver=test_driver/integration_test.dart \
		--target=integration_test/real_qodercli_deliverable_regression_test.dart \
		-d emulator-5554 \
		--dart-define=ARMINTEST_SSH_PASSWORD="$$PASSWORD"
