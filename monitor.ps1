# Read-only battery monitor: checks FoxESS + Amber and pushes alerts to ntfy.
# Never changes inverter settings. Runs every 5 minutes on GitHub Actions (or locally with -DryRun).
param([switch]$DryRun, [switch]$ForceSummary, [switch]$ForceMorning, [switch]$Test)

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
if ($env:WEATHER_LAT) { $cfg.latitude = [double]$env:WEATHER_LAT }
if ($env:WEATHER_LON) { $cfg.longitude = [double]$env:WEATHER_LON }
$api = Join-Path $dir 'foxess.ps1'
$statePath = Join-Path $dir 'state.json'
$logPath = Join-Path $dir 'monitor.log'

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    $line | Add-Content $logPath -Encoding utf8
    Write-Host $line   # also shows in the GitHub Actions run log
}

function Send-Alert($title, $msg, $priority = 'default', $tags = 'battery') {
    # Quiet hours: only urgent alerts go out; the rest are held for the morning outlook.
    if ($quiet -and $priority -ne 'urgent') {
        $state['overnight'] = (@($state['overnight']) + "$($now.ToString('h:mm tt').ToLower()) $title") -ne $null
        Log "HELD (quiet hours) $title :: $msg"
        return
    }
    if ($DryRun) { Write-Output "[DRY RUN] $title :: $msg"; return }
    $headers = @{ Title = $title; Priority = $priority; Tags = $tags }
    Invoke-RestMethod -Uri "https://ntfy.sh/$($cfg.ntfyTopic)" -Method Post -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($msg)) | Out-Null
    Log "SENT $title :: $msg"
}

function Fox($path, $body) {
    try { & $api -Path $path -Body $body | ConvertFrom-Json }
    catch { throw "FoxESS $path : $($_.Exception.Message)" }
}

function Amber($path) {
    $key = $env:AMBER_API_KEY
    if (-not $key) { $key = [Environment]::GetEnvironmentVariable('AMBER_API_KEY', 'User') }
    $key = $key.Trim()
    Invoke-RestMethod -Uri ('https://api.amber.com.au/v1' + $path) -Headers @{ Authorization = "Bearer $key" }
}

# Open-Meteo forecast (free, no key). Returns $null if no location is configured.
function Get-Weather {
    if ($null -eq $cfg.latitude -or $null -eq $cfg.longitude) { return $null }
    $u = 'https://api.open-meteo.com/v1/forecast?latitude={0}&longitude={1}&timezone=Australia%2FBrisbane&forecast_days=2' -f $cfg.latitude, $cfg.longitude
    $u += '&hourly=weather_code,precipitation_probability,cape,wind_gusts_10m&daily=shortwave_radiation_sum,precipitation_probability_max,wind_gusts_10m_max'
    Invoke-RestMethod $u
}

# Storm hours: thunderstorm codes (95-99), or unstable air (high CAPE) with likely rain.
function Get-StormHours($wx, [datetime]$from, [datetime]$to) {
    $hours = @()
    for ($i = 0; $i -lt $wx.hourly.time.Count; $i++) {
        $t = [datetime]$wx.hourly.time[$i]
        if ($t -lt $from -or $t -ge $to) { continue }
        $code = [int]$wx.hourly.weather_code[$i]
        $storm = $code -ge 95 -or ([double]$wx.hourly.cape[$i] -ge $cfg.stormCape -and [double]$wx.hourly.precipitation_probability[$i] -ge $cfg.stormRainPct)
        if ($storm) { $hours += [pscustomobject]@{ Time = $t; Rain = $wx.hourly.precipitation_probability[$i]; Gust = $wx.hourly.wind_gusts_10m[$i] } }
    }
    $hours
}

function Format-StormWindow($hours) {
    $first = $hours[0].Time; $last = $hours[-1].Time.AddHours(1)
    $rain = ($hours.Rain | Measure-Object -Maximum).Maximum
    $gust = ($hours.Gust | Measure-Object -Maximum).Maximum
    '{0}-{1} (rain up to {2}%, gusts {3} km/h)' -f $first.ToString('h tt').ToLower(), $last.ToString('h tt').ToLower(), $rain, [math]::Round($gust)
}

