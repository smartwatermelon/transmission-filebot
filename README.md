# Transmission-Plex Media Manager

[![CI Tests](https://github.com/smartwatermelon/transmission-filebot/actions/workflows/test.yml/badge.svg)](https://github.com/smartwatermelon/transmission-filebot/actions/workflows/test.yml)

A robust solution for automatically processing downloaded media files from Transmission, organizing them with FileBot, and triggering Plex library updates. This project evolved from a simple cleanup script into a comprehensive media management solution.

## Prerequisites

- macOS (tested on Monterey and later)
- [Plex Media Server](https://www.plex.tv/media-server-downloads/) (running locally)
- [FileBot](https://www.filebot.net/) (licensed version)
- [Transmission](https://transmissionbt.com/) (for downloading)
- [Homebrew](https://brew.sh/) (for installing dependencies)
- Command line tools:
  - yq (`brew install yq`)
  - xmlstarlet (`brew install xmlstarlet`)
  - curl (usually pre-installed on macOS)

> **Note**: The installation wizard (`install.sh`) can automatically install missing dependencies with your permission.

## Installation

1. Clone this repository or download the scripts to your preferred location:

   ```bash
   git clone <repository-url>
   cd transmission-filebot
   ```

2. Run the installation wizard:

   ```bash
   ./install.sh
   ```

   The wizard will:
   - Check for required dependencies and offer to install them
   - Validate your Plex server is reachable
   - Guide you through obtaining a Plex authentication token
   - Display your Plex library sections to help choose the media path
   - Generate a complete configuration file at `~/.config/transmission-done/config.yml`
   - Create a symlink at `~/.local/bin/transmission-done`
   - Back up any existing configuration with a timestamp

That's it! The script is now installed and ready to use.

## Configuration

The setup wizard creates `~/.config/transmission-done/config.yml` automatically. If you need to modify it later:

```yaml
paths:
  default_home: /Users/yourusername
plex:
  server: http://localhost:32400
  token: your_plex_token_here
  media_path: /path/to/your/plex/media
logging:
  file: .filebot/logs/transmission-processing.log
  max_size: 10485760  # 10MB in bytes
```

### Transmission Integration

Configure Transmission to run the script automatically:

- Open Transmission
- Go to Preferences (⌘,)
- Navigate to the "Downloading" tab
- Check "Run script when download completes"
- Enter: `~/.local/bin/transmission-done` (or the full path shown during installation)

## How It Works

When Transmission completes a download:

1. The script validates the environment and configuration
2. Cleans up unwanted files (NFO, TXT, EXE)
3. Uses FileBot to:
   - Identify the media (TV show or movie)
   - Rename files according to Plex conventions
   - Move files to the appropriate Plex library folder
   - Download artwork and metadata
   - Import subtitles
4. Triggers a Plex library scan
5. Logs all actions for troubleshooting

## Manual Invocation

The script supports both automated (Transmission) and manual invocation modes.

### Terminal Mode

Double-click `process-media.command` or run from terminal:

```bash
./process-media.command
```

The script will:

1. Present a native macOS folder picker dialog
2. Process all media files in the selected folder
3. Show preview and ask for confirmation
4. Display macOS notifications on completion

### Drag-and-Drop Mode

Create `MediaProcessor.app` using Automator (see `CREATE_AUTOMATOR_APP.md`):

1. Drag a folder containing media files onto the app
2. The app processes the files automatically
3. Notifications indicate success or failure

### Manual Mode Features

- **Safety Checks**: Verifies files are complete (not being downloaded)
- **Preview**: Shows what changes will be made before processing
- **Confirmation**: Asks for approval before moving files
- **Notifications**: macOS notifications with success/failure sounds
- **No Transmission Required**: Works independently of Transmission

## NAS Storage Setup

If your Plex media library lives on a NAS (e.g., Synology) mounted via NFS, the NFS export settings must be configured correctly for FileBot to move files.

### NFS Export Settings (Synology DSM)

In **Control Panel → Shared Folder → [your share] → NFS Permissions**, create or edit the NFS rule:

| Setting | Value | Notes |
|---------|-------|-------|
| Hostname or IP | Your client's IP or subnet (e.g., `10.0.12.0/22`) | Restrict to your LAN |
| Privilege | **Read/Write** | Required for FileBot to move files |
| Squash | **Map all users to admin** | See explanation below |
| Security | **sys** | Standard UNIX authentication |
| Enable asynchronous | **Yes** | Better performance |
| Allow non-privileged ports | **Yes** | Required for macOS clients |
| Allow subfolder access | **Yes** | Media lives in subdirectories |

### Why "Map all users to admin"?

NFS permission checks happen **on the NAS**, not on your Mac. The macOS `noowners` mount option only affects how files appear locally — the NAS still enforces UNIX permissions based on the user ID (UID) it receives with each request.

The problem: macOS user UIDs (501, 502, etc.) don't match Synology user UIDs (admin = 1024). With "No mapping", the NAS receives your macOS UID and can't match it to any NAS user — so writes are denied even though local permissions look fine.

"Map all users to admin" solves this by remapping all NFS requests to the Synology admin user, which has full access to the shared folder.

### Directory Permissions

With "Map all users to admin", directories should be `rwxrwxrwx` (777). This is safe for a media server on a firewalled LAN.

If directories lose write permissions (FileBot will report `Access Denied`), fix from the NAS:

```bash
# SSH into your NAS (requires sudo even for admin):
ssh admin@your-nas
sudo find /volume1/YourShare/Media/ -type d -exec chmod 777 {} +
```

> **Important**: `chmod` from the macOS NFS client will fail with "Operation not permitted". Always fix permissions directly on the NAS via SSH.

### macOS NFS Mount

Mount the NFS share with `noowners`:

```bash
sudo mount -t nfs -o noowners your-nas.local:/volume1/YourShare /path/to/mount
```

After changing permissions on the NAS, you may need to remount to clear the NFS attribute cache:

```bash
sudo diskutil unmount force /path/to/mount
sudo mount -t nfs -o noowners your-nas.local:/volume1/YourShare /path/to/mount
```

### Containerized Transmission

If Transmission runs in a container (e.g., Docker/podman with the haugene image), it cannot directly invoke macOS scripts. The `transmission-trigger-watcher.sh` daemon bridges this:

1. The container writes a trigger file when a download completes
2. The watcher daemon (running on the host) polls for triggers every 60 seconds
3. It maps container paths to macOS NFS mount paths and invokes `transmission-done.sh`
4. Failed triggers are retried up to 5 times, then moved to `.dead` for manual inspection

## Troubleshooting

### Environment Variables

When Transmission runs the script, it does so with a limited environment that differs from your regular shell environment. The script receives:

1. **From Transmission**:
   - `TR_TORRENT_DIR`: Directory containing the downloaded files
   - `TR_TORRENT_NAME`: Name of the downloaded torrent
   - `TR_APP_VERSION`: Transmission version
   - `TR_TIME_LOCALTIME`: Local time of completion
   - `TR_TORRENT_HASH`: Torrent hash
   - `TR_TORRENT_ID`: Internal Transmission torrent ID

2. **System Environment**:
   - Limited `PATH` (usually just `/usr/bin:/bin:/usr/sbin:/sbin`)
   - No user environment variables (like those set in `.zshrc` or `.bash_profile`)
   - No `HOME` variable by default

This is why the script:

- Explicitly sets `PATH` to include `/usr/local/bin`
- Uses a configurable `default_home` in config.yml
- Sources all paths from the config file rather than environment variables

If you need to debug environment issues:

```bash
# Add this near the start of the script
env > /tmp/transmission-env.log
```

### Common Issues

1. **Script not running after download**
   - Check Transmission's script path setting
   - Verify script permissions (`chmod +x`)
   - Check the log file for errors

2. **FileBot errors**
   - Ensure FileBot is properly licensed
   - Verify FileBot is in your PATH
   - Check if the target media directory exists and is writable

3. **FileBot reports "Access Denied" or files not moving**
   - This is almost always a NAS/NFS permission issue, not a FileBot problem
   - Check that the target directory is writable (see [NAS Storage Setup](#nas-storage-setup))
   - FileBot logs both successful and failed moves with `[MOVE]` — check the log for `failed due to I/O error`

4. **Plex not updating**
   - Verify your Plex token is correct
   - Ensure Plex server is running
   - Check server URL in config.yml
   - Look for connection errors in the logs

### Debugging

1. Check the logs:

   ```bash
   tail -f ~/.filebot/logs/transmission-processing.log
   ```

2. Run the test suite:

   ```bash
   ./run_tests.sh
   ```

3. Verify Plex connectivity:

   ```bash
   curl -H "X-Plex-Token: your_token" http://localhost:32400/identity
   ```

## Testing

This project uses [BATS (Bash Automated Testing System)](https://github.com/bats-core/bats-core) for comprehensive testing.

### Prerequisites

Install BATS:

```bash
brew install bats-core
```

### Running Tests

Run all tests:

```bash
./run_tests.sh
```

Run only unit tests:

```bash
bats test/unit/*.bats
```

Run only integration tests:

```bash
bats test/integration/*.bats
```

Run a specific test file:

```bash
bats test/unit/test_mode_detection.bats
```

Run tests with verbose output:

```bash
bats -t test/unit/test_mode_detection.bats
```

### Test Structure

#### Unit Tests (`test/unit/`)

Test individual functions in isolation:

- `test_mode_detection.bats` - Invocation mode detection (automated vs manual)
- `test_type_detection.bats` - Media type heuristics (TV vs movie)
- `test_plex_api.bats` - Plex API functions and library scans
- `test_filebot.bats` - FileBot processing and fallback chains
- `test_error_logging.bats` - Error analysis and reporting
- `test_file_safety.bats` - File readiness and safety checks

#### Integration Tests (`test/integration/`)

Test complete end-to-end workflows:

- `test_tv_workflow.bats` - Complete TV show processing workflow
- `test_movie_workflow.bats` - Complete movie processing workflow
- `test_manual_mode.bats` - Manual invocation mode (user-initiated)

### Test Coverage

- **114 comprehensive tests** covering all major functionality
- **84 unit tests** verify individual components in isolation
- **30 integration tests** verify complete end-to-end workflows
- All tests run in TEST_MODE to avoid side effects
- Comprehensive coverage of error conditions and edge cases
- Mock implementations for FileBot and Plex API calls
- Test helpers for common assertions and setup

### Writing Tests

Tests follow BATS conventions:

```bash
@test "description of what is being tested" {
  # Setup
  export TEST_MODE=true
  local test_dir="${TEST_TEMP_DIR}/test"
  mkdir -p "${test_dir}"

  # Execute
  run function_to_test "${test_dir}"

  # Assert
  assert_success
  assert_equal "expected" "${output}"
}
```

See existing tests in `test/unit/` and `test/integration/` for more examples.

## Project History

This project began as a simple "done-cleanup" script that removed unwanted files after Transmission downloads completed. Key evolution points:

- **Initial Version**: Basic cleanup of NFO, TXT, and EXE files
- **FileBot Integration**: Added automated media organization and renaming
- **Plex Integration**: Implemented automatic library updates
- **Robust Error Handling**: Added retry logic and comprehensive logging
- **Configuration Management**: Moved from hardcoded values to YAML configuration
- **Test Suite (2026-01)**: Comprehensive BATS test infrastructure with 114 tests
  - 84 unit tests for individual functions
  - 30 integration tests for complete workflows
  - Continuous integration with GitHub Actions
- **Unified Installer (2026-01)**: One-command installation with `install.sh`
  - Automatic dependency installation with user consent
  - Plex server validation and token configuration
  - Complete config file generation
  - Library introspection with proper XML parsing
  - Automatic symlink creation to `~/.local/bin`

The current version is a comprehensive media automation solution with proper error handling, logging, configuration management, and extensive testing capabilities.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

Please ensure tests pass before submitting: `./run_tests.sh`

## License

MIT License - See LICENSE file for details
