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
  - jq (`brew install jq`)
  - curl (usually pre-installed on macOS)
  - netcat (`brew install netcat`)

## Installation

1. Clone this repository or download the scripts to your preferred location:

   ```bash
   git clone <repository-url>
   cd transmission-filebot
   ```

2. Create the necessary configuration directory:

   ```bash
   mkdir -p ~/.config/transmission-done
   ```

3. Copy the sample config file:

   ```bash
   cp config.yml ~/.config/transmission-done/
   ```

4. Generate your Plex token:

   ```bash
   ./plex-token.sh
   ```

   Follow the prompts to enter your Plex credentials. The script will provide you with a token to add to your config.yml.

## Configuration

1. Edit `~/.config/transmission-done/config.yml` with your settings:

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

2. Configure Transmission to run the script:
   - Open Transmission
   - Go to Preferences (⌘,)
   - Navigate to the "Downloading" tab
   - Check "Run script when download completes"
   - Enter the full path to `transmission-done.sh`

3. Ensure the script is executable:

   ```bash
   chmod +x transmission-done.sh
   chmod +x plex-token.sh
   ```

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

3. **Plex not updating**
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
   TEST_MODE=true ./transmission-done.sh
   ```

3. Verify Plex connectivity:

   ```bash
   curl -H "X-Plex-Token: your_token" http://localhost:32400/identity
   ```

## Project History

This project began as a simple "done-cleanup" script that removed unwanted files after Transmission downloads completed. Key evolution points:

- **Initial Version**: Basic cleanup of NFO, TXT, and EXE files
- **FileBot Integration**: Added automated media organization and renaming
- **Plex Integration**: Implemented automatic library updates
- **Robust Error Handling**: Added retry logic and comprehensive logging
- **Configuration Management**: Moved from hardcoded values to YAML configuration
- **Test Suite**: Added comprehensive testing capabilities
- **Token Management**: Added secure Plex token generation utility

The current version represents a complete rewrite with proper error handling, logging, configuration management, and extensive testing capabilities.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

## License

MIT License - See LICENSE file for details
