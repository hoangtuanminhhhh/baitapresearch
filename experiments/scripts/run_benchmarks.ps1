<#
.SYNOPSIS
    Automated benchmark runner and validation orchestrator for Member 3 (TV3).
.DESCRIPTION
    Compiles Java modules (Common, Server, LoadGenerator), starts TCPEchoServer,
    runs the 3x3 experimental matrix (1, 10, 50 clients x 3 runs), samples server CPU
    and memory every second, collects raw CSV/JSON metrics into experiments/raw-data/,
    exports environment metadata, and invokes run_validation_tests.ps1 (TC1-TC4).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [string[]]$Clients = @(),
    [int]$Runs = 0,
    [int]$WarmupSec = -1,
    [int]$DurationSec = -1,
    [int]$PayloadBytes = -1,
    [int]$CooldownSec = -1,
    [switch]$UseExternalServer,
    [string[]]$ServerArgs = @(),
    [string]$ServerSourceDir = "",
    [string]$LoadGenSourceDir = "",
    [string]$OutputDir = "",
    [switch]$SkipBenchmarks,
    [switch]$SkipValidation,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($fullPath, $Content, $utf8NoBom)
}

function Resolve-RepoPath {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDir,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )
    if ([System.IO.Path]::IsPathRooted($TargetPath)) {
        return [System.IO.Path]::GetFullPath($TargetPath)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDir $TargetPath))
}

function Format-Win32Arg {
    param([string]$Arg)
    if ($null -eq $Arg -or $Arg.Length -eq 0) { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    $escaped = $Arg -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Join-Win32Args {
    param([string[]]$ArgsList)
    return ((@($ArgsList | ForEach-Object { Format-Win32Arg $_ })) -join ' ')
}

function Resolve-JavaTool {
    param([Parameter(Mandatory = $true)][string]$ToolName)
    if ($env:JAVA_HOME) {
        $candidate = Join-Path $env:JAVA_HOME ("bin\" + $ToolName + ".exe")
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    $cmds = @(Get-Command $ToolName -All -CommandType Application -ErrorAction SilentlyContinue)
    $direct = $cmds | Where-Object { $_.Source -and $_.Source -notmatch '\\javapath\\' } | Select-Object -First 1
    if ($null -ne $direct) {
        return $direct.Source
    }
    $anyCmd = $cmds | Select-Object -First 1
    if ($null -ne $anyCmd) {
        return $anyCmd.Source
    }
    return $ToolName
}

function Stop-ProcessTree {
    param([int]$TargetPid)
    if ($TargetPid -le 0) { return }
    try {
        $children = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $TargetPid" -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            Stop-ProcessTree -TargetPid ([int]$child.ProcessId)
        }
    } catch {}
    Stop-Process -Id $TargetPid -Force -ErrorAction SilentlyContinue
}

function Find-JavaSources {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$OverrideDir,
        [string[]]$CandidateDirs,
        [string]$PreferredMainFileName
    )
    $searchDirs = @()
    if (-not [string]::IsNullOrWhiteSpace($OverrideDir)) {
        $searchDirs += (Resolve-RepoPath -BaseDir (Get-Location).Path -TargetPath $OverrideDir)
    } else {
        foreach ($cand in $CandidateDirs) {
            $searchDirs += (Resolve-RepoPath -BaseDir $RepoRoot -TargetPath $cand)
        }
    }

    foreach ($dir in $searchDirs) {
        if (Test-Path -LiteralPath $dir) {
            $javaFiles = @(Get-ChildItem -LiteralPath $dir -Filter "*.java" -Recurse -File | Sort-Object FullName)
            if ($javaFiles.Count -gt 0) {
                $mainFile = $null
                if (-not [string]::IsNullOrWhiteSpace($PreferredMainFileName)) {
                    $mainFile = $javaFiles | Where-Object { $_.Name -eq $PreferredMainFileName } | Select-Object -First 1
                }
                if ($null -eq $mainFile) {
                    foreach ($jf in $javaFiles) {
                        $txt = Get-Content -LiteralPath $jf.FullName -Raw -Encoding UTF8
                        if ($txt -match '\bstatic\s+void\s+main\s*\(') {
                            $mainFile = $jf
                            break
                        }
                    }
                }
                return [PSCustomObject]@{
                    Found     = $true
                    SourceDir = $dir
                    Files     = @($javaFiles | ForEach-Object { $_.FullName })
                    MainFile  = $(if ($null -ne $mainFile) { $mainFile.FullName } else { "" })
                }
            }
        }
    }

    return [PSCustomObject]@{
        Found       = $false
        SourceDir   = $(if ($searchDirs.Count -gt 0) { $searchDirs[0] } else { "" })
        Files       = @()
        MainFile    = ""
        SearchedIn  = @($searchDirs)
    }
}

function Detect-MainClass {
    param(
        [string]$MainJavaFile,
        [string]$ConfiguredMainClass
    )
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredMainClass)) {
        return $ConfiguredMainClass.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($MainJavaFile) -or -not (Test-Path -LiteralPath $MainJavaFile)) {
        return ""
    }
    $content = Get-Content -LiteralPath $MainJavaFile -Raw -Encoding UTF8
    $className = [System.IO.Path]::GetFileNameWithoutExtension($MainJavaFile)
    if ($content -match '(?m)^\s*package\s+([A-Za-z0-9_\.]+)\s*;') {
        return ($Matches[1] + "." + $className)
    }
    return $className
}

