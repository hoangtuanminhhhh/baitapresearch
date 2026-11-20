<#
.SYNOPSIS
    Runs the 4 mandatory validation test cases (TC1-TC4) for Member 3 (TV3).
.DESCRIPTION
    Executes and verifies:
      TC1: 1 Client vs 50 Clients load & stability check
      TC2: Integrity verification of requestId and payload (boundary sizes, edge IDs, fragmentation, pipelining, concurrency)
      TC3: Abrupt client disconnect (OS Kill Task / TerminateProcess + TCP RST half-frame)
      TC4: Invalid / oversized frame rejection (N > MAX_BODY, N < ID_BYTES, truncated header)
    Outputs validation_results.csv and validation_report.json (UTF-8 without BOM).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [string]$HostName = "",
    [int]$Port = 0,
    [string]$OutputDir = "",
    [string]$BenchmarkCsvPath = "",
    [string]$LoadGenClasspath = "",
    [string]$LoadGenMainClass = "",
    [int]$ServerPid = 0,
    [switch]$UseLoadGenForTC1
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

function ConvertTo-CsvField {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    $escaped = $Value.Replace('"', '""')
    return '"' + $escaped + '"'
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

function Get-ArrayMean {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return 0.0 }
    $sum = 0.0
    foreach ($v in $Values) { $sum += $v }
    return $sum / $Values.Count
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$javaExe = Resolve-JavaTool -ToolName "java"

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

if ([string]::IsNullOrWhiteSpace($HostName)) {
    $HostName = [string]$config.server.host
}
if ($Port -le 0) {
    $Port = [int]$config.server.port
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Resolve-RepoPath -BaseDir $repoRoot -TargetPath ([string]$config.output.raw_data_dir)
} else {
    $OutputDir = Resolve-RepoPath -BaseDir (Get-Location).Path -TargetPath $OutputDir
}

$logsDir = Join-Path $OutputDir "logs"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

$jvmArgs = @("-Duser.language=en", "-Duser.country=US")
if ($config.load_generator.jvm_args) {
    $configuredArgs = @($config.load_generator.jvm_args)
    if ($configuredArgs.Count -gt 0) {
        $jvmArgs = $configuredArgs
    }
}

if (-not ("TcpProtocolValidator" -as [type])) {
    $csharpSource = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

public class ValidationStepResult {
    public bool Success;
    public string Message;
    public long TotalFramesVerified;
    public long Mismatches;
    public long Errors;

    public ValidationStepResult() {
        Success = false;
        Message = "";
        TotalFramesVerified = 0;
        Mismatches = 0;
        Errors = 0;
    }
}

public class BuiltInLoadResult {
    public bool Success;
    public string Message;
    public int Clients;
    public long TotalSuccess;
    public long TotalErrors;
    public double ThroughputReqS;
    public double AvgLatencyMs;
    public double P95LatencyMs;
    public double ErrorRatePercent;

    public BuiltInLoadResult() {
        Success = false;
        Message = "";
    }
}

public static class TcpProtocolValidator {
    private static readonly object SyncLock = new object();

    private sealed class LoadRunState {
        public volatile bool Running = true;
        public volatile bool Recording = false;
        public long TotalSuccess = 0;
        public long TotalErrors = 0;
        public long ReqCounter = 1;
    }

    private static void WriteInt32BE(byte[] buf, int offset, int value) {
        buf[offset]     = (byte)((value >> 24) & 0xFF);
        buf[offset + 1] = (byte)((value >> 16) & 0xFF);
        buf[offset + 2] = (byte)((value >> 8) & 0xFF);
        buf[offset + 3] = (byte)(value & 0xFF);
    }

    private static void WriteInt64BE(byte[] buf, int offset, long value) {
        buf[offset]     = (byte)((value >> 56) & 0xFF);
        buf[offset + 1] = (byte)((value >> 48) & 0xFF);
        buf[offset + 2] = (byte)((value >> 40) & 0xFF);
        buf[offset + 3] = (byte)((value >> 32) & 0xFF);
        buf[offset + 4] = (byte)((value >> 24) & 0xFF);
        buf[offset + 5] = (byte)((value >> 16) & 0xFF);
        buf[offset + 6] = (byte)((value >> 8) & 0xFF);
        buf[offset + 7] = (byte)(value & 0xFF);
    }

    private static int ReadInt32BE(byte[] buf, int offset) {
        return ((buf[offset] & 0xFF) << 24)
             | ((buf[offset + 1] & 0xFF) << 16)
             | ((buf[offset + 2] & 0xFF) << 8)
             | (buf[offset + 3] & 0xFF);
    }

    private static long ReadInt64BE(byte[] buf, int offset) {
        ulong val = (((ulong)buf[offset]) << 56)
                  | (((ulong)buf[offset + 1]) << 48)
                  | (((ulong)buf[offset + 2]) << 40)
                  | (((ulong)buf[offset + 3]) << 32)
                  | (((ulong)buf[offset + 4]) << 24)
                  | (((ulong)buf[offset + 5]) << 16)
                  | (((ulong)buf[offset + 6]) << 8)
                  | ((ulong)buf[offset + 7]);
        return unchecked((long)val);
    }

    private static bool ReadExact(NetworkStream stream, byte[] buf, int offset, int count) {
        int totalRead = 0;
        while (totalRead < count) {
            int n = stream.Read(buf, offset + totalRead, count - totalRead);
            if (n <= 0) {
                return false;
            }
            totalRead += n;
        }
        return true;
    }

    private static byte[] BuildFrame(long requestId, byte[] payload) {
        int payloadLen = (payload == null) ? 0 : payload.Length;
        int bodyLen = 8 + payloadLen;
        byte[] frame = new byte[4 + bodyLen];
        WriteInt32BE(frame, 0, bodyLen);
        WriteInt64BE(frame, 4, requestId);
        if (payloadLen > 0) {
            Buffer.BlockCopy(payload, 0, frame, 12, payloadLen);
        }
        return frame;
    }

    private static byte[] CreatePatternPayload(int length, long seed) {
        byte[] data = new byte[length];
        if (length == 0) return data;
        uint state = (uint)(seed ^ (seed >> 32)) * 2654435761u + 17u;
        for (int i = 0; i < length; i++) {
            state = state * 1664525u + 1013904223u;
            data[i] = (byte)((state >> 16) & 0xFF);
        }
        return data;
    }

    private static bool ReadAndVerifyFrame(NetworkStream stream, long expectedId, byte[] expectedPayload, out string errorDetail) {
        errorDetail = "";
        int expectedPayloadLen = (expectedPayload == null) ? 0 : expectedPayload.Length;
        int expectedBodyLen = 8 + expectedPayloadLen;

        byte[] headerBuf = new byte[4];
        if (!ReadExact(stream, headerBuf, 0, 4)) {
            errorDetail = "EOF while reading 4-byte length header";
            return false;
        }
        int respBodyLen = ReadInt32BE(headerBuf, 0);
        if (respBodyLen != expectedBodyLen) {
            errorDetail = string.Format("Length mismatch: expected {0}, got {1}", expectedBodyLen, respBodyLen);
            return false;
        }

        byte[] idBuf = new byte[8];
        if (!ReadExact(stream, idBuf, 0, 8)) {
            errorDetail = "EOF while reading 8-byte requestId";
            return false;
        }
        long respId = ReadInt64BE(idBuf, 0);
        if (respId != expectedId) {
            errorDetail = string.Format("requestId mismatch: expected {0}, got {1}", expectedId, respId);
            return false;
        }

        if (expectedPayloadLen > 0) {
            byte[] respPayload = new byte[expectedPayloadLen];
            if (!ReadExact(stream, respPayload, 0, expectedPayloadLen)) {
                errorDetail = string.Format("EOF while reading payload ({0} bytes)", expectedPayloadLen);
                return false;
            }
            for (int i = 0; i < expectedPayloadLen; i++) {
                if (respPayload[i] != expectedPayload[i]) {
                    errorDetail = string.Format("Payload byte mismatch at index {0}: expected 0x{1:X2}, got 0x{2:X2}",
                        i, expectedPayload[i], respPayload[i]);
                    return false;
                }
            }
        }
        return true;
    }

    public static ValidationStepResult RunIntegritySuite(
        string host,
        int port,
        int[] payloadSizes,
        int concurrentClients,
        int requestsPerClient,
        int pipelinedFrames,
        int fragmentedPayloadBytes,
        int timeoutMs)
    {
        ValidationStepResult result = new ValidationStepResult();
        long verified = 0;
        long mismatches = 0;
        long errors = 0;
        string firstFailure = "";

        long[] edgeIds = new long[] {
            0L,
            1L,
            -1L,
            long.MaxValue,
            long.MinValue,
            0x0123456789ABCDEFL
        };

        // 2a: Boundary payload sizes and edge requestId values
        try {
            using (TcpClient client = new TcpClient()) {
                client.NoDelay = true;
                client.ReceiveTimeout = timeoutMs;
                client.SendTimeout = timeoutMs;
                client.Connect(host, port);
                NetworkStream stream = client.GetStream();

                long seq = 1000L;
                for (int i = 0; i < payloadSizes.Length; i++) {
                    int size = payloadSizes[i];
                    long reqId = edgeIds[i % edgeIds.Length];
                    byte[] payload = CreatePatternPayload(size, seq++);
                    byte[] frame = BuildFrame(reqId, payload);
                    stream.Write(frame, 0, frame.Length);
                    stream.Flush();

                    string err;
                    if (ReadAndVerifyFrame(stream, reqId, payload, out err)) {
                        verified++;
                    } else {
                        mismatches++;
                        if (firstFailure.Length == 0) firstFailure = string.Format("SizeMatrix({0}B): {1}", size, err);
                        break;
                    }
                }

                for (int j = 0; j < edgeIds.Length; j++) {
                    long reqId = edgeIds[j];
                    byte[] payload = CreatePatternPayload(1024, 50000L + j);
                    byte[] frame = BuildFrame(reqId, payload);
                    stream.Write(frame, 0, frame.Length);
                    stream.Flush();

                    string err;
                    if (ReadAndVerifyFrame(stream, reqId, payload, out err)) {
                        verified++;
                    } else {
                        mismatches++;
                        if (firstFailure.Length == 0) firstFailure = string.Format("EdgeId({0}): {1}", reqId, err);
                        break;
                    }
                }
            }
        } catch (Exception ex) {
            errors++;
            if (firstFailure.Length == 0) firstFailure = "Subtest 2a exception: " + ex.Message;
        }

        // 2b: TCP fragmentation (split frame across 4 writes) & coalescing (pipelined burst)
        try {
            using (TcpClient client = new TcpClient()) {
                client.NoDelay = true;
                client.ReceiveTimeout = timeoutMs;
                client.SendTimeout = timeoutMs;
                client.Connect(host, port);
                NetworkStream stream = client.GetStream();

                long fragId = 0x55AA123456789ABCL;
                byte[] fragPayload = CreatePatternPayload(fragmentedPayloadBytes, fragId);
                byte[] fragFrame = BuildFrame(fragId, fragPayload);

                // Split inside 4-byte length header (2), across header+id (6), inside payload (half), remainder
                int c1 = Math.Min(2, fragFrame.Length);
                int c2 = Math.Min(6, fragFrame.Length - c1);
                int c3 = Math.Min(250, fragFrame.Length - c1 - c2);
                int c4 = fragFrame.Length - c1 - c2 - c3;
                int offset = 0;
                int[] chunks = new int[] { c1, c2, c3, c4 };
                for (int c = 0; c < chunks.Length; c++) {
                    if (chunks[c] > 0) {
                        stream.Write(fragFrame, offset, chunks[c]);
                        stream.Flush();
                        offset += chunks[c];
                        Thread.Sleep(20);
                    }
                }

                string fragErr;
                if (ReadAndVerifyFrame(stream, fragId, fragPayload, out fragErr)) {
                    verified++;
                } else {
                    mismatches++;
                    if (firstFailure.Length == 0) firstFailure = "Fragmentation: " + fragErr;
                }

                // Coalescing / Pipelining: write all pipelinedFrames in a single Write call
                List<long> pipeIds = new List<long>();
                List<byte[]> pipePayloads = new List<byte[]>();
                using (MemoryStream ms = new MemoryStream()) {
                    for (int k = 0; k < pipelinedFrames; k++) {
                        long pid = 700000L + k;
                        int pSize = (k % 3 == 0) ? 128 : ((k % 3 == 1) ? 1024 : 2048);
                        byte[] pp = CreatePatternPayload(pSize, pid * 13);
                        byte[] pf = BuildFrame(pid, pp);
                        pipeIds.Add(pid);
                        pipePayloads.Add(pp);
                        ms.Write(pf, 0, pf.Length);
                    }
                    byte[] combined = ms.ToArray();
                    stream.Write(combined, 0, combined.Length);
                    stream.Flush();
                }

                for (int k = 0; k < pipelinedFrames; k++) {
                    string pipeErr;
                    if (ReadAndVerifyFrame(stream, pipeIds[k], pipePayloads[k], out pipeErr)) {
                        verified++;
                    } else {
                        mismatches++;
                        if (firstFailure.Length == 0) firstFailure = string.Format("Pipeline[{0}]: {1}", k, pipeErr);
                        break;
                    }
                }
            }
        } catch (Exception ex) {
            errors++;
            if (firstFailure.Length == 0) firstFailure = "Subtest 2b exception: " + ex.Message;
        }

        // 2c: Concurrent multi-client integrity
        long globalSeq = 9000000L;
        Task[] tasks = new Task[concurrentClients];
        for (int t = 0; t < concurrentClients; t++) {
            int clientIdx = t;
            tasks[t] = Task.Run(() => {
                try {
                    using (TcpClient client = new TcpClient()) {
                        client.NoDelay = true;
                        client.ReceiveTimeout = timeoutMs;
                        client.SendTimeout = timeoutMs;
                        client.Connect(host, port);
                        NetworkStream stream = client.GetStream();

                        for (int r = 0; r < requestsPerClient; r++) {
                            long reqId = Interlocked.Increment(ref globalSeq);
                            byte[] payload = CreatePatternPayload(1024, reqId + (long)clientIdx * 31L);
                            byte[] frame = BuildFrame(reqId, payload);
                            stream.Write(frame, 0, frame.Length);
                            stream.Flush();

                            string err;
                            if (ReadAndVerifyFrame(stream, reqId, payload, out err)) {
                                Interlocked.Increment(ref verified);
                            } else {
                                Interlocked.Increment(ref mismatches);
                                lock (SyncLock) {
                                    if (firstFailure.Length == 0) {
                                        firstFailure = string.Format("Concurrent(c={0},r={1}): {2}", clientIdx, r, err);
                                    }
                                }
                                break;
                            }
                        }
                    }
                } catch (Exception ex) {
                    Interlocked.Increment(ref errors);
                    lock (SyncLock) {
                        if (firstFailure.Length == 0) {
                            firstFailure = string.Format("Concurrent(c={0}) exception: {1}", clientIdx, ex.Message);
                        }
                    }
                }
            });
        }
        Task.WaitAll(tasks);

        long expectedTotal = payloadSizes.Length + edgeIds.Length + 1 + pipelinedFrames + ((long)concurrentClients * requestsPerClient);
        result.TotalFramesVerified = verified;
        result.Mismatches = mismatches;
        result.Errors = errors;
        result.Success = (mismatches == 0 && errors == 0 && verified == expectedTotal);
        if (result.Success) {
            result.Message = string.Format("Verified {0}/{1} frames (sizes={2}, edgeIds={3}, frag=1, pipeline={4}, concurrent={5}x{6}); mismatches=0; errors=0",
                verified, expectedTotal, payloadSizes.Length, edgeIds.Length, pipelinedFrames, concurrentClients, requestsPerClient);
        } else {
            result.Message = string.Format("Verified {0}/{1}; mismatches={2}; errors={3}; first={4}",
                verified, expectedTotal, mismatches, errors, firstFailure);
        }
        return result;
    }

    public static BuiltInLoadResult RunBuiltInLoadTest(
        string host,
        int port,
        int clients,
        int warmupSec,
        int durationSec,
        int payloadBytes)
    {
        BuiltInLoadResult res = new BuiltInLoadResult();
        res.Clients = clients;

        LoadRunState state = new LoadRunState();
        List<double> latenciesMs = new List<double>();
        object listLock = new object();

        Task[] tasks = new Task[clients];
        for (int c = 0; c < clients; c++) {
            int workerIdx = c;
            tasks[c] = Task.Run(() => {
                byte[] payload = CreatePatternPayload(payloadBytes, 42L + workerIdx);
                List<double> localLatencies = new List<double>();
                try {
                    using (TcpClient client = new TcpClient()) {
                        client.NoDelay = true;
                        client.ReceiveTimeout = 5000;
                        client.SendTimeout = 5000;
                        client.Connect(host, port);
                        NetworkStream stream = client.GetStream();

                        while (state.Running) {
                            long reqId = Interlocked.Increment(ref state.ReqCounter);
                            byte[] frame = BuildFrame(reqId, payload);
                            long startTick = Stopwatch.GetTimestamp();
                            try {
                                stream.Write(frame, 0, frame.Length);
                                stream.Flush();
                                string err;
                                if (ReadAndVerifyFrame(stream, reqId, payload, out err)) {
                                    long endTick = Stopwatch.GetTimestamp();
                                    if (state.Recording) {
                                        double ms = (endTick - startTick) * 1000.0 / Stopwatch.Frequency;
                                        localLatencies.Add(ms);
                                        Interlocked.Increment(ref state.TotalSuccess);
                                    }
                                } else {
                                    if (state.Recording) Interlocked.Increment(ref state.TotalErrors);
                                    break;
                                }
                            } catch {
                                if (state.Recording && state.Running) {
                                    Interlocked.Increment(ref state.TotalErrors);
                                }
                                break;
                            }
                        }
                    }
                } catch {
                    if (state.Recording && state.Running) {
                        Interlocked.Increment(ref state.TotalErrors);
                    }
                }
                if (localLatencies.Count > 0) {
                    lock (listLock) {
                        latenciesMs.AddRange(localLatencies);
                    }
                }
            });
        }

        if (warmupSec > 0) {
            Thread.Sleep(warmupSec * 1000);
        }
        state.Recording = true;
        Thread.Sleep(durationSec * 1000);
        state.Recording = false;
        state.Running = false;
        Task.WaitAll(tasks, 5000);

        long totalSuccess = Interlocked.Read(ref state.TotalSuccess);
        long totalErrors = Interlocked.Read(ref state.TotalErrors);
        res.TotalSuccess = totalSuccess;
        res.TotalErrors = totalErrors;
        long total = totalSuccess + totalErrors;
        res.ThroughputReqS = (durationSec > 0) ? ((double)totalSuccess / durationSec) : 0.0;
        res.ErrorRatePercent = (total == 0) ? 0.0 : ((double)totalErrors / total) * 100.0;

        if (latenciesMs.Count > 0) {
            latenciesMs.Sort();
            double sum = 0.0;
            for (int i = 0; i < latenciesMs.Count; i++) sum += latenciesMs[i];
            res.AvgLatencyMs = sum / latenciesMs.Count;
            int p95Idx = (int)Math.Ceiling(0.95 * latenciesMs.Count) - 1;
            p95Idx = Math.Max(0, Math.Min(p95Idx, latenciesMs.Count - 1));
            res.P95LatencyMs = latenciesMs[p95Idx];
        }

        res.Success = (totalSuccess > 0);
        res.Message = string.Format("clients={0}, success={1}, errors={2}, throughput={3:F2} req/s, avg={4:F4} ms, p95={5:F4} ms, err={6:F2}%",
            clients, totalSuccess, totalErrors, res.ThroughputReqS, res.AvgLatencyMs, res.P95LatencyMs, res.ErrorRatePercent);
        return res;
    }

    public static ValidationStepResult RunHalfFrameRstBurst(string host, int port, int socketCount) {
        ValidationStepResult res = new ValidationStepResult();
        int sentCount = 0;
        try {
            for (int i = 0; i < socketCount; i++) {
                using (TcpClient client = new TcpClient()) {
                    client.NoDelay = true;
                    client.Connect(host, port);
                    NetworkStream stream = client.GetStream();
                    byte[] partial = new byte[104];
                    WriteInt32BE(partial, 0, 1032);
                    stream.Write(partial, 0, partial.Length);
                    stream.Flush();
                    client.LingerState = new LingerOption(true, 0);
                    client.Close();
                    sentCount++;
                }
            }
            res.Success = (sentCount == socketCount);
            res.TotalFramesVerified = sentCount;
            res.Message = string.Format("Sent {0}/{1} half-frame TCP RST sockets", sentCount, socketCount);
        } catch (Exception ex) {
            res.Success = false;
            res.Errors = 1;
            res.Message = "Half-frame RST burst failed: " + ex.Message;
        }
        return res;
    }

    public static ValidationStepResult TestInvalidLengthRejected(
        string host,
        int port,
        int invalidLength,
        int extraBytesCount,
        int timeoutMs)
    {
        ValidationStepResult res = new ValidationStepResult();
        try {
            using (TcpClient client = new TcpClient()) {
                client.NoDelay = true;
                client.ReceiveTimeout = timeoutMs;
                client.SendTimeout = timeoutMs;
                client.Connect(host, port);
                NetworkStream stream = client.GetStream();

                byte[] header = new byte[4];
                WriteInt32BE(header, 0, invalidLength);
                stream.Write(header, 0, 4);
                stream.Flush();

                if (extraBytesCount > 0) {
                    try {
                        byte[] extra = new byte[extraBytesCount];
                        stream.Write(extra, 0, extra.Length);
                        stream.Flush();
                    } catch (IOException) {
                        res.Success = true;
                        res.TotalFramesVerified = 1;
                        res.Message = string.Format("Length {0} rejected immediately during extra write (connection closed)", invalidLength);
                        return res;
                    }
                }

                byte[] probe = new byte[64];
                try {
                    int n = stream.Read(probe, 0, probe.Length);
                    if (n == 0) {
                        res.Success = true;
                        res.TotalFramesVerified = 1;
                        res.Message = string.Format("Length {0} closed cleanly with EOF (FIN)", invalidLength);
                    } else {
                        res.Success = false;
                        res.Mismatches = 1;
                        res.Message = string.Format("Length {0} unexpectedly received {1} bytes back instead of closing", invalidLength, n);
                    }
                } catch (IOException ioEx) {
                    SocketException sockEx = ioEx.InnerException as SocketException;
                    if (sockEx != null && sockEx.SocketErrorCode == SocketError.TimedOut) {
                        res.Success = false;
                        res.Errors = 1;
                        res.Message = string.Format("Length {0} timed out after {1} ms without server closing", invalidLength, timeoutMs);
                    } else {
                        res.Success = true;
                        res.TotalFramesVerified = 1;
                        res.Message = string.Format("Length {0} rejected with socket close/RST", invalidLength);
                    }
                }
            }
        } catch (Exception ex) {
            res.Success = false;
            res.Errors = 1;
            res.Message = string.Format("Length {0} probe failed to connect: {1}", invalidLength, ex.Message);
        }
        return res;
    }

    public static ValidationStepResult TestTruncatedHeaderRejected(string host, int port, int timeoutMs) {
        ValidationStepResult res = new ValidationStepResult();
        try {
            using (TcpClient client = new TcpClient()) {
                client.NoDelay = true;
                client.ReceiveTimeout = timeoutMs;
                client.SendTimeout = timeoutMs;
                client.Connect(host, port);
                NetworkStream stream = client.GetStream();

                byte[] twoBytes = new byte[] { 0x00, 0x00 };
                stream.Write(twoBytes, 0, 2);
                stream.Flush();
                client.Client.Shutdown(SocketShutdown.Send);

                byte[] probe = new byte[16];
                try {
                    int n = stream.Read(probe, 0, probe.Length);
                    if (n == 0) {
                        res.Success = true;
                        res.TotalFramesVerified = 1;
                        res.Message = "Truncated 2-byte header closed cleanly with EOF";
                    } else {
                        res.Success = false;
                        res.Mismatches = 1;
                        res.Message = string.Format("Truncated header returned {0} bytes unexpectedly", n);
                    }
                } catch (IOException ioEx) {
                    SocketException sockEx = ioEx.InnerException as SocketException;
                    if (sockEx != null && sockEx.SocketErrorCode == SocketError.TimedOut) {
                        res.Success = false;
                        res.Errors = 1;
                        res.Message = "Truncated 2-byte header timed out";
                    } else {
                        res.Success = true;
                        res.TotalFramesVerified = 1;
                        res.Message = "Truncated 2-byte header closed by server";
                    }
                }
            }
        } catch (Exception ex) {
            res.Success = false;
            res.Errors = 1;
            res.Message = "Truncated header probe failed: " + ex.Message;
        }
        return res;
    }

    public static ValidationStepResult HealthCheck(string host, int port, int requests, int payloadBytes) {
        ValidationStepResult res = new ValidationStepResult();
        long ok = 0;
        try {
            using (TcpClient client = new TcpClient()) {
                client.NoDelay = true;
                client.ReceiveTimeout = 5000;
                client.SendTimeout = 5000;
                client.Connect(host, port);
                NetworkStream stream = client.GetStream();

                for (int i = 0; i < requests; i++) {
                    long reqId = 8000000L + i;
                    byte[] payload = CreatePatternPayload(payloadBytes, reqId);
                    byte[] frame = BuildFrame(reqId, payload);
                    stream.Write(frame, 0, frame.Length);
                    stream.Flush();

                    string err;
                    if (ReadAndVerifyFrame(stream, reqId, payload, out err)) {
                        ok++;
                    } else {
                        res.Success = false;
                        res.Mismatches = 1;
                        res.TotalFramesVerified = ok;
                        res.Message = string.Format("HealthCheck failed at {0}/{1}: {2}", i + 1, requests, err);
                        return res;
                    }
                }
            }
            res.Success = (ok == requests);
            res.TotalFramesVerified = ok;
            res.Message = string.Format("HealthCheck passed {0}/{1} valid {2}B frames", ok, requests, payloadBytes);
        } catch (Exception ex) {
            res.Success = false;
            res.Errors = 1;
            res.TotalFramesVerified = ok;
            res.Message = string.Format("HealthCheck exception ({0}/{1} ok): {2}", ok, requests, ex.Message);
        }
        return res;
    }
}
"@
    Add-Type -TypeDefinition $csharpSource -Language CSharp
}

function Invoke-LoadGenOnce {
    param(
        [string]$Classpath,
        [string]$MainClass,
        [int]$Clients,
        [int]$WarmupSec,
        [int]$DurationSec,
        [int]$PayloadBytes,
        [int]$RunId,
        [string]$CsvOut,
        [string]$JsonOut,
        [string[]]$ExtraFlags
    )
    $argList = @()
    $argList += $jvmArgs
    $argList += @(
        "-cp", $Classpath,
        $MainClass,
        "--host", $HostName,
        "--port", "$Port",
        "--clients", "$Clients",
        "--warmup", "$WarmupSec",
        "--duration", "$DurationSec",
        "--payload", "$PayloadBytes",
        "--run-id", "$RunId",
        "--csv", $CsvOut,
        "--json", $JsonOut
    )
    if ($ExtraFlags) {
        $argList += $ExtraFlags
    }
    $stdoutPath = Join-Path $logsDir ("val_loadgen_r" + $RunId + "_c" + $Clients + ".out.log")
    $stderrPath = Join-Path $logsDir ("val_loadgen_r" + $RunId + "_c" + $Clients + ".err.log")
    if (Test-Path -LiteralPath $CsvOut) { Remove-Item -LiteralPath $CsvOut -Force }
    if (Test-Path -LiteralPath $JsonOut) { Remove-Item -LiteralPath $JsonOut -Force }

    $argString = Join-Win32Args -ArgsList $argList
    $proc = Start-Process -FilePath $javaExe -ArgumentList $argString -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    return $proc.ExitCode
}

function Test-ServerAlive {
    param([int]$TargetPid)
    if ($TargetPid -le 0) { return $true }
    $p = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
    return ($null -ne $p -and -not $p.HasExited)
}

$hasLoadGen = (-not [string]::IsNullOrWhiteSpace($LoadGenClasspath)) -and (-not [string]::IsNullOrWhiteSpace($LoadGenMainClass))
$results = @()

# =========================================================================
# TC1: 1 Client vs 50 Clients
# =========================================================================
$sw1 = [System.Diagnostics.Stopwatch]::StartNew()
$tc1Pass = $false
$tc1Details = ""

try {
    $lowClients = [int]$config.validation.tc1.low_clients
    $highClients = [int]$config.validation.tc1.high_clients
    $maxErrRate = [double]$config.validation.tc1.max_error_rate_percent
    $tc1Warmup = [int]$config.validation.tc1.warmup_sec
    $tc1Duration = [int]$config.validation.tc1.duration_sec
    $tc1Payload = [int]$config.validation.tc1.payload_bytes

    $usedExistingCsv = $false
    if (-not [string]::IsNullOrWhiteSpace($BenchmarkCsvPath) -and (Test-Path -LiteralPath $BenchmarkCsvPath) -and -not $UseLoadGenForTC1) {
        $rows = @(Import-Csv -LiteralPath $BenchmarkCsvPath)
        $lowRows = @($rows | Where-Object { [int]$_.clients -eq $lowClients })
        $highRows = @($rows | Where-Object { [int]$_.clients -eq $highClients })

        if ($lowRows.Count -gt 0 -and $highRows.Count -gt 0) {
            $usedExistingCsv = $true
            $inv = [System.Globalization.CultureInfo]::InvariantCulture

            $lowSucc = 0L; $lowErr = 0L
            $lowTp = @(); $lowAvg = @(); $lowP95 = @(); $lowErrPct = @()
            foreach ($r in $lowRows) {
                $lowSucc += [long]$r.total_success
                $lowErr += [long]$r.total_errors
                $lowTp += [double]::Parse([string]$r.throughput_req_s, $inv)
                $lowAvg += [double]::Parse([string]$r.avg_latency_ms, $inv)
                $lowP95 += [double]::Parse([string]$r.p95_latency_ms, $inv)
                $lowErrPct += [double]::Parse([string]$r.error_rate_percent, $inv)
            }

            $highSucc = 0L; $highErr = 0L
            $highTp = @(); $highAvg = @(); $highP95 = @(); $highErrPct = @()
            foreach ($r in $highRows) {
                $highSucc += [long]$r.total_success
                $highErr += [long]$r.total_errors
                $highTp += [double]::Parse([string]$r.throughput_req_s, $inv)
                $highAvg += [double]::Parse([string]$r.avg_latency_ms, $inv)
                $highP95 += [double]::Parse([string]$r.p95_latency_ms, $inv)
                $highErrPct += [double]::Parse([string]$r.error_rate_percent, $inv)
            }

            $mLowTp = Get-ArrayMean $lowTp
            $mLowAvg = Get-ArrayMean $lowAvg
            $mLowP95 = Get-ArrayMean $lowP95
            $mLowErr = Get-ArrayMean $lowErrPct

            $mHighTp = Get-ArrayMean $highTp
            $mHighAvg = Get-ArrayMean $highAvg
            $mHighP95 = Get-ArrayMean $highP95
            $mHighErr = Get-ArrayMean $highErrPct

            $tc1Pass = ($lowSucc -gt 0 -and $highSucc -gt 0 -and
                        $mLowTp -gt 0 -and $mHighTp -gt 0 -and
                        $mLowAvg -gt 0 -and $mHighAvg -gt 0 -and
                        $mLowP95 -gt 0 -and $mHighP95 -gt 0 -and
                        $mLowErr -le $maxErrRate -and $mHighErr -le $maxErrRate)

            $tc1Details = [string]::Format(
                $inv,
                "Source=benchmark_results.csv; {0}c(runs={1}): tp={2:F2} req/s, avg={3:F4}ms, p95={4:F4}ms, err={5:F2}%; {6}c(runs={7}): tp={8:F2} req/s, avg={9:F4}ms, p95={10:F4}ms, err={11:F2}%",
                $lowClients, $lowRows.Count, $mLowTp, $mLowAvg, $mLowP95, $mLowErr,
                $highClients, $highRows.Count, $mHighTp, $mHighAvg, $mHighP95, $mHighErr
            )
        }
    }

    if (-not $usedExistingCsv) {
        if ($hasLoadGen) {
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            $csvLow = Join-Path $logsDir "val_tc1_low.csv"
            $jsonLow = Join-Path $logsDir "val_tc1_low.json"
            $csvHigh = Join-Path $logsDir "val_tc1_high.csv"
            $jsonHigh = Join-Path $logsDir "val_tc1_high.json"

            $rcLow = Invoke-LoadGenOnce -Classpath $LoadGenClasspath -MainClass $LoadGenMainClass `
                -Clients $lowClients -WarmupSec $tc1Warmup -DurationSec $tc1Duration -PayloadBytes $tc1Payload `
                -RunId 901 -CsvOut $csvLow -JsonOut $jsonLow -ExtraFlags @()
            $rcHigh = Invoke-LoadGenOnce -Classpath $LoadGenClasspath -MainClass $LoadGenMainClass `
                -Clients $highClients -WarmupSec $tc1Warmup -DurationSec $tc1Duration -PayloadBytes $tc1Payload `
                -RunId 902 -CsvOut $csvHigh -JsonOut $jsonHigh -ExtraFlags @()

            if ($rcLow -eq 0 -and $rcHigh -eq 0 -and (Test-Path -LiteralPath $csvLow) -and (Test-Path -LiteralPath $csvHigh)) {
                $rLow = @(Import-Csv -LiteralPath $csvLow)[0]
                $rHigh = @(Import-Csv -LiteralPath $csvHigh)[0]

                $lSucc = [long]$rLow.total_success
                $lTp = [double]::Parse([string]$rLow.throughput_req_s, $inv)
                $lAvg = [double]::Parse([string]$rLow.avg_latency_ms, $inv)
                $lP95 = [double]::Parse([string]$rLow.p95_latency_ms, $inv)
                $lErr = [double]::Parse([string]$rLow.error_rate_percent, $inv)

                $hSucc = [long]$rHigh.total_success
                $hTp = [double]::Parse([string]$rHigh.throughput_req_s, $inv)
                $hAvg = [double]::Parse([string]$rHigh.avg_latency_ms, $inv)
                $hP95 = [double]::Parse([string]$rHigh.p95_latency_ms, $inv)
                $hErr = [double]::Parse([string]$rHigh.error_rate_percent, $inv)

                $tc1Pass = ($lSucc -gt 0 -and $hSucc -gt 0 -and
                            $lTp -gt 0 -and $hTp -gt 0 -and
                            $lAvg -gt 0 -and $hAvg -gt 0 -and
                            $lP95 -gt 0 -and $hP95 -gt 0 -and
                            $lErr -le $maxErrRate -and $hErr -le $maxErrRate)

                $tc1Details = [string]::Format(
                    $inv,
                    "Source=LoadGeneratorApp; {0}c: tp={1:F2} req/s, avg={2:F4}ms, p95={3:F4}ms, err={4:F2}%; {5}c: tp={6:F2} req/s, avg={7:F4}ms, p95={8:F4}ms, err={9:F2}%",
                    $lowClients, $lTp, $lAvg, $lP95, $lErr,
                    $highClients, $hTp, $hAvg, $hP95, $hErr
                )
            } else {
                $tc1Pass = $false
                $tc1Details = "LoadGeneratorApp failed for TC1 (rcLow=$rcLow, rcHigh=$rcHigh)"
            }
        } else {
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            $resLow = [TcpProtocolValidator]::RunBuiltInLoadTest($HostName, $Port, $lowClients, $tc1Warmup, $tc1Duration, $tc1Payload)
            $resHigh = [TcpProtocolValidator]::RunBuiltInLoadTest($HostName, $Port, $highClients, $tc1Warmup, $tc1Duration, $tc1Payload)

            $tc1Pass = ($resLow.Success -and $resHigh.Success -and
                        $resLow.ThroughputReqS -gt 0 -and $resHigh.ThroughputReqS -gt 0 -and
                        $resLow.AvgLatencyMs -gt 0 -and $resHigh.AvgLatencyMs -gt 0 -and
                        $resLow.P95LatencyMs -gt 0 -and $resHigh.P95LatencyMs -gt 0 -and
                        $resLow.ErrorRatePercent -le $maxErrRate -and $resHigh.ErrorRatePercent -le $maxErrRate)

            $tc1Details = [string]::Format(
                $inv,
                "Source=BuiltInValidator; [{0}] vs [{1}]",
                $resLow.Message, $resHigh.Message
            )
        }
    }
} catch {
    $tc1Pass = $false
    $tc1Details = "TC1 exception: " + $_.Exception.Message
}
$sw1.Stop()
$results += [PSCustomObject]@{
    test_id     = "TC1"
    test_name   = "1 Client vs 50 Clients"
    status      = $(if ($tc1Pass) { "PASS" } else { "FAIL" })
    duration_ms = [int]$sw1.ElapsedMilliseconds
    details     = $tc1Details
}

# =========================================================================
# TC2: requestId and payload Integrity
# =========================================================================
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
$tc2Pass = $false
$tc2Details = ""

try {
    [int[]]$sizes = @($config.validation.tc2.payload_sizes | ForEach-Object { [int]$_ })
    $concClients = [int]$config.validation.tc2.concurrent_clients
    $reqsPerClient = [int]$config.validation.tc2.requests_per_client
    $pipelined = [int]$config.validation.tc2.pipelined_frames
    $fragBytes = [int]$config.validation.tc2.fragmented_payload_bytes
    $tc2Timeout = [int]$config.validation.tc4.socket_timeout_ms

    $integrity = [TcpProtocolValidator]::RunIntegritySuite(
        $HostName, $Port, $sizes, $concClients, $reqsPerClient, $pipelined, $fragBytes, $tc2Timeout
    )
    $tc2Pass = [bool]$integrity.Success
    $tc2Details = [string]$integrity.Message
} catch {
    $tc2Pass = $false
    $tc2Details = "TC2 exception: " + $_.Exception.Message
}
$sw2.Stop()
$results += [PSCustomObject]@{
    test_id     = "TC2"
    test_name   = "requestId & Payload Integrity"
    status      = $(if ($tc2Pass) { "PASS" } else { "FAIL" })
    duration_ms = [int]$sw2.ElapsedMilliseconds
    details     = $tc2Details
}

# =========================================================================
# TC3: Abrupt Client Disconnect (Kill Task client + Half-frame TCP RST)
# =========================================================================
$sw3 = [System.Diagnostics.Stopwatch]::StartNew()
$tc3Pass = $false
$tc3Details = ""

try {
    $killClients = [int]$config.validation.tc3.kill_clients
    $killAfterMs = [int]$config.validation.tc3.kill_after_ms
    $halfSockets = [int]$config.validation.tc3.half_frame_sockets
    $hcReqs = [int]$config.validation.tc3.health_check_requests

    $killerOut = Join-Path $logsDir "val_tc3_victim.out.log"
    $killerErr = Join-Path $logsDir "val_tc3_victim.err.log"
    $victimProc = $null

    if ($hasLoadGen) {
        $vCsv = Join-Path $logsDir "val_tc3_victim.csv"
        $vJson = Join-Path $logsDir "val_tc3_victim.json"
        $vArgs = @()
        $vArgs += $jvmArgs
        $vArgs += @(
            "-cp", $LoadGenClasspath,
            $LoadGenMainClass,
            "--host", $HostName,
            "--port", "$Port",
            "--clients", "$killClients",
            "--warmup", "0",
            "--duration", "30",
            "--payload", "1024",
            "--run-id", "903",
            "--csv", $vCsv,
            "--json", $vJson
        )
        $vArgString = Join-Win32Args -ArgsList $vArgs
        $victimProc = Start-Process -FilePath $javaExe -ArgumentList $vArgString -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $killerOut -RedirectStandardError $killerErr
        $null = $victimProc.Handle
    } else {
        $psCmd = @"
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
public static class TcpVictimRunner {
    public static void Run(string host, int port, int clients, int seconds) {
        Task[] tasks = new Task[clients];
        for (int i = 0; i < clients; i++) {
            tasks[i] = Task.Run(() => {
                try {
                    using (TcpClient c = new TcpClient()) {
                        c.NoDelay = true;
                        c.Connect(host, port);
                        NetworkStream s = c.GetStream();
                        byte[] buf = new byte[1036];
                        buf[2] = 0x04; buf[3] = 0x08;
                        byte[] resp = new byte[1036];
                        while (true) {
                            s.Write(buf, 0, buf.Length);
                            s.Flush();
                            int got = 0;
                            while (got < 1036) {
                                int n = s.Read(resp, got, 1036 - got);
                                if (n <= 0) return;
                                got += n;
                            }
                        }
                    }
                } catch {}
            });
        }
        Task.WaitAll(tasks, seconds * 1000);
    }
}
'@
[TcpVictimRunner]::Run('$HostName', $Port, $killClients, 30)
"@
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($psCmd))
        $victimProc = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-EncodedCommand", $encoded) `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput $killerOut -RedirectStandardError $killerErr
        $null = $victimProc.Handle
    }

    Start-Sleep -Milliseconds $killAfterMs
    $wasRunning = ($null -ne $victimProc -and -not $victimProc.HasExited)
    if ($wasRunning) {
        Stop-ProcessTree -TargetPid $victimProc.Id
        try { $victimProc.WaitForExit(3000) | Out-Null } catch {}
    }

    $rstRes = [TcpProtocolValidator]::RunHalfFrameRstBurst($HostName, $Port, $halfSockets)

    $killEarlyInfo = "skipped"
    $killEarlyOk = $true
    if ($hasLoadGen) {
        $keCsv = Join-Path $logsDir "val_tc3_kill_early.csv"
        $keJson = Join-Path $logsDir "val_tc3_kill_early.json"
        $keRc = Invoke-LoadGenOnce -Classpath $LoadGenClasspath -MainClass $LoadGenMainClass `
            -Clients 5 -WarmupSec 0 -DurationSec 2 -PayloadBytes 1024 -RunId 904 `
            -CsvOut $keCsv -JsonOut $keJson -ExtraFlags @("--kill-early")
        $killEarlyOk = ($keRc -eq 0)
        $killEarlyInfo = "exit=$keRc"
    }

    Start-Sleep -Milliseconds 300
    $serverAlive = Test-ServerAlive -TargetPid $ServerPid
    $hc = [TcpProtocolValidator]::HealthCheck($HostName, $Port, $hcReqs, 1024)

    $tc3Pass = ($wasRunning -and $rstRes.Success -and $killEarlyOk -and $serverAlive -and $hc.Success)
    $tc3Details = "KilledClientActive=$wasRunning; $($rstRes.Message); KillEarly=$killEarlyInfo; ServerAlive=$serverAlive; $($hc.Message)"
} catch {
    $tc3Pass = $false
    $tc3Details = "TC3 exception: " + $_.Exception.Message
}
$sw3.Stop()
$results += [PSCustomObject]@{
    test_id     = "TC3"
    test_name   = "Abrupt Disconnect (Kill Task)"
    status      = $(if ($tc3Pass) { "PASS" } else { "FAIL" })
    duration_ms = [int]$sw3.ElapsedMilliseconds
    details     = $tc3Details
}

