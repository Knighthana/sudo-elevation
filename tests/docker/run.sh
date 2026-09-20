#!/bin/bash
# Docker test driver.
#
#   tests/docker/run.sh                 # all scenarios on all images
#   tests/docker/run.sh 01_install.sh   # selected scenarios
#   SE_TEST_IMAGES="debian:12" tests/docker/run.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

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
	for scenario in "${SCENARIOS[@]}"; do
		name=$(basename "$scenario")
		printf '\n### [%s] %s\n' "$image" "$name"
		if ! docker run --rm -v "$REPO:/src:ro" "sudo-elevation-test:$tag" \
			bash "/src/tests/docker/scenarios/$name"; then
			printf 'FAILED: %s %s\n' "$image" "$name" >&2
			exit 1
		fi
	done
done
printf '\nALL SCENARIOS PASSED\n'
