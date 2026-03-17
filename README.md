# Claude Docker

Containerized drop-in replacement for Claude Code - run worry-free in `--dangerously-skip-permissions` mode with complete isolation. Pre-configured MCP servers, host GPU access, conda environment mounting, and modular plugin system for effortless customization.

---

## Prerequisites

**Required:**
- ✅ Claude Code authentication
- ✅ Docker installation

**Everything else is optional** - the container runs fine without any additional setup.

---

## Quick Start

### Linux / macOS

```bash
# 1. Clone and enter directory
git clone https://github.com/LORDofDOOM/claude-docker.git
cd claude-docker

# 2. Setup environment (completely optional - skip if you don't need custom config)
cp .env.example .env
nano .env  # Add any optional configs

# 3. Install (use sudo for GPU support)
sudo ./src/install.sh  # Or just ./src/install.sh without GPU

# 4. Run from any project
cd ~/your-project
claude-docker
```

Installer notes:
- Alias is added to your detected shell RC file (`.bashrc`, `.bash_profile`, `.zshrc`, or `.profile`)
- Persistent data defaults to `~/.claude-docker`; override with `CLAUDE_DOCKER_HOME=/path/to/writable/dir`

### Windows

```powershell
# 1. Clone and enter directory
git clone https://github.com/LORDofDOOM/claude-docker.git
cd claude-docker

# 2. Setup environment (completely optional)
copy .env.example .env
notepad .env  # Add any optional configs

# 3. Install as global .NET tool (one-time)
install-windows.bat

# 4. Open a NEW terminal, then run from any project
cd C:\your-project
claude-docker
```

