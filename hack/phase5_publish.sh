#!/bin/sh

# Thin shell entry points for descriptor-bound, RENAME_EXCL publication. The
# verifier keeps the moved inode open through identity verification and pair
# rollback, so callers never re-open an attacker-replaceable destination path.

arktrace_phase5_publish_file() {
    python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
        publish-file "$1" "$2" "$3" "$4"
}

arktrace_phase5_publish_directory() {
    python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
        publish-directory "$1" "$2" "$3"
}

arktrace_phase5_publish_candidate_pair() {
    python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
        publish-pair "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}
