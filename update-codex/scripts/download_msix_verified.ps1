# =============================================================================
# Verified Parallel MSIX Downloader  (v2.1 - sub-minute stall detection)
# -----------------------------------------------------------------------------
# WHY THIS EXISTS (learned the hard way, 2026-09-05):
#   The corporate proxy throttles GitHub per TCP CONNECTION (~45 KB/s each) and
#   resets connections mid-transfer. BITS uses ~1 effective stream -> 760 MB at
#   45 KB/s = ~5 HOURS. N parallel ranged connections multiply throughput
#   (~16x = ~30 min).
#
#   CRITICAL: proxy resets can inject garbage (error-page bodies) into a
#   resumed range. A size-only check PASSES while content is corrupt ->
#   Add-AppxPackage then fails 0x80080206 (APPX_E_CORRUPT_CONTENT).
#   => This downloader ALWAYS gates the assembled file on the official
#      SHA-256 (from release-manifest.json) and retries rounds on mismatch.
#
#   v2.1 responsiveness (user feedback: sub-minute detection is mandatory)
#     - the proxy has a measured floor of ~45 KB/s per LIVE connection, so any
#       sustained zero-byte window means the connection is DEAD, not slow
#     - URL re-resolution capped at 15s (was: no timeout -> could hang forever)
#     - in-transfer dead links abort in <=10s via curl --speed-limit 1024
#       --speed-time 10; the 60s max-time only bounds healthy-but-throttled
#       streams (deliberate reconnect = fresh burst token)
#     - root monitor polls every 10s; TOTAL size unchanged for 30s -> slice
#       pool killed + respawned immediately (parts kept)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File download_msix_verified.ps1 `
#     -DownloadUrl <github release asset url> -OutputPath <file> `
#     -ExpectedSha256Hex <64 hex chars> `
#     [-ExpectedSize 0] [-Proxy <http://user:pass@host:port>] [-Slices 16]
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$DownloadUrl,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [long]$ExpectedSize = 0,           # 0 = resolve from server Content-Range
    [Parameter(Mandatory = $true)][string]$ExpectedSha256Hex,
    [string]$Proxy = "",
    [int]$Slices = 16,
    [int]$MaxRounds = 3
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ($Proxy) {
    $env:HTTPS_PROXY = $Proxy
    $env:HTTP_PROXY = $Proxy
    $env:NODE_TLS_REJECT_UNAUTHORIZED = "0"
}
$curl = "$env:SystemRoot\System32\curl.exe"

$dir = Split-Path $OutputPath -Parent
$partsDir = Join-Path $dir "parts"
New-Item -ItemType Directory -Path $partsDir -Force | Out-Null

# --- Resolve final URL + real size (fresh each call; URLs expire) ---
function Get-FinalUrl {
    param([string]$Url)
    $u = (& $curl -s -o NUL -w "%{url_effective}" -L -k --connect-timeout 8 --max-time 15 -r 0-0 $Url)
    return $u
}
function Get-RemoteSize {
    param([string]$FinalUrl)
    $headers = (& $curl -s -k -L --connect-timeout 8 --max-time 15 -r 0-0 -D - -o NUL $FinalUrl)
    # NB: curl -D - output is an ARRAY; array -match is a FILTER and does NOT
    # populate $Matches in PS5.1 -> must match per-line (scalar) instead.
    foreach ($h in $headers) {
        if ($h -match 'content-range:\s*bytes\s+0-0/(\d+)') { return [long]$Matches[1] }
    }
    return 0
}

$finalUrl = Get-FinalUrl -Url $DownloadUrl
if (-not $finalUrl) { Write-Host "FATAL: cannot resolve final URL" -ForegroundColor Red; exit 1 }
Write-Host "Final URL host: $([Uri]$finalUrl | ForEach-Object { $_.Host })" -ForegroundColor Gray

