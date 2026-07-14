using System.Diagnostics;
using System.Text;

// ── Argument parsing ─────────────────────────────────────────────
var dockerCmd = "docker";
var forceRebuild = false;
var noCache = false;
var continueFlag = "";
var memoryLimit = "";
var gpuAccess = "";
var ccVersion = "";
// Default tool: derived from invocation name (so the sister tool
// "opencode-docker" defaults to opencode without needing --tool).
var tool = DefaultToolFromProcessName();
var extraArgs = new List<string>();

for (int i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--podman":
            dockerCmd = "podman";
            break;
        case "--rebuild":
            forceRebuild = true;
            break;
        case "--no-cache":
            noCache = true;
            break;
        case "--continue":
            continueFlag = "--continue";
            break;
        case "--memory" when i + 1 < args.Length:
            memoryLimit = args[++i];
            break;
        case "--gpus" when i + 1 < args.Length:
            gpuAccess = args[++i];
            break;
        case "--cc-version" when i + 1 < args.Length:
            ccVersion = args[++i];
            break;
        case "--tool" when i + 1 < args.Length:
            tool = args[++i];
            break;
        default:
            extraArgs.Add(args[i]);
            break;
    }
}

if (tool != "claude" && tool != "opencode" && tool != "codex")
{
    Error($"--tool must be 'claude', 'opencode' or 'codex' (got: {tool})");
    Environment.Exit(2);
    return;
}

// ── Resolve paths ────────────────────────────────────────────────
var hostHome = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
var currentDir = Environment.CurrentDirectory;

var projectRoot = FindProjectRoot();
if (projectRoot is null)
{
    Error("Could not locate the claude-docker project root.");
    Console.Error.WriteLine("  Set the CLAUDE_DOCKER_PROJECT environment variable to the repo path.");
    Console.Error.WriteLine("  Example: set CLAUDE_DOCKER_PROJECT=D:\\claude-docker");
    Environment.Exit(1);
    return;
}

var claudeDockerDir = Environment.GetEnvironmentVariable("CLAUDE_DOCKER_HOME")
    ?? Path.Combine(hostHome, ".claude-docker");
var claudeHomeDir = Path.Combine(claudeDockerDir, "claude-home");
var opencodeConfigDir = Path.Combine(claudeDockerDir, "opencode-config");
var opencodeDataDir = Path.Combine(claudeDockerDir, "opencode-data");
var codexHomeDir = Path.Combine(claudeDockerDir, "codex-home");
var sshDir = Path.Combine(claudeDockerDir, "ssh");

// ── Check container runtime ──────────────────────────────────────
if (!CommandExists(dockerCmd))
{
    Error($"Container runtime '{dockerCmd}' was not found in PATH.");
    Environment.Exit(1);
    return;
}

var (infoExit, _) = RunCapture(dockerCmd, "info");
if (infoExit != 0)
{
    Error($"Cannot connect to '{dockerCmd}' daemon. Ensure Docker Desktop is running.");
    Environment.Exit(1);
    return;
}

// ── Load .env file ───────────────────────────────────────────────
var envFile = Path.Combine(projectRoot, ".env");
var envVars = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

if (File.Exists(envFile))
{
    Info("Found .env file with credentials");
    foreach (var line in File.ReadLines(envFile))
    {
        var trimmed = line.Trim();
        if (string.IsNullOrEmpty(trimmed) || trimmed.StartsWith('#'))
            continue;
        var eqIdx = trimmed.IndexOf('=');
        if (eqIdx <= 0) continue;
        var key = trimmed[..eqIdx].Trim();
        var val = trimmed[(eqIdx + 1)..].Trim();
        envVars[key] = val;
    }
}
else
{
    Warn("No .env file found at " + envFile);
    Console.WriteLine("    Telegram notifications will be unavailable.");
}

// ── Apply env-var defaults ───────────────────────────────────────
if (string.IsNullOrEmpty(memoryLimit) && envVars.TryGetValue("DOCKER_MEMORY_LIMIT", out var envMem) && !string.IsNullOrEmpty(envMem))
{
    memoryLimit = envMem;
    Info($"Using memory limit from environment: {memoryLimit}");
}
if (string.IsNullOrEmpty(gpuAccess) && envVars.TryGetValue("DOCKER_GPU_ACCESS", out var envGpu) && !string.IsNullOrEmpty(envGpu))
{
    gpuAccess = envGpu;
    Info($"Using GPU access from environment: {gpuAccess}");
}

