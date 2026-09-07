# =============================================================================
# Codex Update Master Script
# Handles both CLI (npm merge approach) and Desktop (BITS download)
# =============================================================================
param(
    [switch]$CliOnly,
    [switch]$DesktopOnly,
    [switch]$CheckOnly,
    [string]$Registry = "https://registry.npmmirror.com",
    [string]$MsixPath = ""          # Use an existing local MSIX instead of downloading
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# =============================================================================
# PROXY SETUP — reads from Claude Code settings.json, falls back to env vars
# =============================================================================
function Setup-Proxy {
    $proxyUrl = $null

    # Primary source: Claude Code settings.json
    # Use regex extraction instead of ConvertFrom-Json because the JSON has
    # case-insensitive duplicate keys (HTTP_PROXY + http_proxy) which break
    # PowerShell's JSON parser.
    $settingsPath = "$env:USERPROFILE\.claude\settings.json"
    $fromSettings = $false
    if (Test-Path $settingsPath) {
        try {
            $raw = Get-Content $settingsPath -Raw -ErrorAction Stop
            # Extract proxy value with regex (case-sensitive, avoids duplicate-key issue)
            if ($raw -match '"HTTPS_PROXY"\s*:\s*"([^"]+)"') {
                $proxyUrl = $Matches[1]
                $fromSettings = $true
            } elseif ($raw -match '"HTTP_PROXY"\s*:\s*"([^"]+)"') {
                $proxyUrl = $Matches[1]
                $fromSettings = $true
            }
        } catch {
            # Silently fall through to env var fallback
        }
    }

    # Fallback: user environment variables
    if (-not $proxyUrl) {
        $proxyUrl = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User')
    }
    if (-not $proxyUrl) {
        $proxyUrl = [Environment]::GetEnvironmentVariable('HTTP_PROXY', 'User')
    }

    if ($proxyUrl -and ($proxyUrl -match 'http://([^:]+):([^@]+)@(.+)')) {
        $script:ProxyUser = $Matches[1]
        $script:ProxyPassEncoded = $Matches[2]
        $script:ProxyHostPort = $Matches[3]   # e.g., "proxysg.huawei.com:8080"

        # Split host:port
        if ($script:ProxyHostPort -match '^(.+):(\d+)$') {
            $script:ProxyHost = $Matches[1]
            $script:ProxyPort = [int]$Matches[2]
        } else {
            $script:ProxyHost = $script:ProxyHostPort
            $script:ProxyPort = 8080
        }

        # Decode password (e.g., %40 -> @) for NetworkCredential
        $script:ProxyPass = [uri]::UnescapeDataString($script:ProxyPassEncoded)

        $fullProxyUrl = "http://${script:ProxyUser}:${script:ProxyPassEncoded}@${script:ProxyHostPort}"

        # For npm / child processes that read env vars
        $env:HTTPS_PROXY = $fullProxyUrl
        $env:HTTP_PROXY = $fullProxyUrl
        $env:NODE_TLS_REJECT_UNAUTHORIZED = "0"
        $env:NO_PROXY = "localhost,127.0.0.1,::1"

        # For Invoke-RestMethod / Invoke-WebRequest (don't read env vars)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $cred = New-Object System.Net.NetworkCredential($script:ProxyUser, $script:ProxyPass)
        $proxy = New-Object System.Net.WebProxy("http://$($script:ProxyHostPort)", $true)
        $proxy.Credentials = $cred
        [System.Net.WebRequest]::DefaultWebProxy = $proxy

        $script:ProxyConfigured = $true
        $sourceLabel = if ($fromSettings) { "settings.json" } else { "env vars" }
        Write-Host "[Proxy] $($script:ProxyHostPort) (user: $($script:ProxyUser), source: $sourceLabel)" -ForegroundColor Gray
    } else {
        $script:ProxyConfigured = $false
        Write-Host "[Proxy] NOT CONFIGURED — network calls will likely fail" -ForegroundColor Red
        Write-Host "  Expected: HTTPS_PROXY in ~/.claude/settings.json or user env vars" -ForegroundColor Yellow
        Write-Host "  Format:   http://<eid>:<password>@proxysg.huawei.com:8080" -ForegroundColor Yellow
    }
}

# =============================================================================
# CONNECTIVITY PRE-CHECK — fail fast if network is broken
# =============================================================================
function Test-Connectivity {
    Write-Host "`n=== Connectivity Check ===" -ForegroundColor Cyan

    if (-not $script:ProxyConfigured) {
        Write-Host "  SKIPPED: No proxy configured" -ForegroundColor Yellow
        return $false
    }

    $allOk = $true
    $proxyHost = $script:ProxyHost
    $proxyPort = $script:ProxyPort

    # 1. TCP reachability to proxy
    Write-Host "  [1/3] Proxy TCP..." -ForegroundColor Gray -NoNewline
    $tcpOk = Test-NetConnection -ComputerName $proxyHost -Port $proxyPort -WarningAction SilentlyContinue -InformationLevel Quiet
    if ($tcpOk) {
        Write-Host " OK ($proxyHost`:$proxyPort reachable)" -ForegroundColor Green
    } else {
        Write-Host " FAIL ($proxyHost`:$proxyPort unreachable)" -ForegroundColor Red
        $allOk = $false
    }

    # 2. GitHub API through proxy
    Write-Host "  [2/3] GitHub API..." -ForegroundColor Gray -NoNewline
    try {
        $gh = Invoke-RestMethod -Uri 'https://api.github.com/repos/Wangnov/codex-app-mirror/releases?per_page=1' -TimeoutSec 15 -ErrorAction Stop
        if ($gh -and $gh.Count -gt 0) {
            Write-Host " OK (release: $($gh[0].tag_name))" -ForegroundColor Green
        } else {
            Write-Host " OK (empty response)" -ForegroundColor Yellow
            $allOk = $false
        }
    } catch {
        $errMsg = $_.Exception.Message
        if ($errMsg -match '407|401|403') {
            Write-Host " FAIL (proxy auth: $errMsg)" -ForegroundColor Red
        } else {
            Write-Host " FAIL ($errMsg)" -ForegroundColor Red
        }
        $allOk = $false
    }

    # 3. npm registry through proxy
    Write-Host "  [3/3] npm registry..." -ForegroundColor Gray -NoNewline
    try {
        $npmTest = [string](npm view @openai/codex version 2>&1)
        if ($npmTest -match '\d+\.\d+\.\d+') {
            Write-Host " OK (@openai/codex $($Matches[1]))" -ForegroundColor Green
        } else {
            Write-Host " FAIL (unexpected output: $npmTest)" -ForegroundColor Red
            $allOk = $false
        }
    } catch {
        Write-Host " FAIL ($($_.Exception.Message))" -ForegroundColor Red
        $allOk = $false
    }

    if (-not $allOk) {
        Write-Host "`n  CONNECTIVITY ISSUES DETECTED. Check:" -ForegroundColor Red
        Write-Host "    - Proxy credentials in ~/.claude/settings.json" -ForegroundColor Yellow
        Write-Host "    - Corporate network connection (VPN?)" -ForegroundColor Yellow
        Write-Host "    - Firewall allowing proxy access on port 8080" -ForegroundColor Yellow
    } else {
        Write-Host "  All checks passed." -ForegroundColor Green
    }

    return $allOk
}

# =============================================================================
# VERSION CHECK
# =============================================================================
function Get-CurrentVersions {
    Write-Host "`n=== Current Versions ===" -ForegroundColor Cyan

    # Desktop
    $script:CurrentDesktop = $null
    $app = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue
    if ($app) {
        $script:CurrentDesktop = $app.Version.ToString()
        Write-Host "  Desktop: $($script:CurrentDesktop)" -ForegroundColor White
    } else {
        Write-Host "  Desktop: NOT INSTALLED" -ForegroundColor DarkGray
    }

    # CLI
    $script:CurrentCli = $null
    try {
        $cliOut = codex --version 2>&1
        if ($cliOut -match '(\d+\.\d+\.\d+)') {
            $script:CurrentCli = $Matches[1]
            Write-Host "  CLI:     $($script:CurrentCli)" -ForegroundColor White
        }
    } catch {
        # codex not on PATH, check npm
        try {
            $npmList = npm list -g @openai/codex 2>&1
            if ($npmList -match '@openai/codex@(\d+\.\d+\.\d+)') {
                $script:CurrentCli = $Matches[1]
                Write-Host "  CLI:     $($script:CurrentCli) (npm, but codex not on PATH)" -ForegroundColor Yellow
            }
        } catch {}
    }
    if (-not $script:CurrentCli) {
        Write-Host "  CLI:     NOT INSTALLED" -ForegroundColor DarkGray
    }
}

function Get-LatestVersions {
    Write-Host "`n=== Latest Versions ===" -ForegroundColor Cyan

    # Desktop - GitHub mirror API
    $script:LatestDesktop = $null
    $script:DesktopDownloadUrl = $null
    try {
        # Search recent releases for one with an x64 Msix (latest may not include it)
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/Wangnov/codex-app-mirror/releases?per_page=10' -TimeoutSec 30 -ErrorAction Stop
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
            $script:LatestDesktop = $msixAsset.name -replace '.*OpenAI\.Codex_([\d.]+)_.*', '$1'
            $script:DesktopDownloadUrl = $msixAsset.browser_download_url
            $script:DesktopSizeMB = [math]::Round($msixAsset.size / 1MB, 0)
            Write-Host "  Desktop: $($script:LatestDesktop) ($($script:DesktopSizeMB) MB, published $($matchedRelease.published_at))" -ForegroundColor White
        } else {
            Write-Host "  Desktop: No x64 Msix in recent releases" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Desktop: FETCH FAILED - $_" -ForegroundColor Red
    }

    # CLI - npm
    $script:LatestCli = $null
    try {
        $npmOut = [string](npm view @openai/codex version 2>&1)
        if ($npmOut -match '(\d+\.\d+\.\d+)') {
            $script:LatestCli = $Matches[1]
            Write-Host "  CLI:     $($script:LatestCli)" -ForegroundColor White
        }
    } catch {
        Write-Host "  CLI:     FETCH FAILED - $_" -ForegroundColor Red
    }

    # Summary
    Write-Host ""
    $desktopAction = if (-not $script:CurrentDesktop) { "INSTALL" }
                     elseif ($script:CurrentDesktop -eq $script:LatestDesktop) { "UP TO DATE" }
                     else { "UPDATE" }
    $cliAction = if (-not $script:CurrentCli) { "INSTALL" }
                 elseif ($script:CurrentCli -eq $script:LatestCli) { "UP TO DATE" }
                 else { "UPDATE" }

    $desktopColor = if ($desktopAction -eq "UP TO DATE") { "Green" } else { "Yellow" }
    $cliColor = if ($cliAction -eq "UP TO DATE") { "Green" } else { "Yellow" }

    Write-Host "  Desktop: $desktopAction ($($script:CurrentDesktop) -> $($script:LatestDesktop))" -ForegroundColor $desktopColor
    Write-Host "  CLI:     $cliAction ($($script:CurrentCli) -> $($script:LatestCli))" -ForegroundColor $cliColor
}

# =============================================================================
# CLI UPDATE — Merge Approach
# =============================================================================
function Update-CodexCli {
    param([string]$Version, [string]$RegistryUrl)

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  UPDATING CODEX CLI" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    $tempDir = "$env:TEMP\codex-cli-update"
    $platformVersion = "$Version-win32-x64"
    $globalCodexDir = "$env:APPDATA\npm\node_modules\@openai\codex"
    $npmPrefix = "$env:APPDATA\npm"

    # Clean temp
    if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    # ---- Step 1: Install main package (gets bin/codex.js) ----
    Write-Host "[1/4] Installing main package..." -ForegroundColor Yellow
    Push-Location $tempDir
    try {
        npm init -y 2>&1 | Out-Null
        # fast-fail network: 20s timeout x 2 retries instead of npm's silent 5-min hangs
        $result = npm install "@openai/codex@$Version" --registry $RegistryUrl --no-save --fetch-timeout=20000 --fetch-retries=2 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ERROR installing main package: $result" -ForegroundColor Red
            Pop-Location
            return $false
        }
        Write-Host "  Main package installed" -ForegroundColor Green
    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
        Pop-Location
        return $false
    }
    Pop-Location

    $codexJsPath = "$tempDir\node_modules\@openai\codex\bin\codex.js"
    if (-not (Test-Path $codexJsPath)) {
        Write-Host "  ERROR: bin/codex.js not found after main install" -ForegroundColor Red
        return $false
    }

    # ---- Step 2: Backup codex.js ----
    Write-Host "[2/4] Saving bin/codex.js..." -ForegroundColor Yellow
    $backupPath = "$tempDir\codex.js.backup"
    Copy-Item $codexJsPath $backupPath -Force
    Write-Host "  Saved ($((Get-Item $backupPath).Length) bytes)" -ForegroundColor Green

    # ---- Step 3: Install platform binary (gets vendor/) ----
    # TWO-TIER: mirror first (fast), fallback to official registry (reliable)
    Write-Host "[3/4] Installing platform binary (~400 MB, this takes several minutes)..." -ForegroundColor Yellow

    $vendorExe = "$tempDir\node_modules\@openai\codex\vendor\x86_64-pc-windows-msvc\bin\codex.exe"
    $officialRegistry = "https://registry.npmjs.org"
    $platformInstalled = $false

    # Tier 1: Try mirror
    Push-Location $tempDir
    try {
        Write-Host "  Tier 1: npm mirror..." -ForegroundColor Gray
        $result = npm install "@openai/codex@$platformVersion" --registry $RegistryUrl --no-save --fetch-timeout=20000 --fetch-retries=2 2>&1
        if (Test-Path $vendorExe) {
            Write-Host "  Mirror OK" -ForegroundColor Green
            $platformInstalled = $true
        } else {
            Write-Host "  Mirror: vendor/codex.exe missing (known mirror corruption)" -ForegroundColor Yellow
            # Clean failed install before retry
            Remove-Item -Recurse -Force "$tempDir\node_modules\@openai\codex" -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "  Mirror attempt failed: $_" -ForegroundColor Yellow
        Remove-Item -Recurse -Force "$tempDir\node_modules\@openai\codex" -ErrorAction SilentlyContinue
    }
    Pop-Location

    # Tier 2: Try official npm registry
    if (-not $platformInstalled) {
        Write-Host "  Tier 2: official npm registry..." -ForegroundColor Gray
        Push-Location $tempDir
        try {
            $result = npm install "@openai/codex@$platformVersion" --registry $officialRegistry --no-save --fetch-timeout=20000 --fetch-retries=2 2>&1
            if (Test-Path $vendorExe) {
                Write-Host "  Official registry OK" -ForegroundColor Green
                $platformInstalled = $true
            } else {
                Write-Host "  Official registry: vendor/codex.exe still missing" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  Official registry attempt failed: $_" -ForegroundColor Yellow
        }
        Pop-Location
    }

    # Tier 3: Reuse vendor from current global install
    if (-not $platformInstalled) {
        $globalVendorExe = "$globalCodexDir\vendor\x86_64-pc-windows-msvc\bin\codex.exe"
        if (Test-Path $globalVendorExe) {
            Write-Host "  Tier 3: Reusing vendor from current install..." -ForegroundColor Gray
            $targetVendorDir = "$tempDir\node_modules\@openai\codex\vendor\x86_64-pc-windows-msvc\bin"
            New-Item -ItemType Directory -Path $targetVendorDir -Force | Out-Null
            Copy-Item $globalVendorExe $targetVendorDir -Force
            $platformInstalled = $true
            Write-Host "  Vendor reused (binary may be older version)" -ForegroundColor Yellow
        }
    }

    if (-not $platformInstalled) {
        Write-Host "  ERROR: All platform binary sources exhausted" -ForegroundColor Red
        return $false
    }
    $vendorSizeMB = [math]::Round((Get-Item $vendorExe).Length / 1MB, 0)
    Write-Host "  codex.exe: $vendorSizeMB MB" -ForegroundColor Green

    # ---- Step 4: Restore codex.js and deploy to global ----
    Write-Host "[4/4] Assembling and deploying..." -ForegroundColor Yellow

    # Restore bin/codex.js (overwritten by platform package)
    $targetJsDir = "$tempDir\node_modules\@openai\codex\bin"
    if (-not (Test-Path $targetJsDir)) { New-Item -ItemType Directory -Path $targetJsDir -Force | Out-Null }
    Copy-Item $backupPath $codexJsPath -Force
    Write-Host "  Restored bin/codex.js" -ForegroundColor Green

    # Copy to global npm
    $globalOpenAiDir = Split-Path $globalCodexDir -Parent
    if (-not (Test-Path $globalOpenAiDir)) { New-Item -ItemType Directory -Path $globalOpenAiDir -Force | Out-Null }
    if (Test-Path $globalCodexDir) { Remove-Item -Recurse -Force $globalCodexDir -ErrorAction SilentlyContinue }
    Copy-Item -Recurse "$tempDir\node_modules\@openai\codex" $globalCodexDir -Force
    Write-Host "  Copied to global npm" -ForegroundColor Green

    # Create bin links (use single-quote heredoc to prevent $_ expansion)
    $cmdContent = @'
@ECHO off
GOTO start
:find_dp0
SET dp0=%~dp0
EXIT /b
:start
SETLOCAL
CALL :find_dp0

IF EXIST "%dp0%\node.exe" (
  SET "_prog=%dp0%\node.exe"
) ELSE (
  SET "_prog=node"
  SET PATHEXT=%PATHEXT:;.JS;=;%
)

endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%" "%dp0%\node_modules\@openai\codex\bin\codex.js" %*
'@

    $ps1Content = @'
#!/usr/bin/env pwsh
$basedir=Split-Path $MyInvocation.MyCommand.Definition -Parent

$exe=""
if ($PSVersionTable.PSVersion -lt "6.0" -or $IsWindows) {
  $exe=".exe"
}
$ret=0

$node_exe = Join-Path $basedir "node$exe"
if (Test-Path $node_exe) {
  & $node_exe (Join-Path $basedir "node_modules/@openai/codex/bin/codex.js") $args
  $ret=$LASTEXITCODE
} else {
  & node (Join-Path $basedir "node_modules/@openai/codex/bin/codex.js") $args
  $ret=$LASTEXITCODE
}
exit $ret
'@

    $cmdContent | Out-File -FilePath "$npmPrefix\codex.cmd" -Encoding ASCII -Force
    $ps1Content | Out-File -FilePath "$npmPrefix\codex.ps1" -Encoding ASCII -Force
    Write-Host "  Created bin links" -ForegroundColor Green

    # Cleanup
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue

    # Verify
    Write-Host ""
    try {
        $verifyOut = codex --version 2>&1
        if ($verifyOut -match 'codex-cli (\d+\.\d+\.\d+)') {
            Write-Host "  VERIFIED: codex-cli $($Matches[1])" -ForegroundColor Green
            return $true
        }
    } catch {
        Write-Host "  VERIFY FAILED: $_" -ForegroundColor Red
        return $false
    }

    Write-Host "  VERIFY FAILED: unexpected output: $verifyOut" -ForegroundColor Red
    return $false
}

# =============================================================================
# DESKTOP UPDATE — Adaptive download + watchdog install
# =============================================================================
function Get-AssetSha256Hex {
    # Official per-asset hash for a mirror release asset.
    # Prefers SHA256SUMS-windows.txt (exact asset bytes); falls back to decoding
    # the Microsoft catalog hash in release-manifest.json.
    param([string]$AssetUrl)
    $base = $AssetUrl.Substring(0, $AssetUrl.LastIndexOf('/'))
    $fileName = $AssetUrl.Substring($AssetUrl.LastIndexOf('/') + 1)

    # Try 1: SHA256SUMS-windows.txt
    try {
        $sumsUrl = "$base/SHA256SUMS-windows.txt"
        $content = (Invoke-WebRequest -Uri $sumsUrl -TimeoutSec 30 -UseBasicParsing).Content
        foreach ($line in ($content -split "`r?`n")) {
            if ($line -match "^([0-9a-fA-F]{64})\s+\*?\s*$([regex]::Escape($fileName))") {
                return $Matches[1].ToLower()
            }
        }
    } catch { }

    # Try 2: release-manifest.json -> Microsoft catalog hash (base64 -> hex)
    try {
        $manifest = Invoke-RestMethod -Uri "$base/release-manifest.json" -TimeoutSec 30
        $b64 = $manifest.sources.windows.architectures.x64.catalog.hash
        if ($b64) {
            $hex = ([Convert]::FromBase64String($b64) | ForEach-Object { $_.ToString('x2') }) -join ''
            return $hex
        }
    } catch { }

    Write-Host "  WARNING: could not fetch official SHA-256 for $fileName" -ForegroundColor Yellow
    return $null
}

function Get-MsixVersion {
    # Reads Version="x.y.z.q" from AppxManifest.xml inside an MSIX (no install).
    param([string]$MsixFile)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zip = [System.IO.Compression.ZipFile]::OpenRead($MsixFile)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq 'AppxManifest.xml' } | Select-Object -First 1
            if (-not $entry) { return $null }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { $xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
            if ($xml -match 'Version="(\d+\.\d+\.\d+\.\d+)"') { return $Matches[1] }
        } finally { $zip.Dispose() }
    } catch {
        Write-Host "  WARNING: cannot read version from $MsixFile : $_" -ForegroundColor Yellow
    }
    return $null
}

