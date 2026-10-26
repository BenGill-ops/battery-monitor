# Read-only battery monitor: checks FoxESS + Amber and pushes alerts to ntfy.
# Never changes inverter settings. Runs every 5 minutes on GitHub Actions (or locally with -DryRun).
param([switch]$DryRun, [switch]$ForceSummary, [switch]$Test)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = $PSScriptRoot
$cfg = Get-Content (Join-Path $dir 'config.json') -Raw | ConvertFrom-Json
# Private identifiers live in config.local.json (not committed) or, on GitHub Actions, in repository secrets.
$localCfg = Join-Path $dir 'config.local.json'
if (Test-Path $localCfg) { (Get-Content $localCfg -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $cfg.($_.Name) = $_.Value } }
if ($env:NTFY_TOPIC) { $cfg.ntfyTopic = $env:NTFY_TOPIC }
if ($env:FOXESS_SN) { $cfg.foxessSN = $env:FOXESS_SN }
if ($env:AMBER_SITE_ID) { $cfg.amberSiteId = $env:AMBER_SITE_ID }
$api = Join-Path $dir 'foxess.ps1'
$statePath = Join-Path $dir 'state.json'
$logPath = Join-Path $dir 'monitor.log'

function Log($msg) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Add-Content $logPath -Encoding utf8 }

function Send-Alert($title, $msg, $priority = 'default', $tags = 'battery') {
    if ($DryRun) { Write-Output "[DRY RUN] $title :: $msg"; return }
    $headers = @{ Title = $title; Priority = $priority; Tags = $tags }
    Invoke-RestMethod -Uri "https://ntfy.sh/$($cfg.ntfyTopic)" -Method Post -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($msg)) | Out-Null
    Log "SENT $title :: $msg"
}

function Fox($path, $body) { & $api -Path $path -Body $body | ConvertFrom-Json }

function Amber($path) {
    $key = $env:AMBER_API_KEY
    if (-not $key) { $key = [Environment]::GetEnvironmentVariable('AMBER_API_KEY', 'User') }
    $key = $key.Trim()
    Invoke-RestMethod -Uri ('https://api.amber.com.au/v1' + $path) -Headers @{ Authorization = "Bearer $key" }
}

if ($Test) { Send-Alert 'Battery monitor' 'Test alert - the monitor can reach your phone.' 'default' 'white_check_mark'; exit }

# State remembers when each alert last fired, so you aren't spammed.
$state = @{}
if (Test-Path $statePath) { (Get-Content $statePath -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $state[$_.Name] = $_.Value } }
# Work in Brisbane time (no daylight saving) so night hours are right on a UTC cloud runner.
$tzId = if ($IsLinux -or $IsMacOS) { 'Australia/Brisbane' } else { 'E. Australia Standard Time' }
$now = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow, $tzId)
function Due($name) { -not $state[$name] -or ($now - [datetime]$state[$name]).TotalMinutes -ge $cfg.repeatMinutes }
function Mark($name) { $state[$name] = $now.ToString('o') }

