$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$nodePath = (Get-Command node.exe -ErrorAction Stop).Source
$entry = Join-Path $PSScriptRoot 'reading-preview.mjs'
$stdoutLog = Join-Path $repoRoot 'docs/reading-preview-service.log'
$stderrLog = Join-Path $repoRoot 'docs/reading-preview-service-error.log'
$url = 'http://127.0.0.1:18089/h5/'
$listener = Get-NetTCPConnection -LocalPort 18089 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1

if ($listener) {
    $running = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)"
    if ($running.CommandLine -notmatch 'reading-preview[.]mjs') {
        throw 'Port 18089 belongs to another service. Stop that service before starting the DIMI preview.'
    }
} else {
    $process = Start-Process -FilePath $nodePath -ArgumentList ('"' + $entry + '"') -WorkingDirectory $repoRoot -WindowStyle Hidden -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru
}

$ready = $false
for ($attempt = 0; $attempt -lt 12; $attempt++) {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
        if ($response.StatusCode -eq 200) { $ready = $true; break }
    } catch {
        if ($process -and $process.HasExited) { break }
        Start-Sleep -Milliseconds 500
    }
}
if (-not $ready) { throw "Preview did not start. See $stderrLog" }

Write-Host 'DIMI preview is running in the background. No account registration is needed.'
Write-Host 'Connect the phone and computer to the same Wi-Fi, then open the latest APK.'
Write-Host 'Phone connection check: http://192.168.3.55:18089/h5/'
Write-Host 'Keep this computer awake. Run this launcher again after restarting the computer.'
if (-not (Get-NetIPAddress -AddressFamily IPv4 -IPAddress '192.168.3.55' -ErrorAction SilentlyContinue)) {
    Write-Warning 'The computer IP has changed. The current APK expects 192.168.3.55; rebuild it with the new address.'
}