**Requirements:** [.NET SDK 10+](https://dotnet.microsoft.com/download) and [Docker Desktop](https://www.docker.com/products/docker-desktop/) with WSL2 backend.

Installer notes:
- Installs `claude-docker` as a .NET global tool (`~/.dotnet/tools`, already in PATH)
- Sets `CLAUDE_DOCKER_PROJECT` environment variable to locate the repo
- Persistent data defaults to `%USERPROFILE%\.claude-docker`; override with `CLAUDE_DOCKER_HOME`
- Conda host-mount is not supported on Windows (Windows paths are incompatible with Linux container paths)

**That's it!** Claude runs in an isolated Docker container with access to your project directory.

---

## Command Line Reference

### Basic Usage
```bash
claude-docker                       # Start Claude in current directory
claude-docker --podman              # Use podman instead of docker
claude-docker --continue            # Resume previous conversation
claude-docker --rebuild             # Force rebuild Docker image
claude-docker --rebuild --no-cache  # Rebuild without using cache
claude-docker --memory 8g           # Set container memory limit
claude-docker --gpus all            # Enable GPU access (requires nvidia-docker)
claude-docker --cc-version 2.0.64   # Install specific Claude Code version
```

### Available Flags

| Flag | Description | Example |
|------|-------------|---------|
| `--podman` | Use podman instead of docker | `claude-docker --podman` |
| `--continue` | Resume previous conversation in current directory | `claude-docker --continue` |
| `--rebuild` | Force rebuild of the Docker image | `claude-docker --rebuild` |
| `--no-cache` | When rebuilding, don't use Docker cache | `claude-docker --rebuild --no-cache` |
| `--memory` | Set container memory limit | `claude-docker --memory 8g` |
| `--gpus` | Enable GPU access | `claude-docker --gpus all` |
| `--cc-version` | Install specific Claude Code version (requires rebuild) | `claude-docker --rebuild --cc-version 2.0.64` |

### Automatic Rebuilds

The Docker image is automatically rebuilt when a new git commit is detected in the claude-docker repository. This means changes to `Dockerfile`, `mcp-servers.txt`, `.env`, or any other build file take effect after you commit and run `claude-docker` — no `--rebuild` flag needed.

The current commit hash is stored in `~/.claude-docker/.build-hash` and compared on each launch.

### Environment Variable Defaults
Set defaults in your `.env` file:
```bash
DOCKER_MEMORY_LIMIT=8g          # Default memory limit
DOCKER_GPU_ACCESS=all           # Default GPU access
```

Set this in your shell if you want to override the default persistent directory:
```bash
# Linux / macOS
export CLAUDE_DOCKER_HOME=/path/to/writable/dir

# Windows (PowerShell)
setx CLAUDE_DOCKER_HOME "C:\path\to\writable\dir"
```

### Examples
```bash
# Resume work with 16GB memory limit
claude-docker --continue --memory 16g

# Rebuild after updating .env file
claude-docker --rebuild

# Use GPU for ML tasks
claude-docker --gpus all

# Rollback to specific Claude Code version
claude-docker --rebuild --cc-version 2.0.64

# Install latest version after rollback
claude-docker --rebuild
```

---

## Optional Configuration

All configuration below is optional. The container works out-of-the-box without any of these settings.

### Environment Variables (.env file)

**All environment variables are completely optional.** Only configure what you need:

#### Telegram Notifications
Get Telegram notifications when Claude completes tasks, hits errors, or needs your input — powered by the [mcp-communicator-telegram](https://github.com/qpd-v/mcp-communicator-telegram) MCP server.
```bash
TELEGRAM_BOT_TOKEN=your_telegram_bot_token
TELEGRAM_CHAT_ID=your_telegram_chat_id
```
**Setup:**
1. Message [@BotFather](https://t.me/BotFather) on Telegram, send `/newbot`, follow prompts
2. Send `/start` to your new bot
3. Get your chat ID from `https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates`

**How it works:**
- Telegram is an MCP tool (`notify_user` / `ask_user`), not a background service. Claude decides when to use it based on the `CLAUDE.md` notification protocol.
- `notify_user` — sends one-way status updates (task complete, milestone reached)
- `ask_user` — sends a question and waits for your reply via Telegram
- Claude will **not** send messages at the idle prompt. It sends notifications when it finishes a task, encounters an error, or needs your input.

**Important:** The notification protocol is defined in the `CLAUDE.md` template. If you customized your persistent `CLAUDE.md` before the Telegram protocol was added, you need to reset it:
```bash
# Linux / macOS
rm "${CLAUDE_DOCKER_HOME:-$HOME/.claude-docker}/claude-home/CLAUDE.md"

# Windows
del "%USERPROFILE%\.claude-docker\claude-home\CLAUDE.md"
```
Then rebuild with `claude-docker --rebuild` to copy the fresh template.

#### Shared Native Claude Configuration
By default, claude-docker uses its own isolated configuration at `~/.claude-docker/claude-home/`. If you also use Claude Code natively (just running `claude` on the host), you can share configuration so both environments have the same memory, sessions, settings, and conversation history.

```bash
SHARE_NATIVE_CLAUDE=true
```

| | `false` (default) | `true` |
|---|---|---|
| **Config location** | `~/.claude-docker/claude-home/` | Host's `~/.claude/` |
| **Memory** | Isolated | Shared |
| **Session history** | Isolated (per project) | Shared (with path linking) |
| **CLAUDE.md / settings** | Isolated | Shared |
| **Commands / Agents** | Isolated | Shared |
| **`--continue`** | Only resumes docker sessions | Resumes across native and docker |
| **MCP servers** | Always separate (stored in `.claude.json`) | Always separate |

When enabled, `--continue` works across both — start a task with `claude-docker`, then resume it with native `claude` (or vice versa) in the same project folder.

**Note:** Each project directory gets its own session history regardless of this setting. Running `claude-docker` in `D:\ProjectA` and `D:\ProjectB` will never share sessions with each other.

#### Extra Directory Mounts
Mount additional host directories into the container for Claude to access. Useful for shared libraries, reference projects, or source code that lives outside the current project folder.

```bash
# Semicolon-separated list of directories
# Append :ro for read-only access
EXTRA_MOUNT_DIRS=D:\Projects\SharedLib:ro;D:\OtherProject
```

Directories are mounted under `/mnt/` using the folder name:
- `D:\Projects\SharedLib` → `/mnt/SharedLib` (read-only)
- `D:\OtherProject` → `/mnt/OtherProject` (read-write)

Linux example:
```bash
EXTRA_MOUNT_DIRS=/home/user/shared-code:ro;/home/user/other-project
```

#### Host Network Access
By default, the container can reach services running on your host machine via `host.docker.internal`. For example, if you have a dev server on port 9000, use `http://host.docker.internal:9000` from inside the container (e.g. with Playwright).

If you need full host network access (so `localhost` inside the container maps directly to the host), enable host network mode:

```bash
DOCKER_NETWORK_MODE=host
```

| Mode | How to reach host port 9000 | Use case |
|---|---|---|
| Default (bridge) | `http://host.docker.internal:9000` | Works out of the box, no config needed |
| `DOCKER_NETWORK_MODE=host` | `http://localhost:9000` | Full host network, useful for Playwright testing local apps |

**Note:** `--network host` disables Docker's network isolation. The container shares the host's network stack entirely. Only use this when you need direct localhost access.

#### Conda Integration
Mount your host conda environments and packages into the container:
```bash
# Primary conda installation path
CONDA_PREFIX=/path/to/your/conda

# Additional conda directories (space-separated list)
# Directories are mounted to the same path inside the container
# Automatic detection:
#   - Paths with "*env*" are added to CONDA_ENVS_DIRS (for environments)
#   - Paths with "*pkg*" are added to CONDA_PKGS_DIRS (for package cache)
CONDA_EXTRA_DIRS="/path/to/envs /path/to/pkgs"
```

All your conda environments work exactly as they do on your host system - no Dockerfile modifications needed.

#### System Packages
Additional apt packages beyond the Dockerfile defaults:
```bash
SYSTEM_PACKAGES="libopenslide0 libgdal-dev"
```
**Note:** Adding system packages requires rebuilding the image with `claude-docker --rebuild`.

### Git & SSH Configuration

#### Git Credentials
Git configuration (global username and email) is automatically loaded from your host system during Docker build. Commits appear as you.

**Note:** Whether Claude uses git at all is controlled by your `CLAUDE.md` prompt engineering. The default configuration does NOT include git behaviors - customize after installation if needed.

#### SSH Keys for Git Push
Claude Docker uses dedicated SSH keys (separate from your personal keys for security):

**Linux / macOS:**
```bash
# 1. Create directory and generate key
CLAUDE_DOCKER_DIR="${CLAUDE_DOCKER_HOME:-$HOME/.claude-docker}"
mkdir -p "$CLAUDE_DOCKER_DIR/ssh"
ssh-keygen -t rsa -b 4096 -f "$CLAUDE_DOCKER_DIR/ssh/id_rsa" -N ''

# 2. Add public key to GitHub
cat "$CLAUDE_DOCKER_DIR/ssh/id_rsa.pub"
# Copy output and add to: GitHub → Settings → SSH and GPG keys → New SSH key

# 3. Test connection
ssh -T git@github.com -i "$CLAUDE_DOCKER_DIR/ssh/id_rsa"
```

**Windows (PowerShell):**
```powershell
# 1. Create directory and generate key
$sshDir = "$env:USERPROFILE\.claude-docker\ssh"
mkdir $sshDir -Force
ssh-keygen -t rsa -b 4096 -f "$sshDir\id_rsa" -N '""'

# 2. Add public key to GitHub
type "$sshDir\id_rsa.pub"
# Copy output and add to: GitHub → Settings → SSH and GPG keys → New SSH key

# 3. Test connection
ssh -T git@github.com -i "$sshDir\id_rsa"
```

### Custom Agent Behavior

After installation, customize Claude's behavior by editing files in `${CLAUDE_DOCKER_HOME:-~/.claude-docker}/claude-home/`:

#### CLAUDE.md (Prompt Engineering)
```bash
# Linux / macOS
nano "${CLAUDE_DOCKER_HOME:-$HOME/.claude-docker}/claude-home/CLAUDE.md"

# Windows
notepad "%USERPROFILE%\.claude-docker\claude-home\CLAUDE.md"
```

**Important:** The default `CLAUDE.md` includes the author's opinionated workflow preferences:
- Automatic codebase indexing on startup
- Task clarification protocols
- Conda environment execution standards
- Context.md maintenance requirements
- Telegram notification behaviors

These are NOT requirements of the Docker container - they're customizable prompt engineering. Change `CLAUDE.md` to match your workflow preferences.

#### settings.json (Claude Code Settings)
```bash
# Linux / macOS
nano "${CLAUDE_DOCKER_HOME:-$HOME/.claude-docker}/claude-home/settings.json"

# Windows
notepad "%USERPROFILE%\.claude-docker\claude-home\settings.json"
```

Configure Claude Code settings including:
- **Timeouts:** Bash command execution timeouts (default: 24 hours)
- **MCP Timeout:** MCP server response timeout (default: 60 seconds)
- **Permissions:** Auto-approved commands (ls, grep, find, etc.)

**Recommended:** Disable auto compact to gain 30% extra usable context window:
```bash
/config auto compact set to false
```
Run this command inside Claude Code to disable automatic context compaction.

#### Other Customizations
This directory is mounted as `~/.claude` inside the container, so you can also customize:
- Slash commands (`.claude/commands/`)
- Agent personas (`.claude/agents/`)
- All standard Claude Code customizations

---

## Pre-configured MCP Servers

MCP (Model Context Protocol) servers extend Claude's capabilities. Installation is simple - just add commands to `mcp-servers.txt` that you'd normally run in terminal.

### Included MCP Servers

#### Serena MCP
Semantic code navigation and symbol manipulation with automatic project indexing.

**Value:** Better efficiency in retrieving and editing code means greater token efficiency and more usable context window.

#### Context7 MCP
Official, version-specific documentation straight from the source.

**Value:** Unhobble Claude Code by giving it up-to-date docs. Stale documentation is an artificial performance bottleneck.

**Setup:** Create a free API key at [context7.com/dashboard](https://context7.com/dashboard) and add it to your `.env` file as `CONTEXT7_API_KEY`.

#### Grep MCP
Search real code examples on GitHub.

**Value:** When documentation is missing, rapidly search across GitHub for working implementations to understand different APIs and syntaxes for unfamiliar tasks.

#### Playwright MCP
Browser automation for web testing, scraping, and interaction.

**Value:** Claude can navigate websites, fill forms, take screenshots, and run end-to-end tests directly from the container. The Playwright MCP runs as a separate Docker container (`mcr.microsoft.com/playwright/mcp`) that is automatically started when you launch `claude-docker`.

#### Telegram MCP
Telegram bot notifications and two-way communication via [mcp-communicator-telegram](https://github.com/qpd-v/mcp-communicator-telegram).

**Value:** Step away from your terminal. Claude sends you Telegram messages when tasks finish or when it needs input. You can reply via Telegram using `ask_user`, and Claude continues working. Notifications are driven by `CLAUDE.md` instructions — Claude uses the tools automatically when it completes work, hits errors, or reaches milestones.

### Optional MCP Servers

These servers are pre-configured but commented out in `mcp-servers.txt` to keep the default setup lean. Uncomment to enable.

#### Zen MCP (Disabled by Default)
Multi-model code review and debugging using Gemini and other LLMs via OpenRouter.

**Value:** Different LLMs debating each other normally outperforms any single LLM. Zen supports conversation threading for collaborative AI discussions, second opinions, and model debates.

**Why disabled by default:** Each Zen tool adds significant tokens to context. For focused agentic coding, this overhead isn't worth it. Enable for "vibe coding" sessions where you want AI model collaboration.

**To enable:**
1. Uncomment the Zen MCP line in `mcp-servers.txt`
2. Add `OPENROUTER_API_KEY` to your `.env` file (get one at [openrouter.ai](https://openrouter.ai))
3. Rebuild: `claude-docker --rebuild`

**Important:** Only enable the tools you need - each tool is expensive in terms of context tokens. See the [Zen MCP tools documentation](https://github.com/BeehiveInnovations/zen-mcp-server/tree/main/tools) for available tools and the [.env.example](https://github.com/BeehiveInnovations/zen-mcp-server/blob/main/.env.example) for all supported environment variables.

### MCP Installation

Example `mcp-servers.txt`:
```bash
# Serena - Coding agent toolkit
claude mcp add-json "serena" '{"command":"bash","args":[...]}'

# Context7 - Documentation lookup (requires API key in .env)
claude mcp add -s user --transport http context7 https://mcp.context7.com/mcp --header "CONTEXT7_API_KEY: ${CONTEXT7_API_KEY}"

# Grep - GitHub code search (no API key needed)
claude mcp add -s user --transport http grep https://mcp.grep.app

# Telegram - Notifications and two-way chat (requires Telegram credentials in .env)
claude mcp add-json telegram -s user '{"command":"npx","args":["-y","mcp-communicator-telegram"],"env":{...}}'
```

Each line is exactly what you'd type in your terminal to run that MCP server. The installation script handles the rest.

📋 **See [MCP_SERVERS.md](MCP_SERVERS.md) for more examples and detailed setup instructions**

---

## Features

### Core Capabilities
- **Complete AI coding agent setup** - Claude Code in isolated Docker container
- **Pre-configured MCP servers** - Advanced coding tools, documentation lookup, Telegram notifications and easy set up to add more.
- **Persistent conversation history** - Resumes from where you left off with `--continue`, even after crashes
- **Host machines conda envs** - No need to waste time re setting up conda environments, host machines conda dirs are mounted and ready to use by claude docker.
- **Simple one-command setup** - Zero friction plug-and-play integration
- **Fully customizable** - Modify files at `${CLAUDE_DOCKER_HOME:-~/.claude-docker}` for custom behavior

---

## Vanilla Installation (Minimal Setup)

Want to start simple? Skip the pre-configured MCP servers and extra packages:

### 1. Remove MCP Servers
```bash
# Empty the file or delete unwanted entries
> mcp-servers.txt
claude-docker --rebuild --no-cache # For changes to take effect.
```

### 2. Remove Unwanted Packages
Edit `Dockerfile` to remove packages you don't need:
```bash
# Line 8: Python
# Line 10: Git
# Other lines: Various system packages
nano Dockerfile
claude-docker --rebuild --no-cache # For changes to take effect.
```

### 3. Customize Agent Behavior
After installation, customize Claude's behavior:
```bash
nano "${CLAUDE_DOCKER_HOME:-$HOME/.claude-docker}/claude-home/CLAUDE.md"
```
---


## Created By
- **Repository**: https://github.com/LORDofDOOM/claude-docker
- **Author**: Vishal J (@VishalJ99)

---

## License

This project is open source. See the LICENSE file for details.
