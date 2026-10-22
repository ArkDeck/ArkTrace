#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
alert="$script_directory/scheduled_ci_alert.sh"

export ALERT_DRY_RUN=1
export GITHUB_REPOSITORY=ArkDeck/ArkTrace
export ALERT_RUN_URL=https://example.invalid/actions/runs/1
export ALERT_HEAD_SHA=0123456789abcdef0123456789abcdef01234567

output=$(ALERT_FAILED_JOBS=benchmark-slow ALERT_EXISTING_ISSUE= sh "$alert")
printf '%s\n' "$output" | grep -F 'action=open' >/dev/null
printf '%s\n' "$output" | grep -F 'marker=arktrace-scheduled-ci-failure' >/dev/null

output=$(ALERT_FAILED_JOBS=benchmark-slow ALERT_EXISTING_ISSUE=41 sh "$alert")
printf '%s\n' "$output" | grep -F 'action=update' >/dev/null

output=$(ALERT_FAILED_JOBS= ALERT_EXISTING_ISSUE=41 sh "$alert")
printf '%s\n' "$output" | grep -F 'action=close' >/dev/null

output=$(ALERT_FAILED_JOBS= ALERT_EXISTING_ISSUE= sh "$alert")
printf '%s\n' "$output" | grep -F 'action=noop' >/dev/null

if env -u GITHUB_REPOSITORY \
    ALERT_DRY_RUN=1 \
    ALERT_RUN_URL=https://example.invalid/actions/runs/1 \
    ALERT_HEAD_SHA=0123456789abcdef0123456789abcdef01234567 \
    ALERT_FAILED_JOBS=benchmark-slow \
    sh "$alert" >/dev/null 2>&1
then
    printf 'scheduled CI alert accepted a missing repository\n' >&2
    exit 1
fi

printf 'scheduled CI alert contract passed\n'
