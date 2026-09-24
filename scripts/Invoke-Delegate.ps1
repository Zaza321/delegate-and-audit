#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('codex', 'grok', 'agy', 'deepseek')][string]$Provider,
    [Parameter(Mandatory)][string]$TaskRoot,
    [Parameter(Mandatory)][string]$TaskFile,
    [string]$RunDirectory,
    [string]$ProbeFile,
    [string]$Model,
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')][string]$CodexReasoningEffort = 'high',
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')][string]$GrokReasoningEffort = 'xhigh',
    [ValidateSet('low', 'medium', 'high')][string]$AgyReasoningEffort,
    [ValidateSet('context', 'read-tools')][string]$DeepSeekAccess = 'context',
    [switch]$DeepSeekIncludeSensitive,
    [switch]$DeepSeekIncludeIgnored,
    [ValidateSet('none', 'low', 'high', 'max')][string]$DeepSeekReasoningEffort = 'high',
    [ValidateSet('read-only', 'workspace-write', 'danger-full-access')][string]$CodexSandbox,
    [ValidateRange(30, 7200)][int]$TimeoutSeconds = 900,
    [switch]$AllowMissingResultContract,
    [switch]$SharedRootParallel,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $OutputEncoding
if ($Provider -eq 'grok' -and -not $PSBoundParameters.ContainsKey('TimeoutSeconds')) {
    $TimeoutSeconds = 2700
}
$utf8 = [System.Text.UTF8Encoding]::new($false)
$sensitivePolicy = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'sensitive-paths.json') -Raw | ConvertFrom-Json
if ($IsWindows) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DelegateProcessJob {
    [StructLayout(LayoutKind.Sequential)]
    public struct BasicLimits {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct IoCounters {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct ExtendedLimits {
        public BasicLimits BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr handle);
    public static IntPtr CreateKillOnClose() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) return IntPtr.Zero;
        ExtendedLimits info = new ExtendedLimits();
        info.BasicLimitInformation.LimitFlags = 0x2000;
        if (!SetInformationJobObject(job, 9, ref info, (uint)Marshal.SizeOf<ExtendedLimits>())) {
            CloseHandle(job);
            return IntPtr.Zero;
        }
        return job;
    }
    public static bool Attach(IntPtr job, IntPtr process) {
        return AssignProcessToJobObject(job, process);
    }
    public static void Close(IntPtr job) {
        if (job != IntPtr.Zero) CloseHandle(job);
    }
}
'@
}
$runId = [guid]::NewGuid().ToString('n')
$status = [ordered]@{
    run_id = $runId
    provider = $Provider
    timeout_seconds = $TimeoutSeconds
    requested_model = $null
    observed_model = $null
    task_root = $null
    git_root = $null
    start_head = $null
    end_head = $null
    initial_dirty_paths = @()
    changed_files_scope = 'git_visible_only'
    probe_file = $null
    probe_line = $null
    read_proof = $false
    proof_at_start = $false
    context_proof = $false
    read_proof_kind = $null
    reported_line = $null
    matched_line = $null
    citation_line_accurate = $null
    exit_code = $null
    final_available = $false
    final_worktree_status = @()
    result_contract = $null
    worker_reported_completed = $false
    outcome = 'preflight'
    status = 'preflight'
    error_type = $null
    error_message = $null
    run_directory = $null
    started_at = (Get-Date).ToUniversalTime().ToString('o')
    finished_at = $null
}

if ([string]::IsNullOrWhiteSpace($RunDirectory)) {
    $RunDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "delegate-$runId"
}
if (-not [System.IO.Path]::IsPathFullyQualified($TaskRoot)) { throw "Proje yolu mutlak değil: $TaskRoot" }
$preflightRoot = (Resolve-Path -LiteralPath $TaskRoot -ErrorAction Stop).ProviderPath
$runFull = [System.IO.Path]::GetFullPath($RunDirectory)
$runRelative = [System.IO.Path]::GetRelativePath($preflightRoot, $runFull)
if ($runRelative -eq '.' -or (-not $runRelative.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar) -and $runRelative -ne '..' -and -not [System.IO.Path]::IsPathRooted($runRelative))) {
    throw "Sonuç klasörü proje dışında olmalı: $runFull"
}
if (Test-Path -LiteralPath $runFull) {
    if (@(Get-ChildItem -LiteralPath $runFull -Force).Count -gt 0) {
        throw "Sonuç klasörü boş olmalı: $runFull"
    }
} else {
    [void](New-Item -ItemType Directory -Path $runFull -Force)
}
$status.run_directory = $runFull
$statusPath = Join-Path $runFull 'status.json'

function Save-Status {
    $status.finished_at = if ($status.status -eq 'running') { $null } else { (Get-Date).ToUniversalTime().ToString('o') }
    [System.IO.File]::WriteAllText($statusPath, ($status | ConvertTo-Json -Depth 8), $utf8)
}

