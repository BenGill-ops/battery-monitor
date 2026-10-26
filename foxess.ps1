param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Body = '{}',
    [string]$Method = 'POST'
)
# Reads the key from the environment (or the Windows user environment); never prints it.
$key = $env:FOXESS_API_KEY
if (-not $key -and $IsWindows -ne $false) { $key = [Environment]::GetEnvironmentVariable('FOXESS_API_KEY', 'User') }
if (-not $key) { Write-Error 'FOXESS_API_KEY not set'; exit 1 }
$key = $key.Trim()

$ts = [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
# FoxESS signs with a literal backslash-r-backslash-n separator.
$raw = ($Path -split '\?')[0] + '\r\n' + $key + '\r\n' + $ts
$md5 = [System.Security.Cryptography.MD5]::Create()
$sig = -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($raw)) | ForEach-Object { $_.ToString('x2') })

$headers = @{ token = $key; timestamp = $ts; signature = $sig; lang = 'en' }
$uri = 'https://www.foxesscloud.com' + $Path
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($Method -eq 'GET') {
    $r = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
} else {
    $r = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $Body -ContentType 'application/json'
}
$r | ConvertTo-Json -Depth 10
