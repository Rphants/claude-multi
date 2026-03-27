# Claude Multi-Instance Manager

Run multiple Claude Desktop instances with fully isolated logins, configs, and MCP servers.

## Quick Start

```bash
curl -O https://raw.githubusercontent.com/Rphants/claude-multi/main/claude-multi.sh
chmod +x claude-multi.sh
./claude-multi.sh personal
./claude-multi.sh work
./claude-multi.sh wrapper personal
./claude-multi.sh wrapper work
```

## Commands

| Command | Description |
|---|---|
| `./claude-multi.sh` | Interactive menu |
| `./claude-multi.sh <name>` | Create or launch instance |
| `./claude-multi.sh list` | List all instances |
| `./claude-multi.sh delete <name>` | Delete an instance |
| `./claude-multi.sh wrapper <name>` | Create .app for Dock/Spotlight |
| `./claude-multi.sh restore` | Restore default config |
| `./claude-multi.sh diagnose` | Troubleshoot |
| `./claude-multi.sh fix` | Repair wrappers |

## Security

Hardened fork of claude-desktop-multi-instance:
- Path traversal protection
- Atomic symlink ops (no TOCTOU race)
- Explicit file permissions (700/644/755)
- Auto backup cleanup
- set -euo pipefail
- No network calls, no credential access

## Environments

| Branch | Purpose |
|---|---|
| main | Production |
| staging | Pre-release validation |
| testing | Active development |

## License

MIT
