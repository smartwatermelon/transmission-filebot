#!/usr/bin/env bash
PATH=${PATH}:/usr/local/bin

# Strict mode
set -euo pipefail
IFS=$'\n\t'

# Signal handling
trap 'log "Script interrupted"; exit 1' INT TERM

# Test mode flags
TEST_MODE="${TEST_MODE:-false}"
TEST_RUNNER="${TEST_RUNNER:-false}"

# Constants
SCRIPT_DIR="$( dirname "$( realpath "${BASH_SOURCE[0]}" )" )"; readonly SCRIPT_DIR
readonly LOCAL_CONFIG="${SCRIPT_DIR}/config.yml"
readonly USER_CONFIG="${HOME:-/Users/andrewrich}/.config/transmission-done/config.yml"
readonly CURL_OPTS=(-s -f -m 10 -v)   # silent, fail on error, 10 second timeout, verbose

# Config vars
PLEX_SERVER=""
PLEX_TOKEN=""
PLEX_MEDIA_PATH="${PLEX_MEDIA_PATH:-}"
LOG_FILE=""
MAX_LOG_SIZE=0

# Config validation functions
validate_config_file() {
    local config_file="$1"
    if ! yq eval '.' "${config_file}" >/dev/null 2>&1; then
        printf 'Error: Invalid YAML in config file: %s\n' "${config_file}" >&2
        return 1
    fi
    return 0
}

get_home_directory() {
    local config_file="$1"
    local default_home

    default_home=$(yq eval '.paths.default_home' "${config_file}")
    if [[ -z "${default_home}" ]]; then
        printf 'Error: default_home not set in config\n' >&2
        return 1
    fi

    if [[ -n "${HOME:-}" ]] && [[ -d "${HOME}" ]]; then
        printf '%s' "${HOME}"
    else
        printf '%s' "${default_home}"
    fi
}

