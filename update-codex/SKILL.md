---
name: update-codex
description: Update OpenAI Codex (Desktop and/or CLI) to the latest version. Use this skill whenever the user mentions updating, upgrading, or checking for new versions of Codex, Codex Desktop, Codex CLI, or OpenAI Codex. Also trigger when the user says their Codex is old, wants the newest Codex features, or asks "what version of Codex am I on?"
---

# Update Codex

Updates OpenAI Codex Desktop and CLI on Windows to the latest version — fully automated, behind the corporate proxy.

## Quick start

```bash
# Check versions only (no install)
powershell -ExecutionPolicy Bypass -File "scripts/update_all.ps1" -CheckOnly

# Update everything
powershell -ExecutionPolicy Bypass -File "scripts/update_all.ps1"

# Update CLI only
powershell -ExecutionPolicy Bypass -File "scripts/update_all.ps1" -CliOnly

# Update Desktop only
powershell -ExecutionPolicy Bypass -File "scripts/update_all.ps1" -DesktopOnly
```

## Architecture

### CLI update: Two-tier merge approach

The npm mirror (`registry.npmmirror.com`) has a **known issue**: the platform-specific binary tarball (`@openai/codex@<version>-win32-x64`, ~400 MB unpacked) is frequently corrupted on the mirror (TAR_BAD_ARCHIVE, checksum failures, missing vendor/). This causes npm to silently skip the optional dependency when installing `@openai/codex`. The official npm registry (`registry.npmjs.org`) has a valid tarball but may be slower through the corporate proxy.

The workaround — installing the platform package directly — overwrites `bin/codex.js` because both packages share the same npm name.

**The merge approach** (two-tier: mirror for JS, official for binary):

1. Install `@openai/codex@<version>` from **mirror** → gets `bin/codex.js` (entry point), no vendor/
2. **Backup** `bin/codex.js`
3. Install `@openai/codex@<version>-win32-x64` from **official registry** → gets `vendor/` (~325 MB binary), overwrites `bin/`
4. **Restore** `bin/codex.js`
5. Copy merged result to global npm
6. Create bin links (`codex.cmd`, `codex.ps1`)

This works because the `codex.js` fallback path (`path.join(__dirname, "..", "vendor")`) resolves to `codex/vendor/` — exactly where the platform binary lands.

**Fallback**: If the official registry also fails, reuse the vendor/ directory from the current global install and only update the JS wrapper. The binary (Rust engine) rarely changes between patch versions.

### Desktop update: Adaptive download + verified install

The corporate proxy throttles large GitHub downloads **per TCP connection** (~45 KB/s each) and frequently resets connections. Measured 2026-09-05: a single BITS stream sustained ~2.6 MB/min → 760 MB would take **~5 hours**. `Invoke-WebRequest` doesn't support resume at all.

**Strategy 1 — BITS with 10s rate watchdog** (default):
- BITS is reliable when the proxy is healthy (historically 25–70 MB/min → 10–30 min).
- The script samples the transfer **every 10 s**: sustained average < 10 MB/min (after ~30 s) OR 30 s of zero growth → BITS is aborted and it switches to Strategy 2. A healthy stream that then stalls >60 s → also switches. Decisions happen in seconds, never minutes.

**Strategy 2 — Verified parallel ranged download** (`download_msix_verified.ps1`, v2):
- The proxy throttles per connection, so N parallel ranged connections multiply throughput (~16× → ~30 min for 760 MB).
- 16 slice jobs download concurrently, each resuming from its part's current size.
- **No silent stalls anywhere** (rationale: the proxy's measured floor is ~45 KB/s per LIVE connection — any sustained zero-byte window means the connection is dead, not slow): URL re-resolution is capped at 15 s per attempt (expiry can't deadlock); in-transfer dead links abort within ≤10 s via curl `--speed-limit 1024 --speed-time 10` (a 60 s max-time only bounds healthy-but-throttled streams, deliberately reconnecting to harvest a fresh burst token); a root monitor polls every 10 s, prints MB/MB-per-min, and if TOTAL size is unchanged for 30 s it kills and respawns the slice pool immediately (parts are kept).
- **CRITICAL**: proxy resets can splice garbage (error-page bodies) into a resumed range — a size-only check PASSES while content is corrupt (`Add-AppxPackage` then fails `0x80080206 APPX_E_CORRUPT_CONTENT`, as happened 2026-09-05). The downloader therefore ALWAYS verifies the assembled file's SHA-256 against the official hash (from `SHA256SUMS-windows.txt`, falling back to the Microsoft catalog hash in `release-manifest.json`) and retries up to 3 rounds on mismatch.
- GitHub's API `size` field for release assets is unreliable — real size is resolved from the server's `Content-Range`.