// ── Decide whether to build ──────────────────────────────────────
var needRebuild = false;

var (imgExit, imgOut) = RunCapture(dockerCmd, "images --format {{.Repository}}");
if (imgExit == 0 && !imgOut.Contains("claude-docker"))
{
    Console.WriteLine("Building Claude Docker image for first time...");
    needRebuild = true;
}
if (forceRebuild)
{
    Console.WriteLine("Forcing rebuild of Claude Docker image...");
    needRebuild = true;
}

// Auto-rebuild: compare git commit hash AND build-time feature flags
// (e.g. switching to --tool opencode on an image built without OpenCode must rebuild).
var buildHashFile = Path.Combine(claudeDockerDir, ".build-hash");
var (_, gitHashOut) = RunCapture("git", $"-C \"{projectRoot}\" rev-parse --short HEAD");
var gitHash = gitHashOut.Trim();
if (string.IsNullOrEmpty(gitHash)) gitHash = "unknown";

var opencodeEnv = envVars.TryGetValue("ENABLE_OPENCODE", out var oce)
    && oce.Equals("true", StringComparison.OrdinalIgnoreCase);
var opencodeRequired = opencodeEnv || tool == "opencode";
var codexEnv = envVars.TryGetValue("ENABLE_CODEX", out var cde)
    && cde.Equals("true", StringComparison.OrdinalIgnoreCase);
var codexRequired = codexEnv || tool == "codex";
var dotnetEnv = envVars.TryGetValue("ENABLE_DOTNET_MCP", out var dne)
    && dne.Equals("true", StringComparison.OrdinalIgnoreCase);
var currentHash = $"{gitHash}|opencode={opencodeRequired.ToString().ToLowerInvariant()}|codex={codexRequired.ToString().ToLowerInvariant()}|dotnet={dotnetEnv.ToString().ToLowerInvariant()}";

if (!needRebuild)
{
    var previousHash = File.Exists(buildHashFile) ? File.ReadAllText(buildHashFile).Trim() : "";
    if (currentHash != previousHash)
    {
        Console.WriteLine($"Build inputs changed ({previousHash} -> {currentHash}) — auto-rebuilding...");
        needRebuild = true;
    }
}

if (noCache && !needRebuild)
{
    Warn("--no-cache flag set but image already exists. Use --rebuild --no-cache to force rebuild without cache.");
}

// ── Build image ──────────────────────────────────────────────────
if (needRebuild)
{
    // Copy auth file to build context
    var hostClaudeJson = Path.Combine(hostHome, ".claude.json");
    var buildClaudeJson = Path.Combine(projectRoot, ".claude.json");
    if (File.Exists(hostClaudeJson))
        File.Copy(hostClaudeJson, buildClaudeJson, overwrite: true);

    // Git config
    var (_, gitName) = RunCapture("git", "config --global --get user.name");
    var (_, gitEmail) = RunCapture("git", "config --global --get user.email");
    gitName = gitName.Trim();
    gitEmail = gitEmail.Trim();

    var buildArgs = new List<string> { "build" };
    if (noCache) buildArgs.Add("--no-cache");

    // On Windows/Docker Desktop the Linux VM handles UID/GID; use defaults.
    buildArgs.AddRange(["--build-arg", "USER_UID=1000", "--build-arg", "USER_GID=1000"]);

    if (!string.IsNullOrEmpty(gitName) && !string.IsNullOrEmpty(gitEmail))
    {
        buildArgs.AddRange(["--build-arg", $"GIT_USER_NAME={gitName}", "--build-arg", $"GIT_USER_EMAIL={gitEmail}"]);
    }

    if (envVars.TryGetValue("SYSTEM_PACKAGES", out var sysPkgs) && !string.IsNullOrEmpty(sysPkgs))
    {
        Info($"Building with additional system packages: {sysPkgs}");
        buildArgs.AddRange(["--build-arg", $"SYSTEM_PACKAGES={sysPkgs}"]);
    }

    if (!string.IsNullOrEmpty(ccVersion))
    {
        Info($"Building with Claude Code version: {ccVersion}");
        buildArgs.AddRange(["--build-arg", $"CC_VERSION={ccVersion}"]);
    }

    if (envVars.TryGetValue("ENABLE_DOTNET_MCP", out var dotnetMcp)
        && dotnetMcp.Equals("true", StringComparison.OrdinalIgnoreCase))
    {
        Info("Building with .NET MCP servers (NuGet, C# LSP, type metadata)");
        buildArgs.AddRange(["--build-arg", "ENABLE_DOTNET_MCP=true"]);
    }

    var envOpencode = envVars.TryGetValue("ENABLE_OPENCODE", out var oc)
        && oc.Equals("true", StringComparison.OrdinalIgnoreCase);
    if (envOpencode || tool == "opencode")
    {
        Info("Building with OpenCode runtime");
        buildArgs.AddRange(["--build-arg", "ENABLE_OPENCODE=true"]);
    }

    var envCodex = envVars.TryGetValue("ENABLE_CODEX", out var cx)
        && cx.Equals("true", StringComparison.OrdinalIgnoreCase);
    if (envCodex || tool == "codex")
    {
        Info("Building with Codex CLI runtime");
        buildArgs.AddRange(["--build-arg", "ENABLE_CODEX=true"]);
    }

    buildArgs.AddRange(["-t", "claude-docker:latest", projectRoot]);

    Console.WriteLine($"Running: {dockerCmd} {string.Join(' ', buildArgs)}");
    var buildExit = RunPassthrough(dockerCmd, buildArgs);
    if (buildExit != 0)
    {
        Error("Docker build failed.");
        Environment.Exit(1);
        return;
    }

    // Clean up copied auth file
    try { File.Delete(buildClaudeJson); } catch { /* ignore */ }

    // Save git hash so we can detect new commits
    try { File.WriteAllText(buildHashFile, currentHash); } catch { /* ignore */ }
}