read_config() {
    if ! yq --version &>/dev/null; then
        printf 'Error: yq required, not found in PATH.\nTry: brew install yq' >&2
        return 1
    fi

    local config_file
    if [[ -f "${LOCAL_CONFIG}" ]]; then
        config_file="${LOCAL_CONFIG}"
    elif [[ -f "${USER_CONFIG}" ]]; then
        config_file="${USER_CONFIG}"
    else
        printf 'Error: No config file found. Checked:\n%s\n%s\n' "${LOCAL_CONFIG}" "${USER_CONFIG}" >&2
        return 1
    fi

    validate_config_file "${config_file}" || return 1

    local effective_home
    effective_home=$(get_home_directory "${config_file}") || return 1

    PLEX_SERVER=$(yq eval '.plex.server' "${config_file}")
    PLEX_TOKEN=$(yq eval '.plex.token' "${config_file}")
    PLEX_MEDIA_PATH=$(yq eval '.plex.media_path' "${config_file}")

    local missing_values=()
    [[ -z "${PLEX_SERVER}" ]] && missing_values+=("plex.server")
    [[ -z "${PLEX_TOKEN}" ]] && missing_values+=("plex.token")
    [[ -z "${PLEX_MEDIA_PATH}" ]] && missing_values+=("plex.media_path")

    if (( ${#missing_values[@]} > 0 )); then
        printf 'Error: Missing required config values: %s\n' "${missing_values[*]}" >&2
        return 1
    fi

    local log_path
    log_path=$(yq eval '.logging.file' "${config_file}")
    LOG_FILE="${effective_home}/${log_path}"
    MAX_LOG_SIZE=$(yq eval '.logging.max_size' "${config_file}")

    if [[ "${TEST_MODE}" != "true" ]]; then
        printf 'Using config file: %s\n' "${config_file}" >&2
    fi
}

# Log function with timestamp
log() {
    if [[ ! -d "$(dirname "${LOG_FILE}")" ]]; then
        printf 'Warning: Log directory does not exist: %s\n' "$(dirname "${LOG_FILE}")" >&2
        mkdir -p "$(dirname "${LOG_FILE}")"
    fi
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
}

# Plex API functions
plex_make_request() {
    local endpoint="$1"
    local max_retries="${2:-1}"
    local retry_delay="${3:-5}"
    local attempt=1

    while [[ ${attempt} -le ${max_retries} ]]; do
        if [[ "${TEST_MODE}" == "true" ]]; then
            log "TEST: Would make Plex request to ${endpoint}"
            return 0
        fi

        local response
        response=$(curl "${CURL_OPTS[@]}" -H "X-Plex-Token: ${PLEX_TOKEN}" \
            "${PLEX_SERVER}${endpoint}" 2>&1)
        local curl_exit=$?

        if [[ ${curl_exit} -eq 0 ]]; then
            echo "${response}"
            return 0
        else
            log "Warning: Plex request failed (attempt ${attempt}/${max_retries})"
            log "Endpoint: ${endpoint}"
            log "Exit code: ${curl_exit}"
            log "Response: ${response}"

            if [[ ${attempt} -lt ${max_retries} ]]; then
                log "Retrying in ${retry_delay} seconds..."
                sleep "${retry_delay}"
            fi
        fi
        ((attempt+=1))
    done

    return 1
}

verify_plex_connection() {
    local test_mode="$1"
    if [[ "${test_mode}" == "true" ]]; then
        log "TEST: Would verify Plex connection"
        return 0
    fi

    log "Verifying Plex connection on ${PLEX_SERVER}..."
    if ! plex_make_request "/identity"; then
        log "Error: Cannot connect to Plex server"
        log "Server: ${PLEX_SERVER}"
        log "Token: ${PLEX_TOKEN:0:3}...${PLEX_TOKEN: -3}"
        return 1
    fi
    log "Plex connection verified"
    return 0
}

get_plex_library_sections() {
    if [[ "${TEST_MODE}" == "true" ]]; then
        log "TEST: Would get Plex library sections"
        return 0
    fi

    log "Querying Plex library sections..."
    local response
    if response=$(plex_make_request "/library/sections"); then
        log "Library sections found:"
        echo "${response}" | grep -o '<Directory.*</Directory>' | while read -r section; do
            local id type title
            id=$(echo "${section}" | grep -o 'key="[^"]*"' | cut -d'"' -f2)
            type=$(echo "${section}" | grep -o 'type="[^"]*"' | cut -d'"' -f2)
            title=$(echo "${section}" | grep -o 'title="[^"]*"' | cut -d'"' -f2)
            log "Section ${id}: ${title} (${type})"
        done
        return 0
    fi
    return 1
}

trigger_plex_scan() {
    local section_type="$1"
    local section_id

    case "${section_type}" in
        "show")  section_id="2" ;;
        "movie") section_id="1" ;;
        *)
            log "Error: Unknown media type for Plex scan: ${section_type}"
            return 1
            ;;
    esac

    log "Triggering Plex scan for ${section_type} library"
    if ! plex_make_request "/library/sections/${section_id}/refresh" 3 5; then
        log "Error: Failed to trigger Plex scan for ${section_type} library"
        return 1
    fi

    log "Plex scan triggered successfully"
    return 0
}

# FileBot wrapper function
run_filebot() {
    if [[ "${TEST_MODE}" == "true" ]]; then
        echo "TEST: filebot called with args: $*" >&2

        if [[ "${FILEBOT_TEST_OVERRIDE:-false}" == "true" ]]; then
            return 0
        fi

        if [[ "$*" == *"TheTVDB"* && "$*" == *"/test/The.Show.S01E01"* ]]; then
            return 0
        elif [[ "$*" == *"TheMovieDB"* && "$*" == *"/test/The.Movie.2024"* ]]; then
            return 0
        fi
        return 1
    else
        local FILEBOT
        FILEBOT="$(command -v filebot 2>/dev/null || echo "/usr/local/bin/filebot")"
        "${FILEBOT}" "$@"
    fi
}

check_disk_space() {
    local required_space=1000000  # 1GB in KB

    if ! df -P "${PLEX_MEDIA_PATH}" | awk -v space="${required_space}" 'NR==2 {exit($4<space)}'; then
        log "Error: Insufficient space on target filesystem (need ${required_space}KB)"
        return 1
    fi
    return 0
}

process_tv_show() {
    local source_dir="$1"

    run_filebot -rename "${source_dir}" \
        --db TheTVDB \
        --format "{plex}" \
        --output "${PLEX_MEDIA_PATH}" \
        -r \
        --conflict auto \
        -non-strict \
        --apply artwork url metadata import subtitles finder date chmod prune clean thumbnail \
        --action move \
        >> "${LOG_FILE}" 2>&1
}

