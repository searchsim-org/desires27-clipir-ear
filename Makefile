# Entry points (HANDOVER §2, P0.3). Run `make doctor` first.
SIM_DEST ?= platform=iOS Simulator,name=EarSim
XCODEPROJ := apps/ios/ClipIREar/ClipIREar.xcodeproj
UV := uv run --project mac/earbridge

.PHONY: stability soak remote-smoke mic-smoke doctor bootstrap deps models test harness report ci demo lint fixtures project

doctor:
	@tools/doctor.sh

bootstrap:
	brew install sox xcbeautify ffmpeg jq git-lfs xcodegen
	command -v uv >/dev/null || brew install uv
	command -v ollama >/dev/null || brew install ollama
	uv python install 3.12
	cd mac/earbridge && uv sync
	git config core.hooksPath .githooks

deps:
	tools/deps/build_sherpa.sh
	tools/deps/build_llama.sh
	tools/deps/fetch_kokoro.sh

models:
	@test -f tools/models/download.py || { echo "models: not yet implemented (P0.4)"; exit 1; }
	CLIPIR_EAR_MAKE_MODELS=1 python3 tools/models/download.py $(ONLY)
	@K="$(HOME)/Library/Application Support/ClipIREar/models/kokoro"; \
	if [ -d "$$K/voices" ]; then python3 -I tools/models/kokoro_voices.py "$$K/voices" "$$K/voices.npz"; fi

fixtures:
	python3 Tests/Fixtures/generate.py
	CLIPIR_EAR_MAKE_MODELS=1 python3 tools/models/download.py librispeech-test-clean
	$(UV) python Tests/Fixtures/librispeech.py
	mkdir -p apps/ios/ClipIREarTests/BenchFixtures
	cp Tests/Fixtures/lecture_en_01.wav Tests/Fixtures/queries/lecture_en_01_q*.wav apps/ios/ClipIREarTests/BenchFixtures/
	python3 -c "import json; q=json.load(open('Tests/Fixtures/queries/en.json')); json.dump([x for x in q if x['fixture']=='lecture_en_01'], open('apps/ios/ClipIREarTests/BenchFixtures/lecture_en_01.queries.json','w'), indent=2)"

project:
	cd apps/ios/ClipIREar && xcodegen generate --quiet

lint:
	swift format lint --strict --recursive Package.swift Sources Tests apps/ios
	$(UV) ruff check mac tools Tests/Fixtures
	$(UV) ruff format --check mac tools Tests/Fixtures

test:
	swift test --skip EarTTSKokoroTests  # MLX needs xcodebuild: see test-kokoro
	$(UV) pytest -q
	@if [ -d "$(XCODEPROJ)" ]; then \
		xcrun simctl boot EarSim 2>/dev/null; \
		xcrun simctl privacy EarSim grant microphone de.zerhoudi.clipir-ear 2>/dev/null; \
		xcrun simctl privacy EarSim grant reminders de.zerhoudi.clipir-ear 2>/dev/null; \
		set -o pipefail; xcodebuild test -project $(XCODEPROJ) -scheme ClipIREar -destination '$(SIM_DEST)' | xcbeautify; \
	else echo "SKIP xcodebuild test: $(XCODEPROJ) not created yet (P0.2)"; fi

mic-smoke:
	xcrun simctl boot EarSim 2>/dev/null || true
	xcrun simctl privacy EarSim grant microphone de.zerhoudi.clipir-ear
	set -o pipefail; TEST_RUNNER_EARSIM_MIC=1 xcodebuild test -project $(XCODEPROJ) -scheme ClipIREar \
		-destination '$(SIM_DEST)' -only-testing:ClipIREarTests/MicSmokeTest | xcbeautify

remote-smoke:  # P5: EarSim → earbridge on this Mac (Mac tier); starts and stops a throwaway earbridge
	swift build -c release --product EarCLI
	( $(UV) earbridge serve --host 127.0.0.1 --port 9479 --token SIMTOKEN --no-bonjour --no-tls --db :memory: & echo $$! > .build/earbridge.pid ); \
	sleep 4; set -o pipefail; TEST_RUNNER_EARBRIDGE_PORT=9479 TEST_RUNNER_EARBRIDGE_TOKEN=SIMTOKEN xcodebuild test -project $(XCODEPROJ) \
		-scheme ClipIREar -destination '$(SIM_DEST)' -only-testing:ClipIREarTests/RemoteLoopSmokeTest | xcbeautify; \
	status=$$?; kill $$(cat .build/earbridge.pid) 2>/dev/null; exit $$status

