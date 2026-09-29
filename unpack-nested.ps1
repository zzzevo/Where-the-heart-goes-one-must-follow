#Requires -Version 5.1
<#
  unpack-nested.ps1  —— 套娃压缩包自动解包工具

  功能：
    * 按文件头（魔数）判断真实类型，不信扩展名
    * 自动循环剥层（tar <-> zip 反复套娃也能剥）
    * 自动找密码：命令行参数 -> 从包内条目名挖（如「解压码1111」）-> 常见弱密码
    * 加密 zip 优先用 7-Zip / libarchive（bsdtar），避开 Python zipfile 的慢速实现
    * tar 遇到畸形/乱码文件名时，自动改用「按偏移直切」绕过文件名解析
    * 防炸弹：解出体积异常时中止

  用法：
    .\unpack-nested.ps1 "包.tar"
    .\unpack-nested.ps1 "包.zip" -Password 1111
    .\unpack-nested.ps1 "包.zip" -OutDir "D:\输出" -MaxLayers 60 -KeepLayers

  注意：本文件是 UTF-8 with BOM 保存。用记事本另存会丢 BOM，中文提示会乱码。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [string]$OutDir,
    [string]$Password,
    [int]$MaxLayers = 40,
    [switch]$KeepLayers,
    [switch]$NoScan
)

$ErrorActionPreference = 'Stop'

