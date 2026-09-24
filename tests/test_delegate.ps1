$ErrorActionPreference = 'Stop'
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcher = Join-Path (Split-Path -Parent $base) 'scripts\Invoke-Delegate.ps1'
$fake = Join-Path $base 'fakebin'
$env:PATH = "$fake;$env:PATH"
$testBase = Join-Path ([System.IO.Path]::GetTempPath()) ('delegate-audit-offline-' + [guid]::NewGuid().ToString('n'))
$root = Join-Path $testBase 'source'
New-Item -ItemType Directory -Path $root -Force | Out-Null
@'
This is a distinctive project line used for offline proof checking.
This second distinctive project line must not pass another challenge.
'@ | Set-Content -LiteralPath (Join-Path $root 'README.md') -Encoding UTF8
$task = Join-Path $testBase 'task.txt'
'Read the project and report the result.' | Set-Content -LiteralPath $task -Encoding UTF8
& git -C $root init -q
if ($LASTEXITCODE -ne 0) { throw 'git init failed' }

function Invoke-Fixture([string]$mode) {
    $run = Join-Path $testBase ('run-' + $mode)
    $env:FAKE_PROOF = $mode
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    & pwsh -NoProfile -NonInteractive -File $launcher -Provider grok -TaskRoot $root -TaskFile $task -RunDirectory $run -ProbeFile README.md -TimeoutSeconds 30 2>$null | Out-Null
    $watch.Stop()
    $result = Get-Content -LiteralPath (Join-Path $run 'status.json') -Raw | ConvertFrom-Json
    return [pscustomobject]@{ status = $result.status; outcome = $result.outcome; proof = $result.read_proof_kind; changed_check = $result.result_contract.changed_files_check; elapsed = [Math]::Round($watch.Elapsed.TotalSeconds, 1) }
}

$wrong = Invoke-Fixture 'wrong'
if ($wrong.status -ne 'unverified') { throw "Wrong challenge passed: $($wrong | ConvertTo-Json -Compress)" }
$right = Invoke-Fixture 'right'
if ($right.status -ne 'verified_project_access' -or $right.outcome -ne 'valid_report' -or
    $right.proof -ne 'challenge_exact' -or $right.changed_check -ne 'unborn_git_tree_compared') {
    throw "Correct challenge failed: $($right | ConvertTo-Json -Compress)"
}
$linger = Invoke-Fixture 'linger'
if ($linger.status -notin @('verified_project_access', 'timed_out') -or $linger.elapsed -gt 11) {
    throw "Pipe timeout failed: $($linger | ConvertTo-Json -Compress)"
}

$relativeRun = Join-Path $testBase 'run-relative'
& pwsh -NoProfile -NonInteractive -File $launcher -Provider grok -TaskRoot . -TaskFile $task -RunDirectory $relativeRun -TimeoutSeconds 30 2>$null | Out-Null
if ($LASTEXITCODE -eq 0 -or (Test-Path -LiteralPath $relativeRun)) { throw 'Relative taskRoot was accepted' }
$insideRun = Join-Path $root '.delegate-run'
& pwsh -NoProfile -NonInteractive -File $launcher -Provider grok -TaskRoot $root -TaskFile $task -RunDirectory $insideRun -TimeoutSeconds 30 2>$null | Out-Null
if ($LASTEXITCODE -eq 0 -or (Test-Path -LiteralPath $insideRun)) { throw 'Run directory inside source was accepted' }
$secretProbe = Join-Path $root '.env-local'
'SENSITIVE_SENTINEL=ThisValueMustNeverBecomeTheReadProof.' | Set-Content -LiteralPath $secretProbe -Encoding UTF8
$secretRun = Join-Path $testBase 'run-secret'
& pwsh -NoProfile -NonInteractive -File $launcher -Provider deepseek -TaskRoot $root -TaskFile $task -RunDirectory $secretRun -ProbeFile .env-local -TimeoutSeconds 30 2>$null | Out-Null
$secretStatus = Get-Content -LiteralPath (Join-Path $secretRun 'status.json') -Raw | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -or $secretStatus.error_message -notmatch 'hassas dosya filtresine') { throw 'Sensitive probe passed preflight' }