// ── Ensure directories ───────────────────────────────────────────
Directory.CreateDirectory(claudeHomeDir);
Directory.CreateDirectory(opencodeConfigDir);
Directory.CreateDirectory(opencodeDataDir);
Directory.CreateDirectory(codexHomeDir);
Directory.CreateDirectory(sshDir);

// Copy template .claude contents to persistent directory if empty
// (mirrors install.sh: cp -r "$PROJECT_ROOT/.claude/." "$CLAUDE_HOME_DIR/")
var templateDir = Path.Combine(projectRoot, ".claude");
if (Directory.Exists(templateDir))
{
    CopyDirectoryIfMissing(templateDir, claudeHomeDir);
}

// Copy credentials if needed
var hostCredsFile = Path.Combine(hostHome, ".claude", ".credentials.json");
var persistCreds = Path.Combine(claudeHomeDir, ".credentials.json");
if (File.Exists(hostCredsFile) && !File.Exists(persistCreds))
{
    Info("Copying Claude authentication to persistent directory");
    File.Copy(hostCredsFile, persistCreds);
}

// Reuse host's OpenCode auth/config when the persistent copies are empty —
// mirrors the Claude bootstrap above so existing host credentials carry over.
var hostOpencodeAuth = Path.Combine(hostHome, ".local", "share", "opencode", "auth.json");
var persistOpencodeAuth = Path.Combine(opencodeDataDir, "auth.json");
if (File.Exists(hostOpencodeAuth) && !File.Exists(persistOpencodeAuth))
{
    Info("Copying OpenCode auth.json from host to persistent directory");
    File.Copy(hostOpencodeAuth, persistOpencodeAuth);
}
var hostOpencodeCfg = Path.Combine(hostHome, ".config", "opencode", "opencode.json");
var persistOpencodeCfg = Path.Combine(opencodeConfigDir, "opencode.json");
if (File.Exists(hostOpencodeCfg) && !File.Exists(persistOpencodeCfg))
{
    Info("Copying host OpenCode config to persistent directory");
    File.Copy(hostOpencodeCfg, persistOpencodeCfg);
}

// Reuse host's Codex auth when the persistent copy is empty (~/.codex/auth.json).
var hostCodexAuth = Path.Combine(hostHome, ".codex", "auth.json");
var persistCodexAuth = Path.Combine(codexHomeDir, "auth.json");
if (File.Exists(hostCodexAuth) && !File.Exists(persistCodexAuth))
{
    Info("Copying Codex auth.json from host to persistent directory");
    File.Copy(hostCodexAuth, persistCodexAuth);
}

Console.WriteLine();
Console.WriteLine($"Claude persistent home directory: {claudeHomeDir}\\");
Console.WriteLine("   This directory contains Claude's settings and CLAUDE.md instructions");
Console.WriteLine("   Modify files here to customize Claude's behavior across all projects");
Console.WriteLine();

