#!/usr/bin/env bash

# Strict mode
set -euo pipefail
IFS=$'\n\t'

# Debug mode: Set DEBUG_MODE=1 to enable verbose logging including credentials
# Example: DEBUG_MODE=1 ./install.sh
# WARNING: Debug mode will print passwords to stderr - only use for troubleshooting

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

  if ! command -v jq &>/dev/null; then
    missing_deps+=("jq")
    missing_brew_deps+=("jq")
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

  printf '\nPlex Server URL\n' >&2
  printf '  Default: http://localhost:32400\n' >&2
  printf '  Or specify: http://YOUR_SERVER_IP:32400\n' >&2
  read -rp "Plex server URL [http://localhost:32400]: " plex_server

  # Use default if empty
  plex_server="${plex_server:-http://localhost:32400}"

  echo "${plex_server}"
}

validate_plex_server() {
  local plex_server="$1"

  printf 'Validating Plex server at %s...\n' "${plex_server}" >&2

  # Try to connect to the identity endpoint without auth
  if ! curl -sf -m 5 "${plex_server}/identity" >/dev/null 2>&1; then
    printf 'Error: Cannot connect to Plex server at %s\n' "${plex_server}" >&2
    printf 'Ensure Plex Media Server is running and accessible.\n' >&2
    return 1
  fi

  printf 'Plex server is reachable.\n' >&2
  return 0
}

get_credentials() {
  local username password

  printf 'Enter your Plex account credentials\n' >&2
  read -rp "Plex username/email: " username

  if [[ -z "${username}" ]]; then
    printf 'Error: Username is required\n' >&2
    return 1
  fi

  read -rsp "Plex password: " password
  printf '\n' >&2

  if [[ -z "${password}" ]]; then
    printf 'Error: Password is required\n' >&2
    return 1
  fi

  echo "${username}:${password}"
}

fetch_token_from_plex() {
  local credentials="$1"
  local username password

  # Extract username and password safely (handles colons in password)
  username="${credentials%%:*}"
  password="${credentials#*:}"

  if [[ -n "${DEBUG_MODE:-}" ]]; then
    printf '[DEBUG] Username: %s\n' "${username}" >&2
    printf '[DEBUG] Password length: %d characters\n' "${#password}" >&2
    printf '[DEBUG] Calling plex.tv API...\n' >&2
  fi

  printf 'Authenticating with plex.tv...\n' >&2

  # Get authentication token from plex.tv
  # Using original plex-token.sh method with --data-urlencode
  local auth_response
  if ! auth_response=$(curl -s -X POST 'https://plex.tv/users/sign_in.json' \
    -H 'X-Plex-Client-Identifier: transmission-done-installer' \
    -H 'X-Plex-Product: transmission-done' \
    -H 'X-Plex-Version: 1.0' \
    --data-urlencode "user[login]=${username}" \
    --data-urlencode "user[password]=${password}"); then
    printf 'Error: Network request failed\n' >&2
    unset username password
    return 1
  fi

  if [[ -n "${DEBUG_MODE:-}" ]]; then
    # Check if response contains authToken (success) or error
    if echo "${auth_response}" | jq -e '.user.authToken' >/dev/null 2>&1; then
      printf '[DEBUG] API Response: Authentication successful (token received)\n' >&2
    else
      # Show error message but not any tokens
      local error_msg
      error_msg=$(echo "${auth_response}" | jq -r '.error // "Unknown error"' 2>/dev/null)
      printf '[DEBUG] API Response: Authentication failed - %s\n' "${error_msg}" >&2
      printf '[DEBUG] Full response (no token): %s\n' "${auth_response}" >&2
    fi
  fi

  # Clear sensitive data from memory
  unset username password

  # Extract the authentication token using jq
  local auth_token
  if ! auth_token=$(echo "${auth_response}" | jq -r '.user.authToken' 2>/dev/null); then
    printf 'Error: Failed to parse authentication response\n' >&2
    printf 'Response: %s\n' "${auth_response}" >&2
    return 1
  fi

  if [[ "${auth_token}" == "null" ]] || [[ -z "${auth_token}" ]]; then
    printf 'Error: Authentication failed. Check your credentials.\n' >&2
    # Try to extract error message from response
    local error_msg
    error_msg=$(echo "${auth_response}" | jq -r '.error // empty' 2>/dev/null)
    if [[ -n "${error_msg}" ]]; then
      printf 'Server error: %s\n' "${error_msg}" >&2
    fi
    return 1
  fi

  printf 'Authentication successful!\n' >&2
  echo "${auth_token}"
}