process_movie() {
    local source_dir="$1"

    run_filebot -rename "${source_dir}" \
        --db TheMovieDB \
        --format "{plex}" \
        --output "${PLEX_MEDIA_PATH}" \
        -r \
        --conflict auto \
        --apply artwork url metadata import subtitles finder date chmod prune clean thumbnail \
        --action move \
        >> "${LOG_FILE}" 2>&1
}

process_media() {
    local source_dir="$1"
    local success=false
    local success_type=""

    log "Processing media in ${source_dir}"

    check_disk_space || return 1

    # Try to determine media type first using filename patterns
    local is_likely_tv=false
    local is_likely_movie=false

	# Match TV patterns: S01E01, s1e1, 1x01 (case insensitive)
    if find "${source_dir}" -type f -iname "*.mkv" -o -iname "*.mp4" | grep -iE 's[0-9]+e[0-9]+|[0-9]+x[0-9]+' >/dev/null; then
        is_likely_tv=true
        log "Media appears to be a TV show based on filename pattern"
    # Match year 1900-2099 not followed by 'p' or 'i' (avoids matching resolution like 1080p)
    elif find "${source_dir}" -type f -iname "*.mkv" -o -iname "*.mp4" | grep -iE '(19|20)[0-9]{2}[^ip]' >/dev/null; then
        is_likely_movie=true
        log "Media appears to be a movie based on filename pattern"
    fi

    # Process based on likely type first
    if [[ "${is_likely_tv}" == "true" ]]; then
        if process_tv_show "${source_dir}"; then
            log "Successfully processed as TV show"
            success=true
            success_type="show"
        else
            log "TV show processing failed despite TV pattern match"
        fi
    elif [[ "${is_likely_movie}" == "true" ]]; then
        if process_movie "${source_dir}"; then
            log "Successfully processed as movie"
            success=true
            success_type="movie"
        else
            log "Movie processing failed despite movie pattern match"
        fi
    else
        # If no clear pattern, try both but log a warning
        log "Warning: Unable to determine media type from filename patterns"

        if process_movie "${source_dir}"; then
            log "Successfully processed as movie"
            success=true
            success_type="movie"
        else
            log "Movie processing failed, trying TV show as fallback..."
            if process_tv_show "${source_dir}"; then
                log "Successfully processed as TV show"
                success=true
                success_type="show"
            fi
        fi
    fi

    if [[ "${success}" == "true" ]]; then
        cleanup_empty_dirs "${source_dir}"
        trigger_plex_scan "${success_type}"
        return 0
    fi

    log "Warning: Could not process media with FileBot"
    return 1
}

cleanup_torrent() {
    local torrent_dir="$1"
    local file_patterns=( "*.nfo" "*.exe" "*.txt" )

    log "Cleaning up extraneous files in ${torrent_dir}"

    pushd "${torrent_dir}" &>/dev/null || {
        log "Error: Could not change to directory ${torrent_dir}"
        return 1
    }

    for pattern in "${file_patterns[@]}"; do
        find . -type f -name "${pattern}" -delete
    done

    popd &>/dev/null || true
}

cleanup_empty_dirs() {
    local dir="$1"
    log "Cleaning up empty directories in ${dir}"
    find "${dir}" -type d -empty -delete 2>/dev/null || true
}

rotate_log() {
    if [[ -f "${LOG_FILE}" ]] && [[ $(stat -f%z "${LOG_FILE}") -gt ${MAX_LOG_SIZE} ]]; then
        mv "${LOG_FILE}" "${LOG_FILE}.old"
    fi
}

setup_test_env() {
    local temp_dir="$1"

    # TV Show test setup
    mkdir -p "${temp_dir}/test/The.Show.S01E01"
    touch "${temp_dir}/test/The.Show.S01E01/video.mkv"
    touch "${temp_dir}/test/The.Show.S01E01/sample.txt"

    # Movie test setup
    mkdir -p "${temp_dir}/test/The.Movie.2024"
    touch "${temp_dir}/test/The.Movie.2024/movie.mkv"
    touch "${temp_dir}/test/The.Movie.2024/sample.nfo"

    # Invalid media setup
    mkdir -p "${temp_dir}/test/Invalid.Media"
    touch "${temp_dir}/test/Invalid.Media/file.txt"

    # Cleanup test setup
    mkdir -p "${temp_dir}/test/cleanup_test"
    touch "${temp_dir}/test/cleanup_test/video.mkv"
    touch "${temp_dir}/test/cleanup_test/info.nfo"
    touch "${temp_dir}/test/cleanup_test/readme.txt"
    touch "${temp_dir}/test/cleanup_test/installer.exe"
}

