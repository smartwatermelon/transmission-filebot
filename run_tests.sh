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

# Check if BATS is installed
if ! command -v bats &>/dev/null; then
  echo -e "${RED}Error: BATS is not installed${NC}"
  echo "Install with: brew install bats-core bats-support bats-assert"
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
