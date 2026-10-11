# DIMI release 构建（Windows PowerShell）：注入正式环境地址（--dart-define），产出 release APK。
# 用法：
#   $env:API_BASE_URL = 'https://api.dimi.example.com/v1'   # 必填
#   $env:H5_BASE_URL  = 'https://h5.dimi.example.com/h5/'   # 必填
#   $env:ICP_NUMBER   = '京ICP备00000000号-1A'              # 可选，展示在「关于 DIMI」页
#   powershell -File tool/build_release.ps1
$ErrorActionPreference = 'Stop'

Set-Location (Join-Path $PSScriptRoot '..')

if (-not $env:API_BASE_URL) {
    throw '必须设置 API_BASE_URL（正式环境 API 地址，如 https://api.dimi.example.com/v1）'
}
if (-not $env:H5_BASE_URL) {
    throw '必须设置 H5_BASE_URL（召集令 H5 落地页地址）'
}

$dartDefines = @(
    "--dart-define=API_BASE_URL=$env:API_BASE_URL",
    "--dart-define=H5_BASE_URL=$env:H5_BASE_URL"
)
if ($env:ICP_NUMBER) {
    $dartDefines += "--dart-define=ICP_NUMBER=$env:ICP_NUMBER"
}

& flutter build apk --release @dartDefines
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host '构建完成：app/build/app/outputs/flutter-apk/app-release.apk'
