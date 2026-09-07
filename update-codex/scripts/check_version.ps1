# =============================================================================
# Codex Version Check (CLI + Desktop)
# Quick read-only check — no downloads, no installs
# =============================================================================
$ErrorActionPreference = "Continue"

# =============================================================================
# PROXY SETUP — reads from Claude Code settings.json, falls back to env vars
# =============================================================================
$proxyUrl = $null
$fromSettings = $false

# Primary: Claude Code settings.json (regex extraction avoids duplicate-key JSON issue)
$settingsPath = "$env:USERPROFILE\.claude\settings.json"
if (Test-Path $settingsPath) {
    try {
        $raw = Get-Content $settingsPath -Raw -ErrorAction Stop
        if ($raw -match '"HTTPS_PROXY"\s*:\s*"([^"]+)"') {
            $proxyUrl = $Matches[1]
            $fromSettings = $true
        } elseif ($raw -match '"HTTP_PROXY"\s*:\s*"([^"]+)"') {
            $proxyUrl = $Matches[1]
            $fromSettings = $true
        }
    } catch {}
}

# Fallback: user environment variables
if (-not $proxyUrl) {
    $proxyUrl = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User')
}
if (-not $proxyUrl) {
    $proxyUrl = [Environment]::GetEnvironmentVariable('HTTP_PROXY', 'User')
}

$proxyConfigured = $false
if ($proxyUrl -and ($proxyUrl -match 'http://([^:]+):([^@]+)@(.+)')) {
    $proxyUser = $Matches[1]
    $proxyPassEncoded = $Matches[2]
    $proxyHostPort = $Matches[3]
    $proxyPass = [uri]::UnescapeDataString($proxyPassEncoded)

    # Split host:port
    if ($proxyHostPort -match '^(.+):(\d+)$') {
        $proxyHost = $Matches[1]
        $proxyPort = [int]$Matches[2]
    } else {
        $proxyHost = $proxyHostPort
        $proxyPort = 8080
    }

    # For child processes (npm)
    $env:HTTPS_PROXY = "http://${proxyUser}:${proxyPassEncoded}@${proxyHostPort}"
    $env:HTTP_PROXY = $env:HTTPS_PROXY
    $env:NODE_TLS_REJECT_UNAUTHORIZED = "0"

    # For PowerShell web cmdlets (don't read env vars)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $cred = New-Object System.Net.NetworkCredential($proxyUser, $proxyPass)
    $proxy = New-Object System.Net.WebProxy("http://${proxyHostPort}", $true)
    $proxy.Credentials = $cred
    [System.Net.WebRequest]::DefaultWebProxy = $proxy

    $proxyConfigured = $true
}

# =============================================================================
# HEADER
# =============================================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Codex Version Check" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not $proxyConfigured) {
    Write-Host "[Proxy] NOT CONFIGURED — check ~/.claude/settings.json" -ForegroundColor Yellow
    Write-Host ""
} else {
    $sourceLabel = if ($fromSettings) { "settings.json" } else { "env vars" }
    Write-Host "[Proxy] ${proxyHostPort} (user: ${proxyUser}, source: ${sourceLabel})" -ForegroundColor Gray
}

# =============================================================================
# CONNECTIVITY PRE-CHECK (only if proxy is configured)
# =============================================================================
if ($proxyConfigured) {
    $ghOk = $false
    try {
        $gh = Invoke-RestMethod -Uri 'https://api.github.com/repos/Wangnov/codex-app-mirror/releases?per_page=1' -TimeoutSec 10 -ErrorAction Stop
        $ghOk = ($gh -and $gh.Count -gt 0)
    } catch {}

    $npmOk = $false
    try {
        $npmTest = [string](npm view @openai/codex version 2>&1)
        $npmOk = ($npmTest -match '\d+\.\d+\.\d+')
    } catch {}

    if ($ghOk -and $npmOk) {
        Write-Host "[Connectivity] All OK" -ForegroundColor Green
    } else {
        $issues = @()
        if (-not $ghOk) { $issues += "GitHub API unreachable" }
        if (-not $npmOk) { $issues += "npm registry unreachable" }
        Write-Host "[Connectivity] ISSUES: $($issues -join ', ')" -ForegroundColor Red
        Write-Host "  Check proxy credentials in ~/.claude/settings.json" -ForegroundColor Yellow
    }
    Write-Host ""
}