function Say  ($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Ok   ($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Info ($m) { Write-Host "  [..] $m" -ForegroundColor Gray }
function Warn ($m) { Write-Host "  [! ] $m" -ForegroundColor Yellow }
function Fail ($m) { Write-Host "  [X ] $m" -ForegroundColor Red }

# ============================================================
# 工具定位
# ============================================================
$script:SevenZip = $null
$script:Bsdtar   = $null
$script:Python   = $null

# 通用工具定位：PATH -> 常见安装位置（避免硬编码某台机器的路径）
function Find-Tool {
    param([string[]]$Names, [string[]]$Hints)
    foreach ($n in $Names) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        # 跳过 Microsoft Store 的占位程序（python3.exe 这类别名会拉起应用商店）
        if ($c -and $c.Source -notmatch '\\WindowsApps\\') { return $c.Source }
    }
    foreach ($h in $Hints) {
        $e = [Environment]::ExpandEnvironmentVariables($h)
        if (Test-Path -LiteralPath $e) { return $e }
    }
    return $null
}

# 7-Zip 要额外读注册表：它允许安装到任意目录（例如 D:\Winrar\7-Zip\），
# 只靠 PATH 和 %ProgramFiles% 会漏掉这类自定义安装
function Find-SevenZip {
    foreach ($k in 'HKLM:\SOFTWARE\7-Zip', 'HKCU:\SOFTWARE\7-Zip', 'HKLM:\SOFTWARE\WOW6432Node\7-Zip') {
        $v = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if (-not $v) { continue }
        foreach ($name in 'Path64', 'Path') {
            $dir = $v.$name
            if (-not $dir) { continue }
            $exe = Join-Path $dir '7z.exe'
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }
    $c = Find-Tool -Names @('7z.exe') -Hints @(
        '%ProgramFiles%\7-Zip\7z.exe',
        '%ProgramFiles(x86)%\7-Zip\7z.exe',
        '%LOCALAPPDATA%\Programs\7-Zip\7z.exe')
    if ($c) { return $c }
    # 最后才退到 7za.exe（精简版，部分格式不支持）
    return (Find-Tool -Names @('7za.exe') -Hints @())
}

$script:SevenZip = Find-SevenZip

$script:Bsdtar = Find-Tool -Names @('bsdtar.exe', 'tar.exe') -Hints @(
    '%SystemRoot%\System32\tar.exe',
    '%ProgramFiles%\Git\usr\bin\bsdtar.exe',
    'C:\ProgramData\chocolatey\bin\bsdtar.exe')

$script:Python = Find-Tool -Names @('python.exe', 'python3.exe', 'py.exe') -Hints @(
    '%LOCALAPPDATA%\Programs\Python\Python313\python.exe',
    '%LOCALAPPDATA%\Programs\Python\Python312\python.exe',
    'C:\Python313\python.exe',
    'C:\Python312\python.exe')

# ============================================================
# 基础工具函数
# ============================================================
function Get-Magic([string]$p) {
    $fs = [IO.File]::OpenRead($p)
    try {
        $b = New-Object byte[] 512
        $n = $fs.Read($b, 0, 512)
        if ($n -lt 4) { return 'RAW' }
        if ($b[0] -eq 0x50 -and $b[1] -eq 0x4B) { return 'ZIP' }
        if ($b[0] -eq 0x52 -and $b[1] -eq 0x61 -and $b[2] -eq 0x72 -and $b[3] -eq 0x21) { return 'RAR' }
        if ($b[0] -eq 0x37 -and $b[1] -eq 0x7A -and $b[2] -eq 0xBC -and $b[3] -eq 0xAF) { return '7Z' }
        if ($b[0] -eq 0x1F -and $b[1] -eq 0x8B) { return 'GZIP' }
        if ($n -ge 262 -and [Text.Encoding]::ASCII.GetString($b, 257, 5) -eq 'ustar') { return 'TAR' }
        return 'RAW'
    }
    finally { $fs.Close() }
}

# 解析 tar 的所有成员（只读头，不依赖文件名能否解码）
function Get-TarMembers([string]$p) {
    $res = New-Object System.Collections.ArrayList
    $fs = [IO.File]::OpenRead($p)
    try {
        $hdr = New-Object byte[] 512
        $pos = 0L
        $len = $fs.Length
        while ($pos + 512 -le $len) {
            $fs.Position = $pos
            if ($fs.Read($hdr, 0, 512) -lt 512) { break }
            $zero = $true
            for ($k = 0; $k -lt 512; $k++) { if ($hdr[$k] -ne 0) { $zero = $false; break } }
            if ($zero) { break }
            $name = [Text.Encoding]::UTF8.GetString($hdr, 0, 100).TrimEnd([char]0)
            $sizeStr = [Text.Encoding]::ASCII.GetString($hdr, 124, 12).Trim([char]0, [char]32)
            $size = 0L
            try { $size = [Convert]::ToInt64($sizeStr, 8) } catch { $size = 0L }
            $tf = [char]$hdr[156]
            [void]$res.Add([pscustomobject]@{ Offset = $pos + 512; Size = $size; Name = $name; Type = $tf })
            $pos += 512 + [long]([Math]::Ceiling($size / 512.0) * 512)
        }
    }
    finally { $fs.Close() }
    return $res
}

# 大文件区间复制（流式，不占内存）
function Copy-Range([string]$src, [string]$dst, [long]$offset, [long]$size) {
    $i = [IO.File]::OpenRead($src)
    $o = [IO.File]::Create($dst)
    try {
        $i.Position = $offset
        $buf = New-Object byte[] (8 * 1024 * 1024)
        $rem = $size
        while ($rem -gt 0) {
            $n = [int][Math]::Min([long]$buf.Length, $rem)
            $r = $i.Read($buf, 0, $n)
            if ($r -le 0) { break }
            $o.Write($buf, 0, $r)
            $rem -= $r
        }
    }
    finally { $o.Close(); $i.Close() }
}

function Get-ZipEntries([string]$p) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $z = [IO.Compression.ZipFile]::OpenRead($p)
    try {
        $out = @()
        foreach ($e in $z.Entries) {
            $out += [pscustomobject]@{
                Name       = $e.FullName
                Size       = [long]$e.Length
                Compressed = [long]$e.CompressedLength
                IsDir      = $e.FullName.EndsWith('/')
            }
        }
        return $out
    }
    finally { $z.Dispose() }
}

# 从条目名里挖密码（「解压码1111」「密码：abc」这类）
function Get-PwdCandidates([string]$given, $names) {
    $list = New-Object System.Collections.ArrayList
    if ($given) { [void]$list.Add($given) }
    foreach ($n in $names) {
        foreach ($m in [regex]::Matches([string]$n, '(?:解压码|解压密码|压缩密码|密码|提取码|pass(?:word)?)\s*[:：]?\s*([A-Za-z0-9_\-\.]{1,32})')) {
            [void]$list.Add($m.Groups[1].Value)
        }
    }
    foreach ($c in '1111', '123456', '0000', '1234', '6666', '8888', 'password', '12345678', '111111', '000000') {
        [void]$list.Add($c)
    }
    return @($list | Select-Object -Unique)
}

# 用 Python 快速试探 zip 密码（只读第一个条目 1KB，秒级）
# 返回：'OK'=密码正确 | 'BAD'=密码错误 | 'PLAIN'=该条目未加密 | 'UNKNOWN'=无法探测
function Test-ZipPassword([string]$p, [string]$pwd) {
    if (-not $script:Python) { return 'UNKNOWN' }
    $probe = Join-Path $env:TEMP ("probe_" + [guid]::NewGuid().ToString('N') + ".py")
    @'
import sys, zipfile
src, pwd = sys.argv[1], sys.argv[2]
try:
    z = zipfile.ZipFile(src)
    infos = [i for i in z.infolist() if not i.filename.endswith('/')]
    if not infos:
        sys.exit(3)
    i0 = infos[0]
    # 未加密的条目，zipfile 会忽略密码直接成功 —— 必须单独区分，否则会误报"密码命中"
    if not (i0.flag_bits & 0x1):
        sys.exit(4)
    with z.open(i0, pwd=pwd.encode()) as f:
        f.read(1024)
    sys.exit(0)
except Exception:
    sys.exit(1)
'@ | Set-Content -LiteralPath $probe -Encoding ASCII
    try {
        & $script:Python $probe $p $pwd 2>&1 | Out-Null
        switch ($LASTEXITCODE) {
            0       { return 'OK' }
            3       { return 'UNKNOWN' }
            4       { return 'PLAIN' }
            default { return 'BAD' }
        }
    }
    finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
}

function Expand-ZipLayer([string]$src, [string]$dst, [string]$pwd) {
    if ($script:SevenZip) {
        $a = @('x', $src, "-o$dst", '-y', '-bso0', '-bsp0')
        if ($pwd) { $a += "-p$pwd" } else { $a += '-p' }
        & $script:SevenZip @a 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        return $false
    }
    if ($script:Bsdtar) {
        $a = @('-xf', $src, '-C', $dst)
        if ($pwd) { $a += @('--passphrase', $pwd) }
        & $script:Bsdtar @a 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        return $false
    }
    if ($script:Python) {
        $py = Join-Path $env:TEMP ("unz_" + [guid]::NewGuid().ToString('N') + ".py")
        @'
import sys, zipfile
src, dst, pwd = sys.argv[1], sys.argv[2], (sys.argv[3] or None)
z = zipfile.ZipFile(src)
z.extractall(dst, pwd=pwd.encode() if pwd else None)
'@ | Set-Content -LiteralPath $py -Encoding ASCII
        try {
            & $script:Python $py $src $dst $pwd 2>&1 | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
        finally { Remove-Item -LiteralPath $py -Force -ErrorAction SilentlyContinue }
    }
    return $false
}

function Expand-TarLayer([string]$src, [string]$dst) {
    $ms = @(Get-TarMembers $src)
    $files = @($ms | Where-Object { $_.Type -eq '0' -or $_.Type -eq [char]0 })
    # 单文件 tar：按偏移直切，彻底绕开文件名
    if ($files.Count -eq 1 -and $ms.Count -le 4) {
        $safe = 'unpacked_layer.bin'
        Copy-Range $src (Join-Path $dst $safe) $files[0].Offset $files[0].Size
        return @([pscustomobject]@{ Name = $files[0].Name; Path = (Join-Path $dst $safe); Size = $files[0].Size; Safe = $true })
    }
    # 多文件：交给外部解包器
    if ($script:SevenZip) {
        & $script:SevenZip @('x', $src, "-o$dst", '-y', '-bso0', '-bsp0') 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return $null }
    }
    if ($script:Bsdtar) {
        & $script:Bsdtar @('-xf', $src, '-C', $dst) 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return $null }
    }
    return $null
}