function Update-CodexDesktop {
    param([string]$Version, [string]$DownloadUrl)

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  UPDATING CODEX DESKTOP" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    $targetMsix = "$env:TEMP\OpenAI.Codex.Update.msix"

    # ---- Stop running app ----
    Write-Host "[1/5] Stopping running Codex Desktop..." -ForegroundColor Yellow
    $stopped = $false
    try {
        $process = Get-Process -Name "Codex" -ErrorAction SilentlyContinue
        if (-not $process) {
            $process = Get-Process | Where-Object { $_.ProcessName -match 'codex' }
        }
        if ($process) {
            $process | ForEach-Object { Write-Host "  Killing: $($_.ProcessName) (PID: $($_.Id))" -ForegroundColor Gray }
            $process | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            Write-Host "  Codex processes stopped" -ForegroundColor Green
        } else {
            Write-Host "  No Codex processes running" -ForegroundColor Gray
        }
        $stopped = $true
    } catch {
        Write-Host "  WARNING: Could not stop Codex: $_" -ForegroundColor Yellow
    }

    if (-not $stopped) {
        $codexApp = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue
        if ($codexApp) {
            Write-Host "  ERROR: Codex Desktop is running and must be closed first" -ForegroundColor Red
            return $false
        }
    }

    # ---- [2/5] Source selection: user-provided MSIX or download ----
    $useMsix = $MsixPath
    if ($useMsix -and (Test-Path $useMsix)) {
        Write-Host "[2/5] Using provided MSIX: $useMsix" -ForegroundColor Yellow
        $localVer = Get-MsixVersion -MsixFile $useMsix
        if ($localVer -ne $Version) {
            Write-Host "  ERROR: provided MSIX is version $localVer, need $Version" -ForegroundColor Red
            Write-Host "  (If the provided file is a NEWER build than the mirror knows, this is OK to skip; otherwise fetch the right one)" -ForegroundColor Yellow
            return $false
        }
        Write-Host "  Version match: $localVer" -ForegroundColor Green
        $msixPath = $useMsix
    } else {
        Write-Host "[2/5] Downloading ~$($script:DesktopSizeMB) MB..." -ForegroundColor Yellow
        if ($useMsix) {
            Write-Host "  ERROR: -MsixPath '$useMsix' not found" -ForegroundColor Red
            return $false
        }
        if (Test-Path $targetMsix) { Remove-Item $targetMsix -Force }

        # Official SHA-256 for content verification (mirror has had corrupt data)
        $expectedSha = Get-AssetSha256Hex -AssetUrl $DownloadUrl

        # --- Adaptive: BITS with rate watchdog, failover to verified parallel download ---
        # The proxy throttles per TCP connection (~45 KB/s). If BITS is stuck in
        # that regime, 760 MB would take ~5 h. Parallel ranged slices multiply it.
        $bitsOK = $false
        try {
            Import-Module BitsTransfer -ErrorAction Stop
            $bt = Start-BitsTransfer -Source $DownloadUrl -Destination $targetMsix -Asynchronous -DisplayName "CodexDesktopUpdate" -RetryInterval 60 -RetryTimeout 7200 -ErrorAction Stop
            Write-Host "  BITS job started; sampling every 10s to decide strategy..." -ForegroundColor Gray

            # 10s-level decision loop: transfer / slow / stalled -> act immediately
            $samples = @()       # rolling bytes history (last ~8 polls)
            $noGrowth = 0
            while ($true) {
                Start-Sleep -Seconds 10
                $bt = Get-BitsTransfer -JobId $bt.JobId -ErrorAction SilentlyContinue
                if (-not $bt) { Write-Host "  BITS job vanished" -ForegroundColor Yellow; break }
                if ($bt.JobState -eq 'Transferred') { $bitsOK = $true; break }
                if ($bt.JobState -match 'Error|TransientError') {
                    Write-Host "  BITS job errored: $($bt.ErrorDescription)" -ForegroundColor Yellow
                    break
                }
                $cur = if (Test-Path $targetMsix) { (Get-Item $targetMsix).Length } else { 0 }
                if ($samples.Count -gt 0 -and $cur -eq $samples[$samples.Count - 1].bytes) { $noGrowth++ } else { $noGrowth = 0 }
                $samples += @{ t = Get-Date; bytes = $cur }
                if ($samples.Count -gt 8) { $samples = $samples | Select-Object -Skip 1 }
                if ($samples.Count -ge 2) {
                    $spanMin = [math]::Max(0.05, ($samples[$samples.Count - 1].t - $samples[0].t).TotalMinutes)
                    $avgMBmin = [math]::Round((($cur - $samples[0].bytes) / 1MB) / $spanMin, 1)
                    Write-Host "  BITS: $([math]::Round($cur/1MB,0)) MB, avg $avgMBmin MB/min" -ForegroundColor Gray
                    if ($avgMBmin -ge 10) {
                        # healthy: keep waiting, but bail if it then stalls
                        if ($noGrowth -ge 6) {   # 60s stalled after being healthy
                            Write-Host "  BITS stalled (no growth 60s) - switching to parallel" -ForegroundColor Yellow
                            break
                        }
                        continue
                    }
                    # sustained slow or zero
                    if ($noGrowth -ge 3 -or ($samples.Count -ge 3 -and $avgMBmin -lt 10)) {
                        Write-Host "  BITS too slow/stalled (per-connection throttle) - switching to parallel download" -ForegroundColor Yellow
                        break
                    }
                }
            }
            if ($bt) { Remove-BitsTransfer $bt -ErrorAction SilentlyContinue }
        } catch {
            Write-Host "  BITS failed: $_" -ForegroundColor Yellow
        }

        if (-not $bitsOK) {
            if (-not $expectedSha) {
                Write-Host "  ERROR: no SHA-256 available; parallel download requires verification" -ForegroundColor Red
                Write-Host "  Retry when the network/mirror is healthy, or provide -MsixPath <file>" -ForegroundColor Yellow
                return $false
            }
            $proxyUrl = ""
            if ($script:ProxyConfigured) { $proxyUrl = "http://${script:ProxyUser}:${script:ProxyPassEncoded}@${script:ProxyHostPort}" }
            $dlScript = Join-Path $PSScriptRoot "download_msix_verified.ps1"
            Write-Host "  Launching verified parallel downloader (16 slices)..." -ForegroundColor Gray
            & powershell -NoProfile -ExecutionPolicy Bypass -File $dlScript `
                -DownloadUrl $DownloadUrl -OutputPath $targetMsix `
                -ExpectedSize 0 -ExpectedSha256Hex $expectedSha `
                -Proxy $proxyUrl
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  ERROR: parallel download failed" -ForegroundColor Red
                return $false
            }
        }

        $msixPath = $targetMsix
    }

    # ---- [3/5] Content verification before install (prevents 0x80080206 surprises) ----
    if ($msixPath -eq $targetMsix -and $expectedSha) {
        Write-Host "[3/5] Verifying SHA-256..." -ForegroundColor Yellow
        $actual = (Get-FileHash -Path $msixPath -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $expectedSha) {
            Write-Host "  ERROR: SHA-256 mismatch - file corrupt (expected $expectedSha)" -ForegroundColor Red
            Write-Host "  actual: $actual" -ForegroundColor Red
            Remove-Item $msixPath -Force -ErrorAction SilentlyContinue
            return $false
        }
        Write-Host "  SHA-256 verified" -ForegroundColor Green
    }

    # ---- [4/5] Install with 10s liveness watchdog ----
    # Wedged deployments show ZERO activity: no new deployment-log entries, no
    # CPU. If the package doesn't get a fresh log entry within 60s of the last
    # one while still running -> it is wedged; kill and guide recovery NOW.
    # (Healthy installs stream deployment-log milestones within seconds.)
    Write-Host "[4/5] Installing (liveness watchdog: 10s polls, 60s-idle = hung)..." -ForegroundColor Yellow
    $installJob = Start-Job -ScriptBlock {
        param($p)
        $ok = $false
        try {
            Add-AppxPackage -Path $p -ForceApplicationShutdown -ErrorAction Stop
            $ok = $true
        } catch {
            if ($_.Exception.Message -match "0x80073D02") {
                Start-Sleep -Seconds 2
                try {
                    Add-AppxPackage -Path $p -ForceApplicationShutdown -ErrorAction Stop
                    $ok = $true
                } catch { }
            }
        }
        return $ok
    } -ArgumentList $msixPath

    $installSuccess = $false
    $lastActivity = Get-Date
    $tStart = Get-Date
    while ($true) {
        Start-Sleep -Seconds 10

        # 1) job finished?
        if ($installJob.State -eq 'Completed') { $installSuccess = Receive-Job $installJob; break }
        if ($installJob.State -ne 'Running') { break }

        # 2) version flipped = success signal
        $v = (Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue).Version
        if ($v -and $v -ne $script:CurrentDesktop) {
            $lastActivity = Get-Date
            if ($v -eq $Version) { $installSuccess = $true; break }
        }

        # 3) deployment log producing new milestones?
        $latestEntry = Get-AppxLog -All -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty TimeCreated
        if ($latestEntry -and $latestEntry -gt $lastActivity) { $lastActivity = $latestEntry }

        # 4) wedged? (still running but idle for 60s)
        $idleSec = [math]::Round(((Get-Date) - $lastActivity).TotalSeconds, 0)
        if ($idleSec -gt 60) {
            Write-Host "`n  HANG DETECTED: install alive but idle $idleSec s (no deployment-log/version movement)" -ForegroundColor Red
            Write-Host "  => deployment queue wedge (AppXSvc). Killing hung install." -ForegroundColor Red
            Write-Host "  Symptoms: op stuck 'Queued'/0 CPU; Restart-Service AppXSvc refused; taskkill Access Denied (EDR)." -ForegroundColor Yellow
            Write-Host "  RECOVERY: reboot, then re-run this script - a fresh boot clears the queue (proven 2026-09-05)." -ForegroundColor Yellow
            Stop-Job $installJob -ErrorAction SilentlyContinue
            break
        }
        if ($idleSec -ge 30) {
            Write-Host "  install: no activity for $idleSec s..." -ForegroundColor Yellow
        }

        # hard safety cap (only if something produces logs forever without finishing)
        if (((Get-Date) - $tStart).TotalMinutes -gt 20) {
            Write-Host "  ERROR: install exceeded 20 min despite activity - aborting" -ForegroundColor Red
            Stop-Job $installJob -ErrorAction SilentlyContinue
            break
        }
    }
    Remove-Job $installJob -Force -ErrorAction SilentlyContinue

    if ($installSuccess) {
        if ($msixPath -eq $targetMsix) { Remove-Item $msixPath -Force -ErrorAction SilentlyContinue }

        $newApp = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue
        if ($newApp) {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "  DESKTOP UPDATE SUCCESSFUL!" -ForegroundColor Green
            Write-Host "  $($script:CurrentDesktop) -> $($newApp.Version)" -ForegroundColor Green
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "  Launch from Start Menu -> Codex" -ForegroundColor Gray
            return $true
        } else {
            Write-Host "  WARNING: Install completed but cannot verify version" -ForegroundColor Yellow
            return $true
        }
    } else {
        Write-Host "  MSIX kept at: $msixPath" -ForegroundColor Gray
        Write-Host "  Manual install: Add-AppxPackage -Path '$msixPath' -ForceApplicationShutdown" -ForegroundColor Gray
        return $false
    }
}