soak:  # P7.1: 30-minute ambient soak on EarSim (device: LoopBench-style run on the iPhone)
	set -o pipefail; TEST_RUNNER_EAR_SOAK=1 TEST_RUNNER_SOAK_MINUTES=$${SOAK_MINUTES:-30} xcodebuild test -project $(XCODEPROJ) \
		-scheme ClipIREar -destination '$(SIM_DEST)' -derivedDataPath .build/xcode-app -only-testing:ClipIREarTests/AmbientSoak \
		| tee .build/soak.log | grep -E "soak|passed|failed"
	grep -o 'soak-result {.*}' .build/soak.log | sed 's/^soak-result //' > docs/evidence/raw/soak_EarSim.json

stability:  # P7.4 on EarSim: the demo scenario 10× in one process (device: a device check)
	xcrun simctl privacy EarSim grant reminders de.zerhoudi.clipir-ear 2>/dev/null || true
	set -o pipefail; TEST_RUNNER_EAR_STABILITY=1 xcodebuild test -project $(XCODEPROJ) -scheme ClipIREar \
		-destination '$(SIM_DEST)' -derivedDataPath .build/xcode-app -only-testing:ClipIREarTests/DemoStabilityTest \
		| tee .build/stability.log | grep -E "stability|passed|failed"
	python3 -c "import json,re,sys; t=open('.build/stability.log').read(); runs=re.findall(r'stability run (\\d+): ok, footprint (\\d+) MB', t); json.dump({'runs':[{'run':int(r),'footprint_mb':int(f)} for r,f in runs],'passed':\"' passed (\" in t and 'DemoStabilityTest' in t}, open('docs/evidence/raw/stability_EarSim.json','w'), indent=2)"

ci: lint
	python3 tools/ci/license_check.py
	python3 tools/ci/egress_check.py
	$(MAKE) test
	$(MAKE) test-kokoro

test-kokoro:  # ADR-020: MLX needs xcodebuild (Metal shaders); EarCore-Package is the package scheme
	xcodebuild -scheme EarCore-Package -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xc \
		-jobs 4 build-for-testing -quiet
	@# xctest finds neither MLX's shader bundle nor KokoroSwift's resources next to a package test bundle:
	@# copy the former into the test bundle and point package resources at the products folder.
	P="$(CURDIR)/.build/xc/Build/Products/Debug"; mkdir -p "$$P/EarTTSKokoroTests.xctest/Contents/Resources"; \
	cp -R "$$P/mlx-swift_Cmlx.bundle" "$$P/EarTTSKokoroTests.xctest/Contents/Resources/"; \
	set -o pipefail; TEST_RUNNER_PACKAGE_RESOURCE_BUNDLE_PATH="$$P" xcodebuild -scheme EarCore-Package \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xc test-without-building \
		-only-testing:EarTTSKokoroTests | grep -E "Test Case|Executed|error" | tail -8

harness:
	$(UV) python tools/harness/run_asr_suite.py
	$(UV) python tools/harness/run_qa_suite.py
	$(UV) python tools/harness/run_latency_suite.py --tier phone
	$(UV) python tools/harness/run_latency_suite.py --tier mac
	$(UV) python tools/harness/report.py

report:
	$(UV) python tools/harness/report.py

demo:  # ADR-010: simulator only until the owner signs a device build (then: xcrun devicectl device install app …)
	xcrun simctl boot EarSim 2>/dev/null || true
	open -a Simulator
	set -o pipefail; xcodebuild build -project $(XCODEPROJ) -scheme ClipIREar -destination '$(SIM_DEST)' \
		-derivedDataPath .build/xcode-app | xcbeautify --quiet
	xcrun simctl install EarSim .build/xcode-app/Build/Products/Debug-iphonesimulator/ClipIREar.app
	xcrun simctl terminate EarSim de.zerhoudi.clipir-ear 2>/dev/null || true
	SIMCTL_CHILD_CLIPIR_EAR_FIXTURES="$(CURDIR)/Tests/Fixtures" xcrun simctl launch EarSim de.zerhoudi.clipir-ear \
		-earSource fixture:lecture_en_02 -earAutostart YES
