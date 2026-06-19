.PHONY: emulator-start emulator-ready emulator-check-network emulator-install emulator-smoke-test emulator-reset

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