# =============================================================================
# MAIN
# =============================================================================
Write-Host "`n========================================" -ForegroundColor Magenta
Write-Host "  CODEX UPDATE TOOL" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

Setup-Proxy

# Pre-flight connectivity check
$connectivityOk = Test-Connectivity
if (-not $connectivityOk -and -not $CheckOnly) {
    Write-Host "`nABORTING: Network connectivity issues. Fix and re-run." -ForegroundColor Red
    exit 1
}

if ($CheckOnly) {
    Get-CurrentVersions
    Get-LatestVersions
    exit 0
}

# Always show versions first
Get-CurrentVersions
Get-LatestVersions

# Determine what to update
$doDesktop = -not $CliOnly
$doCli = -not $DesktopOnly

if (-not $script:LatestDesktop -and -not $script:LatestCli) {
    Write-Host "`nERROR: Cannot fetch latest versions. Check proxy/network." -ForegroundColor Red
    exit 1
}

# Desktop
if ($doDesktop -and $script:LatestDesktop) {
    if ($script:CurrentDesktop -eq $script:LatestDesktop) {
        Write-Host "`nDesktop: Already up to date ($($script:CurrentDesktop))" -ForegroundColor Green
    } else {
        $success = Update-CodexDesktop -Version $script:LatestDesktop -DownloadUrl $script:DesktopDownloadUrl
        if (-not $success) {
            Write-Host "`nDesktop update FAILED. See errors above." -ForegroundColor Red
        }
    }
}

# CLI
if ($doCli -and $script:LatestCli) {
    if ($script:CurrentCli -eq $script:LatestCli) {
        Write-Host "`nCLI: Already up to date ($($script:CurrentCli))" -ForegroundColor Green
    } else {
        $success = Update-CodexCli -Version $script:LatestCli -RegistryUrl $Registry
        if (-not $success) {
            Write-Host "`nCLI update FAILED. See errors above." -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "  FINISHED" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
