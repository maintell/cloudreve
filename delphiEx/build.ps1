<#
.SYNOPSIS
    编译 delphiEx 示例（控制台程序），自动定位本机 Delphi 编译器。

.DESCRIPTION
    默认按编译器版本选择传输层：
      * Delphi XE8 及以上 -> System.Net.HttpClient（Windows 走 WinHTTP，无需 OpenSSL）
      * Delphi XE ~ XE7  -> Indy TIdHTTP
    -Indy 可强制使用 Indy（用于在 10.2+ 上同时验证两条路径）。

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Indy
    .\build.ps1 -Config Debug
    .\build.ps1 -Version 23.0
#>
[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')]
    [string]$Config = 'Release',

    [switch]$Indy,

    # 指定 Delphi 版本目录名，如 18.0（10.2 Tokyo）、22.0（11.3）、23.0（12）
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
$srcDir = Join-Path $root 'src'
$outDir = Join-Path $root 'build'
$logFile = Join-Path $outDir 'dcc32.log'

function Find-Compiler {
    param([string]$PreferredVersion)

    $roots = @(
        'C:\Program Files (x86)\Embarcadero\Studio',
        'C:\Program Files\Embarcadero\Studio',
        'D:\Program Files (x86)\Embarcadero\Studio',
        'E:\Program Files (x86)\Embarcadero\Studio'
    ) | Where-Object { Test-Path $_ }

    $candidates = @()
    foreach ($r in $roots) {
        $candidates += Get-ChildItem -Path $r -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $dcc = Join-Path $_.FullName 'bin\dcc32.exe'
                if (Test-Path $dcc) {
                    [pscustomobject]@{ Version = $_.Name; Dcc = $dcc; Bds = $_.FullName }
                }
            }
    }

    if ($PreferredVersion) {
        $candidates = @($candidates | Where-Object { $_.Version -eq $PreferredVersion })
    }
    if ($candidates.Count -eq 0) {
        throw '没有找到 dcc32.exe。请安装 Delphi XE 及以上，或用 -Version 指定版本目录（如 18.0）。'
    }

    # 版本号大的优先（23.0 > 22.0 > 18.0）
    return $candidates | Sort-Object { [double]$_.Version } -Descending | Select-Object -First 1
}

$compiler = Find-Compiler -PreferredVersion $Version
Write-Host ('编译器: ' + $compiler.Dcc) -ForegroundColor Cyan

# Delphi 只有看到 UTF-8 BOM 才按 UTF-8 读源码；否则中文注释与字面量会被当 ANSI 解析并报奇怪的语法错。
function Ensure-Utf8Bom {
    param([string]$Dir)

    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    $fixed = 0
    foreach ($f in Get-ChildItem -Path (Join-Path $Dir '*') -Include '*.pas', '*.dpr' -File) {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and
            $bytes[2] -eq 0xBF
        if (-not $hasBom) {
            [System.IO.File]::WriteAllBytes($f.FullName, $bom + $bytes)
            $fixed++
        }
    }
    if ($fixed -gt 0) {
        Write-Host ("已为 $fixed 个源文件补上 UTF-8 BOM") -ForegroundColor Yellow
    }
}

Ensure-Utf8Bom -Dir $srcDir

$libDir = Join-Path $compiler.Bds ('lib\win32\' + $Config.ToLower())
if (-not (Test-Path $libDir)) {
    throw "找不到 RTL 单元目录: $libDir"
}

New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$name = if ($Indy) { 'CloudreveEx-indy' } else { 'CloudreveEx' }
$exe = Join-Path $outDir ($name + '.exe')
$dcuDir = Join-Path $outDir 'dcu'
New-Item -ItemType Directory -Path $dcuDir -Force | Out-Null

$dpr = Join-Path $srcDir 'CloudreveEx.dpr'

# 注意：PowerShell 数组字面量里 '-N0' + $dir 会被拆成两个元素，必须先拼好变量
$optUnitOut = '-N0' + $dcuDir
$optUnitPath = '-U' + $libDir
$optIncludePath = '-I' + $libDir
$optExeOut = '-E' + $outDir

$dccArgs = @(
    '-B',              # 全量重编，避免残留 dcu 导致的假通过
    $optUnitOut,       # 单元输出目录（N 零）
    $optUnitPath,      # RTL/VCL 单元搜索路径
    $optIncludePath,
    $optExeOut,        # 可执行文件输出目录
    '-Q'               # 安静模式（错误仍然输出）
)
if ($Indy) {
    $dccArgs += '-DCLOUDREVE_USE_INDY'
}

Write-Host ('输出: ' + $exe) -ForegroundColor Cyan
Write-Host ('配置: ' + $Config + $(if ($Indy) { ' / 传输层: Indy TIdHTTP' } else { ' / 传输层: 自动选择' })) `
    -ForegroundColor Cyan

& $compiler.Dcc @dccArgs $dpr 2>&1 | Tee-Object -FilePath $logFile | ForEach-Object { Write-Host $_ }

if ($LASTEXITCODE -ne 0) {
    throw "编译失败（exit=$LASTEXITCODE），日志：$logFile"
}

# dcc32 以项目名输出 exe；Indy 变体单独改名，方便两条路径并存对比
$produced = Join-Path $outDir 'CloudreveEx.exe'
if (-not (Test-Path $produced)) {
    throw "编译命令成功但没有生成 $produced，请检查日志：$logFile"
}
if ($name -ne 'CloudreveEx') {
    Move-Item -Path $produced -Destination $exe -Force
}

Write-Host ''
Write-Host ('编译成功: ' + $exe) -ForegroundColor Green
Write-Host '自检（不联网，只打印帮助）:'
& $exe --help | Select-Object -First 5
