#!/usr/bin/env bash

# Strict mode
set -euo pipefail
IFS=$'\n\t'

# Constants
BASH_SOURCE_REALPATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${BASH_SOURCE_REALPATH}")"
readonly SCRIPT_DIR
readonly LOCAL_CONFIG="${SCRIPT_DIR}/config.yml"
readonly USER_CONFIG="${HOME:-/Users/andrewrich}/.config/transmission-done/config.yml"

get_plex_server() {
  if ! yq --version &>/dev/null; then
    printf 'Error: yq required, not found in PATH.\nTry: brew install yq\n' >&2
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

  if ! yq eval '.' "${config_file}" >/dev/null 2>&1; then
    printf 'Error: Invalid YAML in config file: %s\n' "${config_file}" >&2
    return 1
  fi

  local plex_server
  plex_server=$(yq eval '.plex.server' "${config_file}")
  if [[ -z "${plex_server}" ]]; then
    printf 'Error: No Plex server found in config\n' >&2
    return 1
  fi

  echo "${plex_server}"
}

validate_plex_server() {
  local plex_server="$1"
  local plex_host="${plex_server#*//}"
  plex_host="${plex_host%%:*}"
  local plex_port="${plex_server##*:}"

  if command -v nc &>/dev/null; then
    if ! nc -w 1 -z "${plex_host}" "${plex_port}" &>/dev/null; then
      printf 'Error: Plex server not found at %s\n' "${plex_server}" >&2
      return 1
    fi
  else
    if ! curl -f -s -I "${plex_server}/identity"; then
      printf 'Error: Plex server not found at %s\n' "${plex_server}" >&2
      return 1
    fi
  fi
  return 0
}

get_credentials() {
  read -erp "Plex username: " username

  # Use read -s for secure password entry
  read -ersp "Password: " password

  if [[ -z "${username}" ]] || [[ -z "${password}" ]]; then
    printf 'Error: Username and password are required\n' >&2
    return 1
  fi

  echo "${username}:${password}"
}

get_plex_token() {
  local plex_server="$1"
  local credentials="$2"
  local username password

  IFS=':' read -r username password <<<"${credentials}"

  # Get authentication token from plex.tv
  local auth_response
  auth_response=$(curl -s -X POST 'https://plex.tv/users/sign_in.json' \
    -H 'X-Plex-Client-Identifier: my-app' \
    -H 'X-Plex-Product: my-app' \
    -H 'X-Plex-Version: 1.0' \
    --data-urlencode "user[login]=${username}" \
    --data-urlencode "user[password]=${password}") >&2 || {
    printf 'Error: Failed to authenticate with Plex\n' >&2
    return 1
  }

  # Extract the authentication token using jq
  local auth_token
  auth_token=$(echo "${auth_response}" | jq -r '.user.authToken') || {
    printf 'Error: Failed to parse authentication response\n' >&2
    return 1
  }

  if [[ "${auth_token}" == "null" ]] || [[ -z "${auth_token}" ]]; then
    printf 'Error: Failed to get authentication token. Check credentials.\n' >&2
    return 1
  fi

  echo "${auth_token}"
}

validate_token() {
  local plex_server="$1"
  local token="$2"

  # Test the token by making a request to the server
  if ! curl -sf -H "X-Plex-Token: ${token}" "${plex_server}/identity" >/dev/null; then
    printf 'Error: Token validation failed\n' >&2
    return 1
  fi
}

main() {
  local plex_server
  plex_server=$(get_plex_server) || exit 1
  validate_plex_server "${plex_server}" || exit 1

  printf 'Using Plex server: %s\n' "${plex_server}"

  local credentials
  credentials=$(get_credentials) || exit 1

  local token
  token=$(get_plex_token "${plex_server}" "${credentials}") || exit 1

  printf '\nValidating token...\n'
  if validate_token "${plex_server}" "${token}"; then
    printf '\nPlex token: %s\n' "${token}"
    printf '\nAdd this to your config.yml as plex.token\n'
  else
    printf 'Token validation failed\n' >&2
    exit 1
  fi
}

main "$@"
