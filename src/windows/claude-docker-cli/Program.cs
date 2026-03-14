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
        default:
            extraArgs.Add(args[i]);
            break;
    }
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

// Auto-rebuild: compare git commit hash against last build
var buildHashFile = Path.Combine(claudeDockerDir, ".build-hash");
var (_, gitHashOut) = RunCapture("git", $"-C \"{projectRoot}\" rev-parse --short HEAD");
var currentHash = gitHashOut.Trim();
if (string.IsNullOrEmpty(currentHash)) currentHash = "unknown";

if (!needRebuild)
{
    var previousHash = File.Exists(buildHashFile) ? File.ReadAllText(buildHashFile).Trim() : "";
    if (currentHash != previousHash)
    {
        Console.WriteLine($"New commit detected ({previousHash} -> {currentHash}) — auto-rebuilding...");
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

// Volume mounts
runArgs.AddRange(["-v", $"{currentDir}:/workspace"]);
runArgs.AddRange(["-v", $"{claudeHomeDir}:/home/claude-user/.claude:rw"]);
runArgs.AddRange(["-v", $"{sshDir}:/home/claude-user/.ssh:rw"]);

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

// Container name
var dirName = Path.GetFileName(currentDir) ?? "project";
var pid = Environment.ProcessId;
var containerName = $"claude-docker-{dirName}-{pid}";

runArgs.AddRange(["--workdir", "/workspace"]);
runArgs.AddRange(["--name", containerName]);
runArgs.Add("claude-docker:latest");
runArgs.AddRange(extraArgs);

// ── Ensure Playwright MCP container is running ───────────────────
const string playwrightContainer = "playwright-mcp";
const string playwrightPort = "8931";

var (psExit, psOut) = RunCapture(dockerCmd, "ps --format {{.Names}}");
if (psExit == 0 && psOut.Split('\n', StringSplitOptions.RemoveEmptyEntries)
        .Any(n => n.Trim() == playwrightContainer))
{
    Info("Playwright MCP container already running");
}
else
{
    // Remove stopped container with same name if it exists
    RunCapture(dockerCmd, $"rm -f {playwrightContainer}");
    Console.WriteLine("Starting Playwright MCP container...");
    var pwArgs = new List<string>
    {
        "run", "-d", "--rm", "--init", "--pull=always",
        "--name", playwrightContainer,
        "-p", $"{playwrightPort}:{playwrightPort}",
        "mcr.microsoft.com/playwright/mcp",
        "--headless", "--port", playwrightPort, "--host", "0.0.0.0"
    };
    var pwExit = RunPassthrough(dockerCmd, pwArgs);
    if (pwExit == 0)
        Info($"Playwright MCP container started on port {playwrightPort}");
    else
        Warn("Failed to start Playwright MCP container (continuing without it)");
}

// ── Run ──────────────────────────────────────────────────────────
Console.WriteLine("Starting Claude Code in Docker...");
var exitCode = RunPassthrough(dockerCmd, runArgs);
Environment.Exit(exitCode);


// ═════════════════════════════════════════════════════════════════
// Helper methods
// ═════════════════════════════════════════════════════════════════

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