function Test-SensitivePath([string]$relative) {
    $parts = @($relative.Replace('\', '/').Split('/') | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    if ($parts.Count -eq 0) { return $false }
    $name = $parts[-1]
    foreach ($part in $parts) { if ($part -in $sensitivePolicy.directories) { return $true } }
    if ($name -in $sensitivePolicy.names) { return $true }
    foreach ($prefix in $sensitivePolicy.prefixes) { if ($name.StartsWith($prefix)) { return $true } }
    foreach ($suffix in $sensitivePolicy.suffixes) { if ($name.EndsWith($suffix)) { return $true } }
    return ($name.StartsWith($sensitivePolicy.service_account_prefix) -and $name.EndsWith($sensitivePolicy.service_account_suffix))
}

function Invoke-PreflightCommand([string]$file, [string[]]$arguments, [string]$workingDirectory) {
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    if ($file.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        $start.FileName = Join-Path $PSHOME 'pwsh.exe'
        foreach ($prefix in @('-NoProfile', '-NonInteractive', '-File', $file)) {
            $start.ArgumentList.Add($prefix)
        }
    } else {
        $start.FileName = $file
    }
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $start.WorkingDirectory = $workingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    $process = [System.Diagnostics.Process]::new()
    $jobHandle = [IntPtr]::Zero
    $started = $false
    try {
        $process.StartInfo = $start
        if ($IsWindows) { $jobHandle = [DelegateProcessJob]::CreateKillOnClose() }
        if (-not $process.Start()) { throw "CLI ön kontrolü başlatılamadı: $file" }
        $started = $true
        if ($jobHandle -ne [IntPtr]::Zero -and -not [DelegateProcessJob]::Attach($jobHandle, $process.Handle)) {
            [DelegateProcessJob]::Close($jobHandle)
            $jobHandle = [IntPtr]::Zero
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) {
            $process.Kill($true)
            throw "CLI ön kontrolü 15 saniyede tamamlanmadı: $file"
        }
        if ($jobHandle -ne [IntPtr]::Zero) {
            [DelegateProcessJob]::Close($jobHandle)
            $jobHandle = [IntPtr]::Zero
        }
        if (-not [System.Threading.Tasks.Task]::WaitAll(
                [System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 5000)) {
            throw "CLI ön kontrolü çıktı borusu kapanmadı: $file"
        }
        $output = $stdoutTask.GetAwaiter().GetResult() + $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "CLI ön kontrolü başarısız ($($process.ExitCode)): $file $output" }
        return $output
    } finally {
        if ($jobHandle -ne [IntPtr]::Zero) { [DelegateProcessJob]::Close($jobHandle) }
        if ($started -and -not $process.HasExited) { $process.Kill($true) }
        $process.Dispose()
    }
}

function Get-WithinRootFile([string]$givenPath, [string]$root) {
    $full = if ([System.IO.Path]::IsPathRooted($givenPath)) {
        [System.IO.Path]::GetFullPath($givenPath)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $root $givenPath))
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Okuma kanıtı dosyası yok: $full" }
    $relative = [System.IO.Path]::GetRelativePath($root, $full)
    if ($relative -eq '..' -or $relative.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar) -or [System.IO.Path]::IsPathRooted($relative)) {
        throw "Okuma kanıtı dosyası proje dışında: $full"
    }
    $walk = $root
    if ((Get-Item -LiteralPath $walk -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Okuma kanıtı proje kökü bağlantı içeriyor: $walk"
    }
    foreach ($component in ($relative -split '[\\/]')) {
        $walk = Join-Path $walk $component
        if ((Get-Item -LiteralPath $walk -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Okuma kanıtı yolu bağlantı içeriyor: $walk"
        }
    }
    return @{ Full = $full; Relative = $relative }
}

function Test-RelativeReportPath([object]$value, [string]$root) {
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or [System.IO.Path]::IsPathRooted($value)) { return $false }
    try {
        $resolved = [System.IO.Path]::GetFullPath((Join-Path $root $value))
        $relative = [System.IO.Path]::GetRelativePath($root, $resolved)
        return ($relative -ne '.' -and $relative -ne '..' -and -not $relative.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar) -and -not [System.IO.Path]::IsPathRooted($relative))
    } catch { return $false }
}