get_plex_token() {
  local token choice

  printf '\nPlex Authentication Token\n' >&2
  printf '  Option 1: Automated - Enter Plex credentials (recommended)\n' >&2
  printf '  Option 2: Manual - Enter existing token\n' >&2
  printf '\n' >&2
  read -rp "Select option [1/2]: " choice

  case "${choice}" in
    1)
      # Automated: Get credentials and fetch token from plex.tv
      local credentials
      credentials=$(get_credentials) || return 1

      token=$(fetch_token_from_plex "${credentials}") || {
        unset credentials
        return 1
      }
      unset credentials
      ;;
    2)
      # Manual: User provides token directly
      printf '\nGet your token from:\n' >&2
      printf '  https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/\n' >&2
      printf '\n' >&2
      read -rsp "Enter your Plex token: " token
      printf '\n' >&2

      if [[ -z "${token}" ]]; then
        printf 'Error: Token is required\n' >&2
        return 1
      fi
      ;;
    *)
      printf 'Invalid option. Please select 1 or 2.\n' >&2
      return 1
      ;;
  esac

  # Detect and warn about claim tokens
  if [[ "${token}" == claim-* ]]; then
    printf '\n⚠️  Warning: This appears to be a claim token (starts with "claim-")\n' >&2
    printf 'Claim tokens from https://www.plex.tv/claim/ expire after 4 minutes\n' >&2
    printf 'and are NOT valid for API authentication.\n' >&2
    printf '\nPlease use Option 1 (automated) or get a permanent token from:\n' >&2
    printf '  https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/\n' >&2
    return 1
  fi

  echo "${token}"
}

validate_token() {
  local plex_server="$1"
  local token="$2"

  printf 'Validating token with Plex server...\n' >&2

  # Test the token by making an authenticated request
  if ! curl -sf -m 5 -H "X-Plex-Token: ${token}" "${plex_server}/identity" >/dev/null 2>&1; then
    printf 'Error: Token validation failed\n' >&2
    printf 'The token may be invalid or expired.\n' >&2
    return 1
  fi

  printf 'Token validated successfully.\n' >&2
  return 0
}