function Compile-JavaModule {
    param(
        [Parameter(Mandatory = $true)][string]$ModuleName,
        [Parameter(Mandatory = $true)][string[]]$SourceFiles,
        [Parameter(Mandatory = $true)][string]$OutDir,
        [string]$ExtraClasspath = ""
    )
    if (Test-Path -LiteralPath $OutDir) {
        Remove-Item -LiteralPath $OutDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    $javacArgs = @("-encoding", "UTF-8", "-d", $OutDir)
    if (-not [string]::IsNullOrWhiteSpace($ExtraClasspath)) {
        $javacArgs += @("-cp", $ExtraClasspath)
    }
    $javacArgs += $SourceFiles

    Write-Host "[BUILD] Compiling $ModuleName ($($SourceFiles.Count) file(s)) -> $OutDir"
    & $javacExe @javacArgs
    if ($LASTEXITCODE -ne 0) {
        throw "javac failed for module '$ModuleName' with exit code $LASTEXITCODE"
    }
}

function Test-TcpPortOpen {
    param(
        [Parameter(Mandatory = $true)][string]$TargetHost,
        [Parameter(Mandatory = $true)][int]$TargetPort
    )
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
        $connected = $iar.AsyncWaitHandle.WaitOne(300, $false)
        if ($connected -and $client.Connected) {
            $client.EndConnect($iar)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        if ($null -ne $client) {
            try { $client.Close() } catch {}
        }
    }
}

function Get-ListeningPidByPort {
    param([int]$TargetPort)
    try {
        $conn = Get-NetTCPConnection -LocalPort $TargetPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $conn -and $conn.OwningProcess -gt 0) {
            return [int]$conn.OwningProcess
        }
    } catch {}
    return 0
}

function Wait-ServerReady {
    param(
        [string]$TargetHost,
        [int]$TargetPort,
        [System.Diagnostics.Process]$ServerProcess,
        [int]$TimeoutSec,
        [string]$StdOutLog,
        [string]$StdErrLog
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ($null -ne $ServerProcess -and $ServerProcess.HasExited) {
            $errText = ""
            if (Test-Path -LiteralPath $StdErrLog) {
                $errText = (Get-Content -LiteralPath $StdErrLog -Raw -ErrorAction SilentlyContinue)
            }
            throw "Server process exited prematurely (exit=$($ServerProcess.ExitCode)). Stderr: $errText"
        }
        if (Test-TcpPortOpen -TargetHost $TargetHost -TargetPort $TargetPort) {
            return
        }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out after ${TimeoutSec}s waiting for server on ${TargetHost}:${TargetPort}"
}

function Get-JavaVersionString {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $javaExe
        $psi.Arguments = "-version"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit(5000) | Out-Null
        $combined = ($err + "`n" + $out).Trim()
        if ($combined) {
            return ($combined -split "`r?`n")[0].Trim()
        }
    } catch {}
    return "unknown"
}

function Export-EnvironmentMetadata {
    param(
        [string]$Path,
        [string]$TargetHost,
        [int]$TargetPort,
        [int[]]$ClientLevels,
        [int]$RunsPerLevel,
        [int]$Warmup,
        [int]$Duration,
        [int]$Payload,
        [int]$Cooldown,
        [bool]$ExternalServer,
        [string]$ServerMain,
        [string]$LoadGenMain
    )
    $cpuName = "unknown"
    $physicalCores = 0
    $logicalCores = [Environment]::ProcessorCount
    $ramGb = 0.0
    $osCaption = [Environment]::OSVersion.VersionString

    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cpu) {
            $cpuName = ([string]$cpu.Name).Trim()
            $physicalCores = [int]$cpu.NumberOfCores
            $logicalCores = [int]$cpu.NumberOfLogicalProcessors
        }
    } catch {}

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cs -and $cs.TotalPhysicalMemory -gt 0) {
            $ramGb = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
        }
    } catch {}

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $os) {
            $osCaption = ("{0} ({1})" -f ([string]$os.Caption).Trim(), ([string]$os.Version).Trim())
        }
    } catch {}

    $meta = [PSCustomObject]@{
        generated_at_utc     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        hostname             = $env:COMPUTERNAME
        os                   = $osCaption
        powershell_version   = $PSVersionTable.PSVersion.ToString()
        java_version         = (Get-JavaVersionString)
        cpu_name             = $cpuName
        physical_cores       = $physicalCores
        logical_processors   = $logicalCores
        ram_gb               = $ramGb
        target_host          = $TargetHost
        target_port          = $TargetPort
        external_server_mode = $ExternalServer
        server_main_class    = $ServerMain
        loadgen_main_class   = $LoadGenMain
        benchmark_parameters = [PSCustomObject]@{
            client_levels  = @($ClientLevels)
            runs_per_level = $RunsPerLevel
            warmup_sec     = $Warmup
            duration_sec   = $Duration
            payload_bytes  = $Payload
            cooldown_sec   = $Cooldown
        }
    }
    $jsonText = ($meta | ConvertTo-Json -Depth 6) + "`n"
    Write-Utf8NoBom -Path $Path -Content $jsonText
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )
    if (-not $Values -or $Values.Count -eq 0) { return 0.0 }
    $sorted = @($Values | Sort-Object)
    $idx = [int][Math]::Ceiling(($Percentile / 100.0) * $sorted.Count) - 1
    $idx = [Math]::Max(0, [Math]::Min($idx, $sorted.Count - 1))
    return [double]$sorted[$idx]
}