if ($ExpectedSize -le 0) {
    $ExpectedSize = Get-RemoteSize -FinalUrl $finalUrl
    if ($ExpectedSize -le 0) { Write-Host "FATAL: cannot resolve file size" -ForegroundColor Red; exit 1 }
    Write-Host "Resolved size from server: $ExpectedSize bytes" -ForegroundColor Gray
}
$sliceBytes = [math]::Ceiling($ExpectedSize / $Slices)

# --- One slice job: self-contained, URL re-resolved every attempt ---
#   Each curl capped at 60s; on reset/expiry the loop immediately retries from
#   the part's current size. Never redirects native output (PS5.1 text-encodes!).
$sliceJobScript = {
    param($partPath, $partStart, $partEnd, $url, $curl)
    $expect = $partEnd - $partStart + 1
    $attempts = 0
    while ($true) {
        $cur = 0
        if (Test-Path $partPath) { $cur = (Get-Item $partPath).Length }
        if ($cur -ge $expect) { return 0 }
        if ($attempts -gt 500) { Write-Output "SLICE-FAILED attempts=$attempts"; return 1 }
        $attempts++
        # fresh signed URL each attempt -> expiry can never deadlock a slice
        $u = (& $curl -s -o NUL -w "%{url_effective}" -L -k --connect-timeout 8 --max-time 15 -r 0-0 $url)
        if (-not $u) { Start-Sleep -Seconds 1; continue }
        $tmp = "$partPath.tmp"
        # speed-limit/time: zero bytes for 10s => connection is dead, abort now.
        # max-time 60 only bounds healthy-but-throttled streams (burst harvest).
        & $curl -s -L -k --connect-timeout 8 --max-time 60 --speed-limit 1024 --speed-time 10 -r "$($partStart + $cur)-$partEnd" -o $tmp $u
        if (Test-Path $tmp) {
            $tmpLen = (Get-Item $tmp).Length
            if ($tmpLen -gt 0) {
                $fs = [System.IO.File]::Open($partPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
                try {
                    $in = [System.IO.File]::OpenRead($tmp)
                    try { $in.CopyTo($fs) } finally { $in.Dispose() }
                } finally { $fs.Dispose() }
            }
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 1
    }
}

# --- Round loop: download -> assemble -> SHA-256 gate ---
$round = 0
while ($round -lt $MaxRounds) {
    $round++
    Write-Host "`n=== Download round $round/$MaxRounds ===" -ForegroundColor Cyan
    Get-ChildItem $partsDir -Filter "part.*" -ErrorAction SilentlyContinue | Remove-Item -Force

    $jobs = @()
    $lastTotal = -1
    $stallPolls = 0
    $startWatch = Get-Date

    # Managed pool: fill missing slices, watch for stalls every 10s
    while ($true) {
        # 1) prune dead jobs, start replacements for incomplete slices
        $live = @()
        foreach ($j in $jobs) {
            if ($j.State -eq 'Running') { $live += $j }
            elseif ($j.State -eq 'Completed') {
                $rc = $j.ChildJobs[0].JobStateInfo.Reason  # not meaningful; ignore
            } else { Remove-Job $j -Force -ErrorAction SilentlyContinue }
        }
        $jobs = $live
        for ($i = 0; $i -lt $Slices; $i++) {
            $start = $i * $sliceBytes
            $end = [math]::Min($start + $sliceBytes - 1, $ExpectedSize - 1)
            if ($start -ge $ExpectedSize) { break }
            $partPath = Join-Path $partsDir "part.$i"
            $have = if (Test-Path $partPath) { (Get-Item $partPath).Length } else { 0 }
            $need = $end - $start + 1
            if ($have -lt $need) {
                $busy = $false
                foreach ($j in $jobs) { if ($j.Name -eq "slice$i") { $busy = $true; break } }
                if (-not $busy) {
                    $jobs += Start-Job -Name "slice$i" -ScriptBlock $sliceJobScript `
                        -ArgumentList $partPath, $start, $end, $DownloadUrl, $curl
                }
            }
        }
        # 2) completion check
        #    (Measure-Object over an empty dir yields $null -> normalize to 0)
        $totalSum = Get-ChildItem $partsDir -Filter "part.*" -ErrorAction SilentlyContinue | Measure-Object Length -Sum
        $total = if ($null -eq $totalSum.Sum) { 0 } else { [long]$totalSum.Sum }
        $allComplete = $true
        for ($i = 0; $i -lt $Slices; $i++) {
            $p = Join-Path $partsDir "part.$i"
            if (Test-Path $p) {
                $len = (Get-Item $p).Length
                $end = [math]::Min($i * $sliceBytes + $sliceBytes - 1, $ExpectedSize - 1)
                if ($len -lt ($end - $i * $sliceBytes + 1)) { $allComplete = $false; break }
            } else { $allComplete = $false; break }
        }
        if ($allComplete) { break }
        # 3) progress report + stall detection (every ~10s)
        Start-Sleep -Seconds 10
        $elapsed = [math]::Max(0.1, ((Get-Date) - $startWatch).TotalMinutes)
        $mbmin = [math]::Round((($total - $lastTotal) / 1MB) * 6, 1)  # last 10s window
        $pct = [math]::Round(100 * $total / $ExpectedSize, 1)
        Write-Host ("  [{0,5:N1}%] {1,7:N1} MB  last10s: {2,6:N1} MB/min  jobs: {3}" -f $pct, ($total/1MB), $mbmin, $jobs.Count) -ForegroundColor Gray
        if ($total -eq $lastTotal) {
            $stallPolls++
            if ($stallPolls -ge 3) {   # 30s with zero growth -> kill & respawn all
                Write-Host "  STALL DETECTED (no progress for 30s) - restarting slice pool" -ForegroundColor Yellow
                foreach ($j in $jobs) { Stop-Job $j -ErrorAction SilentlyContinue; Remove-Job $j -Force -ErrorAction SilentlyContinue }
                $jobs = @()
                $stallPolls = 0
                $lastTotal = -1
                continue
            }
        } else {
            $stallPolls = 0
        }
        $lastTotal = $total
    }

    # per-slice final check
    $badSlices = 0
    foreach ($j in $jobs) {
        if ($j.State -eq 'Completed') {
            $out = Receive-Job $j
            if ($out -match 'SLICE-FAILED') { $badSlices++ }
        }
        Remove-Job $j -Force -ErrorAction SilentlyContinue
    }

    $totalSum = Get-ChildItem $partsDir -Filter "part.*" -ErrorAction SilentlyContinue | Measure-Object Length -Sum
    $total = if ($null -eq $totalSum.Sum) { 0 } else { [long]$totalSum.Sum }
    $mins = [math]::Round(((Get-Date) - $startWatch).TotalMinutes, 1)
    Write-Host "Round $round took $mins min, total = $total / $ExpectedSize" -ForegroundColor Gray
    if ($badSlices -gt 0 -or $total -ne $ExpectedSize) {
        Write-Host "Slices incomplete - retrying round..." -ForegroundColor Yellow
        continue
    }

    # --- Assemble (binary-safe) ---
    Write-Host "Assembling $OutputPath ..." -ForegroundColor Yellow
    $fs = [System.IO.File]::Create($OutputPath)
    try {
        for ($i = 0; $i -lt $Slices; $i++) {
            $p = Join-Path $partsDir "part.$i"
            if (-not (Test-Path $p)) { continue }
            $in = [System.IO.File]::OpenRead($p)
            try { $in.CopyTo($fs) } finally { $in.Dispose() }
        }
    } finally { $fs.Dispose() }

    # --- SHA-256 gate ---
    $actual = (Get-FileHash -Path $OutputPath -Algorithm SHA256).Hash.ToLower()
    if ($actual -eq $ExpectedSha256Hex.ToLower()) {
        Write-Host "SHA-256 VERIFIED ($actual)" -ForegroundColor Green
        Get-ChildItem $partsDir -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        exit 0
    }
    Write-Host "SHA-256 MISMATCH - proxy injected corrupt data; wiping and retrying" -ForegroundColor Yellow
    Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
}

Write-Host "FATAL: download corrupt after $MaxRounds rounds" -ForegroundColor Red
exit 2
