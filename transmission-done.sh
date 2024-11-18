#!/usr/bin/env bash

# Strict mode
set -euo pipefail
IFS=$'\n\t'

# Signal handling
trap 'log "Script interrupted"; exit 1' INT TERM

# Test mode flags
TEST_MODE="${TEST_MODE:-false}"
TEST_RUNNER="${TEST_RUNNER:-false}"

# Constants
readonly SCRIPT_DIR
SCRIPT_DIR="$( dirname "$( realpath "${BASH_SOURCE[0]}" )" )"
readonly LOCAL_CONFIG="${SCRIPT_DIR}/config.yml"
readonly USER_CONFIG="${HOME:-/Users/andrewrich}/.config/transmission-done/config.yml"
readonly CURL_OPTS=(-s -f -m 10 -v)   # silent, fail on error, 10 second timeout, verbose

# Config vars
PLEX_SERVER=""
PLEX_TOKEN=""
PLEX_MEDIA_PATH=""
LOG_FILE=""
MAX_LOG_SIZE=0

# Function to read config
read_config() {
    if ! command -v yq >/dev/null 2>&1; then
        printf 'Error: yq is required but not installed\n' >&2
        exit 1
    fi

    # Determine which config file to use
    local config_file
    if [[ -f "${LOCAL_CONFIG}" ]]; then
        config_file="${LOCAL_CONFIG}"
    elif [[ -f "${USER_CONFIG}" ]]; then
        config_file="${USER_CONFIG}"
    else
        printf 'Error: No config file found. Checked:\n%s\n%s\n' "${LOCAL_CONFIG}" "${USER_CONFIG}" >&2
        exit 1
    fi

    # Read and validate config
    if ! yq eval '.' "${config_file}" >/dev/null 2>&1; then
        printf 'Error: Invalid YAML in config file: %s\n' "${config_file}" >&2
        exit 1
    fi

    PLEX_SERVER=$(yq eval '.plex.server' "${config_file}")
    PLEX_TOKEN=$(yq eval '.plex.token' "${config_file}")
    PLEX_MEDIA_PATH=$(yq eval '.plex.media_path' "${config_file}")
    LOG_FILE=$(yq eval '.logging.file' "${config_file}" | envsubst)
    MAX_LOG_SIZE=$(yq eval '.logging.max_size' "${config_file}")

    # Log which config we're using (but not in test mode)
    if [[ "${TEST_MODE}" != "true" ]]; then
        printf 'Using config file: %s\n' "${config_file}" >&2
    fi
}

# Log function with timestamp
log() {
	# Create log directory if it doesn't exist
	mkdir -p "$(dirname "${LOG_FILE}")"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
}

# FileBot wrapper function
run_filebot() {
    if [[ "${TEST_MODE}" == "true" ]]; then
        # Test mode behavior
        echo "TEST: filebot called with args: $*" >&2

        # If we're in cleanup test, always succeed
        if [[ "${FILEBOT_TEST_OVERRIDE:-false}" == "true" ]]; then
            return 0
        fi

        # Simulate success based on input pattern
        if [[ "$*" == *"TheTVDB"* && "$*" == *"/test/The.Show.S01E01"* ]]; then
            return 0
        elif [[ "$*" == *"TheMovieDB"* && "$*" == *"/test/The.Movie.2024"* ]]; then
            return 0
        fi
        return 1
    else
        # Production mode - use actual FileBot
        local FILEBOT
        FILEBOT="$(command -v filebot 2>/dev/null || echo "/usr/local/bin/filebot")"
        "${FILEBOT}" "$@"
    fi
}

# Functions to test Plex connectivity
test_plex_api() {
    log "Testing basic Plex API endpoints..."

    # Test identity endpoint
    log "Testing identity endpoint:"
    curl "${CURL_OPTS[@]}" -H "X-Plex-Token: ${PLEX_TOKEN}" \
        "${PLEX_SERVER}/identity"

    # Test libraries endpoint
    log "Testing libraries endpoint:"
    curl "${CURL_OPTS[@]}" -H "X-Plex-Token: ${PLEX_TOKEN}" \
        "${PLEX_SERVER}/library/sections"

    # Try to get a specific section
    log "Testing section 2 endpoint:"
    curl "${CURL_OPTS[@]}" -H "X-Plex-Token: ${PLEX_TOKEN}" \
        "${PLEX_SERVER}/library/sections/2"
}

