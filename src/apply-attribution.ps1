<#
.SYNOPSIS
    Turns off Claude Code's git commit / PR attribution for the current Windows user.

.DESCRIPTION
    Merges the attribution keys into %USERPROFILE%\.claude\settings.json. Every
    other key in that file is preserved, so this is safe to re-run. Called by
    install-windows.bat; the Docker equivalent lives in src/startup.sh.

    Four keys are involved and they are NOT interchangeable:

      includeCoAuthoredBy    = false  legacy "Co-Authored-By: Claude" trailer (deprecated key)
      attribution.commit     = ""     "Generated with Claude Code" commit footer
      attribution.pr         = ""     the same footer in PR bodies
      attribution.sessionUrl = false  "Claude-Session: https://claude.ai/code/..." trailer

    sessionUrl is the one people miss. An empty attribution.commit does NOT
    suppress the session trailer - Claude Code then emits the session URL as the
    *only* trailer, because it builds the text as:

        commit = e.commit ? `${e.commit}\nClaude-Session: ${url}` : `Claude-Session: ${url}`

    See anthropics/claude-code#77830 (closed as working-as-designed; sessionUrl
    is the documented switch). The env var CLAUDE_CODE_SUPPRESS_SESSION_ATTRIBUTION
    hits the same gate, but a setting survives across shells and terminals.

.NOTES
    Skipped when DISABLE_AI_ATTRIBUTION=false, matching the .env flag the Docker
    side honours.
#>

$ErrorActionPreference = 'Stop'

if ($env:DISABLE_AI_ATTRIBUTION -eq 'false') {
    Write-Host '[--] DISABLE_AI_ATTRIBUTION=false - leaving Claude attribution settings alone.'
    exit 0
}

function Set-Prop($target, $name, $value) {
    if ($target.PSObject.Properties.Match($name).Count) { $target.$name = $value }
    else { $target | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

$settingsPath = Join-Path $HOME '.claude\settings.json'
$dir = Split-Path -Parent $settingsPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

$obj = $null
if (Test-Path $settingsPath) {
    $raw = [System.IO.File]::ReadAllText($settingsPath)
    if ($raw.Trim()) {
        try {
            $obj = $raw | ConvertFrom-Json
        } catch {
            Write-Host "[!] $settingsPath is not valid JSON - refusing to rewrite it."
            Write-Host "    Fix the file (or delete it) and re-run install-windows.bat."
            exit 1
        }
        # Rewriting a real config: keep one rollback copy next to it.
        Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.bak" -Force
    }
}
if ($null -eq $obj) { $obj = [pscustomobject]@{} }

# Preserve any other attribution sub-keys a future Claude Code version may add.
$attr = $obj.attribution
if ($null -eq $attr -or $attr.GetType().Name -ne 'PSCustomObject') { $attr = [pscustomobject]@{} }
Set-Prop $attr 'commit' ''
Set-Prop $attr 'pr' ''
Set-Prop $attr 'sessionUrl' $false

Set-Prop $obj 'attribution' $attr
Set-Prop $obj 'includeCoAuthoredBy' $false

# ConvertTo-Json escapes non-ASCII to \uXXXX, so writing UTF-8 without BOM keeps
# the file byte-safe for both Claude Code and anything else that reads it.
$json = $obj | ConvertTo-Json -Depth 100
[System.IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "[OK] AI attribution disabled in $settingsPath"
Write-Host '     (Co-Authored-By, commit/PR footer, and the Claude-Session trailer)'