function Read-SharedCsvLines {
    param([Parameter(Mandatory = $true)][string]$Path)
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    $fs = $null
    $sr = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        while ($null -ne ($line = $sr.ReadLine())) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $lines.Add($line)
            }
        }
    } finally {
        if ($null -ne $sr) { $sr.Dispose() }
        elseif ($null -ne $fs) { $fs.Dispose() }
    }
    return $lines.ToArray()
}

# =========================================================================
# Initialization & Config Resolution
# =========================================================================
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$javaExe = Resolve-JavaTool -ToolName "java"
$javacExe = Resolve-JavaTool -ToolName "javac"

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot "experiments\configs\benchmark_config.json"
} else {
    $ConfigPath = Resolve-RepoPath -BaseDir (Get-Location).Path -TargetPath $ConfigPath
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Error "Config file not found: $ConfigPath"
    exit 1
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$targetHost = [string]$config.server.host
$targetPort = [int]$config.server.port

[int[]]$resolvedClients = @()
if ($Clients.Count -eq 0) {
    $resolvedClients = @($config.benchmark.client_levels | ForEach-Object { [int]$_ })
} else {
    $parsedClients = New-Object System.Collections.Generic.List[int]
    foreach ($item in $Clients) {
        foreach ($tok in ($item -split '[,;\s]+')) {
            if (-not [string]::IsNullOrWhiteSpace($tok)) {
                $parsedClients.Add([int]$tok.Trim())
            }
        }
    }
    $resolvedClients = $parsedClients.ToArray()
}
if ($resolvedClients.Count -eq 0) {
    throw "No client levels resolved."
}
if ($Runs -le 0) {
    $Runs = [int]$config.benchmark.runs_per_level
}
if ($WarmupSec -lt 0) {
    $WarmupSec = [int]$config.benchmark.warmup_sec
}
if ($DurationSec -lt 0) {
    $DurationSec = [int]$config.benchmark.duration_sec
}
if ($PayloadBytes -lt 0) {
    $PayloadBytes = [int]$config.benchmark.payload_bytes
}
if ($CooldownSec -lt 0) {
    $CooldownSec = [int]$config.benchmark.cooldown_sec
}
$cpuIntervalMs = [int]$config.benchmark.cpu_sample_interval_ms
$startupTimeoutSec = [int]$config.server.startup_timeout_sec

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Resolve-RepoPath -BaseDir $repoRoot -TargetPath ([string]$config.output.raw_data_dir)
} else {
    $OutputDir = Resolve-RepoPath -BaseDir (Get-Location).Path -TargetPath $OutputDir
}

$buildRoot = Resolve-RepoPath -BaseDir $repoRoot -TargetPath ([string]$config.output.build_dir)

$commonInfo = Find-JavaSources -RepoRoot $repoRoot -OverrideDir "" -CandidateDirs @($config.server.common_source_dirs) -PreferredMainFileName ""
$serverInfo = Find-JavaSources -RepoRoot $repoRoot -OverrideDir $ServerSourceDir -CandidateDirs @($config.server.source_dirs) -PreferredMainFileName "TCPEchoServer.java"
$loadGenInfo = Find-JavaSources -RepoRoot $repoRoot -OverrideDir $LoadGenSourceDir -CandidateDirs @($config.load_generator.source_dirs) -PreferredMainFileName "LoadGeneratorApp.java"

$serverMainClass = Detect-MainClass -MainJavaFile $serverInfo.MainFile -ConfiguredMainClass ([string]$config.server.main_class)
$loadGenMainClass = Detect-MainClass -MainJavaFile $loadGenInfo.MainFile -ConfiguredMainClass ([string]$config.load_generator.main_class)

$serverJvmArgs = @("-Duser.language=en", "-Duser.country=US")
if ($config.server.jvm_args) {
    $sArgs = @($config.server.jvm_args)
    if ($sArgs.Count -gt 0) { $serverJvmArgs = $sArgs }
}
$loadGenJvmArgs = @("-Duser.language=en", "-Duser.country=US")
if ($config.load_generator.jvm_args) {
    $lArgs = @($config.load_generator.jvm_args)
    if ($lArgs.Count -gt 0) { $loadGenJvmArgs = $lArgs }
}

$effectiveServerArgs = @()
if ($ServerArgs.Count -gt 0) {
    $effectiveServerArgs = $ServerArgs
} elseif ($config.server.args) {
    $effectiveServerArgs = @($config.server.args)
}

$useTv1CpuLog = $true
if ($null -ne $config.server.PSObject.Properties["use_tv1_cpu_log"]) {
    $useTv1CpuLog = [bool]$config.server.use_tv1_cpu_log
}