verify_plex_connection() {
    local test_mode="$1"
    if [[ "${test_mode}" == "true" ]]; then
        log "TEST: Would verify Plex connection"
        return 0
    fi

    log "Verifying Plex connection on ${PLEX_SERVER}..."
    if ! curl "${CURL_OPTS[@]}" -H "X-Plex-Token: ${PLEX_TOKEN}" \
        "${PLEX_SERVER}/identity" > /dev/null 2>&1; then
        local curl_exit=$?
        log "Error: Cannot connect to Plex server (curl exit code: ${curl_exit})"
        log "Tried connecting to: ${PLEX_SERVER} with token: ${PLEX_TOKEN:0:3}...${PLEX_TOKEN: -3}"
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
    response=$(curl "${CURL_OPTS[@]}" -H "X-Plex-Token: ${PLEX_TOKEN}" \
        "${PLEX_SERVER}/library/sections" 2>&1)
    local curl_exit=$?

    if [[ ${curl_exit} -eq 0 ]]; then
        log "Library sections found:"
        echo "${response}" | grep -o '<Directory.*</Directory>' | while read -r section; do
            local id type title
            id=$(echo "${section}" | grep -o 'key="[^"]*"' | cut -d'"' -f2)
            type=$(echo "${section}" | grep -o 'type="[^"]*"' | cut -d'"' -f2)
            title=$(echo "${section}" | grep -o 'title="[^"]*"' | cut -d'"' -f2)
            log "Section ${id}: ${title} (${type})"
        done
        return 0
    else
        log "Error: Failed to get library sections (curl exit code: ${curl_exit})"
        log "Response: ${response}"
        return 1
    fi
}

# Function to trigger the Plex scan
trigger_plex_scan() {
    local section_type="$1"  # "show" or "movie"
    local section_id
    local max_retries=3
    local retry_delay=5

    # Get the library section ID based on type
    case "${section_type}" in
        "show")
            section_id="2"
            ;;
        "movie")
            section_id="1"
            ;;
        *)
            log "Error: Unknown media type for Plex scan: ${section_type}"
            return 1
            ;;
    esac

    log "Triggering Plex scan for ${section_type} library"

    local attempt=1
    while [[ ${attempt} -le ${max_retries} ]]; do
        if [[ "${TEST_MODE}" == "true" ]]; then
            log "TEST: Would trigger Plex scan for section ${section_id} (${section_type})"
            return 0
        fi

        local scan_url="${PLEX_SERVER}/library/sections/${section_id}/refresh?X-Plex-Token=${PLEX_TOKEN}"
        local response
        response=$(curl "${CURL_OPTS[@]}" "${scan_url}" 2>&1)
        local curl_exit=$?

        if [[ ${curl_exit} -eq 0 ]]; then
            log "Plex scan triggered successfully"
            return 0
        else
            log "Warning: Failed to trigger Plex scan (attempt ${attempt}/${max_retries})"
            log "Curl exit code: ${curl_exit}"
            log "Response: ${response}"
            if [[ ${attempt} -lt ${max_retries} ]]; then
                log "Retrying in ${retry_delay} seconds..."
                sleep "${retry_delay}"
            fi
        fi
        ((attempt+=1))
    done

    log "Error: Failed to trigger Plex scan after ${max_retries} attempts"
    return 1
}

# Mock commands for testing
if [[ "${TEST_MODE}" == "true" ]]; then
    # Mock df command for testing
    df() {
        echo "Filesystem    1024-blocks      Used  Available  Capacity  Mounted on"
        echo "/dev/disk1     976762584  418612404    2000000      45%  ${PLEX_MEDIA_PATH}"
    }

    # Mock stat command for testing
    stat() {
        echo "1000"  # Small file size for testing
    }
