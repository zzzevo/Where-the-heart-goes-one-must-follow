#Requires -Version 5.1
<#
  install-context-menu.ps1 —— 把「用 Nested Unpacker 解包」加进右键菜单

  只写 HKCU，不需要管理员权限，也不会影响系统其他用户。
  卸载： .\install-context-menu.ps1 -Uninstall

  用法：
      powershell -ExecutionPolicy Bypass -File .\tools\install-context-menu.ps1
      powershell -ExecutionPolicy Bypass -File .\tools\install-context-menu.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$keyName = 'NestedUnpacker'
$menuText = '用 Nested Unpacker 解包'

# 脚本本体位置（本文件在 tools\ 下，往上一层）
$ps1 = Join-Path (Split-Path $PSScriptRoot -Parent) 'unpack-nested.ps1'
if (-not (Test-Path -LiteralPath $ps1)) { throw "找不到 unpack-nested.ps1: $ps1" }
$ps1 = (Resolve-Path -LiteralPath $ps1).Path

# 要挂右键菜单的扩展名
$exts = @('.zip', '.tar', '.rar', '.7z', '.gz', '.tgz', '.xz', '.bz2', '.cab', '.iso', '.001')

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

if ($Uninstall) {
    Say ""
    Say "=== 移除右键菜单 ===" Cyan
    foreach ($e in $exts) {
        $p = "HKCU:\Software\Classes\SystemFileAssociations\$e\shell\$keyName"
        if (Test-Path $p) {
            Remove-Item -LiteralPath $p -Recurse -Force
            Say "  已移除 $e"
        }
    }
    Say ""
    Say "完成。资源管理器可能需要刷新（重启 explorer 或注销）。" Green
    Say ""
    exit 0
}

Say ""
Say "=== 安装右键菜单 ===" Cyan
Say ("  脚本路径: {0}" -f $ps1)
Say ""

$cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" "%1"' -f $ps1

foreach ($e in $exts) {
    $base = "HKCU:\Software\Classes\SystemFileAssociations\$e\shell\$keyName"
    if (-not (Test-Path $base)) { New-Item -Path $base -Force | Out-Null }
    New-ItemProperty -Path $base -Name '(default)' -Value $menuText -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $base -Name 'Icon' -Value 'powershell.exe,0' -PropertyType String -Force | Out-Null

    $cmdKey = Join-Path $base 'command'
    if (-not (Test-Path $cmdKey)) { New-Item -Path $cmdKey -Force | Out-Null }
    New-ItemProperty -Path $cmdKey -Name '(default)' -Value $cmd -PropertyType String -Force | Out-Null
    Say "  已注册 $e"
}

Say ""
Say "完成。请注销或重启资源管理器后生效：" Green
Say "  taskkill /f /im explorer.exe ; start explorer.exe"
Say ""
Say "卸载： powershell -ExecutionPolicy Bypass -File .\tools\install-context-menu.ps1 -Uninstall" Cyan
Say ""