if ($DryRun) {
    Write-Host "================ DRY RUN CONFIGURATION ================"
    Write-Host "Repo Root      : $repoRoot"
    Write-Host "Config Path    : $ConfigPath"
    Write-Host "Target Server  : ${targetHost}:${targetPort} (UseExternalServer=$UseExternalServer)"
    Write-Host "Server Args    : $($effectiveServerArgs -join ' ') (use_tv1_cpu_log=$useTv1CpuLog)"
    Write-Host "Output Dir     : $OutputDir"
    Write-Host "Build Dir      : $buildRoot"
    Write-Host ""
    Write-Host "Discovered Modules:"
    Write-Host "  Common       : $(if ($commonInfo.Found) { "[FOUND] $($commonInfo.SourceDir) ($($commonInfo.Files.Count) files)" } else { "[MISSING] searched: $($commonInfo.SearchedIn -join ', ')" })"
    Write-Host "  Server (TV1) : $(if ($serverInfo.Found) { "[FOUND] $($serverInfo.SourceDir) (main=$serverMainClass, $($serverInfo.Files.Count) files)" } else { "[MISSING] searched: $($serverInfo.SearchedIn -join ', ')" })"
    Write-Host "  LoadGen (TV2): $(if ($loadGenInfo.Found) { "[FOUND] $($loadGenInfo.SourceDir) (main=$loadGenMainClass, $($loadGenInfo.Files.Count) files)" } else { "[MISSING] searched: $($loadGenInfo.SearchedIn -join ', ')" })"
    Write-Host ""
    Write-Host "Planned Execution Matrix ($($resolvedClients.Count) levels x $Runs runs = $($resolvedClients.Count * $Runs) runs):"
    Write-Host "  Clients      : $($resolvedClients -join ', ')"
    Write-Host "  Warmup/Run   : ${WarmupSec}s | Duration/Run: ${DurationSec}s | Payload: ${PayloadBytes}B | Cooldown: ${CooldownSec}s | CPU Interval: ${cpuIntervalMs}ms"
    foreach ($c in $resolvedClients) {
        for ($r = 1; $r -le $Runs; $r++) {
            Write-Host "    - clients=$c, run_id=$r -> runs/c${c}_run${r}.csv, runs/c${c}_run${r}.json, cpu/cpu_c${c}_run${r}.csv"
        }
    }
    Write-Host "  Validation   : $(if ($SkipValidation) { 'SKIPPED' } else { 'TC1, TC2, TC3, TC4 via run_validation_tests.ps1' })"
    Write-Host "======================================================="
    exit 0
}

# =========================================================================
# Validate Required Sources
# =========================================================================
if (-not $UseExternalServer -and (-not $serverInfo.Found -or [string]::IsNullOrWhiteSpace($serverMainClass))) {
    Write-Error ("TV1 server sources not found or main class could not be detected. Searched: " + ($serverInfo.SearchedIn -join ", ") + ". Place TV1 code under src/server/TCPEchoServer.java, pass -ServerSourceDir, or use -UseExternalServer.")
    exit 1
}

if (-not $SkipBenchmarks -and (-not $loadGenInfo.Found -or [string]::IsNullOrWhiteSpace($loadGenMainClass))) {
    Write-Error ("TV2 load generator sources not found or main class could not be detected. Searched: " + ($loadGenInfo.SearchedIn -join ", ") + ". Merge TV2 branch (origin/feat/tv2-load-generator), pass -LoadGenSourceDir, or use -SkipBenchmarks.")
    exit 1
}

# =========================================================================
# Compile Java Modules
# =========================================================================
$commonOutDir = Join-Path $buildRoot "common"
$serverOutDir = Join-Path $buildRoot "server"
$loadGenOutDir = Join-Path $buildRoot "load-generator"

$commonCp = ""
if ($commonInfo.Found) {
    Compile-JavaModule -ModuleName "Common" -SourceFiles $commonInfo.Files -OutDir $commonOutDir
    $commonCp = $commonOutDir
}

$serverCp = ""
if (-not $UseExternalServer) {
    Compile-JavaModule -ModuleName "Server (TV1)" -SourceFiles $serverInfo.Files -OutDir $serverOutDir -ExtraClasspath $commonCp
    $serverCp = $(if ($commonCp) { "$serverOutDir;$commonCp" } else { $serverOutDir })
}

$loadGenCp = ""
if ($loadGenInfo.Found -and -not [string]::IsNullOrWhiteSpace($loadGenMainClass)) {
    Compile-JavaModule -ModuleName "LoadGenerator (TV2)" -SourceFiles $loadGenInfo.Files -OutDir $loadGenOutDir -ExtraClasspath $commonCp
    $loadGenCp = $(if ($commonCp) { "$loadGenOutDir;$commonCp" } else { $loadGenOutDir })
}

# =========================================================================
# Prepare Output Directories
# =========================================================================
$runsDir = Join-Path $OutputDir "runs"
$cpuDir = Join-Path $OutputDir "cpu"
$logsDir = Join-Path $OutputDir "logs"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
New-Item -ItemType Directory -Force -Path $runsDir | Out-Null
New-Item -ItemType Directory -Force -Path $cpuDir | Out-Null
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

$masterCsvPath = Join-Path $OutputDir ([string]$config.output.master_csv)
$cpuSummaryCsvPath = Join-Path $OutputDir ([string]$config.output.cpu_summary_csv)
$metadataJsonPath = Join-Path $OutputDir ([string]$config.output.metadata_json)

if (-not $SkipBenchmarks) {
    Get-ChildItem -LiteralPath $runsDir -Filter "c*_run*.csv" -File -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem -LiteralPath $runsDir -Filter "c*_run*.json" -File -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem -LiteralPath $cpuDir -Filter "cpu_c*_run*.csv" -File -ErrorAction SilentlyContinue | Remove-Item -Force
    $oldMxBean = Join-Path $cpuDir "server_cpu_mxbean.csv"
    if (Test-Path -LiteralPath $oldMxBean) { Remove-Item -LiteralPath $oldMxBean -Force }
}

# =========================================================================
# Server Lifecycle + Execution
# =========================================================================
$serverProcess = $null
$startedServer = $false
$monitoredServerPid = 0
$tv1CpuLogPath = ""
$benchmarkFailed = $false
$validationExitCode = 0
$inv = [System.Globalization.CultureInfo]::InvariantCulture

