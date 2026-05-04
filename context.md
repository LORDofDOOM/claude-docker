# claude-docker — Architectural Overview

Containerized launcher for Claude Code (default) and OpenCode (opt-in sister runtime). Same Docker image, same MCP servers, same persistence patterns.

## Runtimes

Selected at launch via `CLAUDE_TOOL` env var (set by the wrappers):

| Runtime | Wrapper (Linux/macOS) | Wrapper (Windows .NET tool) | Tool flag |
|---|---|---|---|
| Claude Code | `src/claude-docker.sh` | `claude-docker` | (default) |
| OpenCode    | `src/opencode-docker.sh` | `opencode-docker` | `--tool opencode` |

Both wrappers feed into the same image and the same `src/startup.sh`, which dispatches on `$CLAUDE_TOOL` to `exec claude` or `exec opencode`.

## Module map

- `Dockerfile` — single image. Build args: `USER_UID`, `USER_GID`, `CC_VERSION`, `SYSTEM_PACKAGES`, `GIT_USER_NAME`, `GIT_USER_EMAIL`, `ENABLE_DOTNET_MCP`, `ENABLE_OPENCODE`. Installs Claude unconditionally and OpenCode when `ENABLE_OPENCODE=true`.
- `src/startup.sh` — container entrypoint. Loads baked `.env`, seeds `CLAUDE.md` (and `opencode.json` when needed), wires git credentials, then `exec`s the selected runtime with the right flags.
- `src/claude-docker.sh` — host wrapper. Parses CLI flags including `--tool`, decides whether to rebuild (auto-rebuild on git hash drift), assembles `docker run` with per-tool mounts and `-e CLAUDE_TOOL`.
- `src/opencode-docker.sh` — thin wrapper that shells out to `claude-docker.sh --tool opencode "$@"`.
- `src/install.sh` — Linux/macOS installer. Adds `claude-docker` and `opencode-docker` aliases to the shell rc.
- `src/lib-common.sh` — shared bash helpers (runtime check, persistence-dir resolution).
- `src/statusline.sh` — Claude statusline (Claude-only feature; OpenCode has its own).
- `src/windows/claude-docker-cli/Program.cs` — single .NET source file; supports `--tool` and auto-detects from `Environment.ProcessPath`.
- `src/windows/opencode-docker-cli/opencode-docker-cli.csproj` — sister .NET tool. Compiles the same `Program.cs` with `<AssemblyName>opencode-docker-cli</AssemblyName>` so the apphost reports `opencode-docker.exe`, which auto-defaults `--tool` to `opencode`.
- `mcp-servers.txt` / `mcp-servers-dotnet.txt` / `install-mcp-servers.sh` — Claude's CLI-imperative MCP setup (`claude mcp add ...`).
- `opencode.json` (repo root) — OpenCode's declarative MCP + permission config, copied to `~/.config/opencode/opencode.json` on first launch when missing. Key directives:
  - `"permission": "allow"` — TUI equivalent of `--dangerously-skip-permissions` (the flag exists only on `opencode run`).
  - `"mcp": { … }` — same five MCP servers translated to OpenCode schema with `{env:VAR}` substitution.
- `context-menu-install.reg` — Windows Explorer cascaded "Claude" menu with native Claude, Claude Docker, native OpenCode, OpenCode Docker entries.

## Persistence layout (host)

Default base: `${CLAUDE_DOCKER_HOME:-$HOME/.claude-docker}` (Linux/macOS) or `%USERPROFILE%\.claude-docker` (Windows).

| Subdir | Mounted into container at | Purpose |
|---|---|---|
| `claude-home/` | `/home/claude-user/.claude` | Claude memory, sessions, settings, CLAUDE.md |
| `opencode-config/` | `/home/claude-user/.config/opencode` | OpenCode user config |
| `opencode-data/` | `/home/claude-user/.local/share/opencode` | OpenCode `auth.json`, sessions |
| `ssh/` | `/home/claude-user/.ssh` | SSH keys for git ops |
| `.build-hash` | (host-only) | Last-built git hash for auto-rebuild |

When `SHARE_NATIVE_CLAUDE=true` / `SHARE_NATIVE_OPENCODE=true`, the corresponding `~/.claude` / `~/.config/opencode` + `~/.local/share/opencode` host paths are mounted directly instead.

## Auth bootstrap flow

On first launch, the host wrappers copy:
- `~/.claude/.credentials.json` → `claude-home/.credentials.json` (if missing)
- `~/.local/share/opencode/auth.json` → `opencode-data/auth.json` (if missing)
- `~/.config/opencode/opencode.json` → `opencode-config/opencode.json` (if missing)

This means existing host credentials carry over without manual setup.

## Key entry points

- `claude-docker` — Claude Code default flow.
- `claude-docker --tool opencode` / `opencode-docker` — OpenCode flow (auto-forces `ENABLE_OPENCODE=true` at build time).
- `claude-docker --rebuild --no-cache` — full clean rebuild.

## Notes for future agents

- Don't try to add `--dangerously-skip-permissions` to the OpenCode TUI command — it's only valid on `opencode run`. The bypass for the TUI is the `"permission": "allow"` shorthand in `opencode.json` (verified in `packages/opencode/src/config/permission.ts`).
- `opencode.json` uses `{env:VAR}` substitution, **not** `${VAR}` — the latter is what `mcp-servers.txt` uses for Claude's CLI.
- The two .NET projects share `Program.cs` via `<Compile Include="..\claude-docker-cli\Program.cs" Link="Program.cs" />`. Edit the source in `claude-docker-cli/`; the sister project picks it up automatically.
