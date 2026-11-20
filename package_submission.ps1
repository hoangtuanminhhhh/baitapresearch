<#
.SYNOPSIS
    Script chuẩn hóa kiểm tra cấu trúc repository và đóng gói hồ sơ nộp bài
    Dành cho Thành viên 6 (Packaging & Technical Writer Lead)
.DESCRIPTION
    1. Kiểm tra cấu trúc thư mục chuẩn theo yêu cầu Mục 5 Đề tài Research.
    2. Quét và cảnh báo file rác (build cache, IDE files, .class, __pycache__).
    3. Đóng gói mã nguồn và dữ liệu sạch thành file ZIP nộp bài.
#>

param (
    [string]$OutputFile = "submission_tcp_server_benchmark.zip"
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  KIỂM TRA CẤU TRÚC REPO & ĐÓNG GÓI HỒ SƠ NỘP BÀI (TV6)   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$root = $PSScriptRoot
if (-not $root) { $root = Get-Location }

# 1. Danh sách thư mục và file bắt buộc theo Mục 5 Đề tài
$requiredDirs = @(
    "src/server",
    "src/load-generator",
    "experiments/configs",
    "experiments/raw-data",
    "experiments/analysis",
    "experiments/figures",
    "docs"
)

$requiredFiles = @(
    "README.md",
    ".gitignore"
)

$allPassed = $true

Write-Host "`n[1] Kiểm tra cấu trúc thư mục chuẩn:" -ForegroundColor Yellow
foreach ($dir in $requiredDirs) {
    $path = Join-Path $root $dir
    if (Test-Path $path) {
        Write-Host "  [OK] Thư mục: $dir" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Thiếu thư mục: $dir" -ForegroundColor Red
        $allPassed = $false
    }
}

foreach ($file in $requiredFiles) {
    $path = Join-Path $root $file
    if (Test-Path $path) {
        Write-Host "  [OK] File: $file" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Thiếu file: $file" -ForegroundColor Red
        $allPassed = $false
    }
}

# 2. Kiểm tra tài liệu báo cáo docs/REPORT.pdf
Write-Host "`n[2] Kiểm tra hồ sơ báo cáo (docs/):" -ForegroundColor Yellow
$reportPdf = Join-Path $root "docs/REPORT.pdf"
if (Test-Path $reportPdf) {
    Write-Host "  [OK] Đã có file docs/REPORT.pdf" -ForegroundColor Green
} else {
    Write-Host "  [INFO] Chưa tìm thấy docs/REPORT.pdf (TV5 & TV6 đang hoàn thiện theo tiến độ)" -ForegroundColor DarkYellow
}

# 3. Quét kiểm tra file rác biên dịch hoặc IDE
Write-Host "`n[3] Quét kiểm tra file rác (không được phép nộp):" -ForegroundColor Yellow
$bannedPatterns = @("*.class", "*.pyc", ".DS_Store", "Thumbs.db")
$junkFound = $false

foreach ($pattern in $bannedPatterns) {
    $junkFiles = Get-ChildItem -Path $root -Recurse -Filter $pattern -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notmatch "\\target\\" -and $_.FullName -notmatch "\\\.git\\" }
    if ($junkFiles.Count -gt 0) {
        foreach ($j in $junkFiles) {
            Write-Host "  [CẢNH BÁO] Phát hiện file rác: $($j.FullName)" -ForegroundColor Red
        }
        $junkFound = $true
    }
}

if (-not $junkFound) {
    Write-Host "  [OK] Không có file rác (*.class, *.pyc, OS junk) nằm ngoài vùng quản lý!" -ForegroundColor Green
}

# 4. Đóng gói ZIP sạch
Write-Host "`n[4] Tiến hành đóng gói hồ sơ nộp bài:" -ForegroundColor Yellow

$zipPath = Join-Path $root $OutputFile
if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
    Write-Host "  Đã xóa file zip cũ: $OutputFile" -ForegroundColor DarkGray
}

$tempStaging = Join-Path $env:TEMP ("repo_pack_" + [System.Guid]::NewGuid().ToString().Substring(0,8))
New-Item -ItemType Directory -Path $tempStaging | Out-Null

try {
    # Copy các thư mục và file chuẩn sang thư mục tạm, loại bỏ git, target, .idea
    $excludeList = @(".git", ".idea", ".vscode", "target", "bin", "out", "__pycache__", ".mvn", $OutputFile)
    
    Get-ChildItem -Path $root -Force | Where-Object { $excludeList -notcontains $_.Name } | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $tempStaging -Recurse -Force
    }

    # Nén thư mục tạm thành zip
    Compress-Archive -Path "$tempStaging\*" -DestinationPath $zipPath -Force
    Write-Host "  [OK] Đã tạo gói nộp bài thành công: $OutputFile" -ForegroundColor Green
    $fileSize = (Get-Item $zipPath).Length / 1KB
    Write-Host "  Kích thước gói nén: $([Math]::Round($fileSize, 2)) KB" -ForegroundColor Cyan
}
finally {
    if (Test-Path $tempStaging) {
        Remove-Item -Path $tempStaging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  HOÀN TẤT KIỂM CHỨNG & ĐÓNG GÓI!                        " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