**Install — 10s liveness watchdog**: `Add-AppxPackage -ForceApplicationShutdown` runs in a job while the parent polls **every 10 s** for signs of life: deployment-log milestones (`Get-AppxLog`), version flip, job completion. Wedged deployments show ZERO of these; if the install is still running but idle for **60 s → declared hung immediately** (warning printed at 30 s), the job is killed and recovery guidance printed (a wedged queue otherwise hangs forever). A 20-min hard cap is a last-resort safety net only.

### Failure modes learned the hard way (2026-09-05)

- **`0x80080206` (corrupt content)**: downloaded file is bad despite correct size → hash-gate before install; never trust byte counts.
- **Wedged AppXSvc deployment queue**: install hangs forever at "Queued" with 0 CPU; `Restart-Service AppXSvc` reports it cannot stop the service; `taskkill` on its svchost returns Access Denied when the corporate EDR protects it. **Recovery: reboot, then re-run** — a fresh boot clears the queue (worked 2026-09-05: 760 MB installed in 50 s after reboot). Don't burn hours fighting it.
- **User-provided MSIX**: if the user already downloaded the package (`-MsixPath D:\...\file.msix`), its version is read from `AppxManifest.xml` (no install needed) and used directly when it matches the target version. This is often the fastest path — the deployment engine itself validates content on install.

## Critical rules for the agent

1. **NEVER run PowerShell inline with Bash** — Bash mangles PowerShell escaping (here-strings, regex, `$env:`, `$_`). Always use `-File` pointing to a `.ps1` script.
2. **Don't kill npm prematurely** — npm downloads/extracts large tarballs with no progress output. A CLI install can take 5–10 minutes through the proxy. The only way to know it's working is to wait or check file creation.
3. **Start Desktop download EARLY and in parallel with the CLI** — kick Desktop off first, then run the CLI while it downloads.
4. **Never trust a proxy download's byte count** — verify the final file against the official SHA-256 before installing. Parallel ranged downloads are fine (see Desktop section); what killed us was missing content verification.
5. **Platform binary MUST come from official registry** — `registry.npmmirror.com` has a corrupt `@openai/codex@<version>-win32-x64` tarball (missing vendor/). Always use `registry.npmjs.org` for this step. The mirror is fine for the main JS package.
6. **Desktop force-shutdown as fallback** — If `Get-Process -Name "Codex"` finds nothing but `Add-AppxPackage` still fails with 0x80073D02 (app in use), use `Add-AppxPackage -ForceApplicationShutdown` which terminates background app components that aren't visible as separate processes.
7. **A wedged AppXSvc queue is a reboot problem, not a retry problem** — symptoms: "Queued" forever, 0 CPU in installer, `Restart-Service AppXSvc -Force` refused, `taskkill` Access Denied (EDR). Reboot once and re-run instead of retrying.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/update_all.ps1` | Master script: checks versions, updates CLI and/or Desktop |
| `scripts/download_msix_verified.ps1` | Verified parallel ranged downloader (16 slices, SHA-256 gate, retry rounds) |
| `scripts/check_version.ps1` | Quick version check only (legacy, kept for reference) |

### Parameters for `update_all.ps1`

| Parameter | Effect |
|-----------|--------|
| `-CheckOnly` | Show current vs latest versions, exit |
| `-CliOnly` | Only update CLI |
| `-DesktopOnly` | Only update Desktop |
| `-MsixPath <file>` | Install from an existing local MSIX instead of downloading (version-checked) |
| `-Registry <url>` | Override npm registry (default: `https://registry.npmmirror.com`) |

## What this skill covers

- **Codex Desktop** (Windows MSIX): checked via `Get-AppxPackage`, fetched from `Wangnov/codex-app-mirror` GitHub releases
- **Codex CLI** (npm `@openai/codex`): checked via `codex --version`, fetched from npm registry

## Proxy

Scripts read proxy credentials from the user env vars `HTTPS_PROXY` or `HTTP_PROXY`. The skill assumes:
```
HTTPS_PROXY=http://<eid>:<password>@proxysg.huawei.com:8080
```

If credentials aren't set, the scripts will warn but try to proceed (may fail on external network calls).

## Notes

- Desktop MSIX is ~695–760 MB — BITS 10–30 min when healthy; parallel download ~30 min under per-connection throttle (~5 h via BITS)
- CLI binary is ~400 MB unpacked — npm download + extraction takes 5–10 min
- Desktop updates don't affect `%USERPROFILE%\.codex` config
- The GitHub mirror probes the Microsoft Store every 15 min and publishes `release-manifest.json` + `SHA256SUMS-windows.txt` per release
- Version scheme: `26.YYMM.build` (e.g., 26.707 = July 7 week); MSIX build revisions within a day differ in the 3rd segment (e.g. 26.901.5003.0 vs 26.901.5280.0)
