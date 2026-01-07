#!/usr/bin/env bash

# Test runner for transmission-plex media manager
# Runs all BATS unit and integration tests

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Check and install dependencies
check_dependencies() {
  local missing_deps=()
  local missing_brew_deps=()

  # Required BATS packages
  if ! command -v bats &>/dev/null; then
    missing_deps+=("bats-core")
    missing_brew_deps+=("bats-core")
  fi

  # Check for bats-support and bats-assert by looking for their libraries
  # These are typically installed alongside bats-core but are separate packages
  local bats_lib_dir
  if command -v bats &>/dev/null; then
    bats_lib_dir="$(brew --prefix)/lib"
    if [[ ! -d "${bats_lib_dir}/bats-support" ]]; then
      missing_deps+=("bats-support")
      missing_brew_deps+=("bats-support")
    fi
    if [[ ! -d "${bats_lib_dir}/bats-assert" ]]; then
      missing_deps+=("bats-assert")
      missing_brew_deps+=("bats-assert")
    fi
  else
    # If bats isn't installed, we'll need support and assert too
    missing_deps+=("bats-support" "bats-assert")
    missing_brew_deps+=("bats-support" "bats-assert")
  fi

  if [[ ${#missing_deps[@]} -eq 0 ]]; then
    return 0
  fi

  # Report missing dependencies
  echo -e "${RED}Missing required test dependencies:${NC}"
  for dep in "${missing_deps[@]}"; do
    printf '  - %s\n' "${dep}"
  done
  echo

  # Offer to install brew packages
  if [[ ${#missing_brew_deps[@]} -gt 0 ]]; then
    if ! command -v brew &>/dev/null; then
      echo -e "${RED}Error: Homebrew not found. Install from https://brew.sh/${NC}"
      return 1
    fi

    echo -e "${YELLOW}Install missing dependencies with Homebrew? [y/N]:${NC} "
    read -r response

    case "${response}" in
      [yY][eE][sS] | [yY])
        echo -e "${BLUE}Installing: ${missing_brew_deps[*]}${NC}"
        if brew install "${missing_brew_deps[@]}"; then
          echo -e "${GREEN}Dependencies installed successfully.${NC}"
          echo
        else
          echo -e "${RED}Error: Failed to install dependencies${NC}"
          return 1
        fi
        ;;
      *)
        echo -e "${YELLOW}Installation cancelled. Please install manually:${NC}"
        echo "  brew install ${missing_brew_deps[*]}"
        return 1
        ;;
    esac
  fi

  return 0
}

if ! check_dependencies; then
  exit 1
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}transmission-plex Test Suite${NC}"
echo -e "${BLUE}========================================${NC}"
echo

# Run unit tests
echo -e "${YELLOW}Running Unit Tests...${NC}"
echo -e "${BLUE}────────────────────────────────────────${NC}"
if bats test/unit/*.bats; then
  echo -e "${GREEN}✓ Unit tests passed${NC}"
  UNIT_RESULT=0
else
  echo -e "${RED}✗ Unit tests failed${NC}"
  UNIT_RESULT=1
fi
echo

# Run integration tests
echo -e "${YELLOW}Running Integration Tests...${NC}"
echo -e "${BLUE}────────────────────────────────────────${NC}"
if bats test/integration/*.bats; then
  echo -e "${GREEN}✓ Integration tests passed${NC}"
  INTEGRATION_RESULT=0
else
  echo -e "${RED}✗ Integration tests failed${NC}"
  INTEGRATION_RESULT=1
fi
echo

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"

if [[ ${UNIT_RESULT} -eq 0 ]]; then
  echo -e "Unit Tests:        ${GREEN}✓ PASSED${NC}"
else
  echo -e "Unit Tests:        ${RED}✗ FAILED${NC}"
fi

if [[ ${INTEGRATION_RESULT} -eq 0 ]]; then
  echo -e "Integration Tests: ${GREEN}✓ PASSED${NC}"
else
  echo -e "Integration Tests: ${RED}✗ FAILED${NC}"
fi

echo -e "${BLUE}========================================${NC}"

# Exit with failure if any tests failed
if [[ ${UNIT_RESULT} -ne 0 ]] || [[ ${INTEGRATION_RESULT} -ne 0 ]]; then
  echo -e "${RED}Some tests failed${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi
