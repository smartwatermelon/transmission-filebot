#!/usr/bin/env bash

# Strict mode
set -euo pipefail
IFS=$'\n\t'

# Constants
readonly USER_CONFIG_DIR="${HOME}/.config/transmission-done"
readonly USER_CONFIG="${USER_CONFIG_DIR}/config.yml"

check_dependencies() {
  local missing_deps=()

  # Required dependencies
  if ! command -v yq &>/dev/null; then
    missing_deps+=("yq")
  fi

  if ! command -v curl &>/dev/null; then
    missing_deps+=("curl")
  fi

  if ! command -v jq &>/dev/null; then
    missing_deps+=("jq")
  fi

  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    printf 'Error: Missing required dependencies:\n' >&2
    for dep in "${missing_deps[@]}"; do
      printf '  - %s\n' "${dep}" >&2
    done
    printf '\nInstallation:\n' >&2
    printf '  brew install yq jq\n' >&2
    printf '  curl should be pre-installed on macOS\n' >&2
    return 1
  fi

  return 0
}

get_plex_server() {
  local plex_server

  printf '\nPlex Server URL\n'
  printf '  Default: http://localhost:32400\n'
  printf '  Or specify: http://YOUR_SERVER_IP:32400\n'
  read -rp "Plex server URL [http://localhost:32400]: " plex_server

  # Use default if empty
  plex_server="${plex_server:-http://localhost:32400}"

  echo "${plex_server}"
}

validate_plex_server() {
  local plex_server="$1"

  printf 'Validating Plex server at %s...\n' "${plex_server}"

  # Try to connect to the identity endpoint without auth
  if ! curl -sf -m 5 "${plex_server}/identity" >/dev/null 2>&1; then
    printf 'Error: Cannot connect to Plex server at %s\n' "${plex_server}" >&2
    printf 'Ensure Plex Media Server is running and accessible.\n' >&2
    return 1
  fi

  printf 'Plex server is reachable.\n'
  return 0
}

get_plex_token() {
  local token

  printf '\nPlex Authentication Token\n'
  printf '  Option 1: Visit https://www.plex.tv/claim/ (expires in 4 minutes)\n'
  printf '  Option 2: Get from your Plex account at:\n'
  printf '            https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/\n'
  printf '\n'
  read -rsp "Enter your Plex token: " token
  printf '\n'

  if [[ -z "${token}" ]]; then
    printf 'Error: Token is required\n' >&2
    return 1
  fi

  echo "${token}"
}

validate_token() {
  local plex_server="$1"
  local token="$2"

  printf 'Validating token with Plex server...\n'

  # Test the token by making an authenticated request
  if ! curl -sf -m 5 -H "X-Plex-Token: ${token}" "${plex_server}/identity" >/dev/null 2>&1; then
    printf 'Error: Token validation failed\n' >&2
    printf 'The token may be invalid or expired.\n' >&2
    return 1
  fi

  printf 'Token validated successfully.\n'
  return 0
}

get_plex_library_info() {
  local plex_server="$1"
  local token="$2"

  printf '\nQuerying Plex library sections...\n'

  local response
  if ! response=$(curl -sf -m 10 -H "X-Plex-Token: ${token}" "${plex_server}/library/sections" 2>&1); then
    printf 'Warning: Could not retrieve library sections\n' >&2
    return 1
  fi

  # Parse and display library sections
  printf 'Available library sections:\n'
  echo "${response}" | grep -o '<Directory[^>]*>' | while read -r section; do
    local id type title location
    id=$(echo "${section}" | grep -o 'key="[^"]*"' | cut -d'"' -f2)
    type=$(echo "${section}" | grep -o 'type="[^"]*"' | cut -d'"' -f2)
    title=$(echo "${section}" | grep -o 'title="[^"]*"' | cut -d'"' -f2)

    # Get location for this section
    local section_detail
    section_detail=$(curl -sf -m 5 -H "X-Plex-Token: ${token}" "${plex_server}/library/sections/${id}" 2>/dev/null || echo "")
    if [[ -n "${section_detail}" ]]; then
      location=$(echo "${section_detail}" | grep -o '<Location[^>]*path="[^"]*"' | sed 's/.*path="\([^"]*\)".*/\1/' | head -1)
      printf '  [%s] %s (%s): %s\n' "${id}" "${title}" "${type}" "${location}"
    else
      printf '  [%s] %s (%s)\n' "${id}" "${title}" "${type}"
    fi
  done

  return 0
}