run_test() {
    local name="$1"
    local cmd="$2"
    local expect_failure="${3:-false}"

    echo "Running test: ${name}"
    if eval "${cmd}"; then
        if [[ "${expect_failure}" == "true" ]]; then
            echo "✗ ${name} failed: Expected failure, got success"
            return 1
        fi
        echo "✓ ${name} passed"
        return 0
    else
        if [[ "${expect_failure}" == "true" ]]; then
            echo "✓ ${name} passed: Failed as expected"
            return 0
        fi
        echo "✗ ${name} failed"
        return 1
    fi
}

test_tv_processing() {
    local temp_dir="$1"
    local script_path="$2"

    run_test "TV Show processing" "TR_TORRENT_DIR='${temp_dir}/test/The.Show.S01E01' \
        TR_TORRENT_NAME='The.Show.S01E01' \
        TEST_MODE=true \
        TEST_RUNNER=true \
        PLEX_MEDIA_PATH=${temp_dir} \
        '${script_path}'"
}

test_movie_processing() {
    local temp_dir="$1"
    local script_path="$2"

    run_test "Movie processing" "TR_TORRENT_DIR='${temp_dir}/test/The.Movie.2024' \
        TR_TORRENT_NAME='The.Movie.2024' \
        TEST_MODE=true \
        TEST_RUNNER=true \
        PLEX_MEDIA_PATH=${temp_dir} \
        '${script_path}'"
}

test_invalid_media() {
    local temp_dir="$1"
    local script_path="$2"

    run_test "Invalid media handling" "TR_TORRENT_DIR='${temp_dir}/test/Invalid.Media' \
        TR_TORRENT_NAME='Invalid.Media' \
        TEST_MODE=true \
        TEST_RUNNER=true \
        PLEX_MEDIA_PATH=${temp_dir} \
        '${script_path}'" true
}

test_missing_env() {
    local temp_dir="$1"
    local script_path="$2"

    run_test "Missing environment variables" "TEST_MODE=true \
        TEST_RUNNER=true \
        PLEX_MEDIA_PATH=${temp_dir} \
        '${script_path}'" true
}

test_cleanup() {
    local temp_dir="$1"
    local script_path="$2"
    local test_dir="${temp_dir}/test/cleanup_test"

    TR_TORRENT_DIR="${test_dir}" \
    TR_TORRENT_NAME="cleanup_test" \
    TEST_MODE=true \
    TEST_RUNNER=true \
    FILEBOT_TEST_OVERRIDE=true \
    PLEX_MEDIA_PATH=${temp_dir} \
    "${script_path}" || true

    local unwanted_files
    unwanted_files=$(find "${test_dir}" -name "*.nfo" -o -name "*.txt" -o -name "*.exe" | wc -l)
    unwanted_files=$(echo "${unwanted_files}" | tr -d '[:space:]')

    [[ "${unwanted_files}" -eq 0 ]]
}

test_plex_scanning() {
    run_test "TV Show library scan" "trigger_plex_scan 'show'" && \
    run_test "Movie library scan" "trigger_plex_scan 'movie'" && \
    run_test "Invalid library type handling" "! trigger_plex_scan 'invalid_type'"
}

test_plex_api() {
    log "Testing basic Plex API endpoints..."

    # Test identity endpoint
    if ! plex_make_request "/identity"; then
        log "Failed to test identity endpoint"
        return 1
    fi
    log "Identity endpoint test passed"

    # Test libraries endpoint
    if ! plex_make_request "/library/sections"; then
        log "Failed to test libraries endpoint"
        return 1
    fi
    log "Libraries endpoint test passed"

    # Test specific section
    if ! plex_make_request "/library/sections/2"; then
        log "Failed to test section endpoint"
        return 1
    fi
    log "Section endpoint test passed"

    return 0
}