# Active BOM warnings that mention your area (cancellations and final notices are skipped).
function Get-BomWarnings {
    $xml = [xml](Invoke-WebRequest $cfg.bomWarningsFeed -UseBasicParsing -UserAgent 'Mozilla/5.0 (battery-monitor)').Content
    foreach ($item in $xml.rss.channel.item) {
        $title = ($item.title -replace '\s+', ' ').Trim()
        if ($title -match 'Cancellation|Final ') { continue }
        $area = $cfg.bomAreaWords | Where-Object { $title -like "*$_*" }
        $kind = $cfg.bomWarningWords | Where-Object { $title -like "*$_*" }
        if ($area -and $kind) { [pscustomobject]@{ Title = $title; Link = $item.link; Id = "$($item.link)|$($item.pubDate)"; Severe = $title -match 'Severe Thunderstorm|Tropical Cyclone|Severe Weather' } }
    }
}

function Get-SolarEstimate($wx, $dayIndex) { [math]::Round([double]$wx.daily.shortwave_radiation_sum[$dayIndex] * $cfg.solarKwhPerMJ) }

if ($Test) { Send-Alert 'Battery monitor' 'Test alert - the monitor can reach your phone.' 'default' 'white_check_mark'; exit }

# State remembers when each alert last fired, so you aren't spammed.
$state = @{}
if (Test-Path $statePath) { (Get-Content $statePath -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $state[$_.Name] = $_.Value } }
# Work in Brisbane time (no daylight saving) so night hours are right on a UTC cloud runner.
$tzId = if ($IsLinux -or $IsMacOS) { 'Australia/Brisbane' } else { 'E. Australia Standard Time' }
$now = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow, $tzId)
$quiet = $now.Hour -ge $cfg.quietStartHour -or $now.Hour -lt $cfg.quietEndHour
# A "night" runs from evening to morning, so key it by the date it started.
$nightKey = $(if ($now.Hour -lt 12) { $now.Date.AddDays(-1) } else { $now.Date }).ToString('yyyy-MM-dd')
function Due($name) { -not $state[$name] -or ($now - [datetime]$state[$name]).TotalMinutes -ge $cfg.repeatMinutes }
function Mark($name) { $state[$name] = $now.ToString('o') }

