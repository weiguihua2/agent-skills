# Quick BITS transfer status check
$transfers = Get-BitsTransfer -ErrorAction SilentlyContinue
if (-not $transfers) {
    Write-Host "No active BITS transfers"
    exit 0
}
foreach ($t in $transfers) {
    $pct = if ($t.BytesTotal -gt 0) { [math]::Round($t.BytesTransferred / $t.BytesTotal * 100, 1) } else { 0 }
    Write-Host ("{0}: {1}% ({2} / {3} MB)  State: {4}" -f $t.DisplayName, $pct, [math]::Round($t.BytesTransferred/1MB,1), [math]::Round($t.BytesTotal/1MB,1), $t.JobState)
}