get_plex_library_info() {
  local plex_server="$1"
  local token="$2"

  printf '\nQuerying Plex library sections...\n' >&2

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

  printf 'Available library sections:\n' >&2

  # Collect unique paths to stdout for caller
  local -a paths=()

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

    if [[ -n "${DEBUG_MODE:-}" ]]; then
      printf '[DEBUG] Section %s detail response length: %d bytes\n' "${id}" "${#section_detail}" >&2
      if [[ -n "${section_detail}" ]]; then
        printf '[DEBUG] Section %s XML (first 500 chars):\n%s\n' "${id}" "${section_detail:0:500}" >&2
      fi
    fi

    if [[ -n "${section_detail}" ]]; then
      # Extract path from first Location element
      location=$(echo "${section_detail}" | xmlstarlet sel -t -v "//Location[1]/@path" 2>/dev/null)

      if [[ -n "${DEBUG_MODE:-}" ]]; then
        printf '[DEBUG] Section %s extracted location: "%s"\n' "${id}" "${location}" >&2
      fi

      if [[ -n "${location}" ]]; then
        printf '  [%s] %s (%s): %s\n' "${id}" "${title}" "${type}" "${location}" >&2
        # Collect path for return value
        paths+=("${location}")
      else
        printf '  [%s] %s (%s)\n' "${id}" "${title}" "${type}" >&2
      fi
    else
      printf '  [%s] %s (%s)\n' "${id}" "${title}" "${type}" >&2
    fi
  done

  # Return unique paths to stdout (one per line)
  if [[ ${#paths[@]} -gt 0 ]]; then
    printf '%s\n' "${paths[@]}" | sort -u
  fi

  return 0
}

get_media_path() {
  local plex_server="$1"
  local token="$2"
  local media_path

  printf '\nPlex Media Path\n' >&2
  printf '  This is the root path where FileBot will organize your media.\n' >&2

  # Try to get paths from Plex library sections
  local plex_paths
  plex_paths=$(get_plex_library_info "${plex_server}" "${token}")
  local get_plex_exit=$?

  # If we got paths from Plex, present them as options
  if [[ ${get_plex_exit} -eq 0 ]] && [[ -n "${plex_paths}" ]]; then
    printf '\nDetected Plex library paths:\n' >&2

    local -a path_array=()
    while IFS= read -r path; do
      [[ -n "${path}" ]] && path_array+=("${path}")
    done <<<"${plex_paths}"

    # Show numbered options
    local i
    for i in "${!path_array[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${path_array[i]}" >&2
    done
    printf '  %d) Enter custom path\n' "$((${#path_array[@]} + 1))" >&2
    printf '\n' >&2

    read -rp "Select option [1-$((${#path_array[@]} + 1))]: " selection

    if [[ "${selection}" =~ ^[0-9]+$ ]]; then
      if [[ "${selection}" -ge 1 && "${selection}" -le "${#path_array[@]}" ]]; then
        # User selected a Plex path (options 1 to N)
        media_path="${path_array[$((selection - 1))]}"
        printf 'Using: %s\n' "${media_path}" >&2
      elif [[ "${selection}" -eq $((${#path_array[@]} + 1)) ]]; then
        # User selected custom path option (N+1)
        printf '\n' >&2
        read -rp "Enter custom path: " media_path
      else
        # Out of range number
        printf 'Invalid selection. Enter custom path:\n' >&2
        read -rp "Plex media path: " media_path
      fi
    else
      # Non-numeric input
      printf 'Invalid input. Enter custom path:\n' >&2
      read -rp "Plex media path: " media_path
    fi
  else
    # No Plex paths available, ask for manual entry
    printf '  Example: /Users/yourname/Media\n' >&2
    printf '  Example: /Volumes/Storage/PlexMedia\n' >&2
    printf '\n' >&2
    read -rp "Plex media path: " media_path
  fi

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
        printf 'Directory created.\n' >&2
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
    printf 'Creating config directory: %s\n' "${USER_CONFIG_DIR}" >&2
    mkdir -p "${USER_CONFIG_DIR}"
  fi

  # Backup existing config if present
  if [[ -f "${USER_CONFIG}" ]]; then
    local backup
    backup="${USER_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    printf 'Backing up existing config to: %s\n' "${backup}" >&2
    cp "${USER_CONFIG}" "${backup}"
  fi

  # Write new config
  printf 'Writing config to: %s\n' "${USER_CONFIG}" >&2
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

  printf 'Config file written successfully.\n' >&2
  return 0
}

install_symlink() {
  local target="${SCRIPT_DIR}/transmission-done.sh"
  local symlink="${SYMLINK_DIR}/${SYMLINK_NAME}"

  printf '\nInstalling symlink...\n' >&2

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
  printf 'Set execute permissions on: %s\n' "${target}" >&2

  # Create symlink directory if it doesn't exist
  if [[ ! -d "${SYMLINK_DIR}" ]]; then
    printf 'Creating directory: %s\n' "${SYMLINK_DIR}" >&2
    if ! mkdir -p "${SYMLINK_DIR}"; then
      printf 'Error: Failed to create %s\n' "${SYMLINK_DIR}" >&2
      return 1
    fi
  fi

  # Check if symlink already exists
  if [[ -e "${symlink}" || -L "${symlink}" ]]; then
    if [[ -L "${symlink}" ]]; then
      local current_target
      current_target=$(readlink "${symlink}")
      if [[ "${current_target}" == "${target}" ]]; then
        printf 'Symlink already exists and points to correct location.\n' >&2
        return 0
      else
        printf 'Warning: Overwriting existing symlink (was: %s)\n' "${current_target}" >&2
      fi
    else
      # Regular file exists, not a symlink
      printf 'Error: %s exists but is not a symlink (cannot overwrite)\n' "${symlink}" >&2
      return 1
    fi
  fi

  # Create or overwrite the symlink (using -f to force)
  if ln -sf "${target}" "${symlink}"; then
    printf 'Symlink created: %s -> %s\n' "${symlink}" "${target}" >&2
  else
    printf 'Error: Failed to create symlink\n' >&2
    return 1
  fi

  # Check if SYMLINK_DIR is in PATH
  if [[ ":${PATH}:" != *":${SYMLINK_DIR}:"* ]]; then
    printf '\n⚠️  Warning: %s is not in your PATH\n' "${SYMLINK_DIR}" >&2
    printf 'Add this to your shell profile (~/.zshrc or ~/.bash_profile):\n' >&2
    printf "  export PATH=\"%s:\$PATH\"\n" "${SYMLINK_DIR}" >&2
  fi

  return 0
}

main() {
  printf '==============================================\n' >&2
  printf 'Transmission-Plex Media Manager Installation\n' >&2
  printf '==============================================\n' >&2

  if [[ -n "${DEBUG_MODE:-}" ]]; then
    printf '\n⚠️  DEBUG MODE ENABLED - Credentials will be logged\n' >&2
    printf '==============================================\n\n' >&2
  fi

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

  # Get media path (will query Plex library paths and offer as options)
  local media_path
  media_path=$(get_media_path "${plex_server}" "${token}") || exit 1

  # Write configuration file
  if ! write_config "${plex_server}" "${token}" "${media_path}"; then
    printf 'Error: Failed to write configuration\n' >&2
    exit 1
  fi

  # Install symlink
  if ! install_symlink; then
    printf '\nWarning: Symlink installation failed, but config was created successfully.\n' >&2
    printf 'You can still use the script directly: %s/transmission-done.sh\n' "${SCRIPT_DIR}" >&2
  fi

  # Success summary
  printf '\n==============================================\n' >&2
  printf 'Installation Complete!\n' >&2
  printf '==============================================\n' >&2
  printf 'Config file: %s\n' "${USER_CONFIG}" >&2
  printf 'Script symlink: %s/%s\n' "${SYMLINK_DIR}" "${SYMLINK_NAME}" >&2
  printf '\nNext steps:\n' >&2
  printf '1. Test the installation:\n' >&2
  printf '   transmission-done\n' >&2
  printf '   (It will prompt for a directory to process)\n' >&2
  printf '\n2. Configure Transmission:\n' >&2
  printf '   - Open Transmission Preferences\n' >&2
  printf '   - Go to "Downloading" tab\n' >&2
  printf '   - Enable "Run script when download completes"\n' >&2
  printf '   - Enter: %s/%s\n' "${SYMLINK_DIR}" "${SYMLINK_NAME}" >&2
  printf '\n3. Download and enjoy!\n' >&2
}

main "$@"