try {
    $rt = Fox '/op/v0/device/real/query' ('{"sn":"' + $cfg.foxessSN + '","variables":["SoC","batDischargePower","batChargePower","loadsPower","feedinPower","gridConsumptionPower","pvPower","RVolt","epsPower","runningState"]}')
    if ($rt.errno -ne 0) { throw "FoxESS errno $($rt.errno) $($rt.msg)" }
    $d = @{}; $rt.result[0].datas | ForEach-Object { $d[$_.variable] = [double]$_.value }
    $soc = $d.SoC

    # 0. Blackout detection (urgent, any time of night).
    # Grid voltage drops to ~0 when the grid fails while the inverter keeps reporting on battery.
    # If the internet router isn't on backup power, readings stop instead - so stale data is flagged too.
    $readAt = [datetime]::ParseExact($rt.result[0].time.Substring(0, 19), 'yyyy-MM-dd HH:mm:ss', $null)
    $staleMin = [math]::Round(($now - $readAt).TotalMinutes)
    if ($staleMin -ge $cfg.staleMinutes) {
        if (-not $state['stale']) {
            Send-Alert 'Lost contact with battery' "No data from the inverter for $staleMin minutes. Possible blackout (if the internet router has no backup power) or an internet/Wi-Fi outage.`nLast reading: battery $soc%." 'urgent' 'rotating_light'
            $state['stale'] = $now.ToString('o')
        }
    } else {
        if ($state['stale']) { Send-Alert 'Battery back online' "Inverter data is coming through again. Battery at $soc%." 'default' 'white_check_mark'; $state.Remove('stale') }
        $gridDown = $null -ne $d.RVolt -and $d.RVolt -lt $cfg.gridDownVolts
        if ($gridDown -and -not $state['gridDown']) {
            Send-Alert 'BLACKOUT - grid power is off' "Grid voltage is $($d.RVolt) V. The house is running on battery (backup circuit) at $soc%, using $($d.epsPower) kW." 'urgent' 'rotating_light'
            $state['gridDown'] = $now.ToString('o')
        } elseif (-not $gridDown -and $state['gridDown']) {
            $mins = [math]::Round(($now - [datetime]$state['gridDown']).TotalMinutes)
            Send-Alert 'Grid power is back' "Grid restored ($($d.RVolt) V) after about $mins minutes. Battery at $soc%." 'default' 'white_check_mark'
            $state.Remove('gridDown')
        }
    }

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

    $wx = $null
    try { $wx = Get-Weather } catch { Log "Weather error: $($_.Exception.Message)" }
    $stormSoon = @()
    if ($wx) { $stormSoon = @(Get-StormHours $wx $now.AddHours(-1) $now.AddHours($cfg.stormLookaheadHours)) }

    $night = $now.Hour -ge $cfg.nightStartHour -or $now.Hour -lt $cfg.nightEndHour
    $line = 'SoC {0}% | load {1} kW | solar {2} kW | export {3} kW | grid {4} kW | mode {5} | buy {6}c | feed-in {7}c' -f $soc, $d.loadsPower, $d.pvPower, $d.feedinPower, $d.gridConsumptionPower, $activeMode, [math]::Round([double]$price,1), [math]::Round([double]$feedPrice,1)
    if ($DryRun) { Write-Output $line; if ($stormSoon.Count) { Write-Output "Storm in next $($cfg.stormLookaheadHours)h: $(Format-StormWindow $stormSoon)" } }

    # Remember the lowest battery level overnight for the morning outlook.
    if ($quiet -and ($null -eq $state['overnightMinSoc'] -or $soc -lt [double]$state['overnightMinSoc'])) {
        $state['overnightMinSoc'] = $soc; $state['overnightMinAt'] = $now.ToString('h:mm tt').ToLower()
    }

    # 1. Low battery at night - once per night
    if ($night -and $soc -lt $cfg.lowBatteryPct -and $state['lowBatteryNight'] -ne $nightKey) {
        $hrs = if ($d.loadsPower -gt 0.1) { [math]::Round(((($soc - 10) / 100) * 41.9) / $d.loadsPower, 1) } else { 'many' }
        Send-Alert "Battery low: $soc%" "Battery is at $soc% with the house using $($d.loadsPower) kW. About $hrs h until the 10% floor." 'high' 'warning'
        $state['lowBatteryNight'] = $nightKey
    }

    # 2. Amber force-exporting while the battery is already low
    # Schedule windows can linger after Amber stops, so require real export too.
    $exporting = $d.feedinPower -gt 1 -and ($activeMode -like 'ForceDischarge*' -or $d.pvPower -lt 0.5)
    if ($exporting -and $soc -lt $cfg.exportBelowPct -and (Due 'lowExport')) {
        $fp = if ($feedPrice -ne $null) { " for $([math]::Round($feedPrice,1))c/kWh" } else { '' }
        Send-Alert "Exporting at $soc%" "Amber is sending $($d.feedinPower) kW to the grid$fp while the battery is at $soc%." 'high' 'electric_plug'
        Mark 'lowExport'
    }

    # 2b. Exporting while a storm (possible blackout) is close - urgent at any battery level
    if ($exporting -and $stormSoon.Count -gt 0 -and (Due 'stormExport')) {
        Send-Alert "Exporting before a storm ($soc%)" "Amber is sending $($d.feedinPower) kW to the grid with storms forecast $(Format-StormWindow $stormSoon). Battery at $soc%. Consider pausing SmartShift to keep backup power." 'urgent' 'zap'
        Mark 'stormExport'
    }

    # 2c. BOM warning for your area - sent once per issued warning
    $bom = @()
    try { $bom = @(Get-BomWarnings) } catch { Log "BOM error: $($_.Exception.Message)" }
    foreach ($w in $bom) {
        if ($state["bom:$($w.Id)"]) { continue }
        $extra = if ($exporting) { " Amber is exporting $($d.feedinPower) kW right now - consider pausing SmartShift." } else { '' }
        Send-Alert 'BOM warning for your area' "$($w.Title)`nBattery at $soc%.$extra`n$($w.Link)" $(if ($w.Severe) { 'urgent' } else { 'high' }) 'rotating_light'
        $state["bom:$($w.Id)"] = $now.ToString('o')
    }
    if ($DryRun) { Write-Output "BOM warnings for area: $($bom.Count)"; $bom | ForEach-Object { Write-Output "  $($_.Title)" } }

    # 3. Buying from the grid at a high price
    if ($price -ne $null -and $price -ge $cfg.highPriceCents -and $d.gridConsumptionPower -ge $cfg.gridImportKw -and (Due 'highPrice')) {
        Send-Alert "Buying power at $([math]::Round($price))c" "Importing $($d.gridConsumptionPower) kW from the grid at $([math]::Round($price,1))c/kWh. Battery at $soc%." 'default' 'moneybag'
        Mark 'highPrice'
    }

    $today = $now.ToString('yyyy-MM-dd')

    # 4. Morning weather outlook, once per day on the first run between morningHour and noon (GitHub can skip runs)
    # Includes an overnight recap: lowest battery and any alerts held during quiet hours.
    if ($ForceMorning -or (-not $quiet -and $now.Hour -ge $cfg.morningHour -and $now.Hour -lt 12 -and $state['morningDate'] -ne $today)) {
        $recap = ''
        if ($null -ne $state['overnightMinSoc']) { $recap = "`nOvernight: lowest battery $($state['overnightMinSoc'])% at $($state['overnightMinAt'])." }
        $held = @($state['overnight']) -ne $null
        if ($held.Count) { $recap += "`nHeld overnight: " + ($held -join '; ') }
        if (-not $wx) {
            Send-Alert "Good morning" "Battery at $soc%. (Weather forecast unavailable.)$recap" 'low' 'battery'
        } else {
            $dayStorms = @(Get-StormHours $wx $now.Date $now.Date.AddDays(1))
            $solar = Get-SolarEstimate $wx 0
            if ($dayStorms.Count -gt 0) {
                Send-Alert "Storms forecast today" "Storms likely $(Format-StormWindow $dayStorms). Possible blackout.`nBattery at $soc%, solar expected ~$solar kWh.`nTo keep backup power, consider raising the reserve or pausing SmartShift this afternoon.$recap" 'high' 'cloud_with_lightning'
            } else {
                Send-Alert "Today's solar outlook" "Solar expected ~$solar kWh, rain chance $($wx.daily.precipitation_probability_max[0])%. No storms forecast.`nBattery at $soc%.$recap" 'low' 'partly_sunny'
            }
        }
        if (-not $ForceMorning) {
            $state['morningDate'] = $today
            $state.Remove('overnight'); $state.Remove('overnightMinSoc'); $state.Remove('overnightMinAt')
        }
    }

    # 5. Daily summary, once per day on the first run from summaryHour to midnight
    if ($ForceSummary -or ($now.Hour -ge $cfg.summaryHour -and $state['summaryDate'] -ne $today)) {
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
        $outlook = ''
        if ($wx) {
            $tmrStorms = @(Get-StormHours $wx $now.Date.AddDays(1) $now.Date.AddDays(2))
            $outlook = "`nTomorrow: ~$(Get-SolarEstimate $wx 1) kWh solar expected"
            if ($tmrStorms.Count -gt 0) { $outlook += ", storms $(Format-StormWindow $tmrStorms)" }
        }
        $msg = "Solar $($t.PVEnergyTotal) kWh | used $($t.loads) kWh`nExported $($t.feedin) kWh | bought $($t.gridConsumption) kWh`nBattery now $soc%$money$outlook"
        Send-Alert 'Daily battery summary' $msg 'default' 'sunny'
        if (-not $ForceSummary) { $state['summaryDate'] = $today }
    }
    $state['errorCount'] = 0
} catch {
    Log "ERROR $($_.Exception.Message)"
    if ($DryRun) { throw }
    # One-off cloud hiccups are common; only tell you after 3 failed runs in a row (about 15 minutes),
    # and then at most once per repeat window.
    $state['errorCount'] = [int]$state['errorCount'] + 1
    if ($state['errorCount'] -ge 3 -and (Due 'error')) {
        try { Send-Alert 'Battery monitor error' "Failing for $($state['errorCount']) runs in a row: $($_.Exception.Message)" 'low' 'x' } catch {}
        Mark 'error'
    }
}

if (-not $DryRun) { $state | ConvertTo-Json | Set-Content $statePath -Encoding utf8 }