run_tests() {
    local temp_dir script_path
    temp_dir=$(mktemp -d)
    script_path="$0"
    local tests_run=0
    local tests_passed=0

    log "Starting test suite"
    setup_test_env "${temp_dir}"

    # Run all tests
    declare -a tests=(
        "test_tv_processing ${temp_dir} ${script_path}"
        "test_movie_processing ${temp_dir} ${script_path}"
        "test_invalid_media ${temp_dir} ${script_path}"
        "test_missing_env ${temp_dir} ${script_path}"
        "test_cleanup ${temp_dir} ${script_path}"
        "test_plex_scanning"
        "verify_plex_connection false"
        "test_plex_api"
    )

    for test_cmd in "${tests[@]}"; do
        ((tests_run+=1))
        if eval "${test_cmd}"; then
            ((tests_passed+=1))
        fi
    done

    # Cleanup
    rm -rf "${temp_dir}"

    # Summary
    echo -e "\nTest Summary:"
    echo "-------------"
    echo "Total tests: ${tests_run}"
    echo "Passed tests: ${tests_passed}"
    echo "Failed tests: $((tests_run - tests_passed))"
    echo

    [[ ${tests_passed} -eq ${tests_run} ]]
}

# Mock commands for testing
if [[ "${TEST_MODE}" == "true" ]]; then
    df() {
        echo "Filesystem    1024-blocks      Used  Available  Capacity  Mounted on"
        echo "/dev/disk1     976762584  418612404    2000000      45%  ${PLEX_MEDIA_PATH}"
    }

    stat() {
        echo "1000"
    }
fi

validate_environment() {
    # Skip transmission variable check in test mode unless explicitly testing for it
    if [[ "${TEST_MODE}" != "true" ]] || [[ "${TEST_RUNNER}" == "true" ]]; then
        if [[ -z "${TR_TORRENT_DIR:-}" ]] || [[ -z "${TR_TORRENT_NAME:-}" ]]; then
            printf 'Error: Required Transmission variables not set\nTR_TORRENT_DIR: \t[%s]\nTR_TORRENT_NAME:\t[%s]\n' \
                "${TR_TORRENT_DIR:-}" "${TR_TORRENT_NAME:-}" >&2
            return 1
        fi
    fi

    if [[ -z "${TR_TORRENT_DIR:-}" ]] || [[ -z "${TR_TORRENT_NAME:-}" ]]; then
        printf 'Error: Required Transmission variables not set\nTR_TORRENT_DIR: \t[%s]\nTR_TORRENT_NAME:\t[%s]\n' \
            "${TR_TORRENT_DIR:-}" "${TR_TORRENT_NAME:-}" >&2
        return 1
    fi

    if [[ ! -d "${PLEX_MEDIA_PATH}" ]]; then
        printf 'Error: Plex media path %s does not exist\n' "${PLEX_MEDIA_PATH}" >&2
        return 1
    fi

    if [[ ! -w "${PLEX_MEDIA_PATH}" ]]; then
        printf 'Error: No write permission to %s\n' "${PLEX_MEDIA_PATH}" >&2
        return 1
    fi

    return 0
}

initialize() {
    # Read config
    if ! read_config; then
        printf 'Error: Failed to read configuration\n' >&2
        return 1
    fi

    return 0
}

main() {
    # Validate environment variables first
    if ! validate_environment; then
        log "Error: Environment validation failed"
        return 1
    fi

    rotate_log
    log "Starting post-download processing for ${TR_TORRENT_NAME}"

    # Continue with processing...
    if ! cleanup_torrent "${TR_TORRENT_DIR}"; then
        log "Warning: Cleanup failed but continuing"
    fi

    if ! process_media "${TR_TORRENT_DIR}"; then
        log "Error: Media processing failed"
        return 1
    fi

    log "Processing completed successfully"
    return 0
}

# Early initialization to set test flags and logging
TEST_MODE="${TEST_MODE:-false}"
TEST_RUNNER="${TEST_RUNNER:-false}"

# Set default values for test mode
if [[ "${TEST_MODE}" == "true" ]]; then
    PLEX_SERVER="${PLEX_SERVER:-http://localhost:32400}"
    PLEX_TOKEN="${PLEX_TOKEN:-test_token}"
    LOG_FILE="${LOG_FILE:-/tmp/transmission-test.log}"
    MAX_LOG_SIZE="${MAX_LOG_SIZE:-10485760}"
else
    initialize || exit 1
fi

# Entry point logic
if [[ "${TEST_MODE}" == "true" ]] && [[ "${TEST_RUNNER}" == "false" ]]; then
    run_tests
else
    main "$@"
fi