function Get-ReportPathKey([string]$path) {
    $key = $path.Replace('\', '/')
    while ($key.StartsWith('./', [System.StringComparison]::Ordinal)) { $key = $key.Substring(2) }
    return $key.ToLowerInvariant()
}

function Get-NonGitFileStates([string]$root, [string]$excludeDirectory) {
    $states = @{}
    $excluded = [System.IO.Path]::GetFullPath($excludeDirectory).TrimEnd('\', '/')
    foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop) {
        $full = [System.IO.Path]::GetFullPath($item.FullName)
        if ($full.Equals($excluded, [System.StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($excluded + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative = [System.IO.Path]::GetRelativePath($root, $full).Replace('\', '/')
        if ($relative -match '(^|/)\.git(/|$)') { continue }
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            $state = 'LINK:' + [string]$item.LinkTarget
        } elseif ($item.PSIsContainer) { continue }
        else { $state = (Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash }
        $states[(Get-ReportPathKey $relative)] = [pscustomobject]@{ path = $relative; state = $state }
    }
    return $states
}

function Get-GitChangedPaths([string]$root) {
    $gitRoot = (& git -C $root rev-parse --show-toplevel 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $gitRoot) { throw 'Git kökü okunamadı.' }
    $prefix = [System.IO.Path]::GetRelativePath($gitRoot, $root).Replace('\', '/')
    if ($prefix -eq '.') { $prefix = '' } else { $prefix += '/' }
    $raw = & git -C $root -c status.relativePaths=true status --porcelain=v1 -z --untracked-files=all -- . 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Git son değişiklik yolları okunamadı.' }
    if (-not $raw) { return @() }
    $entries = ([string]$raw).Split([char]0)
    $paths = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $entries.Length; $i++) {
        $entry = $entries[$i]
        if (-not $entry) { continue }
        if ($entry.Length -lt 4 -or $entry[2] -ne ' ') { throw "Git status girdisi anlaşılamadı: $entry" }
        $reportedPath = $entry.Substring(3).Replace('\', '/')
        if ($prefix) {
            if (-not $reportedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Git yolu görev kökü dışında: $reportedPath" }
            $reportedPath = $reportedPath.Substring($prefix.Length)
        }
        $paths.Add($reportedPath)
        if ($entry.Substring(0, 2) -match '[RC]') {
            $i++
            if ($i -ge $entries.Length -or -not $entries[$i]) { throw 'Git yeniden adlandırma yolu eksik.' }
            $oldPath = $entries[$i].Replace('\', '/')
            if ($prefix) {
                if (-not $oldPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Git eski yolu görev kökü dışında: $oldPath" }
                $oldPath = $oldPath.Substring($prefix.Length)
            }
            $paths.Add($oldPath)
        }
    }
    return $paths.ToArray()
}

function Get-GitCommittedPaths([string]$root, [string]$startHead, [string]$endHead) {
    if (-not $endHead -or $startHead -eq $endHead) { return @() }
    $gitRoot = (& git -C $root rev-parse --show-toplevel 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $gitRoot) { throw 'Git kökü okunamadı.' }
    $prefix = [System.IO.Path]::GetRelativePath($gitRoot, $root).Replace('\', '/')
    if ($prefix -eq '.') { $prefix = '' } else { $prefix += '/' }
    $raw = if ($startHead) {
        & git -C $root diff --name-only --no-renames -z $startHead $endHead -- . 2>$null
    } else {
        & git -C $root ls-tree -r --name-only --full-name -z $endHead -- . 2>$null
    }
    if ($LASTEXITCODE -ne 0) { throw 'Git commit farkı okunamadı.' }
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in ([string]$raw).Split([char]0)) {
        if (-not $entry) { continue }
        $relative = $entry.Replace('\', '/')
        if ($prefix) {
            if (-not $relative.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Git commit yolu görev kökü dışında: $relative" }
            $relative = $relative.Substring($prefix.Length)
        }
        $paths.Add($relative)
    }
    return $paths.ToArray()
}

function Get-GitPathState([string]$root, [string]$relative) {
    $full = [System.IO.Path]::GetFullPath((Join-Path $root $relative))
    $within = [System.IO.Path]::GetRelativePath($root, $full)
    if ($within -eq '..' -or $within.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar) -or [System.IO.Path]::IsPathRooted($within)) {
        throw "Git yolu görev kökü dışında: $relative"
    }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    $working = if ($null -eq $item) { 'absent' }
        elseif ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { "link:$($item.LinkTarget)" }
        elseif ($item.PSIsContainer) { 'directory' }
        else { (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash }
    $index = [string](& git -C $root ls-files --stage -z -- $relative 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "Git index durumu okunamadı: $relative" }
    return "$working`n$index"
}

function Read-ResultContract([string]$finalText, [System.Collections.IDictionary]$expected, [string]$root, [object[]]$finalWorktreeStatus, [string]$endHead, [string]$requiredProbePath, [bool]$contextMode, [bool]$sharedRootParallel = $false) {
    $report = [ordered]@{ valid = $false; state = 'invalid'; errors = @(); worker_final_status = $null; reported_scope = $null; reported_files_read = @(); reported_changed_files = @(); reported_tests = @(); reported_evidence = @(); reported_blockers = @(); changed_files_check = 'not_available'; files_read_check = 'not_available' }
    $errors = [System.Collections.Generic.List[string]]::new()
    $blocks = [regex]::Matches($finalText, '(?s)DELEGATE_RESULT_JSON_BEGIN\s*(?:```(?:json)?\s*)?(?<json>\{.*?\})\s*(?:```)?\s*DELEGATE_RESULT_JSON_END')
    if ($blocks.Count -ne 1) {
        if ($blocks.Count -eq 0) { $report.state = 'missing' }
        $errors.Add("Beklenen tek sonuç JSON bloğu bulunmadı (sayı: $($blocks.Count)).")
        $report.errors = @($errors)
        return $report
    }
    try { $data = $blocks[0].Groups['json'].Value | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch {
        $errors.Add('Sonuç JSON bloğu ayrıştırılamadı.')
        $report.errors = @($errors)
        return $report
    }
    if ($data -isnot [System.Collections.IDictionary]) {
        $errors.Add('Sonuç JSON nesne olmalı.')
        $report.errors = @($errors)
        return $report
    }
    foreach ($name in @('task_id','task_root','git_root','start_head','initial_dirty_paths','scope','files_read','changed_files','tests','evidence','blockers','final_status')) {
        if (-not $data.Contains($name)) { $errors.Add("Eksik alan: $name") }
    }
    if ($errors.Count -gt 0) { $report.errors = @($errors); return $report }
    foreach ($name in @('task_id','task_root','scope','final_status')) {
        if ($data[$name] -isnot [string] -or [string]::IsNullOrWhiteSpace($data[$name])) { $errors.Add("Boş veya metin olmayan alan: $name") }
    }
    if ($data.task_id -cne $expected.task_id) { $errors.Add('task_id başlatıcı ile eşleşmiyor.') }
    if ($data.task_root -isnot [string] -or -not [string]::Equals($data.task_root, $expected.task_root, [System.StringComparison]::OrdinalIgnoreCase)) { $errors.Add('task_root başlatıcı ile eşleşmiyor.') }
    foreach ($name in @('git_root','start_head')) {
        if ($null -ne $data[$name] -and $data[$name] -isnot [string]) { $errors.Add("Metin veya null olmalı: $name") }
        if (-not [string]::Equals([string]$data[$name], [string]$expected[$name], [System.StringComparison]::OrdinalIgnoreCase)) { $errors.Add("$name başlatıcı ile eşleşmiyor.") }
    }
    foreach ($name in @('initial_dirty_paths','files_read','changed_files','tests','evidence','blockers')) {
        if ($data[$name] -isnot [System.Collections.IList]) { $errors.Add("Dizi olmalı: $name") }
    }
    if ($data.initial_dirty_paths -is [System.Collections.IList] -and (@($data.initial_dirty_paths) -join "`n") -cne (@($expected.initial_dirty_paths) -join "`n")) { $errors.Add('initial_dirty_paths başlatıcı ile eşleşmiyor.') }
    if ($data.final_status -notin @('completed','partial','blocked','failed')) { $errors.Add('final_status geçersiz.') }
    $report.worker_final_status = $data.final_status
    $report.reported_scope = $data.scope
    foreach ($name in @('files_read','changed_files')) {
        if ($data[$name] -isnot [System.Collections.IList]) { continue }
        foreach ($path in $data[$name]) {
            if (-not (Test-RelativeReportPath $path $root)) { $errors.Add("Geçersiz göreli yol ($name): $path") }
        }
    }
    if ($data.files_read -is [System.Collections.IList]) { $report.reported_files_read = @($data.files_read) }
    if (-not $contextMode -and $data.files_read -is [System.Collections.IList] -and (Get-ReportPathKey $requiredProbePath) -notin @($data.files_read | ForEach-Object { Get-ReportPathKey $_ })) {
        $errors.Add('files_read okuma kanıtı dosyasını içermiyor.')
    }
    if ($data.changed_files -is [System.Collections.IList]) { $report.reported_changed_files = @($data.changed_files) }
    if ($data.tests -is [System.Collections.IList]) {
        $report.reported_tests = @($data.tests)
        foreach ($item in $data.tests) {
            if ($item -isnot [System.Collections.IDictionary] -or $item.command -isnot [string] -or [string]::IsNullOrWhiteSpace($item.command) -or $item.status -notin @('passed','failed','not_run') -or $item.evidence -isnot [string] -or ($item.status -in @('passed','failed') -and [string]::IsNullOrWhiteSpace($item.evidence))) { $errors.Add('tests girdisi {command,status,evidence} biçiminde olmalı; çalışan testin kanıtı boş olamaz.') }
        }
    }
    if ($data.evidence -is [System.Collections.IList]) {
        $report.reported_evidence = @($data.evidence)
        foreach ($item in $data.evidence) {
            if ($item -isnot [System.Collections.IDictionary] -or $item.claim -isnot [string] -or [string]::IsNullOrWhiteSpace($item.claim) -or $item.source -isnot [string] -or [string]::IsNullOrWhiteSpace($item.source)) { $errors.Add('evidence girdisi {claim,source} biçiminde olmalı.') }
        }
    }
    if ($data.blockers -is [System.Collections.IList]) {
        $report.reported_blockers = @($data.blockers)
        foreach ($item in $data.blockers) { if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) { $errors.Add('blockers girdileri boş olmayan metin olmalı.') } }
    }
    if ($sharedRootParallel) { $report.changed_files_check = 'deferred_shared_root' }
    elseif ($null -ne $expected.git_root -and $data.changed_files -is [System.Collections.IList] -and ($endHead -or -not $expected.start_head)) {
        $reportedKeys = @($data.changed_files | ForEach-Object { Get-ReportPathKey $_ } | Sort-Object -Unique)
        $observedKeys = @($finalWorktreeStatus | ForEach-Object { Get-ReportPathKey $_ } | Sort-Object -Unique)
        $report.changed_files_check = if (-not $endHead) { 'unborn_git_tree_compared' }
            elseif ($endHead -ne $expected.start_head) { 'head_changed_compared' }
            elseif (@($expected.initial_dirty_paths).Count -eq 0) { 'clean_git_start_compared' } else { 'dirty_git_start_compared' }
        if (($reportedKeys -join "`n") -cne ($observedKeys -join "`n")) { $errors.Add('changed_files başlangıçtan beri gözlenen değişikliklerle eşleşmiyor.') }
    } elseif ($null -eq $expected.git_root -and $data.changed_files -is [System.Collections.IList]) {
        $reportedKeys = @($data.changed_files | ForEach-Object { Get-ReportPathKey $_ } | Sort-Object -Unique)
        $observedKeys = @($finalWorktreeStatus | ForEach-Object { Get-ReportPathKey $_ } | Sort-Object -Unique)
        $report.changed_files_check = 'non_git_tree_compared'
        if (($reportedKeys -join "`n") -cne ($observedKeys -join "`n")) { $errors.Add('changed_files başlangıçtan beri gözlenen değişikliklerle eşleşmiyor.') }
    }
    else { $report.changed_files_check = 'not_available_git_change'; $errors.Add('Git değişiklikleri bağımsız karşılaştırılamadı.') }
    $report.errors = @($errors)
    $report.valid = ($errors.Count -eq 0)
    if ($report.valid) { $report.state = 'valid' }
    return $report
}

try {
    if ($TaskRoot.Contains('${') -or $TaskRoot.Contains('<')) {
        throw 'TaskRoot genişletilmemiş değişken/örnek yol içeriyor; aktif projenin gerçek mutlak yolunu ver.'
    }
    $root = (Resolve-Path -LiteralPath $TaskRoot -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Proje klasörü yok: $root" }
    $status.task_root = $root

    $taskPath = (Resolve-Path -LiteralPath $TaskFile -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Görev dosyası yok: $taskPath" }
    $taskText = [System.IO.File]::ReadAllText($taskPath, $utf8)
    if ([string]::IsNullOrWhiteSpace($taskText)) { throw 'Görev dosyası boş.' }

    $gitRootRaw = if (Get-Command git -ErrorAction SilentlyContinue) { & git -C $root rev-parse --show-toplevel 2>$null }
    if ($gitRootRaw -and $LASTEXITCODE -eq 0) {
        $status.git_root = (Resolve-Path -LiteralPath $gitRootRaw.Trim()).ProviderPath
        $headRaw = & git -C $root rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $headRaw) { $status.start_head = $headRaw.Trim() }
        $status.initial_dirty_paths = @(& git -C $root -c status.relativePaths=true status --porcelain --untracked-files=all -- . 2>$null)
        $initialChangedPaths = @(Get-GitChangedPaths $root)
        $initialPathStates = @{}
        foreach ($relative in $initialChangedPaths) { $initialPathStates[(Get-ReportPathKey $relative)] = Get-GitPathState $root $relative }
    } else {
        $status.changed_files_scope = 'all_files_non_git'
        $initialNonGitStates = Get-NonGitFileStates $root $runFull
    }

    if ([string]::IsNullOrWhiteSpace($ProbeFile)) {
        $candidates = @('README.md', 'README.MD', 'AGENTS.md', 'CLAUDE.md', 'package.json', 'pyproject.toml', 'Cargo.toml', 'go.mod', 'pom.xml', 'src/README.md')
        foreach ($candidatePath in $candidates) {
            if (-not (Test-Path -LiteralPath (Join-Path $root $candidatePath) -PathType Leaf)) { continue }
            $candidateLines = [System.IO.File]::ReadAllLines((Join-Path $root $candidatePath), $utf8)
            $candidateUsable = @($candidateLines | Where-Object {
                $trimmed = $_.Trim()
                $trimmed.Length -ge 30 -and $trimmed.Length -le 160 -and -not $trimmed.StartsWith('#') -and
                -not $taskText.Contains($trimmed) -and $trimmed -notmatch '(?i)(api.?key|password|secret|token)\s*[:=]'
            })
            if ($candidateUsable.Count -gt 0) { $ProbeFile = $candidatePath; break }
        }
        if (-not $ProbeFile) { throw 'Kökte uygun okuma kanıtı dosyası bulunamadı; -ProbeFile ile proje içindeki bir metin dosyası ver.' }
    }
    $probe = Get-WithinRootFile $ProbeFile $root
    if ($Provider -eq 'deepseek' -and -not $DeepSeekIncludeSensitive -and (Test-SensitivePath $probe.Relative)) {
        throw 'DeepSeek okuma kanıtı dosyası hassas dosya filtresine takıldı; başka -ProbeFile seç.'
    }
    $probeLines = [System.IO.File]::ReadAllLines($probe.Full, $utf8)
    $usable = @(for ($i = 0; $i -lt $probeLines.Count; $i++) {
        $candidate = $probeLines[$i].Trim()
        if ($candidate.Length -ge 30 -and $candidate.Length -le 160 -and -not $candidate.StartsWith('#') -and -not $taskText.Contains($candidate) -and $candidate -notmatch '(?i)(api.?key|password|secret|token)\s*[:=]') { $i }
    })
    if ($usable.Count -eq 0) { throw "Okuma kanıtı için uygun metin satırı yok: $($probe.Relative)" }
    $lineIndex = $usable | Get-Random
    $expectedLine = $probeLines[$lineIndex].Trim()
    $lineNumber = $lineIndex + 1
    $status.probe_file = $probe.Relative
    $status.probe_line = $lineNumber

    $modelExplicit = -not [string]::IsNullOrWhiteSpace($Model)
    $modelDefaults = @{ codex = 'gpt-6-sol'; grok = 'grok-4.7'; agy = 'gemini-3.8-flash-high'; deepseek = 'deepseek-v4-pro' }
    if ([string]::IsNullOrWhiteSpace($Model)) { $Model = $modelDefaults[$Provider] }
    if ($Provider -eq 'agy' -and $AgyReasoningEffort -and $Model -match '^gemini-') {
        $modelEffort = [regex]::Match($Model, '^gemini-.*-(low|medium|high)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($modelEffort.Success) {
            if ($modelExplicit -and $modelEffort.Groups[1].Value -ine $AgyReasoningEffort) {
                throw 'agy model slug ile -AgyReasoningEffort çelişiyor; aynı eforu seç veya yalnız modeli ver.'
            }
            $Model = $Model.Substring(0, $modelEffort.Groups[1].Index) + $AgyReasoningEffort
        } else {
            $Model += '-' + $AgyReasoningEffort
        }
    }
    $status.requested_model = $Model

    $command = if ($Provider -eq 'deepseek') { Get-Command python -ErrorAction Stop } else { Get-Command $Provider -ErrorAction Stop }
    $launcherPrefix = @()
    if ([System.IO.Path]::GetExtension($command.Source) -in @('.cmd', '.bat')) {
        $stem = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($command.Source),
                                          [System.IO.Path]::GetFileNameWithoutExtension($command.Source))
        $alternative = @("$stem.exe", "$stem.ps1") | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if ($alternative) { $command = Get-Command $alternative -ErrorAction Stop }
        else {
            $shimDir = [System.IO.Path]::GetDirectoryName($command.Source)
            $shimText = [System.IO.File]::ReadAllText($command.Source)
            $match = [regex]::Match($shimText, '"%dp0%\\(?<entry>node_modules\\[^"\r\n]+\.js)"\s+%\*', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $match.Success) { throw "$Provider .cmd/.bat başlatıcısı tanınan npm Node shim biçiminde değil." }
            $entry = [System.IO.Path]::GetFullPath((Join-Path $shimDir $match.Groups['entry'].Value))
            $relativeEntry = [System.IO.Path]::GetRelativePath($shimDir, $entry)
            if ($relativeEntry -eq '..' -or $relativeEntry.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar) -or
                [System.IO.Path]::IsPathRooted($relativeEntry) -or -not (Test-Path -LiteralPath $entry -PathType Leaf)) {
                throw "$Provider npm shim giriş dosyası bulunamadı veya shim klasörü dışında."
            }
            $nodePath = Join-Path $shimDir 'node.exe'
            $command = if (Test-Path -LiteralPath $nodePath -PathType Leaf) { Get-Command $nodePath -ErrorAction Stop }
                       else { Get-Command node.exe -ErrorAction Stop }
            $launcherPrefix = @($entry)
        }
    }
    $helpText = if ($Provider -eq 'deepseek') { '' }
        elseif ($Provider -eq 'codex') { Invoke-PreflightCommand $command.Source ([string[]](@($launcherPrefix) + @('exec', '--help'))) $root }
        else { Invoke-PreflightCommand $command.Source ([string[]](@($launcherPrefix) + @('--help'))) $root }
    $requiredFlags = @{ codex = @('--cd', '--model', '--config', '--output-last-message'); grok = @('--cwd', '--model', '--prompt-file'); agy = @('--add-dir', '--model', '--print-timeout') }
    if ($Provider -ne 'deepseek') {
        foreach ($flag in $requiredFlags[$Provider]) {
            if (-not $helpText.Contains($flag)) { throw "$Provider sürümünde beklenen bayrak yok: $flag" }
        }
    }
    if ($Provider -eq 'codex' -and -not $status.git_root -and -not $helpText.Contains('--skip-git-repo-check')) {
        throw 'Git dışı Codex görevi için --skip-git-repo-check bayrağı yok.'
    }
    $versionText = (Invoke-PreflightCommand $command.Source ([string[]](@($launcherPrefix) + @('--version'))) $root).Trim()
    $status['cli_version'] = $versionText

    $runManifest = [ordered]@{
        task_id = $runId
        task_root = $root
        git_root = $status.git_root
        start_head = $status.start_head
        initial_dirty_paths = @($status.initial_dirty_paths)
    }
    [System.IO.File]::WriteAllText((Join-Path $runFull 'task-manifest.json'), ($runManifest | ConvertTo-Json -Depth 5), $utf8)

    $taskHeader = @(
        "Proje kökü (taskRoot): $root",
        "Git kökü (gitRoot): $($status.git_root)",
        "Başlangıç commit'i: $($status.start_head)",
        $(if ($Provider -eq 'deepseek' -and $DeepSeekAccess -eq 'context') { "Aşağıdaki proje bağlamında şu dosyanın $lineNumber. satırını bul: $($probe.Relative)." } else { "Önce proje dosyasını gerçekten aç: $($probe.Relative), satır $lineNumber." }),
        'Son yanıtının ilk satırı tam olarak şu biçimde olsun:',
        "PROJECT_READ_PROOF|$($probe.Relative)|$lineNumber|<satırın dosyadaki tam metni>",
        $(if ($Provider -eq 'deepseek' -and $DeepSeekAccess -eq 'context') { 'Satır metni bu başlıkta verilmedi; aşağıdaki proje bağlamından bul. Bağlam eksikse mimariyi tahmin etme.' } else { 'Satır metni bu görevde verilmedi. Dosyayı okuyamıyorsan işi yapmadan erişim hatasını bildir; mimariyi tahmin etme.' }),
        'Sonrasında ilgili proje talimatlarını ve görev dosyalarını oku. TaskRoot alt proje ise Git köküne çıkıp başka projede çalışma.',
        'Son yanıtın sonunda TAM BİR DELEGATE_RESULT_JSON_BEGIN / DELEGATE_RESULT_JSON_END bloğu ver. Aradaki içerik geçerli JSON nesnesi olmalı.',
        'Şema: {"task_id":string,"task_root":string,"git_root":string|null,"start_head":string|null,"initial_dirty_paths":string[],"scope":string,"files_read":string[],"changed_files":string[],"tests":[{"command":string,"status":"passed|failed|not_run","evidence":string}],"evidence":[{"claim":string,"source":string}],"blockers":string[],"final_status":"completed|partial|blocked|failed"}.',
        'Kimlik/Git alanlarını aşağıdaki RUN_MANIFEST_JSON değerlerinden aynen kopyala. Dosya yollarını task_root göreli yaz. changed_files yalnız başlangıç anına göre değiştirdiğin dosyaları içerir; başlangıçta kirli ama dokunmadığın dosyaları ekleme. Okumadığın dosyayı files_read içine, çalıştırmadığın testi passed olarak yazma. Boş listeler için [] kullan. Rapor iddiadır; ana ajan bağımsız denetler.',
        'RUN_MANIFEST_JSON:',
        ($runManifest | ConvertTo-Json -Depth 5 -Compress -EscapeHandling EscapeNonAscii),
        '',
        'GÖREV:',
        $taskText
    )
    $prompt = $taskHeader -join "`n"
    $promptPath = Join-Path $runFull 'prompt.txt'
    [System.IO.File]::WriteAllText($promptPath, $prompt, $utf8)

    $args = [System.Collections.Generic.List[string]]::new()
    switch ($Provider) {
        'codex' {
            $args.Add('exec'); $args.Add('-C'); $args.Add($root); $args.Add('-m'); $args.Add($Model)
            $args.Add('-c'); $args.Add('model_reasoning_effort="' + $CodexReasoningEffort + '"')
            $status['requested_effort'] = $CodexReasoningEffort
            if ($CodexSandbox) { $args.Add('-s'); $args.Add($CodexSandbox) }
            if (-not $status.git_root) { $args.Add('--skip-git-repo-check') }
            $args.Add('-o'); $args.Add((Join-Path $runFull 'codex-final.txt')); $args.Add('-')
        }
        'grok' {
            $args.Add('--cwd'); $args.Add($root); $args.Add('--model'); $args.Add($Model)
            $effectiveGrokEffort = if ($GrokReasoningEffort -eq 'max') { 'xhigh' } else { $GrokReasoningEffort }
            $args.Add('--reasoning-effort'); $args.Add($effectiveGrokEffort); $args.Add('--output-format'); $args.Add('json')
            $args.Add('--prompt-file'); $args.Add($promptPath)
            $status['requested_effort'] = $GrokReasoningEffort
            $status['effective_effort'] = $effectiveGrokEffort
        }
        'agy' {
            $agyStreamInput = ($prompt.Length -gt 20000)
            $args.Add('--model'); $args.Add($Model); $args.Add('--add-dir'); $args.Add($root)
            if ($AgyReasoningEffort) {
                if ($Model -notmatch '^gemini-.*-(low|medium|high)$') { $args.Add('--effort'); $args.Add($AgyReasoningEffort) }
                $status['requested_effort'] = $AgyReasoningEffort
            }
            $args.Add('--dangerously-skip-permissions'); $args.Add('--output-format')
            $args.Add($(if ($agyStreamInput) { 'stream-json' } else { 'json' }))
            $args.Add('--print-timeout'); $args.Add("${TimeoutSeconds}s")
            if ($agyStreamInput) {
                if (-not $helpText.Contains('--input-format') -or -not $helpText.Contains('stream-json')) { throw 'agy sürümü uzun istem için stream-json standart girdisini desteklemiyor.' }
                $args.Add('--input-format'); $args.Add('stream-json')
                $status['prompt_transport'] = 'stdin_stream_json'
            } else {
                $args.Add('--print'); $args.Add($prompt)
                $status['prompt_transport'] = 'argument'
            }
        }
        'deepseek' {
            $helper = Join-Path $PSScriptRoot 'Invoke-DeepSeek.py'
            if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw "DeepSeek yardımcı dosyası yok: $helper" }
            $args.Add($helper); $args.Add('--task-root'); $args.Add($root)
            $args.Add('--prompt-file'); $args.Add($promptPath)
            $args.Add('--result-file'); $args.Add((Join-Path $runFull 'deepseek-result.json'))
            $args.Add('--model'); $args.Add($Model)
            $args.Add('--access'); $args.Add($DeepSeekAccess)
            $args.Add('--reasoning-effort'); $args.Add($DeepSeekReasoningEffort)
            $args.Add('--http-timeout'); $args.Add([string]$TimeoutSeconds)
            $args.Add('--probe-file'); $args.Add($probe.Relative)
            if ($DeepSeekIncludeSensitive) { $args.Add('--include-sensitive') }
            if ($DeepSeekIncludeIgnored) { $args.Add('--include-ignored') }
            $status['project_access_mode'] = $DeepSeekAccess
            $status['requested_effort'] = $DeepSeekReasoningEffort
            $status['include_sensitive'] = [bool]$DeepSeekIncludeSensitive
            $status['include_ignored'] = [bool]$DeepSeekIncludeIgnored
        }
    }
    $status['command_arguments'] = @($args | ForEach-Object { if ($_ -eq $prompt) { '<prompt>' } else { $_ } })
    if ($DryRun) {
        $status.status = 'launch_prepared'
        $status.outcome = 'launch_prepared'
        Save-Status
        Write-Output $statusPath
        return
    }

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    if ($command.Source.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        $start.FileName = Join-Path $PSHOME 'pwsh.exe'
        $start.ArgumentList.Add('-NoProfile')
        $start.ArgumentList.Add('-NonInteractive')
        $start.ArgumentList.Add('-File')
        $start.ArgumentList.Add($command.Source)
    } else {
        $start.FileName = $command.Source
    }
    foreach ($arg in $launcherPrefix) { $start.ArgumentList.Add($arg) }
    foreach ($arg in $args) { $start.ArgumentList.Add($arg) }
    $start.WorkingDirectory = $root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($Provider -eq 'deepseek' -and [string]::IsNullOrWhiteSpace($env:DEEPSEEK_API_KEY)) {
        $credentialPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'delegate-and-audit\deepseek-key.dpapi'
        if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
            throw 'DeepSeek anahtarı yok. DEEPSEEK_API_KEY ayarla veya Set-DeepSeekKey.ps1 çalıştır.'
        }
        $secureKey = (Get-Content -LiteralPath $credentialPath -Raw).Trim() | ConvertTo-SecureString
        $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        try { $start.Environment['DEEPSEEK_API_KEY'] = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer) }
    }
    $start.StandardInputEncoding = $utf8
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8

    $process = [System.Diagnostics.Process]::new()
    $processStarted = $false
    $jobHandle = [IntPtr]::Zero
    try {
        $process.StartInfo = $start
        if ($IsWindows) { $jobHandle = [DelegateProcessJob]::CreateKillOnClose() }
        if (-not $process.Start()) { throw "$Provider süreci başlatılamadı." }
        $processStarted = $true
        if ($jobHandle -ne [IntPtr]::Zero -and -not [DelegateProcessJob]::Attach($jobHandle, $process.Handle)) {
            [DelegateProcessJob]::Close($jobHandle)
            $jobHandle = [IntPtr]::Zero
        }
        $status['pid'] = $process.Id
        $status.status = 'running'
        $status.outcome = 'running'
        Save-Status
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($Provider -eq 'codex') { $process.StandardInput.Write($prompt) }
        elseif ($Provider -eq 'agy' -and $agyStreamInput) {
            $streamMessage = [ordered]@{ event = 'user'; message = [ordered]@{ role = 'user'; content = $prompt } } | ConvertTo-Json -Depth 5 -Compress
            $process.StandardInput.WriteLine($streamMessage)
        }
        $process.StandardInput.Close()
        $completed = $process.WaitForExit(($TimeoutSeconds + 20) * 1000)
        if (-not $completed) {
            $status.status = 'timed_out'
            $status.error_type = 'timeout'
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
        }
        if ($jobHandle -ne [IntPtr]::Zero) {
            [DelegateProcessJob]::Close($jobHandle)
            $jobHandle = [IntPtr]::Zero
        }
        $drainsComplete = [System.Threading.Tasks.Task]::WaitAll(
            [System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 5000)
        if (-not $drainsComplete) {
            $status.status = 'timed_out'
            $status.error_type = 'output_pipe_timeout'
        }
        $stdout = if ($stdoutTask.IsCompletedSuccessfully) { $stdoutTask.GetAwaiter().GetResult() } else { '' }
        $stderr = if ($stderrTask.IsCompletedSuccessfully) { $stderrTask.GetAwaiter().GetResult() } else { '' }
        if ($completed) { $status.exit_code = $process.ExitCode }
    } finally {
        if ($jobHandle -ne [IntPtr]::Zero) { [DelegateProcessJob]::Close($jobHandle) }
        if ($processStarted -and -not $process.HasExited) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
    $limit = 1000000
    $stdoutLog = if ($stdout.Length -gt $limit) { $stdout.Substring(0, $limit) + "`n[truncated]" } else { $stdout }
    $stderrLog = if ($stderr.Length -gt $limit) { $stderr.Substring(0, $limit) + "`n[truncated]" } else { $stderr }
    [System.IO.File]::WriteAllText((Join-Path $runFull 'stdout.log'), $stdoutLog, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $runFull 'stderr.log'), $stderrLog, $utf8)

    $final = ''
    if ($Provider -eq 'codex') {
        $codexFinalPath = Join-Path $runFull 'codex-final.txt'
        if (Test-Path -LiteralPath $codexFinalPath) { $final = [System.IO.File]::ReadAllText($codexFinalPath, $utf8) }
    } elseif ($Provider -eq 'agy') {
        try {
            if ($agyStreamInput) {
                $resultEvents = @($stdout -split "`r?`n" | Where-Object { $_ -match '^\s*\{' } | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop } | Where-Object { $_.event -eq 'result' })
                if ($resultEvents.Count -ne 1) { throw "agy stream-json sonuç olayı sayısı: $($resultEvents.Count)" }
                $agyResult = $resultEvents[0].result
            } else { $agyResult = $stdout | ConvertFrom-Json -ErrorAction Stop }
            if ($agyResult.status -and $agyResult.status -notin @('success', 'completed', 'ok')) {
                $status.error_type = 'provider_error'
                $status.error_message = "agy status: $($agyResult.status); $($agyResult.error)"
            }
            $final = [string]$agyResult.response
        } catch {
            $status.error_type = 'invalid_provider_json'
            $status.error_message = $_.Exception.Message
        }
    } elseif ($Provider -eq 'deepseek') {
        $deepSeekPath = Join-Path $runFull 'deepseek-result.json'
        if (-not (Test-Path -LiteralPath $deepSeekPath -PathType Leaf)) {
            $status.error_type = 'provider_error'
            $status.error_message = if ($stderr) { $stderr.Trim() } else { 'DeepSeek sonuç dosyası oluşmadı.' }
        } else { try {
            $deepSeekResult = [System.IO.File]::ReadAllText($deepSeekPath, $utf8) | ConvertFrom-Json -ErrorAction Stop
            $final = [string]$deepSeekResult.text
            $status.observed_model = [string]$deepSeekResult.model
            $status['tool_calls'] = [int]$deepSeekResult.tool_calls
            $status['read_paths'] = @($deepSeekResult.read_paths)
            $status['context_incomplete'] = [bool]$deepSeekResult.context_incomplete
            $status['context_skipped_count'] = @($deepSeekResult.skipped_files).Count
            $status['context_skipped_files'] = @($deepSeekResult.skipped_files | Select-Object -First 50)
            $status['usage'] = $deepSeekResult.usage
            $status['stop_reason'] = [string]$deepSeekResult.finish_reason
        } catch {
            $status.error_type = 'invalid_provider_json'
            $status.error_message = $_.Exception.Message
        } }
    } else {
        try {
            $grokResult = $stdout | ConvertFrom-Json -ErrorAction Stop
            if ($grokResult.type -eq 'error' -or $grokResult.is_error -or $grokResult.error) {
                $status.error_type = 'provider_error'
                $status.error_message = if ($grokResult.message) { [string]$grokResult.message } else { [string]$grokResult.error }
            }
            $final = [string]$grokResult.text
            $usedModels = @()
            if ($null -ne $grokResult.modelUsage) {
                $usedModels = @($grokResult.modelUsage.PSObject.Properties.Name | Where-Object { $_ })
            }
            if ($usedModels.Count -gt 0) { $status.observed_model = $usedModels -join ', ' }
            if ($grokResult.sessionId) { $status['session_id'] = [string]$grokResult.sessionId }
            if ($grokResult.stopReason) { $status['stop_reason'] = [string]$grokResult.stopReason }
        } catch {
            $status.error_type = 'invalid_provider_json'
            $status.error_message = $_.Exception.Message
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $runFull 'final.txt'), $final, $utf8)
    $status.final_available = -not [string]::IsNullOrWhiteSpace($final)
    $proofMatches = [regex]::Matches($final, 'PROJECT_READ_PROOF\|(?<path>[^|\r\n]+)\|(?<line>\d+)\|(?<content>[^\r\n]*)')
    foreach ($match in $proofMatches) {
        $reportedPath = $match.Groups['path'].Value.Replace('/', '\')
        if (-not [string]::Equals($reportedPath, $probe.Relative.Replace('/', '\'), [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $reported = 0
        if (-not [int]::TryParse($match.Groups['line'].Value, [ref]$reported)) { continue }
        $returnedText = $match.Groups['content'].Value.Trim()
        if ($reported -eq $lineNumber -and
            $probeLines[$reported - 1].Trim() -ceq $returnedText) {
            $status.read_proof = $true
            $status.proof_at_start = ($match.Index -eq 0)
            $status.reported_line = $reported
            $status.matched_line = $reported
            $status.citation_line_accurate = $true
            $status.read_proof_kind = 'challenge_exact'
            break
        }
    }

    if ($Provider -eq 'deepseek' -and $DeepSeekAccess -eq 'context') {
        $contextProbePath = $probe.Relative.Replace('\', '/')
        $status.context_proof = ($status.read_proof -and $contextProbePath -in @($status.read_paths))
        $status.read_proof = $false
        if ($status.context_proof) { $status.read_proof_kind = 'context_supplied' }
    } elseif ($Provider -eq 'deepseek' -and $status.read_proof) {
        $readProbePath = $probe.Relative.Replace('\', '/')
        if ($readProbePath -notin @($status.read_paths)) {
            $status.read_proof = $false
            $status.read_proof_kind = $null
        }
    }

    if ($status.git_root) {
        $status.final_worktree_status = @(& git -C $root -c status.relativePaths=true status --porcelain --untracked-files=all -- . 2>$null)
        $finalChangedPaths = @(Get-GitChangedPaths $root)
        $endHeadRaw = & git -C $root rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $endHeadRaw) { $status.end_head = $endHeadRaw.Trim() }
        $committedPaths = @(Get-GitCommittedPaths $root $status.start_head $status.end_head)
        $changedSinceStart = [System.Collections.Generic.List[string]]::new()
        foreach ($relative in $committedPaths) { $changedSinceStart.Add($relative) }
        $finalKeys = @{}
        foreach ($relative in $finalChangedPaths) {
            $key = Get-ReportPathKey $relative
            $finalKeys[$key] = $true
            if (-not $initialPathStates.ContainsKey($key) -or $initialPathStates[$key] -cne (Get-GitPathState $root $relative)) { $changedSinceStart.Add($relative) }
        }
        foreach ($relative in $initialChangedPaths) {
            if (-not $finalKeys.ContainsKey((Get-ReportPathKey $relative))) { $changedSinceStart.Add($relative) }
        }
        $status['changed_since_start'] = @($changedSinceStart | Sort-Object -Unique)
    } else {
        $finalNonGitStates = Get-NonGitFileStates $root $runFull
        $changedSinceStart = [System.Collections.Generic.List[string]]::new()
        foreach ($key in @($initialNonGitStates.Keys) + @($finalNonGitStates.Keys) | Sort-Object -Unique) {
            $before = $initialNonGitStates[$key]
            $after = $finalNonGitStates[$key]
            if ($before.state -cne $after.state) {
                $changedSinceStart.Add($(if ($after) { $after.path } else { $before.path }))
            }
        }
        $status['changed_since_start'] = @($changedSinceStart | Sort-Object -Unique)
    }
    if ($status.final_available) {
        $status.result_contract = Read-ResultContract $final $runManifest $root @($status.changed_since_start) $status.end_head $probe.Relative ($Provider -eq 'deepseek' -and $DeepSeekAccess -eq 'context') ([bool]$SharedRootParallel)
        if ($status.result_contract.valid) {
            if ($Provider -eq 'deepseek' -and $DeepSeekAccess -eq 'context') { $status.result_contract.files_read_check = 'context_supplied_only' }
            elseif ($status.read_proof -and (Get-ReportPathKey $status.probe_file) -in @($status.result_contract.reported_files_read | ForEach-Object { Get-ReportPathKey $_ })) { $status.result_contract.files_read_check = 'probe_confirmed_other_paths_unverified' }
            else { $status.result_contract.files_read_check = 'reported_paths_unverified' }
        }
    }
    if ($status.status -ne 'timed_out') {
        if ($Provider -eq 'deepseek' -and $DeepSeekAccess -eq 'context' -and $status.context_incomplete) { $status.status = 'failed'; $status.error_type = 'incomplete_context' }
        elseif ($status.exit_code -ne 0) { $status.status = 'failed'; if (-not $status.error_type) { $status.error_type = 'nonzero_exit' } }
        elseif ($status.error_type) { $status.status = 'failed' }
        elseif (-not $status.final_available) { $status.status = 'failed'; $status.error_type = 'missing_final' }
        elseif ($Provider -eq 'deepseek' -and $DeepSeekAccess -eq 'context' -and $status.context_proof) { $status.status = 'verified_project_context' }
        elseif (-not $status.read_proof) { $status.status = 'unverified'; $status.error_type = 'missing_read_proof' }
        else { $status.status = 'verified_project_access' }
    }
    $status.worker_reported_completed = ($null -ne $status.result_contract -and $status.result_contract.valid -and $status.result_contract.worker_final_status -eq 'completed')
    if ($status.status -notin @('verified_project_access', 'verified_project_context')) { $status.outcome = $status.status }
    elseif ($null -eq $status.result_contract -or -not $status.result_contract.valid) {
        if ($AllowMissingResultContract -and $null -ne $status.result_contract -and $status.result_contract.state -eq 'missing') { $status.outcome = 'legacy_access_only' }
        else { $status.outcome = 'invalid_result_contract' }
    }
    elseif (-not $status.worker_reported_completed) { $status.outcome = 'worker_incomplete' }
    elseif ($SharedRootParallel) { $status.outcome = 'pending_parallel_group_check' }
    else { $status.outcome = 'valid_report' }
    Save-Status
    Write-Output $statusPath
    if ($status.outcome -notin @('valid_report', 'legacy_access_only', 'pending_parallel_group_check')) { exit 2 }
} catch {
    $status.status = 'failed'
    $status.outcome = 'failed'
    if (-not $status.error_type) { $status.error_type = 'preflight_or_launch' }
    $status.error_message = $_.Exception.Message
    Save-Status
    Write-Error $status.error_message
    exit 1
}
