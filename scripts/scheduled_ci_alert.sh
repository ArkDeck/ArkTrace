#!/bin/sh
# Open, update, or close the single tracking issue for a scheduled CI run.
#
# Production callers are the CI workflow. ALERT_DRY_RUN=1 skips gh and prints
# the decision so the contract test can run without a token.
set -eu

: "${GITHUB_REPOSITORY:?}"
: "${ALERT_RUN_URL:?}"
: "${ALERT_HEAD_SHA:?}"

marker='arktrace-scheduled-ci-failure'
failed=$(printf '%s' "${ALERT_FAILED_JOBS:-}" | tr -d '[:space:]')

if [ "${ALERT_DRY_RUN:-0}" = 1 ]; then
    number=${ALERT_EXISTING_ISSUE:-}
else
    number=$(gh issue list \
        --repo "$GITHUB_REPOSITORY" \
        --state open \
        --limit 5 \
        --search "${marker} in:body" \
        --json number \
        --jq '.[0].number // empty')
fi

if [ -z "$failed" ]; then
    if [ -n "$number" ]; then
        action=close
    else
        action=noop
    fi
elif [ -n "$number" ]; then
    action=update
else
    action=open
fi

if [ "${ALERT_DRY_RUN:-0}" = 1 ]; then
    printf 'action=%s\nmarker=%s\n' "$action" "$marker"
    exit 0
fi

body=$(cat <<EOF
<!-- ${marker} -->

Scheduled CI run: ${ALERT_RUN_URL}
Commit: \`${ALERT_HEAD_SHA}\`
Failed jobs: ${failed:-none}

The \`CI required\` aggregate does not include \`benchmark-slow\`. This issue tracks scheduled-run failures, including that lane.
EOF
)

case "$action" in
    noop)
        exit 0
        ;;
    open)
        gh issue create \
            --repo "$GITHUB_REPOSITORY" \
            --title "Scheduled CI failure" \
            --body "$body"
        ;;
    update)
        gh issue comment \
            --repo "$GITHUB_REPOSITORY" \
            "$number" \
            --body "$body"
        ;;
    close)
        gh issue comment \
            --repo "$GITHUB_REPOSITORY" \
            "$number" \
            --body "$(printf 'Scheduled CI recovered.\n\nRun: %s\nCommit: `%s`\n' "$ALERT_RUN_URL" "$ALERT_HEAD_SHA")"
        gh issue close \
            --repo "$GITHUB_REPOSITORY" \
            "$number" \
            --reason completed
        ;;
esac