$fallback = Join-Path $testBase 'fallback'
New-Item -ItemType Directory -Path $fallback | Out-Null
'short' | Set-Content -LiteralPath (Join-Path $fallback 'README.md') -Encoding UTF8
'{"description":"This project has a sufficiently descriptive line for read proof selection."}' | Set-Content -LiteralPath (Join-Path $fallback 'package.json') -Encoding UTF8
$env:FAKE_PROOF = 'right'
$fallbackRun = Join-Path $testBase 'run-fallback'
& pwsh -NoProfile -NonInteractive -File $launcher -Provider grok -TaskRoot $fallback -TaskFile $task -RunDirectory $fallbackRun -TimeoutSeconds 30 2>$null | Out-Null
$fallbackStatus = Get-Content -LiteralPath (Join-Path $fallbackRun 'status.json') -Raw | ConvertFrom-Json
if ($fallbackStatus.probe_file -ne 'package.json' -or $fallbackStatus.outcome -ne 'valid_report' -or
    $fallbackStatus.changed_files_scope -ne 'all_files_non_git') {
    throw "Probe fallback failed: $($fallbackStatus | ConvertTo-Json -Compress)"
}

$commitRoot = Join-Path $testBase 'unborn-commit'
New-Item -ItemType Directory -Path $commitRoot | Out-Null
'This is a sufficiently descriptive line for a worker commit proof.' | Set-Content -LiteralPath (Join-Path $commitRoot 'README.md') -Encoding UTF8
& git -C $commitRoot init -q
$env:FAKE_PROOF = 'commit'
$commitRun = Join-Path $testBase 'run-commit'
& pwsh -NoProfile -NonInteractive -File $launcher -Provider grok -TaskRoot $commitRoot -TaskFile $task -RunDirectory $commitRun -ProbeFile README.md -TimeoutSeconds 30 2>$null | Out-Null
$commitStatus = Get-Content -LiteralPath (Join-Path $commitRun 'status.json') -Raw | ConvertFrom-Json
if ($commitStatus.outcome -ne 'valid_report' -or $commitStatus.result_contract.changed_files_check -ne 'head_changed_compared' -or
    'README.md' -notin @($commitStatus.changed_since_start)) {
    throw "Unborn Git first commit failed: $($commitStatus | ConvertTo-Json -Compress)"
}

function Invoke-TwoCommitFixture([string]$mode) {
    $twoRoot = Join-Path $testBase ('unborn-' + $mode)
    New-Item -ItemType Directory -Path $twoRoot | Out-Null
    'This is a sufficiently descriptive line for a two commit proof.' | Set-Content -LiteralPath (Join-Path $twoRoot 'README.md') -Encoding UTF8
    & git -C $twoRoot init -q
    $env:FAKE_PROOF = $mode
    $run = Join-Path $testBase ('run-' + $mode)
    & pwsh -NoProfile -NonInteractive -File $launcher -Provider grok -TaskRoot $twoRoot -TaskFile $task -RunDirectory $run -ProbeFile README.md -TimeoutSeconds 30 2>$null | Out-Null
    return (Get-Content -LiteralPath (Join-Path $run 'status.json') -Raw | ConvertFrom-Json)
}
$both = Invoke-TwoCommitFixture 'two-commits'
$lastOnly = Invoke-TwoCommitFixture 'two-commits-last-only'
if ($both.outcome -ne 'valid_report' -or
    (@($both.changed_since_start | Sort-Object) -join ',') -ne 'first.txt,second.txt' -or
    $lastOnly.outcome -ne 'invalid_result_contract') {
    throw "Two-commit comparison failed: both=$($both.outcome), last=$($lastOnly.outcome)"
}

Write-Output ([ordered]@{
    wrong_proof = $wrong.status
    exact_proof = $right.status
    unborn_git = $right.changed_check
    pipe_timeout_seconds = $linger.elapsed
    relative_root_rejected = $true
    inside_run_rejected = $true
    sensitive_probe_rejected = $true
    fallback_probe = $fallbackStatus.probe_file
    non_git_scope = $fallbackStatus.changed_files_scope
    first_commit = $commitStatus.outcome
    two_commits = $both.outcome
    last_only = $lastOnly.outcome
} | ConvertTo-Json -Compress)