function Invoke-DefenderScan([string]$p) {
    $mp = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
    if (-not (Test-Path -LiteralPath $mp)) { return }
    Info "Defender 扫描中（大文件较慢）..."
    & $mp -Scan -ScanType 3 -File $p 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "未发现威胁" } else { Warn "扫描返回码 $LASTEXITCODE，请留意" }
}

# ============================================================
# 主流程
# ============================================================
Say ""
Say "==============================================" Cyan
Say "  套娃压缩包自动解包" Cyan
Say "==============================================" Cyan
Say ""
Say ("  7-Zip   : " + $(if ($script:SevenZip) { $script:SevenZip } else { '未安装（建议装，处理 AES 加密和乱码名最好）' }))
Say ("  bsdtar  : " + $(if ($script:Bsdtar) { $script:Bsdtar } else { '未找到' }))
Say ("  Python  : " + $(if ($script:Python) { $script:Python } else { '未找到' }))
Say ""

$src = (Resolve-Path -LiteralPath $Path).Path
if (-not (Test-Path -LiteralPath $src)) { Fail "输入文件不存在: $src"; exit 1 }
if (-not $OutDir) { $OutDir = Join-Path (Split-Path $src -Parent) ((Split-Path $src -Leaf) + '_解出') }
$OutDir = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Say "输入 : $src"
Say ("大小 : {0:N1} MB" -f ((Get-Item -LiteralPath $src).Length / 1MB))
Say "输出 : $OutDir"

