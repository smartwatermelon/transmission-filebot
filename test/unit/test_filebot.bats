#!/usr/bin/env bats

# Tests for FileBot processing functions

# shellcheck disable=SC2030,SC2031,SC2154
# SC2030/SC2031: BATS runs tests in subshells, variable modifications are intentional
# SC2154: TEST_TEMP_DIR, TEST_MODE, FILEBOT_TEST_OVERRIDE provided by test_helper

load ../test_helper

@test "run_filebot: succeeds in TEST_MODE with FILEBOT_TEST_OVERRIDE" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true

  run run_filebot -rename "/test/dir" --format "{plex}"

  assert_success
}

@test "process_media_with_autodetect: calls FileBot without --db flag" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  run process_media_with_autodetect "${test_dir}"

  assert_success
}

@test "process_media_with_autodetect: logs auto-detection attempt" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  process_media_with_autodetect "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "Attempting FileBot auto-detection" "${output}"
}

@test "process_with_database: calls FileBot with --db flag" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  run process_with_database "${test_dir}" "TheMovieDB"

  assert_success
}

@test "process_with_database: logs database name" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  process_with_database "${test_dir}" "TheMovieDB"

  run cat "${LOG_FILE}"
  assert_output_contains "Attempting FileBot processing with database: TheMovieDB" "${output}"
}

@test "process_with_database: handles different database names" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  process_with_database "${test_dir}" "TheTVDB"

  run cat "${LOG_FILE}"
  assert_output_contains "Attempting FileBot processing with database: TheTVDB" "${output}"
}

@test "try_tv_databases: logs fallback chain" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  try_tv_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying TV database fallback chain" "${output}"
}

@test "try_tv_databases: tries TheTVDB first" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  try_tv_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying TV database: TheTVDB" "${output}"
}

@test "try_tv_databases: tries TheMovieDB::TV as fallback" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  try_tv_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying TV database: TheMovieDB::TV" "${output}"
}

@test "try_tv_databases: tries AniDB as last resort" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  try_tv_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying TV database: AniDB" "${output}"
}

@test "try_movie_databases: logs fallback chain" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  try_movie_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying movie database fallback chain" "${output}"
}

@test "try_movie_databases: tries TheMovieDB first" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  try_movie_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying movie database: TheMovieDB" "${output}"
}

@test "try_movie_databases: tries OMDb as fallback" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  try_movie_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying movie database: OMDb" "${output}"
}

@test "process_media_with_fallback: validates source directory exists" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  run process_media_with_fallback "/nonexistent/directory"

  assert_failure
}

@test "process_media_with_fallback: logs error for missing directory" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  process_media_with_fallback "/nonexistent/directory" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Error: Source directory does not exist" "${output}"
}

@test "process_media_with_fallback: starts with auto-detection" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  process_media_with_fallback "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "Strategy 1: FileBot auto-detection" "${output}"
}

@test "process_media_with_fallback: logs comprehensive fallback processing" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  process_media_with_fallback "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "Starting comprehensive fallback processing" "${output}"
}

@test "process_media_with_fallback: succeeds with auto-detection when FILEBOT_TEST_OVERRIDE=true" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  run process_media_with_fallback "${test_dir}"

  assert_success
}
