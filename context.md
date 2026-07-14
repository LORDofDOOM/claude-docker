# claude-docker — Architectural Overview

Containerized launcher for Claude Code (default), OpenCode, and Codex CLI (opt-in sister runtimes). Same Docker image, same MCP servers, same persistence patterns.

## Runtimes

Selected at launch via `CLAUDE_TOOL` env var (set by the wrappers):

| Runtime | Wrapper (Linux/macOS) | Wrapper (Windows .NET tool) | Tool flag |
|---|---|---|---|
| Claude Code | `src/claude-docker.sh` | `claude-docker` | (default) |
| OpenCode    | `src/opencode-docker.sh` | `opencode-docker` | `--tool opencode` |
| Codex CLI   | `src/codex-docker.sh` | `codex-docker` | `--tool codex` |

All wrappers feed into the same image and the same `src/startup.sh`, which dispatches on `$CLAUDE_TOOL` to `exec claude`, `exec opencode`, or `exec codex`.

## Module map

- `Dockerfile` — single image. Build args: `USER_UID`, `USER_GID`, `CC_VERSION`, `SYSTEM_PACKAGES`, `GIT_USER_NAME`, `GIT_USER_EMAIL`, `ENABLE_DOTNET_MCP`, `ENABLE_OPENCODE`, `ENABLE_CODEX`. Installs Claude unconditionally, OpenCode when `ENABLE_OPENCODE=true`, and Codex (`npm i -g @openai/codex`) when `ENABLE_CODEX=true`.
- `src/startup.sh` — container entrypoint. Loads baked `.env`, seeds `CLAUDE.md` (and `opencode.json` / `codex config.toml` when needed), wires git credentials, then `exec`s the selected runtime with the right flags.
- `src/claude-docker.sh` — host wrapper. Parses CLI flags including `--tool`, decides whether to rebuild (auto-rebuild on git hash drift), assembles `docker run` with per-tool mounts and `-e CLAUDE_TOOL`.
- `src/opencode-docker.sh` — thin wrapper that shells out to `claude-docker.sh --tool opencode "$@"`.
- `src/codex-docker.sh` — thin wrapper that shells out to `claude-docker.sh --tool codex "$@"`.
- `src/install.sh` — Linux/macOS installer. Adds `claude-docker`, `opencode-docker`, and `codex-docker` aliases to the shell rc.
- `src/lib-common.sh` — shared bash helpers (runtime check, persistence-dir resolution).
- `src/statusline.sh` — Claude statusline (Claude-only feature; OpenCode/Codex have their own).
- `src/windows/claude-docker-cli/Program.cs` — single .NET source file; supports `--tool` and auto-detects from `Environment.ProcessPath`.
- `src/windows/opencode-docker-cli/opencode-docker-cli.csproj` — sister .NET tool. Compiles the same `Program.cs` with `<AssemblyName>opencode-docker-cli</AssemblyName>` so the apphost reports `opencode-docker.exe`, which auto-defaults `--tool` to `opencode`.
- `src/windows/codex-docker-cli/codex-docker-cli.csproj` — sister .NET tool. Same pattern with `<AssemblyName>codex-docker-cli</AssemblyName>`; `codex-docker.exe` auto-defaults `--tool` to `codex`.
- `mcp-servers.txt` / `mcp-servers-dotnet.txt` / `install-mcp-servers.sh` — Claude's CLI-imperative MCP setup (`claude mcp add ...`).
- `opencode.json` (repo root) — OpenCode's declarative MCP + permission config, copied to `~/.config/opencode/opencode.json` on first launch when missing. Key directives:
  - `"permission": "allow"` — TUI equivalent of `--dangerously-skip-permissions` (the flag exists only on `opencode run`).
  - `"mcp": { … }` — same five MCP servers translated to OpenCode schema with `{env:VAR}` substitution.
- `codex-config.toml` (repo root) — Codex's declarative TOML config, copied to `~/.codex/config.toml` on first launch when missing. Key directives:
  - `approval_policy = "never"` + `sandbox_mode = "danger-full-access"` — full-auto; combined with the `codex --yolo` launch flag it is the equivalent of `--dangerously-skip-permissions`.
  - `[mcp_servers.*]` — Serena, Context7 (HTTP, key via `env_http_headers`), grep.app (HTTP), Playwright. The `telegram` stdio server is **not** in this template; `startup.sh` appends it with real creds when `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` are set (Codex TOML does not do env substitution inside `env = { … }`).
- `context-menu-install.reg` — Windows Explorer cascaded "Claude/OpenCode/Codex" menu with native Claude, Claude Docker, native OpenCode, OpenCode Docker, native Codex, Codex Docker entries.