// ── SSH key info ─────────────────────────────────────────────────
var sshKeyPath = Path.Combine(sshDir, "id_rsa");
var sshPubKeyPath = Path.Combine(sshDir, "id_rsa.pub");

if (!File.Exists(sshKeyPath) || !File.Exists(sshPubKeyPath))
{
    Warn("SSH keys not found for git operations");
    Console.WriteLine("    To enable git push/pull in Claude Docker:");
    Console.WriteLine();
    Console.WriteLine("    1. Generate SSH key:");
    Console.WriteLine($"       ssh-keygen -t rsa -b 4096 -f \"{sshDir}\\id_rsa\" -N \"\"");
    Console.WriteLine();
    Console.WriteLine("    2. Add public key to GitHub:");
    Console.WriteLine($"       type \"{sshDir}\\id_rsa.pub\"");
    Console.WriteLine();
    Console.WriteLine("    Claude will continue without SSH keys (read-only git operations only)");
    Console.WriteLine();
}
else
{
    Info("SSH keys found for git operations");

    var sshConfigPath = Path.Combine(sshDir, "config");
    if (!File.Exists(sshConfigPath))
    {
        File.WriteAllText(sshConfigPath,
            """
            Host github.com
                HostName github.com
                User git
                IdentityFile ~/.ssh/id_rsa
                IdentitiesOnly yes
            """);
        Info("SSH config created for GitHub");
    }
}

// ── Assemble docker run ──────────────────────────────────────────
var runArgs = new List<string> { "run", "-it", "--rm" };

// Docker options
if (!string.IsNullOrEmpty(memoryLimit))
{
    Info($"Setting memory limit: {memoryLimit}");
    runArgs.AddRange(["--memory", memoryLimit]);
}

if (!string.IsNullOrEmpty(gpuAccess))
{
    var (_, dockerInfo) = RunCapture(dockerCmd, "info");
    if (dockerInfo.Contains("nvidia", StringComparison.OrdinalIgnoreCase))
    {
        Info($"Enabling GPU access: {gpuAccess}");
        runArgs.AddRange(["--gpus", gpuAccess]);
    }
    else
    {
        Warn("GPU access requested but NVIDIA Docker runtime not found");
        Console.WriteLine("    Continuing without GPU access...");
    }
}

runArgs.Add("--add-host=host.docker.internal:host-gateway");

// Network mode: use host networking if specified (gives full access to host ports)
if (envVars.TryGetValue("DOCKER_NETWORK_MODE", out var networkMode) && !string.IsNullOrEmpty(networkMode))
{
    Info($"Using network mode: {networkMode}");
    runArgs.AddRange(["--network", networkMode]);
}


// Use project-specific workspace path so each project gets its own session history
var projectName = Path.GetFileName(currentDir) ?? "project";
var workspacePath = $"/workspace/{projectName}";

// Volume mounts
runArgs.AddRange(["-v", $"{currentDir}:{workspacePath}"]);

// Choose claude config mount: shared with host or isolated
var shareNative = envVars.TryGetValue("SHARE_NATIVE_CLAUDE", out var sn)
    && sn.Equals("true", StringComparison.OrdinalIgnoreCase);
var nativeClaudeDir = Path.Combine(hostHome, ".claude");

if (shareNative && Directory.Exists(nativeClaudeDir))
{
    Info("Sharing host's ~/.claude (memory, sessions, settings)");
    runArgs.AddRange(["-v", $"{nativeClaudeDir}:/home/claude-user/.claude:rw"]);
}
else
{
    runArgs.AddRange(["-v", $"{claudeHomeDir}:/home/claude-user/.claude:rw"]);
}

runArgs.AddRange(["-v", $"{sshDir}:/home/claude-user/.ssh:rw"]);

// OpenCode mounts: only added when running with --tool opencode.
if (tool == "opencode")
{
    var shareNativeOpencode = envVars.TryGetValue("SHARE_NATIVE_OPENCODE", out var sno)
        && sno.Equals("true", StringComparison.OrdinalIgnoreCase);
    var nativeOpencodeCfg = Path.Combine(hostHome, ".config", "opencode");
    var nativeOpencodeData = Path.Combine(hostHome, ".local", "share", "opencode");

    string opencodeCfgMount;
    string opencodeDataMount;
    if (shareNativeOpencode &&
        (Directory.Exists(nativeOpencodeCfg) || Directory.Exists(nativeOpencodeData)))
    {
        Info("Sharing host's OpenCode config + auth (~/.config/opencode, ~/.local/share/opencode)");
        Directory.CreateDirectory(nativeOpencodeCfg);
        Directory.CreateDirectory(nativeOpencodeData);
        opencodeCfgMount = nativeOpencodeCfg;
        opencodeDataMount = nativeOpencodeData;
    }
    else
    {
        opencodeCfgMount = opencodeConfigDir;
        opencodeDataMount = opencodeDataDir;
    }

    runArgs.AddRange(["-v", $"{opencodeCfgMount}:/home/claude-user/.config/opencode:rw"]);
    runArgs.AddRange(["-v", $"{opencodeDataMount}:/home/claude-user/.local/share/opencode:rw"]);
}