if (-not $NoScan) { Invoke-DefenderScan $src }

$work = Join-Path $OutDir '_layers_tmp'
New-Item -ItemType Directory -Force -Path $work | Out-Null

$cur      = $src
$layerSrc = @($src)
$done     = $false
$sw       = [Diagnostics.Stopwatch]::StartNew()

for ($L = 0; $L -lt $MaxLayers; $L++) {

    $type = Get-Magic $cur
    $size = (Get-Item -LiteralPath $cur).Length
    Say ""
    Say ("---- 第 {0} 层  [{1}]  {2:N1} MB ----" -f $L, $type, ($size / 1MB)) Cyan

    if ($type -eq 'RAW') {
        Ok "已不是压缩包 —— 这就是最终内容"
        $done = $true
        break
    }

    $stage = Join-Path $work "L$L"
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    # ---------- ZIP ----------
    if ($type -eq 'ZIP') {
        $entries = $null
        try { $entries = @(Get-ZipEntries $cur) } catch { Warn "读取 zip 目录失败：$($_.Exception.Message)" }

        if ($entries) {
            $files = @($entries | Where-Object { -not $_.IsDir })
            Info ("条目 {0} 个（文件 {1} 个），未压缩合计 {2:N1} MB" -f $entries.Count, $files.Count, (($entries | Measure-Object Size -Sum).Sum / 1MB))

            # 炸弹保护
            $ratio = 1.0
            if ($size -gt 0) { $ratio = (($entries | Measure-Object Size -Sum).Sum) / $size }
            if ($ratio -gt 200) { Fail ("解出体积是压缩包的 {0:N0} 倍，疑似 zip 炸弹，已中止" -f $ratio); exit 2 }

            if ($files.Count -gt 1) { Ok "解出多个文件 —— 真实内容"; $done = $true }

            # 找密码并解包
            $cands  = Get-PwdCandidates $Password ($entries | ForEach-Object { $_.Name })
            $good   = $null
            $isPlain = $false
            if ($script:Python) {
                foreach ($c in $cands) {
                    $t = Test-ZipPassword $cur $c
                    if ($t -eq 'OK')    { $good = $c; break }
                    if ($t -eq 'PLAIN') { $isPlain = $true; break }
                }
            }
            if ($good)    { Ok "自动命中密码：$good" }
            if ($isPlain) { Info "未加密，无需密码" }

            $expanded = Expand-ZipLayer $cur $stage $good
            if (-not $expanded -and -not $script:Python) { $expanded = Expand-ZipLayer $cur $stage '' }
            if (-not $expanded) {
                $manual = Read-Host "  需要密码，请输入（留空=无密码）"
                Remove-Item "$stage\*" -Recurse -Force -ErrorAction SilentlyContinue
                $expanded = Expand-ZipLayer $cur $stage $manual
            }
            if (-not $expanded) {
                Fail "解包失败（密码错误，或条目名畸形）"
                Warn "可尝试：装 7-Zip 后用 -mcp=936 重试"
                exit 3
            }
        }
        else {
            if (-not (Expand-ZipLayer $cur $stage $Password)) { Fail "解包失败"; exit 3 }
        }
    }
    # ---------- TAR ----------
    elseif ($type -eq 'TAR') {
        $ms = @(Get-TarMembers $cur)
        $files = @($ms | Where-Object { $_.Type -eq '0' -or $_.Type -eq [char]0 })
        Info ("成员 {0} 个（文件 {1} 个）" -f $ms.Count, $files.Count)
        if ($files.Count -ne 1) { Ok "解出多个文件 —— 真实内容"; $done = $true }
        $r = @(Expand-TarLayer $cur $stage)
        if ($r.Count -eq 1 -and $r[0]) { Info ("按偏移直切：{0}" -f $r[0].Name) }
        if (-not (Get-ChildItem $stage -Recurse -File -ErrorAction SilentlyContinue)) { Fail "tar 解包失败"; exit 3 }
    }
    # ---------- 其他格式 ----------
    else {
        if (-not $script:SevenZip) { Fail "遇到 $type，需要 7-Zip 才能解（请安装）"; exit 4 }
        & $script:SevenZip @('x', $cur, "-o$stage", '-y', '-bso0', '-bsp0') 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "$type 解包失败"; exit 3 }
    }

    # ---------- 决定是否继续剥 ----------
    $got = @(Get-ChildItem $stage -Recurse -File -ErrorAction SilentlyContinue)
    if ($got.Count -eq 0) { Fail "这一层没解出任何文件"; exit 5 }

    if ($done) {
        # 真实内容，收尾
        foreach ($f in $got) {
            $rel = $f.FullName.Substring($stage.Length).TrimStart('\')
            $dst = Join-Path $OutDir $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
            Move-Item -LiteralPath $f.FullName -Destination $dst -Force
        }
        break
    }

    if ($got.Count -ne 1) {
        Warn ("解出 {0} 个文件，按真实内容处理" -f $got.Count)
        foreach ($f in $got) {
            $rel = $f.FullName.Substring($stage.Length).TrimStart('\')
            $dst = Join-Path $OutDir $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
            Move-Item -LiteralPath $f.FullName -Destination $dst -Force
        }
        break
    }

    # 单文件 -> 继续
    $next = Join-Path $work ("cur_{0}.bin" -f ($L + 1))
    Move-Item -LiteralPath $got[0].FullName -Destination $next -Force
    Info ("单文件，继续剥：{0}" -f $got[0].Name)

    if (-not $KeepLayers) {
        if ($cur -ne $src) { Remove-Item -LiteralPath $cur -Force -ErrorAction SilentlyContinue }
    }
    else { $layerSrc += $cur }
    $cur = $next
}

Say ""
Say "==============================================" Cyan
if ($L -ge $MaxLayers) { Warn "达到层数上限 $MaxLayers，可能还有更多层（用 -MaxLayers 调大）" }

$final = @(Get-ChildItem $OutDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike "$work*" })
$totalMB = ($final | Measure-Object Length -Sum).Sum / 1MB
Ok ("完成：{0} 个文件，共 {1:N1} MB，耗时 {2:N1} 秒" -f $final.Count, $totalMB, $sw.Elapsed.TotalSeconds)
Say ""
$final | Sort-Object Name | Select-Object -First 40 | ForEach-Object {
    Say ("  {0,10:N2} MB  {1}" -f ($_.Length / 1MB), $_.Name)
}
if ($final.Count -gt 40) { Say ("  ... 另外 {0} 个" -f ($final.Count - 40)) }

if (-not $KeepLayers) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
else { Say ""; Say "中间层保留在: $work" }
Say ""