$serverStdoutLog = Join-Path $logsDir "server_stdout.log"
$serverStderrLog = Join-Path $logsDir "server_stderr.log"

try {
    if ($UseExternalServer) {
        if (-not (Test-TcpPortOpen -TargetHost $targetHost -TargetPort $targetPort)) {
            throw "UseExternalServer specified, but ${targetHost}:${targetPort} is not reachable."
        }
        $monitoredServerPid = Get-ListeningPidByPort -TargetPort $targetPort
        Write-Host "[SERVER] Connected to external server at ${targetHost}:${targetPort} (detected PID=$monitoredServerPid)"
    } else {
        if (Test-TcpPortOpen -TargetHost $targetHost -TargetPort $targetPort) {
            $existingPid = Get-ListeningPidByPort -TargetPort $targetPort
            throw "Port $targetPort is already in use (PID=$existingPid). Stop it or pass -UseExternalServer."
        }

        $serverLaunchArgs = @()
        if ($effectiveServerArgs.Count -gt 0) {
            $serverLaunchArgs += $effectiveServerArgs
        }
        if (-not ($serverLaunchArgs -contains "--host")) {
            $serverLaunchArgs += @("--host", $targetHost)
        }
        if (-not ($serverLaunchArgs -contains "--port")) {
            $serverLaunchArgs += @("--port", "$targetPort")
        }
        if ($useTv1CpuLog -and -not $SkipBenchmarks) {
            if (-not ($serverLaunchArgs -contains "--cpu-log")) {
                $tv1CpuLogPath = Join-Path $cpuDir "server_cpu_mxbean.csv"
                if (Test-Path -LiteralPath $tv1CpuLogPath) { Remove-Item -LiteralPath $tv1CpuLogPath -Force }
                $serverLaunchArgs += @("--cpu-log", $tv1CpuLogPath)
            } else {
                $idxLog = [Array]::IndexOf($serverLaunchArgs, "--cpu-log")
                if ($idxLog -ge 0 -and ($idxLog + 1) -lt $serverLaunchArgs.Count) {
                    $tv1CpuLogPath = $serverLaunchArgs[$idxLog + 1]
                }
            }
            if (-not ($serverLaunchArgs -contains "--cpu-interval-ms")) {
                $serverLaunchArgs += @("--cpu-interval-ms", "$cpuIntervalMs")
            }
        }

        $javaServerArgs = @()
        $javaServerArgs += $serverJvmArgs
        $javaServerArgs += @("-cp", $serverCp, $serverMainClass)
        if ($serverLaunchArgs.Count -gt 0) {
            $javaServerArgs += $serverLaunchArgs
        }

        $javaServerArgString = Join-Win32Args -ArgsList $javaServerArgs
        Write-Host "[SERVER] Launching: `"$javaExe`" $javaServerArgString"
        $serverProcess = Start-Process -FilePath $javaExe -ArgumentList $javaServerArgString `
            -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $serverStdoutLog -RedirectStandardError $serverStderrLog
        $null = $serverProcess.Handle
        $startedServer = $true

        Wait-ServerReady -TargetHost $targetHost -TargetPort $targetPort -ServerProcess $serverProcess `
            -TimeoutSec $startupTimeoutSec -StdOutLog $serverStdoutLog -StdErrLog $serverStderrLog

        $listeningPid = Get-ListeningPidByPort -TargetPort $targetPort
        $monitoredServerPid = $(if ($listeningPid -gt 0) { $listeningPid } else { $serverProcess.Id })
        Write-Host "[SERVER] Ready on ${targetHost}:${targetPort} (PID=$monitoredServerPid)"
    }

    if (-not $SkipBenchmarks) {
        $masterLines = New-Object System.Collections.Generic.List[string]
        $masterLines.Add("run_id,clients,duration_sec,payload_bytes,total_success,total_errors,throughput_req_s,avg_latency_ms,p95_latency_ms,error_rate_percent")

        $cpuSummaryLines = New-Object System.Collections.Generic.List[string]
        $cpuSummaryLines.Add("run_id,clients,samples,avg_cpu_percent,max_cpu_percent,min_cpu_percent,p95_cpu_percent,avg_cpu_one_core_percent,avg_system_cpu_percent,avg_working_set_mb")

        $logicalCores = [Environment]::ProcessorCount
        $totalSteps = $resolvedClients.Count * $Runs
        $stepIdx = 0

        foreach ($clientCount in $resolvedClients) {
            for ($runId = 1; $runId -le $Runs; $runId++) {
                $stepIdx++
                Write-Host ""
                Write-Host "--------------------------------------------------------"
                Write-Host "[BENCHMARK $stepIdx/$totalSteps] Clients=$clientCount | Run=$runId | Warmup=${WarmupSec}s | Duration=${DurationSec}s | Payload=${PayloadBytes}B"
                Write-Host "--------------------------------------------------------"

                $runCsvPath = Join-Path $runsDir ("c{0}_run{1}.csv" -f $clientCount, $runId)
                $runJsonPath = Join-Path $runsDir ("c{0}_run{1}.json" -f $clientCount, $runId)
                $runCpuCsvPath = Join-Path $cpuDir ("cpu_c{0}_run{1}.csv" -f $clientCount, $runId)
                $lgOutLog = Join-Path $logsDir ("loadgen_c{0}_run{1}.out.log" -f $clientCount, $runId)
                $lgErrLog = Join-Path $logsDir ("loadgen_c{0}_run{1}.err.log" -f $clientCount, $runId)

                if (Test-Path -LiteralPath $runCsvPath) { Remove-Item -LiteralPath $runCsvPath -Force }
                if (Test-Path -LiteralPath $runJsonPath) { Remove-Item -LiteralPath $runJsonPath -Force }

                $lgArgs = @()
                $lgArgs += $loadGenJvmArgs
                $lgArgs += @(
                    "-cp", $loadGenCp,
                    $loadGenMainClass,
                    "--host", $targetHost,
                    "--port", "$targetPort",
                    "--clients", "$clientCount",
                    "--duration", "$DurationSec",
                    "--warmup", "$WarmupSec",
                    "--payload", "$PayloadBytes",
                    "--run-id", "$runId",
                    "--csv", $runCsvPath,
                    "--json", $runJsonPath
                )

                $lgArgString = Join-Win32Args -ArgsList $lgArgs
                $lgProc = Start-Process -FilePath $javaExe -ArgumentList $lgArgString `
                    -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru `
                    -RedirectStandardOutput $lgOutLog -RedirectStandardError $lgErrLog
                $null = $lgProc.Handle

                # Wait out warmup window while checking process health
                if ($WarmupSec -gt 0) {
                    $warmupSw = [System.Diagnostics.Stopwatch]::StartNew()
                    while (-not $lgProc.HasExited -and $warmupSw.Elapsed.TotalSeconds -lt $WarmupSec) {
                        Start-Sleep -Milliseconds 200
                    }
                }

                # Sample server WorkingSet64 and fallback CPU during active measurement window
                $measureStartEpochMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                $psCpuSamples = New-Object System.Collections.Generic.List[double]
                $wsSamples = New-Object System.Collections.Generic.List[double]
                $psCpuDetailRows = New-Object System.Collections.Generic.List[object]

                $monProc = $null
                if ($monitoredServerPid -gt 0) {
                    $monProc = Get-Process -Id $monitoredServerPid -ErrorAction SilentlyContinue
                }

                if ($null -ne $monProc) {
                    $monProc.Refresh()
                    $prevCpuMs = $monProc.TotalProcessorTime.TotalMilliseconds
                    $intervalSw = [System.Diagnostics.Stopwatch]::StartNew()
                    $measureSw = [System.Diagnostics.Stopwatch]::StartNew()

                    while (-not $lgProc.HasExited -and $measureSw.Elapsed.TotalSeconds -lt $DurationSec) {
                        $remainingMs = [int](($DurationSec * 1000.0) - $measureSw.Elapsed.TotalMilliseconds)
                        if ($remainingMs -le 0) { break }
                        $sleepMs = [Math]::Min($cpuIntervalMs, $remainingMs)
                        if ($sleepMs -lt 100) { $sleepMs = 100 }
                        Start-Sleep -Milliseconds $sleepMs

                        $monProc = Get-Process -Id $monitoredServerPid -ErrorAction SilentlyContinue
                        if ($null -eq $monProc -or $monProc.HasExited) { break }
                        $monProc.Refresh()

                        $wallMs = $intervalSw.Elapsed.TotalMilliseconds
                        $nowCpuMs = $monProc.TotalProcessorTime.TotalMilliseconds
                        $intervalSw.Restart()

                        if ($wallMs -gt 0) {
                            $deltaCpuMs = $nowCpuMs - $prevCpuMs
                            $cpuPct = ($deltaCpuMs / ($wallMs * $logicalCores)) * 100.0
                            $cpuPct = [Math]::Max(0.0, [Math]::Min(100.0, $cpuPct))
                            $wsMb = $monProc.WorkingSet64 / 1MB

                            $psCpuSamples.Add($cpuPct)
                            $wsSamples.Add($wsMb)

                            $psCpuDetailRows.Add([PSCustomObject]@{
                                epoch_ms     = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                                elapsed_sec  = $measureSw.Elapsed.TotalSeconds
                                cpu_pct      = $cpuPct
                                one_core_pct = ($cpuPct * $logicalCores)
                                ws_mb        = $wsMb
                            })
                        }
                        $prevCpuMs = $nowCpuMs
                    }
                } else {
                    Write-Warning "Server PID unavailable; skipping fallback CPU/memory sampling for c=${clientCount}, run=${runId}."
                }
                $measureEndEpochMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

                $waitMs = ($DurationSec + 30) * 1000
                if (-not $lgProc.WaitForExit($waitMs)) {
                    Stop-ProcessTree -TargetPid $lgProc.Id
                    throw "LoadGeneratorApp timed out for clients=$clientCount run=$runId"
                }
                $lgProc.WaitForExit()

                if ($lgProc.ExitCode -ne 0) {
                    $errContent = ""
                    if (Test-Path -LiteralPath $lgErrLog) {
                        $errContent = Get-Content -LiteralPath $lgErrLog -Raw -ErrorAction SilentlyContinue
                    }
                    throw "LoadGeneratorApp exited with code $($lgProc.ExitCode) for clients=$clientCount run=${runId}. Stderr: $errContent"
                }

                if (-not (Test-Path -LiteralPath $runCsvPath) -or -not (Test-Path -LiteralPath $runJsonPath)) {
                    throw "Expected per-run outputs missing for clients=$clientCount run=$runId ($runCsvPath / $runJsonPath)"
                }

                $runCsvLines = @(Get-Content -LiteralPath $runCsvPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($runCsvLines.Count -lt 2) {
                    throw "Per-run CSV $runCsvPath has no data row."
                }
                $dataRow = $runCsvLines[-1].Trim()
                $masterLines.Add($dataRow)

                $avgWs = 0.0
                if ($wsSamples.Count -gt 0) {
                    $sumWs = 0.0
                    foreach ($w in $wsSamples) { $sumWs += $w }
                    $avgWs = $sumWs / $wsSamples.Count
                }

                # Prefer TV1 CpuMonitor (--cpu-log) samples filtered to this measurement window
                $matchedTv1Rows = New-Object System.Collections.Generic.List[object]
                if (-not [string]::IsNullOrWhiteSpace($tv1CpuLogPath)) {
                    Start-Sleep -Milliseconds 200
                    $mxLines = @(Read-SharedCsvLines -Path $tv1CpuLogPath)
                    $minDeltaMs = [Math]::Max(50, [Math]::Min(200, [int]($cpuIntervalMs * 0.5)))
                    $prevMxEp = 0L
                    if ($mxLines.Count -gt 1) {
                        for ($li = 1; $li -lt $mxLines.Count; $li++) {
                            $parts = $mxLines[$li].Split(',')
                            if ($parts.Length -ge 4) {
                                $ep = 0L
                                if ([long]::TryParse($parts[0].Trim(), [ref]$ep)) {
                                    $isCatchup = ($prevMxEp -gt 0 -and ($ep - $prevMxEp) -lt $minDeltaMs)
                                    $prevMxEp = $ep
                                    if (-not $isCatchup -and $ep -ge ($measureStartEpochMs - 200) -and $ep -le ($measureEndEpochMs + 200)) {
                                        $oneCore = 0.0
                                        $normPct = 0.0
                                        if ([double]::TryParse($parts[2].Trim(), [System.Globalization.NumberStyles]::Float, $inv, [ref]$oneCore) -and
                                            [double]::TryParse($parts[3].Trim(), [System.Globalization.NumberStyles]::Float, $inv, [ref]$normPct)) {
                                            $sysVal = $null
                                            if ($parts.Length -ge 5 -and -not [string]::IsNullOrWhiteSpace($parts[4])) {
                                                $tmpSys = 0.0
                                                if ([double]::TryParse($parts[4].Trim(), [System.Globalization.NumberStyles]::Float, $inv, [ref]$tmpSys)) {
                                                    $sysVal = $tmpSys
                                                }
                                            }
                                            $matchedTv1Rows.Add([PSCustomObject]@{
                                                epoch_ms     = $ep
                                                elapsed_sec  = (($ep - $measureStartEpochMs) / 1000.0)
                                                cpu_pct      = $normPct
                                                one_core_pct = $oneCore
                                                sys_pct      = $sysVal
                                            })
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                $cpuDetailLines = New-Object System.Collections.Generic.List[string]
                $cpuDetailLines.Add("sample_index,epoch_ms,elapsed_sec,cpu_percent,cpu_pct_of_one_core,system_cpu_pct,working_set_mb")

                if ($matchedTv1Rows.Count -gt 0) {
                    $normList = New-Object System.Collections.Generic.List[double]
                    $oneCoreList = New-Object System.Collections.Generic.List[double]
                    $sysList = New-Object System.Collections.Generic.List[double]

                    for ($si = 0; $si -lt $matchedTv1Rows.Count; $si++) {
                        $row = $matchedTv1Rows[$si]
                        $normList.Add([double]$row.cpu_pct)
                        $oneCoreList.Add([double]$row.one_core_pct)
                        $sysStr = ""
                        if ($null -ne $row.sys_pct) {
                            $sysList.Add([double]$row.sys_pct)
                            $sysStr = [string]::Format($inv, "{0:F2}", [double]$row.sys_pct)
                        }
                        $rowWs = $avgWs
                        if ($wsSamples.Count -gt 0) {
                            $wsIdx = [Math]::Min($si, $wsSamples.Count - 1)
                            $rowWs = [double]$wsSamples[$wsIdx]
                        }
                        $cpuDetailLines.Add([string]::Format(
                            $inv,
                            "{0},{1},{2:F3},{3:F2},{4:F2},{5},{6:F2}",
                            ($si + 1), $row.epoch_ms, $row.elapsed_sec, $row.cpu_pct, $row.one_core_pct, $sysStr, $rowWs
                        ))
                    }

                    $cpuArr = $normList.ToArray()
                    $sumCpu = 0.0; foreach ($v in $cpuArr) { $sumCpu += $v }
                    $avgCpu = $sumCpu / $cpuArr.Count
                    $maxCpu = ($cpuArr | Measure-Object -Maximum).Maximum
                    $minCpu = ($cpuArr | Measure-Object -Minimum).Minimum
                    $p95Cpu = Get-Percentile -Values $cpuArr -Percentile 95.0

                    $sumOne = 0.0; foreach ($v in $oneCoreList) { $sumOne += $v }
                    $avgOne = $sumOne / $oneCoreList.Count

                    $avgSys = 0.0
                    if ($sysList.Count -gt 0) {
                        $sumSys = 0.0; foreach ($v in $sysList) { $sumSys += $v }
                        $avgSys = $sumSys / $sysList.Count
                    }

                    $cpuSummaryLines.Add([string]::Format(
                        $inv,
                        "{0},{1},{2},{3:F2},{4:F2},{5:F2},{6:F2},{7:F2},{8:F2},{9:F2}",
                        $runId, $clientCount, $cpuArr.Count, $avgCpu, $maxCpu, $minCpu, $p95Cpu, $avgOne, $avgSys, $avgWs
                    ))
                } elseif ($psCpuSamples.Count -gt 0) {
                    for ($si = 0; $si -lt $psCpuDetailRows.Count; $si++) {
                        $row = $psCpuDetailRows[$si]
                        $cpuDetailLines.Add([string]::Format(
                            $inv,
                            "{0},{1},{2:F3},{3:F2},{4:F2},,{5:F2}",
                            ($si + 1), $row.epoch_ms, $row.elapsed_sec, $row.cpu_pct, $row.one_core_pct, $row.ws_mb
                        ))
                    }

                    $cpuArr = $psCpuSamples.ToArray()
                    $sumCpu = 0.0; foreach ($v in $cpuArr) { $sumCpu += $v }
                    $avgCpu = $sumCpu / $cpuArr.Count
                    $maxCpu = ($cpuArr | Measure-Object -Maximum).Maximum
                    $minCpu = ($cpuArr | Measure-Object -Minimum).Minimum
                    $p95Cpu = Get-Percentile -Values $cpuArr -Percentile 95.0
                    $avgOne = $avgCpu * $logicalCores

                    $cpuSummaryLines.Add([string]::Format(
                        $inv,
                        "{0},{1},{2},{3:F2},{4:F2},{5:F2},{6:F2},{7:F2},0.00,{8:F2}",
                        $runId, $clientCount, $cpuArr.Count, $avgCpu, $maxCpu, $minCpu, $p95Cpu, $avgOne, $avgWs
                    ))
                } else {
                    $cpuSummaryLines.Add([string]::Format($inv, "{0},{1},0,0.00,0.00,0.00,0.00,0.00,0.00,0.00", $runId, $clientCount))
                }

                Write-Utf8NoBom -Path $runCpuCsvPath -Content (($cpuDetailLines.ToArray() -join "`n") + "`n")

                Write-Host "[RUN COMPLETE] $dataRow"

                if ($stepIdx -lt $totalSteps -and $CooldownSec -gt 0) {
                    Write-Host "[COOLDOWN] Waiting ${CooldownSec}s..."
                    Start-Sleep -Seconds $CooldownSec
                }
            }
        }

        Write-Utf8NoBom -Path $masterCsvPath -Content (($masterLines.ToArray() -join "`n") + "`n")
        Write-Utf8NoBom -Path $cpuSummaryCsvPath -Content (($cpuSummaryLines.ToArray() -join "`n") + "`n")
        Write-Host ""
        Write-Host "[ARTIFACT] Master benchmark CSV : $masterCsvPath"
        Write-Host "[ARTIFACT] CPU summary CSV      : $cpuSummaryCsvPath"
    }

    Export-EnvironmentMetadata -Path $metadataJsonPath -TargetHost $targetHost -TargetPort $targetPort `
        -ClientLevels $resolvedClients -RunsPerLevel $Runs -Warmup $WarmupSec -Duration $DurationSec `
        -Payload $PayloadBytes -Cooldown $CooldownSec -ExternalServer ([bool]$UseExternalServer) `
        -ServerMain $serverMainClass -LoadGenMain $loadGenMainClass
    Write-Host "[ARTIFACT] Environment metadata : $metadataJsonPath"

    if (-not $SkipValidation) {
        $valScript = Join-Path $PSScriptRoot "run_validation_tests.ps1"
        if (-not (Test-Path -LiteralPath $valScript)) {
            throw "Validation script not found: $valScript"
        }

        Write-Host ""
        Write-Host "================ RUNNING VALIDATION TESTS ================"
        $valParams = @{
            ConfigPath = $ConfigPath
            HostName   = $targetHost
            Port       = $targetPort
            OutputDir  = $OutputDir
            ServerPid  = $monitoredServerPid
        }
        if (-not $SkipBenchmarks -and (Test-Path -LiteralPath $masterCsvPath)) {
            $valParams["BenchmarkCsvPath"] = $masterCsvPath
        }
        if (-not [string]::IsNullOrWhiteSpace($loadGenCp) -and -not [string]::IsNullOrWhiteSpace($loadGenMainClass)) {
            $valParams["LoadGenClasspath"] = $loadGenCp
            $valParams["LoadGenMainClass"] = $loadGenMainClass
        }

        & $valScript @valParams
        $validationExitCode = $LASTEXITCODE
    }
} catch {
    $benchmarkFailed = $true
    Write-Error $_.Exception.Message
} finally {
    if ($startedServer) {
        if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
            Write-Host "[SERVER] Stopping TCPEchoServer (PID=$($serverProcess.Id))..."
            Stop-ProcessTree -TargetPid $serverProcess.Id
            try { $serverProcess.WaitForExit(3000) | Out-Null } catch {}
        }
        if ($monitoredServerPid -gt 0 -and ($null -eq $serverProcess -or $monitoredServerPid -ne $serverProcess.Id)) {
            $rem = Get-Process -Id $monitoredServerPid -ErrorAction SilentlyContinue
            if ($null -ne $rem -and -not $rem.HasExited) {
                Stop-ProcessTree -TargetPid $monitoredServerPid
            }
        }
    }
}

if ($benchmarkFailed -or $validationExitCode -ne 0) {
    exit 1
}

Write-Host ""
Write-Host "[DONE] Member 3 (TV3) benchmark & validation pipeline completed successfully."
exit 0