// Codex mount: only added when running with --tool codex.
// Codex keeps config.toml AND auth.json under a single dir (~/.codex).
if (tool == "codex")
{
    var shareNativeCodex = envVars.TryGetValue("SHARE_NATIVE_CODEX", out var snc)
        && snc.Equals("true", StringComparison.OrdinalIgnoreCase);
    var nativeCodexDir = Path.Combine(hostHome, ".codex");

    string codexMount;
    if (shareNativeCodex && Directory.Exists(nativeCodexDir))
    {
        Info("Sharing host's Codex config + auth (~/.codex)");
        codexMount = nativeCodexDir;
    }
    else
    {
        codexMount = codexHomeDir;
    }

    runArgs.AddRange(["-v", $"{codexMount}:/home/claude-user/.codex:rw"]);
}

// Extra directory mounts (append :ro for read-only)
if (envVars.TryGetValue("EXTRA_MOUNT_DIRS", out var extraDirs) && !string.IsNullOrEmpty(extraDirs))
{
    foreach (var entry in extraDirs.Split(';', StringSplitOptions.RemoveEmptyEntries))
    {
        var trimmed = entry.Trim();
        if (string.IsNullOrEmpty(trimmed)) continue;

        var readOnly = trimmed.EndsWith(":ro", StringComparison.OrdinalIgnoreCase);
        var dirPath = readOnly ? trimmed[..^3] : trimmed;
        var mode = readOnly ? "ro" : "rw";

        if (!Directory.Exists(dirPath))
        {
            Warn($"Extra mount dir not found, skipping: {dirPath}");
            continue;
        }
        var mountName = Path.GetFileName(dirPath.TrimEnd('\\', '/'));
        var containerPath = $"/mnt/{mountName}";
        Info($"Mounting extra dir ({mode}): {dirPath} → {containerPath}");
        runArgs.AddRange(["-v", $"{dirPath}:{containerPath}:{mode}"]);
    }
}

// Conda mounts
if (envVars.TryGetValue("CONDA_PREFIX", out var condaPrefix) && !string.IsNullOrEmpty(condaPrefix))
{
    if (IsWindowsAbsolutePath(condaPrefix))
    {
        Console.WriteLine("Note: Conda mount from Windows paths into Linux container is not supported.");
        Console.WriteLine("      Use WSL2 for conda integration, or set CONDA_PREFIX to a WSL path.");
    }
    else if (Directory.Exists(condaPrefix))
    {
        Info($"Mounting conda installation from {condaPrefix}");
        runArgs.AddRange(["-v", $"{condaPrefix}:{condaPrefix}:ro"]);
        runArgs.AddRange(["-e", $"CONDA_PREFIX={condaPrefix}"]);
        runArgs.AddRange(["-e", $"CONDA_EXE={condaPrefix}/bin/conda"]);
    }
}

// Environment variables
runArgs.AddRange(["-e", $"CLAUDE_CONTINUE_FLAG={continueFlag}"]);
runArgs.AddRange(["-e", $"CLAUDE_TOOL={tool}"]);

// Pass host project key so startup.sh can link session history (only needed in shared mode)
if (shareNative)
{
    var hostProjectKey = currentDir.Replace("\\", "/").Replace(":/", "--").Replace("/", "-").Replace(".", "-");
    runArgs.AddRange(["-e", $"HOST_PROJECT_KEY={hostProjectKey}"]);
}

// Container name
var dirName = Path.GetFileName(currentDir) ?? "project";
var pid = Environment.ProcessId;
var containerName = $"claude-docker-{dirName}-{pid}";

runArgs.AddRange(["--workdir", workspacePath]);
runArgs.AddRange(["--name", containerName]);
runArgs.Add("claude-docker:latest");
runArgs.AddRange(extraArgs);