# =========================================================================
# TC4: Invalid / Oversized Frame Rejection
# =========================================================================
$sw4 = [System.Diagnostics.Stopwatch]::StartNew()
$tc4Pass = $false
$tc4Details = ""

try {
    $oversizedBoundary = [int]$config.validation.tc4.oversized_boundary_length
    $hugeLength = [int]$config.validation.tc4.huge_length
    [int[]]$tooSmallLengths = @($config.validation.tc4.too_small_lengths | ForEach-Object { [int]$_ })
    $tc4Timeout = [int]$config.validation.tc4.socket_timeout_ms
    $hcReqs4 = [int]$config.validation.tc4.health_check_requests

    $probeResults = @()
    $probeResults += [TcpProtocolValidator]::TestInvalidLengthRejected($HostName, $Port, $oversizedBoundary, 16, $tc4Timeout)
    $probeResults += [TcpProtocolValidator]::TestInvalidLengthRejected($HostName, $Port, $hugeLength, 16, $tc4Timeout)
    foreach ($badLen in $tooSmallLengths) {
        $probeResults += [TcpProtocolValidator]::TestInvalidLengthRejected($HostName, $Port, $badLen, 0, $tc4Timeout)
    }
    $probeResults += [TcpProtocolValidator]::TestTruncatedHeaderRejected($HostName, $Port, $tc4Timeout)

    $testInvalidOk = $true
    $testInvalidInfo = "skipped"
    if ($hasLoadGen) {
        $tiCsv = Join-Path $logsDir "val_tc4_test_invalid.csv"
        $tiJson = Join-Path $logsDir "val_tc4_test_invalid.json"
        $tiRc = Invoke-LoadGenOnce -Classpath $LoadGenClasspath -MainClass $LoadGenMainClass `
            -Clients 2 -WarmupSec 0 -DurationSec 2 -PayloadBytes 1024 -RunId 905 `
            -CsvOut $tiCsv -JsonOut $tiJson -ExtraFlags @("--test-invalid")
        $testInvalidOk = ($tiRc -eq 0)
        $testInvalidInfo = "exit=$tiRc"
    }

    $allProbesPassed = $true
    $failedProbes = @()
    foreach ($pr in $probeResults) {
        if (-not $pr.Success) {
            $allProbesPassed = $false
            $failedProbes += $pr.Message
        }
    }

    Start-Sleep -Milliseconds 200
    $serverAlive4 = Test-ServerAlive -TargetPid $ServerPid
    $hc4 = [TcpProtocolValidator]::HealthCheck($HostName, $Port, $hcReqs4, 1024)

    $tc4Pass = ($allProbesPassed -and $testInvalidOk -and $serverAlive4 -and $hc4.Success)
    if ($allProbesPassed) {
        $tc4Details = "Rejected all $($probeResults.Count) invalid probes (boundary=$oversizedBoundary, huge=$hugeLength, too_small=$($tooSmallLengths -join ','), truncated=2B); TestInvalidFlag=$testInvalidInfo; ServerAlive=$serverAlive4; $($hc4.Message)"
    } else {
        $tc4Details = "Failed probes: $($failedProbes -join ' | '); TestInvalidFlag=$testInvalidInfo; ServerAlive=$serverAlive4; $($hc4.Message)"
    }
} catch {
    $tc4Pass = $false
    $tc4Details = "TC4 exception: " + $_.Exception.Message
}
$sw4.Stop()
$results += [PSCustomObject]@{
    test_id     = "TC4"
    test_name   = "Invalid / Oversized Frame"
    status      = $(if ($tc4Pass) { "PASS" } else { "FAIL" })
    duration_ms = [int]$sw4.ElapsedMilliseconds
    details     = $tc4Details
}