fi

# Test function to verify script behavior
run_tests() {
    local temp_dir script_name script_dir
    temp_dir=$(mktemp -d)
    script_name="$(basename "$0")"
    script_dir="$(dirname "$0")"
    local test_count=0
    local pass_count=0

    log "T E S T M O D you can now test all my modes"
    echo "Running tests in ${temp_dir}"
    echo "Creating test directory structure..."

    # Test 1: TV Show processing
    ((test_count+=1))
    echo "Setting up Test 1: TV Show processing"
    mkdir -p "${temp_dir}/test/The.Show.S01E01" || echo "Failed to create TV show directory"
    touch "${temp_dir}/test/The.Show.S01E01/video.mkv" || echo "Failed to create TV show test file"
    touch "${temp_dir}/test/The.Show.S01E01/sample.txt" || echo "Failed to create TV show sample file"

    echo "Test 1 directory contents:"
    ls -la "${temp_dir}/test/The.Show.S01E01"

    echo "Running Test 1 with TV show path: ${temp_dir}/test/The.Show.S01E01"
    if TR_TORRENT_DIR="${temp_dir}/test/The.Show.S01E01" \
       TR_TORRENT_NAME="The.Show.S01E01" \
       TEST_MODE=true \
       TEST_RUNNER=true \
       "${script_dir}/${script_name}"; then
        echo "✓ Test 1 passed: TV Show processing"
        ((pass_count+=1))
    else
        echo "✗ Test 1 failed: TV Show processing (exit code: $?)"
    fi

    # Test 2: Movie processing
    ((test_count+=1))
    echo "Setting up Test 2: Movie processing"
    mkdir -p "${temp_dir}/test/The.Movie.2024" || echo "Failed to create movie directory"
    touch "${temp_dir}/test/The.Movie.2024/movie.mkv" || echo "Failed to create movie test file"
    touch "${temp_dir}/test/The.Movie.2024/sample.nfo" || echo "Failed to create movie sample file"

    echo "Test 2 directory contents:"
    ls -la "${temp_dir}/test/The.Movie.2024"

    echo "Running Test 2 with movie path: ${temp_dir}/test/The.Movie.2024"
    if TR_TORRENT_DIR="${temp_dir}/test/The.Movie.2024" \
       TR_TORRENT_NAME="The.Movie.2024" \
       TEST_MODE=true \
       TEST_RUNNER=true \
       "${script_dir}/${script_name}"; then
        echo "✓ Test 2 passed: Movie processing"
        ((pass_count+=1))
    else
        echo "✗ Test 2 failed: Movie processing (exit code: $?)"
    fi

    # Test 3: Invalid media
    ((test_count+=1))
    echo "Setting up Test 3: Invalid media"
    mkdir -p "${temp_dir}/test/Invalid.Media" || echo "Failed to create invalid media directory"
    touch "${temp_dir}/test/Invalid.Media/file.txt" || echo "Failed to create invalid media test file"

    echo "Test 3 directory contents:"
    ls -la "${temp_dir}/test/Invalid.Media"

    echo "Running Test 3 with invalid media path: ${temp_dir}/test/Invalid.Media"
    if ! TR_TORRENT_DIR="${temp_dir}/test/Invalid.Media" \
        TR_TORRENT_NAME="Invalid.Media" \
        TEST_MODE=true \
        TEST_RUNNER=true \
        "${script_dir}/${script_name}"; then
        echo "✓ Test 3 passed: Invalid media handling"
        ((pass_count+=1))
    else
        echo "✗ Test 3 failed: Invalid media handling (expected failure, got success)"
    fi

	# Test 4: Missing required environment variables
    ((test_count+=1))
    echo "Running Test 4: Missing environment variables"
    if ! TEST_MODE=true TEST_RUNNER=true "${script_dir}/${script_name}"; then
        echo "✓ Test 4 passed: Missing environment variables handling"
        ((pass_count+=1))
    else
        echo "✗ Test 4 failed: Missing environment variables handling (expected failure, got success)"
    fi

    # Test 5: Cleanup of unwanted files
    ((test_count+=1))
    echo "Setting up Test 5: Cleanup of unwanted files"
    local test_dir="${temp_dir}/test/cleanup_test"
    mkdir -p "${test_dir}" || echo "Failed to create cleanup test directory"
    touch "${test_dir}/video.mkv" || echo "Failed to create video test file"
    touch "${test_dir}/info.nfo" || echo "Failed to create nfo test file"
    touch "${test_dir}/readme.txt" || echo "Failed to create txt test file"
    touch "${test_dir}/installer.exe" || echo "Failed to create exe test file"

    echo "Test 5 directory contents before cleanup:"
    ls -la "${test_dir}"

    echo "Running Test 5 with cleanup test path: ${test_dir}"
    TR_TORRENT_DIR="${test_dir}" \
    TR_TORRENT_NAME="cleanup_test" \
    TEST_MODE=true \
    TEST_RUNNER=true \
    FILEBOT_TEST_OVERRIDE=true \
    "${script_dir}/${script_name}" || true

    echo "Test 5 directory contents after cleanup:"
    ls -la "${test_dir}"

    local unwanted_files
    unwanted_files=$(find "${test_dir}" -name "*.nfo" -o -name "*.txt" -o -name "*.exe" | wc -l)
    unwanted_files=$(echo "${unwanted_files}" | tr -d '[:space:]')

    if [[ "${unwanted_files}" -eq 0 ]]; then
        echo "✓ Test 5 passed: Cleanup of unwanted files"
        ((pass_count+=1))
    else
        echo "✗ Test 5 failed: Cleanup of unwanted files (found ${unwanted_files} unwanted files)"
    fi

    # Test 6: Plex scanning
    ((test_count+=1))
    echo "Setting up Test 6: Plex scanning"

    # Test TV Show scan
    echo "Testing TV Show library scan..."
    if trigger_plex_scan "show"; then
        echo "✓ Test 6a passed: TV Show library scan"
        ((pass_count+=1))
    else
        echo "✗ Test 6a failed: TV Show library scan"
    fi

    # Test Movie scan
    echo "Testing Movie library scan..."
    if trigger_plex_scan "movie"; then
        echo "✓ Test 6b passed: Movie library scan"
        ((pass_count+=1))
    else
        echo "✗ Test 6b failed: Movie library scan"
    fi

    # Test invalid media type
    echo "Testing invalid library type scan..."
    if ! trigger_plex_scan "invalid_type"; then
        echo "✓ Test 6c passed: Invalid library type handling"
        ((pass_count+=1))
    else
        echo "✗ Test 6c failed: Invalid library type handling"
    fi

    # Increment test count for the additional two sub-tests
    ((test_count+=2))

    # Test 7: Plex Connection
    ((test_count+=1))
    echo "Testing Plex connectivity..."
    if verify_plex_connection false; then
        echo "✓ Test 7 passed: Plex connection verified"
        ((pass_count+=1))
    else
        echo "✗ Test 7 failed: Could not connect to Plex"
    fi

    # Test 8: Plex API Test
    ((test_count+=1))
    echo "Testing Plex API endpoints..."
    if ! test_plex_api; then
        echo "✗ Test 8 failed: Plex API test"
    else
        echo "✓ Test 8 passed: Plex API test"
        ((pass_count+=1))
    fi

    # Cleanup
    echo "Cleaning up test directory: ${temp_dir}"
    rm -rf "${temp_dir}"

    # Summary
    echo
    echo "Test Summary:"
    echo "-------------"
    echo "Total tests: ${test_count}"
    echo "Passed tests: ${pass_count}"
    echo "Failed tests: $((test_count - pass_count))"
    echo

    if [[ "${pass_count}" -eq "${test_count}" ]]; then
        echo "All tests passed! 🎉"
        return 0
    else
        echo "Some tests failed! 😢"
        return 1
    fi
}

