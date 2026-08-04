$ErrorActionPreference = 'Stop'

# 这个打包脚本只把模块固定文件写入 ZIP 根目录，避免 Magisk 识别到多一层目录。
# 使用脚本自身路径而不是当前工作目录，兼容从 Android Studio 或其他目录调用。
$moduleRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($moduleRoot)) {
    # 某些旧版 PowerShell 在通过相对路径 -File 调用时不会填充 PSScriptRoot；
    # README 的调用位置是项目根目录，因此在这里使用固定的模块相对路径兜底。
    $candidate = Join-Path (Get-Location) 'tools/magisk-shell-rootctl'
    if (Test-Path -LiteralPath (Join-Path $candidate 'module.prop')) {
        $moduleRoot = (Resolve-Path -LiteralPath $candidate).Path
    } else {
        throw '无法定位 Magisk 模块目录，请从项目根目录运行此脚本。'
    }
}
$distDir = Join-Path $moduleRoot 'dist'
$zipPath = Join-Path $distDir 'shell-root-control-v1.2.0.zip'
$stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ('shell-root-control-' + [Guid]::NewGuid().ToString('N'))

New-Item -ItemType Directory -Path $distDir -Force | Out-Null
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

try {
    $include = @(
        'module.prop',
        'post-fs-data.sh',
        'customize.sh',
        'service.sh',
        'rootctld.sh',
        'wirelessd.sh',
        'uninstall.sh',
        'system/bin/rootctl'
    )
    foreach ($relative in $include) {
        $source = Join-Path $moduleRoot $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "缺少模块文件: $relative"
        }
        $destination = Join-Path $stagingDir $relative
        $parent = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $stagingDir '*') -DestinationPath $zipPath -CompressionLevel Optimal

    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Output "ZIP=$zipPath"
    Write-Output "SHA256=$hash"
    Write-Output 'CONTENT='
    [System.IO.Compression.ZipFile]::OpenRead($zipPath).Entries | ForEach-Object { $_.FullName }
}
finally {
    if (Test-Path -LiteralPath $stagingDir) {
        # 递归清理前验证目标仍是本脚本创建的临时目录，避免变量异常时误删宽泛路径。
        $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $stagingFull = [System.IO.Path]::GetFullPath($stagingDir)
        $stagingLeaf = Split-Path -Leaf $stagingFull
        $insideTemp = $stagingFull.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $insideTemp -or $stagingLeaf -notlike 'shell-root-control-*') {
            throw "拒绝清理未验证的临时目录: $stagingFull"
        }
        Remove-Item -LiteralPath $stagingFull -Recurse -Force
    }
}
