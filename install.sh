#!/usr/bin/env bash

# Strict mode
set -euo pipefail
IFS=$'\n\t'

# Constants
BASH_SOURCE_REALPATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${BASH_SOURCE_REALPATH}")"
readonly SCRIPT_DIR
readonly USER_CONFIG_DIR="${HOME}/.config/transmission-done"
readonly USER_CONFIG="${USER_CONFIG_DIR}/config.yml"
readonly SYMLINK_DIR="${HOME}/.local/bin"
readonly SYMLINK_NAME="transmission-done"

check_dependencies() {
  local missing_deps=()
  local missing_brew_deps=()

  # Required dependencies
  if ! command -v yq &>/dev/null; then
    missing_deps+=("yq")
    missing_brew_deps+=("yq")
  fi

  if ! command -v xmlstarlet &>/dev/null; then
    missing_deps+=("xmlstarlet")
    missing_brew_deps+=("xmlstarlet")
  fi

  if ! command -v curl &>/dev/null; then
    missing_deps+=("curl")
  fi

  if [[ ${#missing_deps[@]} -eq 0 ]]; then
    return 0
  fi

  # Report missing dependencies
  printf 'Missing required dependencies:\n' >&2
  for dep in "${missing_deps[@]}"; do
    printf '  - %s\n' "${dep}" >&2
  done
  printf '\n'

  # Offer to install brew packages
  if [[ ${#missing_brew_deps[@]} -gt 0 ]]; then
    if ! command -v brew &>/dev/null; then
      printf 'Error: Homebrew not found. Install from https://brew.sh/\n' >&2
      return 1
    fi

    printf 'Install missing dependencies with Homebrew? [y/N]: '
    read -r response

    case "${response}" in
      [yY][eE][sS] | [yY])
        printf 'Installing: %s\n' "${missing_brew_deps[*]}"
        if brew install "${missing_brew_deps[@]}"; then
          printf 'Dependencies installed successfully.\n'
        else
          printf 'Error: Failed to install dependencies\n' >&2
          return 1
        fi
        ;;
      *)
        printf 'Installation cancelled. Please install manually:\n' >&2
        printf '  brew install %s\n' "${missing_brew_deps[*]}" >&2
        return 1
        ;;
    esac
  fi

  # Check if curl is missing (should be pre-installed on macOS)
  if ! command -v curl &>/dev/null; then
    printf 'Error: curl not found (should be pre-installed on macOS)\n' >&2
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

  # Parse XML with xmlstarlet
  local section_count
  if ! section_count=$(echo "${response}" | xmlstarlet sel -t -v "count(//Directory)" 2>/dev/null); then
    printf 'Warning: Could not parse library sections XML\n' >&2
    return 1
  fi

  if [[ -z "${section_count}" ]] || [[ "${section_count}" -eq 0 ]]; then
    printf 'Warning: No library sections found\n' >&2
    return 1
  fi

  printf 'Available library sections:\n'

  # Iterate through each Directory element
  local i
  for ((i = 1; i <= section_count; i++)); do
    local id type title
    id=$(echo "${response}" | xmlstarlet sel -t -v "//Directory[${i}]/@key" 2>/dev/null)
    type=$(echo "${response}" | xmlstarlet sel -t -v "//Directory[${i}]/@type" 2>/dev/null)
    title=$(echo "${response}" | xmlstarlet sel -t -v "//Directory[${i}]/@title" 2>/dev/null)

    [[ -z "${id}" ]] && continue

    # Get location for this section
    local section_detail location
    section_detail=$(curl -sf -m 5 -H "X-Plex-Token: ${token}" "${plex_server}/library/sections/${id}" 2>/dev/null || echo "")

    if [[ -n "${section_detail}" ]]; then
      # Extract path from first Location element
      location=$(echo "${section_detail}" | xmlstarlet sel -t -v "//Location[1]/@path" 2>/dev/null)

      if [[ -n "${location}" ]]; then
        printf '  [%s] %s (%s): %s\n' "${id}" "${title}" "${type}" "${location}"
      else
        printf '  [%s] %s (%s)\n' "${id}" "${title}" "${type}"
      fi
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

install_symlink() {
  local target="${SCRIPT_DIR}/transmission-done.sh"
  local symlink="${SYMLINK_DIR}/${SYMLINK_NAME}"

  printf '\nInstalling symlink...\n'

  # Verify target script exists
  if [[ ! -f "${target}" ]]; then
    printf 'Error: Target script not found: %s\n' "${target}" >&2
    return 1
  fi

  # Ensure target script is executable
  if ! chmod +x "${target}"; then
    printf 'Error: Failed to set execute permissions on %s\n' "${target}" >&2
    return 1
  fi
  printf 'Set execute permissions on: %s\n' "${target}"

  # Create symlink directory if it doesn't exist
  if [[ ! -d "${SYMLINK_DIR}" ]]; then
    printf 'Creating directory: %s\n' "${SYMLINK_DIR}"
    if ! mkdir -p "${SYMLINK_DIR}"; then
      printf 'Error: Failed to create %s\n' "${SYMLINK_DIR}" >&2
      return 1
    fi
  fi

  # Check if symlink already exists
  if [[ -L "${symlink}" ]]; then
    local current_target
    current_target=$(readlink "${symlink}")
    if [[ "${current_target}" == "${target}" ]]; then
      printf 'Symlink already exists and points to correct location.\n'
      return 0
    else
      printf 'Existing symlink points to: %s\n' "${current_target}"
      read -rp "Replace with new location? [y/N]: " replace
      case "${replace}" in
        [yY][eE][sS] | [yY])
          if ! rm "${symlink}"; then
            printf 'Error: Failed to remove existing symlink\n' >&2
            return 1
          fi
          ;;
        *)
          printf 'Keeping existing symlink.\n'
          return 0
          ;;
      esac
    fi
  elif [[ -e "${symlink}" ]]; then
    printf 'Error: %s exists but is not a symlink\n' "${symlink}" >&2
    return 1
  fi

  # Create the symlink
  if ln -s "${target}" "${symlink}"; then
    printf 'Symlink created: %s -> %s\n' "${symlink}" "${target}"
  else
    printf 'Error: Failed to create symlink\n' >&2
    return 1
  fi

  # Check if SYMLINK_DIR is in PATH
  if [[ ":${PATH}:" != *":${SYMLINK_DIR}:"* ]]; then
    printf '\n⚠️  Warning: %s is not in your PATH\n' "${SYMLINK_DIR}"
    printf 'Add this to your shell profile (~/.zshrc or ~/.bash_profile):\n'
    printf "  export PATH=\"%s:\$PATH\"\n" "${SYMLINK_DIR}"
  fi

  return 0
}

main() {
  printf '==============================================\n'
  printf 'Transmission-Plex Media Manager Installation\n'
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
  if ! write_config "${plex_server}" "${token}" "${media_path}"; then
    printf 'Error: Failed to write configuration\n' >&2
    exit 1
  fi

  # Install symlink
  if ! install_symlink; then
    printf '\nWarning: Symlink installation failed, but config was created successfully.\n' >&2
    printf 'You can still use the script directly: %s/transmission-done.sh\n' "${SCRIPT_DIR}"
  fi

  # Success summary
  printf '\n==============================================\n'
  printf 'Installation Complete!\n'
  printf '==============================================\n'
  printf 'Config file: %s\n' "${USER_CONFIG}"
  printf 'Script symlink: %s/%s\n' "${SYMLINK_DIR}" "${SYMLINK_NAME}"
  printf '\nNext steps:\n'
  printf '1. Test the installation:\n'
  printf '   transmission-done\n'
  printf '   (It will prompt for a directory to process)\n'
  printf '\n2. Configure Transmission:\n'
  printf '   - Open Transmission Preferences\n'
  printf '   - Go to "Downloading" tab\n'
  printf '   - Enable "Run script when download completes"\n'
  printf '   - Enter: %s/%s\n' "${SYMLINK_DIR}" "${SYMLINK_NAME}"
  printf '\n3. Download and enjoy!\n'
}

main "$@"