# Log rotation function
rotate_log() {
    if [[ -f "${LOG_FILE}" ]] && [[ $(stat -f%z "${LOG_FILE}") -gt ${MAX_LOG_SIZE} ]]; then
        mv "${LOG_FILE}" "${LOG_FILE}.old"
    fi
}

# Cleanup function for unwanted files
cleanup_torrent() {
    local torrent_dir="$1"

    log "Cleaning up extraneous files in ${torrent_dir}"

    # Save current directory and change to torrent directory
    pushd "${torrent_dir}" &>/dev/null || {
        log "Error: Could not change to directory ${torrent_dir}"
        return 1
    }

    # Delete common unwanted files
    find . -type f \( \
        -name "*.nfo" -o \
        -name "*.exe" -o \
        -name "*.txt" \
    \) -delete

    # Return to original directory
    popd &>/dev/null || true
}

# Cleanup empty directories
cleanup_empty_dirs() {
    local dir="$1"

    log "Cleaning up empty directories in ${dir}"

    # Remove empty subdirectories
    find "${dir}" -type d -empty -delete 2>/dev/null || true
}

# Process media with FileBot
process_media() {
    local source_dir="$1"

    log "Processing media in ${source_dir}"

    # Check disk space before proceeding
    if ! df -P "${PLEX_MEDIA_PATH}" | awk 'NR==2 {exit($4<1000000)}'; then
        log "Error: Insufficient space on target filesystem"
        return 1
    fi

    # Try TV shows first
    if run_filebot -rename "${source_dir}" \
        --db TheTVDB \
        -non-strict \
        --format "{plex}" \
        --output "${PLEX_MEDIA_PATH}" \
        -r \
        --apply artwork url metadata import subtitles finder date chmod prune clean thumbnail \
        --action move \
        >> "${LOG_FILE}" 2>&1; then
        log "Successfully processed as TV show"
        cleanup_empty_dirs "${source_dir}"
        trigger_plex_scan "show"
        return 0
    fi

    # If TV show processing fails, try movies
    if run_filebot -rename "${source_dir}" \
        --db TheMovieDB \
        --format "{plex}" \
        --output "${PLEX_MEDIA_PATH}" \
        -r \
        --apply artwork url metadata import subtitles finder date chmod prune clean thumbnail \
        --action move \
        >> "${LOG_FILE}" 2>&1; then
        log "Successfully processed as movie"
        cleanup_empty_dirs "${source_dir}"
        trigger_plex_scan "movie"
        return 0
    fi

    log "Warning: Could not process media with FileBot"
    return 1
}