# =========================================================================
# Write Outputs & Print Summary
# =========================================================================
$valCsvName = [string]$config.output.validation_csv
$valJsonName = [string]$config.output.validation_json
$valCsvPath = Join-Path $OutputDir $valCsvName
$valJsonPath = Join-Path $OutputDir $valJsonName

$csvLines = New-Object System.Collections.Generic.List[string]
$csvLines.Add("test_id,test_name,status,duration_ms,details")
foreach ($row in $results) {
    $line = "{0},{1},{2},{3},{4}" -f `
        (ConvertTo-CsvField $row.test_id), `
        (ConvertTo-CsvField $row.test_name), `
        (ConvertTo-CsvField $row.status), `
        $row.duration_ms, `
        (ConvertTo-CsvField $row.details)
    $csvLines.Add($line)
}
Write-Utf8NoBom -Path $valCsvPath -Content (($csvLines.ToArray() -join "`n") + "`n")

$passedCount = @($results | Where-Object { $_.status -eq "PASS" }).Count
$reportObj = [PSCustomObject]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    target_host      = $HostName
    target_port      = $Port
    server_pid       = $ServerPid
    total_tests      = $results.Count
    passed           = $passedCount
    failed           = ($results.Count - $passedCount)
    all_passed       = ($passedCount -eq $results.Count)
    results          = @($results)
}
$jsonText = ($reportObj | ConvertTo-Json -Depth 6) + "`n"
Write-Utf8NoBom -Path $valJsonPath -Content $jsonText

Write-Host ""
Write-Host "================ VALIDATION SUMMARY ================"
$results | Format-Table -Property test_id, test_name, status, duration_ms, details -AutoSize -Wrap | Out-String | Write-Host
Write-Host "Validation CSV : $valCsvPath"
Write-Host "Validation JSON: $valJsonPath"
Write-Host "Result         : $passedCount / $($results.Count) PASSED"
Write-Host "===================================================="

if ($passedCount -ne $results.Count) {
    exit 1
}
exit 0
