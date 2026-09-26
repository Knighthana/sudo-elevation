#!/bin/bash
# Docker test driver.
#
#   tests/docker/run.sh                 # all scenarios on all images
#   tests/docker/run.sh 01_install.sh   # selected scenarios
#   SE_TEST_IMAGES="debian:12" tests/docker/run.sh
#
# Each scenario runs in a fresh container with a hard timeout. Docker CLI can
# occasionally hang after a container has already exited; the SCENARIO-DONE
# marker printed by lib.sh lets us tolerate that case without hiding real hangs.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SCENARIO_TIMEOUT=${SCENARIO_TIMEOUT:-300}

IMAGES=${SE_TEST_IMAGES:-"ubuntu:24.04 debian:12"}
SCENARIOS=("$@")
if [ "${#SCENARIOS[@]}" -eq 0 ]; then
	SCENARIOS=("$HERE"/scenarios/*.sh)
fi

# Timing ledger. Build time and per-scenario wall time are the two numbers the
# Actions UI cannot give us: the API only reports whole-step durations, and
# `docker build` output goes to /dev/null, so without this the build cost is
# an invisible gap between "##########" and the first scenario line.
RUN_START=$(date +%s)
BUILD_TOTAL=0
SCEN_TOTAL=0
SCEN_PASS=0
declare -A SCEN_BY_NAME=()

for image in $IMAGES; do
	tag=$(printf '%s' "$image" | tr ':/' '--')
	printf '\n########## %s ##########\n' "$image"
	build_start=$(date +%s)
	docker build -q -t "sudo-elevation-test:$tag" -f "$HERE/Dockerfile" \
		--build-arg BASE="$image" "$HERE" >/dev/null
	build_elapsed=$(( $(date +%s) - build_start ))
	BUILD_TOTAL=$(( BUILD_TOTAL + build_elapsed ))
	printf '  --> BUILD (%ss)\n' "$build_elapsed"
	idx=0
	total=${#SCENARIOS[@]}
	for scenario in "${SCENARIOS[@]}"; do
		idx=$((idx + 1))
		name=$(basename "$scenario")
		ctr="se-test-$(printf '%s-%s' "$tag" "${name%.sh}" | tr -c 'A-Za-z0-9_.-' '_')"
		printf '\n### [%s] %s (%s/%s)\n' "$image" "$name" "$idx" "$total"
		docker rm -f "$ctr" >/dev/null 2>&1 || true
		out=$(mktemp)
		start=$(date +%s)
		set +e
		timeout --kill-after=10 "$SCENARIO_TIMEOUT" docker run --rm --name "$ctr" \
			-v "$REPO:/src:ro" \
			"sudo-elevation-test:$tag" \
			bash "/src/tests/docker/scenarios/$name" 2>&1 | tee "$out"
		rc=${PIPESTATUS[0]}
		set -e
		elapsed=$(( $(date +%s) - start ))
		SCEN_TOTAL=$(( SCEN_TOTAL + elapsed ))
		SCEN_BY_NAME["$name"]=$(( ${SCEN_BY_NAME["$name"]:-0} + elapsed ))
		if [ "$rc" = 0 ]; then
			printf '  --> PASS (%ss)\n' "$elapsed"
			SCEN_PASS=$(( SCEN_PASS + 1 ))
			rm -f "$out"
			continue
		fi
		if [ "$rc" = 124 ]; then
			docker rm -f "$ctr" >/dev/null 2>&1 || true
			if grep -q 'SCENARIO-DONE rc=0' "$out"; then
				printf '  WARN: docker CLI hung after scenario completed (%ss elapsed)\n' "$elapsed"
				SCEN_PASS=$(( SCEN_PASS + 1 ))
				rm -f "$out"
				continue
			fi
		fi
		rm -f "$out"
		printf 'FAILED: %s %s (rc=%s, %ss)\n' "$image" "$name" "$rc" "$elapsed" >&2
		exit 1
	done
done

# Where the wall clock went, in one place. Most scenarios deliberately wait out
# real lease durations (see 12/03/13), so a large scenario total is expected
# and is not by itself a regression.
run_seconds=$(( $(date +%s) - RUN_START ))
printf '\n===== docker matrix summary =====\n'
printf 'scenarios passed : %d\n' "$SCEN_PASS"
printf 'scenario runtime : %ss\n' "$SCEN_TOTAL"
printf 'image build time : %ss\n' "$BUILD_TOTAL"
printf 'wall clock       : %ss\n' "$run_seconds"
printf -- '-- slowest scenarios (all images) --\n'
if [ "${#SCEN_BY_NAME[@]}" -gt 0 ]; then
	for name in "${!SCEN_BY_NAME[@]}"; do
		printf '%s\t%s\n' "${SCEN_BY_NAME[$name]}" "$name"
	done | sort -rn | head -n 8 | while IFS=$'\t' read -r secs name; do
		printf '  %4ss  %s\n' "$secs" "$name"
	done
fi
printf '===================================\n'
printf '\nALL SCENARIOS PASSED\n'