# Main function
main() {
    rotate_log
    log "Starting post-download processing for ${TR_TORRENT_NAME}"

    # Clean up unwanted files
    cleanup_torrent "${TR_TORRENT_DIR}"

    # Process media with FileBot
    if ! process_media "${TR_TORRENT_DIR}"; then
        log "Error: Media processing failed"
        exit 1
    fi

    log "Processing completed successfully"
}

# read the external config file
read_config || exit 1

# If in test mode and not being called as a test subject, run all tests
if [[ "${TEST_MODE}" == "true" ]] && [[ "${TEST_RUNNER}" == "false" ]]; then
    # This is the entrypoint for test mode - we only want to run tests here
    run_tests
    exit $?
fi

# Ensure required environment variables are set
if [[ -z "${TR_TORRENT_DIR:-}" ]] || [[ -z "${TR_TORRENT_NAME:-}" ]]; then
    printf 'Error: Required Transmission environment variables not set\nTR_TORRENT_DIR: \t[%s]\nTR_TORRENT_NAME:\t[%s]\n' "${TR_TORRENT_DIR:-}" "${TR_TORRENT_NAME:-}" >&2
    exit 1
fi

# Verify Plex media path exists and is writable
if [[ ! -d "${PLEX_MEDIA_PATH}" ]]; then
    printf 'Error: Plex media path %s does not exist\n' "${PLEX_MEDIA_PATH}" >&2
    exit 1
fi

if [[ ! -w "${PLEX_MEDIA_PATH}" ]]; then
    printf 'Error: No write permission to %s\n' "${PLEX_MEDIA_PATH}" >&2
    exit 1
fi

main "$@"
