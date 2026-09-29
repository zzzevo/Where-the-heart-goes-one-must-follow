#Requires -Version 5.1
<#
  make-test-archive.ps1 —— 生成一个模拟「套娃 + 畸形文件名」的测试包

  生成的嵌套结构（从外到内）：
      外层 tar  ->  zip  ->  tar  ->  内容 zip（内含 3 个文本文件）

  其中外层 tar 的文件名会被故意追加一个多字节字符（模拟真实分享包中
  常见的「破坏文件名」手法），用来验证 unpack-nested.ps1 的
  「按偏移直切」分支能否正常工作。

  用法：
      powershell -ExecutionPolicy Bypass -File .\make-test-archive.ps1
      powershell -ExecutionPolicy Bypass -File ..\unpack-nested.ps1 .\_out\nested-test.tar
#>
[CmdletBinding()]
param(
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
# 注意：$PSScriptRoot 在 param() 默认值求值时可能为空，必须放到运行时再算
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot '_out' }

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say ""
Say "=== 生成套娃测试包 ===" Cyan

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("mkzip_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

try {
    # ---------- 1. 造 3 个内容文件 ----------
    $content = Join-Path $tmp 'content'
    New-Item -ItemType Directory -Force -Path $content | Out-Null
    1..3 | ForEach-Object {
        $body = ("这是测试文件 {0}`r`n" -f $_) * 200
        Set-Content -LiteralPath (Join-Path $content ("part{0}.txt" -f $_)) -Value $body -Encoding UTF8
    }
    Say "  已生成 3 个内容文件"

    # ---------- 2. 内容 zip（最内层） ----------
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip1 = Join-Path $tmp 'content.zip'
    $z = [IO.Compression.ZipFile]::Open($zip1, 'Create')
    try {
        foreach ($f in Get-ChildItem $content -File) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f.FullName, $f.Name)
        }
    }
    finally { $z.Dispose() }
    Say ("  第 3 层 zip  : {0:N0} 字节" -f (Get-Item $zip1).Length)

    # ---------- 3. 包一层 tar ----------
    $tar1 = Join-Path $tmp 'L2.tar'
    & tar.exe -cf $tar1 -C $tmp 'content.zip'
    if ($LASTEXITCODE -ne 0) { throw "tar 打包失败" }
    Say ("  第 2 层 tar  : {0:N0} 字节" -f (Get-Item $tar1).Length)

    # ---------- 4. 包一层 zip ----------
    $zip2 = Join-Path $tmp 'L1.zip'
    $z = [IO.Compression.ZipFile]::Open($zip2, 'Create')
    try {
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $tar1, 'L2.tar')
    }
    finally { $z.Dispose() }
    Say ("  第 1 层 zip  : {0:N0} 字节" -f (Get-Item $zip2).Length)

    # ---------- 5. 包一层 tar（最外层） ----------
    $tar2 = Join-Path $tmp 'L0.tar'
    & tar.exe -cf $tar2 -C $tmp 'L1.zip'
    if ($LASTEXITCODE -ne 0) { throw "tar 打包失败" }
    Say ("  第 0 层 tar  : {0:N0} 字节" -f (Get-Item $tar2).Length)

    # ---------- 6. 破坏外层 tar 的文件名 ----------
    #    在 name 字段（偏移 0，最多 100 字节）的结尾追加 U+5220（E5 88 A0）
    $bytes = [IO.File]::ReadAllBytes($tar2)
    if ([Text.Encoding]::ASCII.GetString($bytes, 257, 5) -ne 'ustar') { throw "不是预期的 tar 结构" }
    $nameEnd = 0
    while ($nameEnd -lt 100 -and $bytes[$nameEnd] -ne 0) { $nameEnd++ }
    $inject = [byte[]](0xE5, 0x88, 0xA0)
    for ($i = 0; $i -lt $inject.Length; $i++) {
        if ($nameEnd + $i -ge 100) { throw "name 字段放不下" }
        $bytes[$nameEnd + $i] = $inject[$i]
    }
    $final = Join-Path $OutDir 'nested-test.tar'
    [IO.File]::WriteAllBytes($final, $bytes)
    Say "  已在外层 tar 的文件名末尾注入多字节字符（模拟畸形名）"

    Say ""
    Say "完成：" Green
    Say ("  测试包 : {0}" -f $final)
    Say ("  大小   : {0:N0} 字节" -f (Get-Item $final).Length)
    Say ""
    Say "接下来验证：" Cyan
    Say ("  powershell -ExecutionPolicy Bypass -File `"$((Resolve-Path (Join-Path $PSScriptRoot '..\unpack-nested.ps1')).Path)`" `"$final`"")
    Say "  期望：剥 4 层，最终得到 3 个 part*.txt"
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
