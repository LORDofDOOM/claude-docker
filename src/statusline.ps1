# ABOUTME: Custom Claude Code status line for native Windows Claude (PowerShell port of statusline.sh)
# ABOUTME: Receives JSON on stdin, renders model, cost, context bar, git branch, plan usage. Cached usage TTL = 60s.

# Force UTF-8 stdout so block + emoji glyphs render correctly in Claude's status line.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
$data = $raw | ConvertFrom-Json

$model = $data.model.display_name
$dir   = $data.workspace.current_dir
$cost  = if ($null -ne $data.cost.total_cost_usd) { [double]$data.cost.total_cost_usd } else { 0.0 }
$pct   = if ($null -ne $data.context_window.used_percentage) { [int][math]::Floor([double]$data.context_window.used_percentage) } else { 0 }
$durMs = if ($null -ne $data.cost.total_duration_ms) { [long]$data.cost.total_duration_ms } else { 0 }

$E = [char]27
$CYAN = "$E[36m"; $GREEN = "$E[32m"; $YELLOW = "$E[33m"; $RED = "$E[31m"
$MAGENTA = "$E[35m"; $DIM = "$E[2m"; $RESET = "$E[0m"

# Glyphs - built from char codes so the file is safe to read on any code page.
$BLOCK_FULL  = [char]0x2588   # full block
$BLOCK_LIGHT = [char]0x2591   # light shade
$ARROW       = [char]0x21BB   # clockwise arrow (reset countdown)
$BRANCH_GLY  = [char]0x1F33F  # herb / branch indicator
$FOLDER_GLY  = [char]0x1F4C1  # folder
$CLOCK_GLY   = [char]0x23F1   # stopwatch

if ($pct -ge 90)    { $barColor = $RED }
elseif ($pct -ge 70) { $barColor = $YELLOW }
else                  { $barColor = $GREEN }

$filled = [math]::Min(10, [math]::Max(0, [int][math]::Floor($pct / 10)))
$empty  = 10 - $filled
$bar = ([string]$BLOCK_FULL * $filled) + ([string]$BLOCK_LIGHT * $empty)

$mins = [int]($durMs / 60000)
$secs = [int](($durMs % 60000) / 1000)

$branch = ''
git rev-parse --git-dir 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    $b = (git branch --show-current 2>$null).Trim()
    if ($b) { $branch = " | $BRANCH_GLY $b" }
}

# Plan usage cache (60s TTL, $env:TEMP\.claude-usage-cache.json)
$cacheFile = Join-Path $env:TEMP '.claude-usage-cache.json'
$cacheTtl  = 60
$usageLine = ''

function Refresh-Usage {
    $credsFile = Join-Path $HOME '.claude\.credentials.json'
    if (-not (Test-Path $credsFile)) { return }
    try {
        $creds = Get-Content $credsFile -Raw | ConvertFrom-Json
        $token = $creds.claudeAiOauth.accessToken
        if (-not $token) { return }
        $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' `
            -Headers @{ 'Authorization' = "Bearer $token"; 'anthropic-beta' = 'oauth-2025-04-20' } `
            -TimeoutSec 5 -ErrorAction Stop
        if ($null -ne $resp.five_hour) {
            $resp | ConvertTo-Json -Depth 6 | Set-Content -Path $cacheFile -Encoding UTF8
        }
    } catch { }
}

$cacheStale = $true
if (Test-Path $cacheFile) {
    $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
    $cacheStale = ($age.TotalSeconds -ge $cacheTtl)
}
if ($cacheStale) { Refresh-Usage }

if (Test-Path $cacheFile) {
    try {
        $cache = Get-Content $cacheFile -Raw | ConvertFrom-Json
        $fiveH = $cache.five_hour
        $sevenD = $cache.seven_day

        if ($null -ne $fiveH -and $null -ne $fiveH.utilization) {
            $fhPct = [int][math]::Floor([double]$fiveH.utilization)

            $reset5h = ''
            if ($fiveH.resets_at) {
                $diff = [int]([DateTimeOffset]::Parse($fiveH.resets_at).ToUnixTimeSeconds() - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
                if ($diff -gt 0) {
                    $h = [int]($diff / 3600); $m = [int](($diff % 3600) / 60)
                    $reset5h = " $ARROW ${h}h${m}m"
                }
            }

            $reset7d = ''
            if ($sevenD -and $sevenD.resets_at) {
                $diff = [int]([DateTimeOffset]::Parse($sevenD.resets_at).ToUnixTimeSeconds() - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
                if ($diff -gt 0) {
                    $d = [int]($diff / 86400); $h = [int](($diff % 86400) / 3600)
                    $reset7d = " $ARROW ${d}d${h}h"
                }
            }

            if ($fhPct -ge 80)    { $u5 = $RED }
            elseif ($fhPct -ge 50) { $u5 = $YELLOW }
            else                    { $u5 = $GREEN }

            if ($null -ne $sevenD -and $null -ne $sevenD.utilization) {
                $sdPct = [int][math]::Floor([double]$sevenD.utilization)
                if ($sdPct -ge 80)    { $u7 = $RED }
                elseif ($sdPct -ge 50) { $u7 = $YELLOW }
                else                    { $u7 = $GREEN }
                $usageLine = " | 5h: ${u5}${fhPct}%${RESET}${DIM}${reset5h}${RESET} | 7d: ${u7}${sdPct}%${RESET}${DIM}${reset7d}${RESET}"
            } else {
                $usageLine = " | 5h: ${u5}${fhPct}%${RESET}${DIM}${reset5h}${RESET}"
            }
        }
    } catch { }
}

# Plan / API detection
$planStr = ''
$credsFile = Join-Path $HOME '.claude\.credentials.json'
if (Test-Path $credsFile) {
    try {
        $creds = Get-Content $credsFile -Raw | ConvertFrom-Json
        $sub = $creds.claudeAiOauth.subscriptionType
        $tier = $creds.claudeAiOauth.rateLimitTier
        if ($sub) {
            $planName = $sub.Substring(0,1).ToUpper() + $sub.Substring(1)
            if ($tier -match '([0-9]+x)$') { $planName = "$planName $($Matches[1])" }
            $planStr = " ${MAGENTA}${planName}${RESET}"
        }
    } catch { }
} elseif ($env:ANTHROPIC_API_KEY) {
    $planStr = " ${MAGENTA}API${RESET}"
}

$dirName = if ($dir) { Split-Path -Leaf $dir } else { '' }
$costFmt = '$' + ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:N2}', $cost))

[Console]::Out.WriteLine("${CYAN}[$model]${RESET}${planStr} | $FOLDER_GLY $dirName${branch}")
[Console]::Out.WriteLine("${barColor}${bar}${RESET} ${pct}% | ${YELLOW}${costFmt}${RESET} | $CLOCK_GLY ${mins}m ${secs}s${usageLine}")