## Persistence layout (host)

Default base: `${CLAUDE_DOCKER_HOME:-$HOME/.claude-docker}` (Linux/macOS) or `%USERPROFILE%\.claude-docker` (Windows).

| Subdir | Mounted into container at | Purpose |
|---|---|---|
| `claude-home/` | `/home/claude-user/.claude` | Claude memory, sessions, settings, CLAUDE.md |
| `opencode-config/` | `/home/claude-user/.config/opencode` | OpenCode user config |
| `opencode-data/` | `/home/claude-user/.local/share/opencode` | OpenCode `auth.json`, sessions |
| `codex-home/` | `/home/claude-user/.codex` | Codex `config.toml`, `auth.json`, sessions (single dir) |
| `ssh/` | `/home/claude-user/.ssh` | SSH keys for git ops |
| `.build-hash` | (host-only) | Last-built git hash for auto-rebuild |

When `SHARE_NATIVE_CLAUDE=true` / `SHARE_NATIVE_OPENCODE=true` / `SHARE_NATIVE_CODEX=true`, the corresponding `~/.claude` / `~/.config/opencode` + `~/.local/share/opencode` / `~/.codex` host paths are mounted directly instead.

## Auth bootstrap flow

On first launch, the host wrappers copy:
- `~/.claude/.credentials.json` → `claude-home/.credentials.json` (if missing)
- `~/.local/share/opencode/auth.json` → `opencode-data/auth.json` (if missing)
- `~/.config/opencode/opencode.json` → `opencode-config/opencode.json` (if missing)
- `~/.codex/auth.json` → `codex-home/auth.json` (if missing)

This means existing host credentials carry over without manual setup.

## Key entry points

- `claude-docker` — Claude Code default flow.
- `claude-docker --tool opencode` / `opencode-docker` — OpenCode flow (auto-forces `ENABLE_OPENCODE=true` at build time).
- `claude-docker --tool codex` / `codex-docker` — Codex flow (auto-forces `ENABLE_CODEX=true` at build time).
- `claude-docker --rebuild --no-cache` — full clean rebuild.

## Notes for future agents

- Don't try to add `--dangerously-skip-permissions` to the OpenCode TUI command — it's only valid on `opencode run`. The bypass for the TUI is the `"permission": "allow"` shorthand in `opencode.json` (verified in `packages/opencode/src/config/permission.ts`).
- `opencode.json` uses `{env:VAR}` substitution, **not** `${VAR}` — the latter is what `mcp-servers.txt` uses for Claude's CLI.
- Codex's full-auto is `approval_policy = "never"` + `sandbox_mode = "danger-full-access"` in `~/.codex/config.toml`, plus the `codex --yolo` launch flag (belt-and-suspenders against any first-run trust prompt). Codex has no `--continue` flag — `--continue` maps to the `codex resume --last` subcommand in `startup.sh`.
- Codex TOML does **not** substitute env vars inside `env = { … }` for stdio servers, so the telegram block (which needs the real token) is appended by `startup.sh`, not shipped in `codex-config.toml`. Context7's key is handled differently — `env_http_headers = { CONTEXT7_API_KEY = "CONTEXT7_API_KEY" }` reads the value from the env var at runtime, so no secret lands in the file.
- Codex keeps `config.toml` and `auth.json` in the **same** `~/.codex` dir, so it needs only one persistence dir/mount (unlike OpenCode's two).
- The three .NET projects share `Program.cs` via `<Compile Include="..\claude-docker-cli\Program.cs" Link="Program.cs" />`. Edit the source in `claude-docker-cli/`; the sister projects pick it up automatically. The runtime default is chosen from the process name (`opencode`/`codex` substring → that tool, else `claude`).
- Icons: `claude.ico`, `opencode.ico`, `codex.ico` at repo root (referenced by `context-menu-install.reg` as `%CLAUDE_DOCKER_PROJECT%\*.ico`, hex(2) UTF-16LE). `codex.ico` is the official Codex mark (OpenAI blossom) built from the docs favicon; `codex-docker-cli.csproj` also uses it as its `ApplicationIcon`.
- `install-windows.bat` does two things: (1) builds + `dotnet tool install`s the three `*-docker` wrappers, and (2) installs/updates the **native host** runtimes that back the non-Docker menu entries — Claude via `claude.ai/install.ps1`, Codex via `chatgpt.com/codex/install.ps1` (non-interactive), OpenCode via `npm i -g opencode-ai` (no PS1 installer exists). Native installs are failure-tolerant; Docker mode never needs them. The Dockerfile installs the in-container copies separately (`@openai/codex` via npm, etc.).
