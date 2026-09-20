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

for image in $IMAGES; do
	tag=$(printf '%s' "$image" | tr ':/' '--')
	printf '\n########## %s ##########\n' "$image"
	docker build -q -t "sudo-elevation-test:$tag" -f "$HERE/Dockerfile" \
		--build-arg BASE="$image" "$HERE" >/dev/null
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
		if [ "$rc" = 0 ]; then
			printf '  --> PASS (%ss)\n' "$elapsed"
			rm -f "$out"
			continue
		fi
		if [ "$rc" = 124 ]; then
			docker rm -f "$ctr" >/dev/null 2>&1 || true
			if grep -q 'SCENARIO-DONE' "$out"; then
				printf '  WARN: docker CLI hung after scenario completed (%ss elapsed)\n' "$elapsed"
				rm -f "$out"
				continue
			fi
		fi
		rm -f "$out"
		printf 'FAILED: %s %s (rc=%s, %ss)\n' "$image" "$name" "$rc" "$elapsed" >&2
		exit 1
	done
done
printf '\nALL SCENARIOS PASSED\n'