// ── Run ──────────────────────────────────────────────────────────
Console.WriteLine("Starting Claude Code in Docker...");
var exitCode = RunPassthrough(dockerCmd, runArgs);
Environment.Exit(exitCode);


// ═════════════════════════════════════════════════════════════════
// Helper methods
// ═════════════════════════════════════════════════════════════════

static string DefaultToolFromProcessName()
{
    // The Windows tool ships under two ToolCommandNames: claude-docker and
    // opencode-docker. Inspect the entry assembly / process path to default
    // the runtime when no --tool flag is given.
    try
    {
        var path = Environment.ProcessPath ?? "";
        var name = Path.GetFileNameWithoutExtension(path);
        if (!string.IsNullOrEmpty(name)
            && name.Contains("opencode", StringComparison.OrdinalIgnoreCase))
        {
            return "opencode";
        }
        if (!string.IsNullOrEmpty(name)
            && name.Contains("codex", StringComparison.OrdinalIgnoreCase))
        {
            return "codex";
        }
    }
    catch { /* ignore */ }
    return "claude";
}

static string? FindProjectRoot()
{
    // 1. Explicit env var
    var envRoot = Environment.GetEnvironmentVariable("CLAUDE_DOCKER_PROJECT");
    if (!string.IsNullOrEmpty(envRoot) && IsProjectRoot(envRoot))
        return envRoot;

    // 2. Walk up from current directory
    var dir = Environment.CurrentDirectory;
    while (dir is not null)
    {
        if (IsProjectRoot(dir)) return dir;
        dir = Path.GetDirectoryName(dir);
    }

    // 3. Well-known locations
    var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    string[] candidates =
    [
        Path.Combine(home, "claude-docker"),
        Path.Combine(home, "source", "repos", "claude-docker"),
        Path.Combine(home, "Projects", "claude-docker"),
        @"D:\claude-docker",
        @"C:\claude-docker",
    ];

    foreach (var candidate in candidates)
    {
        if (IsProjectRoot(candidate)) return candidate;
    }

    return null;
}

static bool IsProjectRoot(string path)
{
    return Directory.Exists(path)
        && File.Exists(Path.Combine(path, "Dockerfile"))
        && File.Exists(Path.Combine(path, "src", "startup.sh"));
}

static bool CommandExists(string command)
{
    try
    {
        var psi = new ProcessStartInfo
        {
            FileName = OperatingSystem.IsWindows() ? "where" : "which",
            Arguments = command,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using var proc = Process.Start(psi);
        proc?.WaitForExit();
        return proc?.ExitCode == 0;
    }
    catch
    {
        return false;
    }
}

static (int exitCode, string output) RunCapture(string command, string arguments)
{
    try
    {
        var psi = new ProcessStartInfo
        {
            FileName = command,
            Arguments = arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8
        };
        using var proc = Process.Start(psi);
        if (proc is null) return (-1, "");
        var output = proc.StandardOutput.ReadToEnd();
        proc.WaitForExit();
        return (proc.ExitCode, output);
    }
    catch
    {
        return (-1, "");
    }
}

static int RunPassthrough(string command, IEnumerable<string> arguments)
{
    var psi = new ProcessStartInfo
    {
        FileName = command,
        UseShellExecute = false
    };
    foreach (var arg in arguments)
        psi.ArgumentList.Add(arg);

    using var proc = Process.Start(psi);
    if (proc is null)
    {
        Console.Error.WriteLine($"Failed to start process: {command}");
        return 1;
    }
    proc.WaitForExit();
    return proc.ExitCode;
}

static bool IsWindowsAbsolutePath(string path)
{
    return path.Length >= 2 && char.IsLetter(path[0]) && path[1] == ':';
}

static void CopyDirectoryIfMissing(string sourceDir, string destDir)
{
    foreach (var file in Directory.GetFiles(sourceDir))
    {
        var destFile = Path.Combine(destDir, Path.GetFileName(file));
        if (!File.Exists(destFile))
        {
            File.Copy(file, destFile);
        }
    }
    foreach (var dir in Directory.GetDirectories(sourceDir))
    {
        var destSubDir = Path.Combine(destDir, Path.GetFileName(dir));
        Directory.CreateDirectory(destSubDir);
        CopyDirectoryIfMissing(dir, destSubDir);
    }
}

static void Info(string msg) => Console.WriteLine($"[OK] {msg}");
static void Warn(string msg) => Console.WriteLine($"[!]  {msg}");
static void Error(string msg) => Console.Error.WriteLine($"[ERR] {msg}");