# =============================================================================
# DESKTOP
# =============================================================================
Write-Host "=== Codex Desktop ===" -ForegroundColor Yellow
$desktop = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue
if ($desktop) {
    Write-Host "  Installed: $($desktop.Version)" -ForegroundColor White
} else {
    Write-Host "  Installed: NOT FOUND" -ForegroundColor DarkGray
}

if ($proxyConfigured) {
    try {
        # Search recent releases for one with an x64 Msix (latest may not include it)
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/Wangnov/codex-app-mirror/releases?per_page=10' -TimeoutSec 15 -ErrorAction Stop
        $msixAsset = $null
        $matchedRelease = $null
        foreach ($release in $releases) {
            $msixAsset = $release.assets | Where-Object { $_.name -like "*x64*.Msix" } | Select-Object -First 1
            if ($msixAsset) {
                $matchedRelease = $release
                break
            }
        }
        if ($msixAsset) {
            $latestDesktop = $msixAsset.name -replace '.*OpenAI\.Codex_([\d.]+)_.*', '$1'
            $sizeMB = [math]::Round($msixAsset.size / 1MB, 0)
            Write-Host "  Latest:    $latestDesktop ($sizeMB MB, $($matchedRelease.published_at))" -ForegroundColor White

            if ($desktop -and $desktop.Version -eq $latestDesktop) {
                Write-Host "  Status:    UP TO DATE" -ForegroundColor Green
            } elseif ($desktop) {
                Write-Host "  Status:    UPDATE AVAILABLE" -ForegroundColor Magenta
            } else {
                Write-Host "  Status:    NOT INSTALLED" -ForegroundColor Red
            }
        } else {
            Write-Host "  Latest:    No x64 Msix found in recent releases" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Latest:    FETCH FAILED ($($_.Exception.Message))" -ForegroundColor Red
    }
} else {
    Write-Host "  Latest:    SKIPPED (no proxy)" -ForegroundColor DarkGray
}

Write-Host ""

# =============================================================================
# CLI
# =============================================================================
Write-Host "=== Codex CLI ===" -ForegroundColor Yellow
$installedCli = $null

# Try codex --version first
try {
    $cliOut = codex --version 2>&1
    if ($cliOut -match 'codex-cli (\d+\.\d+\.\d+)') {
        $installedCli = $Matches[1]
        Write-Host "  Installed: $installedCli" -ForegroundColor White
    }
} catch {}

# Fallback: npm list
if (-not $installedCli) {
    try {
        $npmList = npm list -g @openai/codex 2>&1
        if ($npmList -match '@openai/codex@(\d+\.\d+\.\d+)') {
            $installedCli = $Matches[1]
            Write-Host "  Installed: $installedCli (npm global, but codex cmd not on PATH)" -ForegroundColor Yellow
        }
    } catch {}
}

if (-not $installedCli) {
    Write-Host "  Installed: NOT FOUND" -ForegroundColor DarkGray
}

# Check latest from npm (only if proxy is configured)
if ($proxyConfigured) {
    try {
        $latestCli = [string](npm view @openai/codex version 2>&1)
        if ($latestCli -match '(\d+\.\d+\.\d+)') {
            $latestCli = $Matches[1]
            Write-Host "  Latest:    $latestCli" -ForegroundColor White

            if ($installedCli -and $installedCli -eq $latestCli) {
                Write-Host "  Status:    UP TO DATE" -ForegroundColor Green
            } elseif ($installedCli) {
                Write-Host "  Status:    UPDATE AVAILABLE" -ForegroundColor Magenta
            } else {
                Write-Host "  Status:    NOT INSTALLED" -ForegroundColor Red
            }
        }
    } catch {
        Write-Host "  Latest:    FETCH FAILED ($($_.Exception.Message))" -ForegroundColor Red
    }
} else {
    Write-Host "  Latest:    SKIPPED (no proxy)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