try {
    $rt = Fox '/op/v0/device/real/query' ('{"sn":"' + $cfg.foxessSN + '","variables":["SoC","batDischargePower","batChargePower","loadsPower","feedinPower","gridConsumptionPower","pvPower"]}')
    if ($rt.errno -ne 0) { throw "FoxESS errno $($rt.errno) $($rt.msg)" }
    $d = @{}; $rt.result[0].datas | ForEach-Object { $d[$_.variable] = [double]$_.value }
    $soc = $d.SoC

    $sched = Fox '/op/v1/device/scheduler/get' ('{"deviceSN":"' + $cfg.foxessSN + '"}')
    $hm = $now.Hour * 60 + $now.Minute
    $activeMode = ($sched.result.groups | Where-Object {
        $_.enable -eq 1 -and $hm -ge ($_.startHour * 60 + $_.startMinute) -and $hm -le ($_.endHour * 60 + $_.endMinute)
    } | Select-Object -First 1).workMode

    $price = $null; $feedPrice = $null
    try {
        $p = Amber "/sites/$($cfg.amberSiteId)/prices/current"
        $price = ($p | Where-Object channelType -eq 'general' | Select-Object -First 1).perKwh
        $feedPrice = -($p | Where-Object channelType -eq 'feedIn' | Select-Object -First 1).perKwh
    } catch { Log "Amber price error: $($_.Exception.Message)" }

    $night = $now.Hour -ge $cfg.nightStartHour -or $now.Hour -lt $cfg.nightEndHour
    $line = 'SoC {0}% | load {1} kW | solar {2} kW | export {3} kW | grid {4} kW | mode {5} | price {6}c' -f $soc, $d.loadsPower, $d.pvPower, $d.feedinPower, $d.gridConsumptionPower, $activeMode, $price
    if ($DryRun) { Write-Output $line }

    # 1. Low battery at night
    if ($night -and $soc -lt $cfg.lowBatteryPct -and (Due 'lowBattery')) {
        $hrs = if ($d.loadsPower -gt 0.1) { [math]::Round(((($soc - 10) / 100) * 41.9) / $d.loadsPower, 1) } else { 'many' }
        Send-Alert "Battery low: $soc%" "Battery is at $soc% with the house using $($d.loadsPower) kW. About $hrs h until the 10% floor." 'high' 'warning'
        Mark 'lowBattery'
    }

    # 2. Amber force-exporting while the battery is already low
    # Schedule windows can linger after Amber stops, so require real export too.
    $exporting = $d.feedinPower -gt 1 -and ($activeMode -like 'ForceDischarge*' -or $d.pvPower -lt 0.5)
    if ($exporting -and $soc -lt $cfg.exportBelowPct -and (Due 'lowExport')) {
        $fp = if ($feedPrice -ne $null) { " for $([math]::Round($feedPrice,1))c/kWh" } else { '' }
        Send-Alert "Exporting at $soc%" "Amber is sending $($d.feedinPower) kW to the grid$fp while the battery is at $soc%." 'high' 'electric_plug'
        Mark 'lowExport'
    }

    # 3. Buying from the grid at a high price
    if ($price -ne $null -and $price -ge $cfg.highPriceCents -and $d.gridConsumptionPower -ge $cfg.gridImportKw -and (Due 'highPrice')) {
        Send-Alert "Buying power at $([math]::Round($price))c" "Importing $($d.gridConsumptionPower) kW from the grid at $([math]::Round($price,1))c/kWh. Battery at $soc%." 'default' 'moneybag'
        Mark 'highPrice'
    }

    # 4. Daily summary, once per day at summaryHour
    $today = $now.ToString('yyyy-MM-dd')
    if ($ForceSummary -or ($now.Hour -eq $cfg.summaryHour -and $state['summaryDate'] -ne $today)) {
        $rep = Fox '/op/v0/device/report/query' ('{"sn":"' + $cfg.foxessSN + '","year":' + $now.Year + ',"month":' + $now.Month + ',"dimension":"month","variables":["PVEnergyTotal","loads","feedin","gridConsumption"]}')
        $t = @{}; foreach ($v in $rep.result) { $t[$v.variable] = [math]::Round([double]$v.values[$now.Day - 1], 1) }
        $money = ''
        try {
            # Amber's usage data lags by a day or more, so report two days back.
            $y = $now.AddDays(-2).ToString('yyyy-MM-dd')
            $u = Amber "/sites/$($cfg.amberSiteId)/usage?startDate=$y&endDate=$y"
            $cost = (($u | Where-Object channelIdentifier -eq 'E1' | Measure-Object cost -Sum).Sum) / 100
            $earn = -(($u | Where-Object channelIdentifier -eq 'B1' | Measure-Object cost -Sum).Sum) / 100
            $money = "`n$y (Amber): earned `${0:N2}, spent `${1:N2}, net `${2:N2}" -f $earn, $cost, ($earn - $cost)
        } catch { Log "Amber usage error: $($_.Exception.Message)" }
        $msg = "Solar $($t.PVEnergyTotal) kWh | used $($t.loads) kWh`nExported $($t.feedin) kWh | bought $($t.gridConsumption) kWh`nBattery now $soc%$money"
        Send-Alert 'Daily battery summary' $msg 'low' 'sunny'
        if (-not $ForceSummary) { $state['summaryDate'] = $today }
    }
} catch {
    Log "ERROR $($_.Exception.Message)"
    if ($DryRun) { throw }
    # Tell you if the monitor itself keeps failing (at most once per repeat window).
    if (Due 'error') { try { Send-Alert 'Battery monitor error' $_.Exception.Message 'low' 'x' } catch {}; Mark 'error' }
}

if (-not $DryRun) { $state | ConvertTo-Json | Set-Content $statePath -Encoding utf8 }