get_media_path() {
  local media_path

  printf '\nPlex Media Path\n'
  printf '  This is the root path where FileBot will organize your media.\n'
  printf '  Example: /Users/yourname/Media\n'
  printf '  Example: /Volumes/Storage/PlexMedia\n'
  printf '\n'
  read -rp "Plex media path: " media_path

  # Expand tilde to home directory
  media_path="${media_path/#\~/${HOME}}"

  if [[ -z "${media_path}" ]]; then
    printf 'Error: Media path is required\n' >&2
    return 1
  fi

  # Check if path exists
  if [[ ! -d "${media_path}" ]]; then
    printf 'Warning: Directory does not exist: %s\n' "${media_path}" >&2
    read -rp "Create it now? [y/N]: " create_dir
    case "${create_dir}" in
      [yY][eE][sS] | [yY])
        if ! mkdir -p "${media_path}"; then
          printf 'Error: Failed to create directory\n' >&2
          return 1
        fi
        printf 'Directory created.\n'
        ;;
      *)
        printf 'Error: Media path must exist\n' >&2
        return 1
        ;;
    esac
  fi

  # Check if writable
  if [[ ! -w "${media_path}" ]]; then
    printf 'Error: No write permission to %s\n' "${media_path}" >&2
    return 1
  fi

  echo "${media_path}"
}

write_config() {
  local plex_server="$1"
  local plex_token="$2"
  local media_path="$3"

  # Create config directory if it doesn't exist
  if [[ ! -d "${USER_CONFIG_DIR}" ]]; then
    printf 'Creating config directory: %s\n' "${USER_CONFIG_DIR}"
    mkdir -p "${USER_CONFIG_DIR}"
  fi

  # Backup existing config if present
  if [[ -f "${USER_CONFIG}" ]]; then
    local backup
    backup="${USER_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    printf 'Backing up existing config to: %s\n' "${backup}"
    cp "${USER_CONFIG}" "${backup}"
  fi

  # Write new config
  printf 'Writing config to: %s\n' "${USER_CONFIG}"
  cat >"${USER_CONFIG}" <<EOF
---
version: 1.0
paths:
  default_home: ${HOME}
plex:
  server: ${plex_server}
  token: ${plex_token}
  media_path: ${media_path}
logging:
  file: .filebot/logs/transmission-processing.log
  max_size: 10485760  # 10MB
EOF

  # Validate the generated YAML
  if ! yq eval '.' "${USER_CONFIG}" >/dev/null 2>&1; then
    printf 'Error: Generated invalid YAML config\n' >&2
    return 1
  fi

  printf 'Config file written successfully.\n'
  return 0
}

main() {
  printf '==============================================\n'
  printf 'Plex Configuration Setup for transmission-done\n'
  printf '==============================================\n'

  # Check dependencies first
  if ! check_dependencies; then
    exit 1
  fi

  # Get Plex server URL
  local plex_server
  plex_server=$(get_plex_server) || exit 1

  # Validate server is reachable
  validate_plex_server "${plex_server}" || exit 1

  # Get authentication token
  local token
  token=$(get_plex_token) || exit 1

  # Validate token works
  validate_token "${plex_server}" "${token}" || exit 1

  # Show library info (best effort, don't fail if this doesn't work)
  get_plex_library_info "${plex_server}" "${token}" || true

  # Get media path
  local media_path
  media_path=$(get_media_path) || exit 1

  # Write configuration file
  if write_config "${plex_server}" "${token}" "${media_path}"; then
    printf '\n==============================================\n'
    printf 'Setup Complete!\n'
    printf '==============================================\n'
    printf 'Config location: %s\n' "${USER_CONFIG}"
    printf '\nYou can now run transmission-done.sh\n'
    printf '\nTo test the configuration:\n'
    printf '  ./transmission-done.sh\n'
    printf '  (It will prompt for a directory to process)\n'
  else
    printf 'Error: Failed to write configuration\n' >&2
    exit 1
  fi
}

main "$@"
