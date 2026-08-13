#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
phase=${1:-phase4}
fixture_class=${2:-medium}

case "$phase" in
    phase3)
        exec "$script_directory/benchmark_phase3.sh" "$fixture_class"
        ;;
    phase4)
        integration_source="$script_directory/../Tests/ArkTraceIntegrationTests/ParserIntegrationTests.swift"
        grep -F 'TraceContextBuilder(' "$integration_source" >/dev/null 2>&1 \
            || { printf 'Phase 4 benchmark lacks production ContextBuilder\n' >&2; exit 1; }
        grep -F 'TraceDeterministicAnalysisEngine(' "$integration_source" >/dev/null 2>&1 \
            || { printf 'Phase 4 benchmark lacks deterministic AnalysisEngine\n' >&2; exit 1; }
        # The single real-trace producer retains Phase 3 cache/render evidence
        # and adds production Phase 4 Context/Analysis samples under the same
        # parser, trace, source-tree and test-binary provenance chain.
        exec "$script_directory/benchmark_phase3.sh" "$fixture_class"
        ;;
    *)
        printf 'Usage: scripts/benchmark.sh <phase3|phase4> <medium|large>\n' >&2
        exit 2
        ;;
esac
