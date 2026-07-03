<#
    Independent MATLAB self-check diagnostic utility - NOT affiliated with, endorsed by, or
    created by The MathWorks, Inc. "MATLAB" is a registered trademark of The MathWorks, Inc.

    Runs local checks useful for a MATLAB support request (system requirements, license file
    validity, network license server reachability, today's log entries) and writes only the
    PASS/FAIL results to a report. Your MAC address, hostname, and disk identifiers are read
    in memory ONLY to compare against your MATLAB license file - they are never written to
    the report. No admin rights required. Nothing is sent over the network except a DNS
    lookup and a TCP connection test against the license server named in your own license
    file. See ../README.md for the full privacy notice.
#>

param(
    [string]$OutputDir = $PSScriptRoot
)

$ErrorActionPreference = 'Continue'

function Add-Section {
    param([System.Text.StringBuilder]$Report, [string]$Title)
    [void]$Report.AppendLine("`n=== $Title ===")
}

function Add-Line {
    param([System.Text.StringBuilder]$Report, [string]$Text)
    [void]$Report.AppendLine($Text)
}

# Replaces the home directory and username in a path with placeholders before it is printed.
function Mask-Path {
    param([string]$Path)
    $masked = $Path -replace [regex]::Escape($env:USERPROFILE), '<home>'
    $masked = $masked -replace [regex]::Escape($env:USERNAME), '<user>'
    return $masked
}

# Collects this machine's MAC addresses (no colons/dashes, uppercase) for in-memory comparison only.
function Get-LocalMacs {
    $macs = @()
    try {
        $adapters = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True"
        foreach ($a in $adapters) {
            if ($a.MACAddress) { $macs += ($a.MACAddress -replace '[:\-]', '').ToUpper() }
        }
    } catch {}
    return $macs
}

# Extracts a KEY=value or KEY="value" field from a license file's INCREMENT/SERVER lines.
function Get-LicenseField {
    param([string]$FilePath, [string]$FieldName)
    try {
        $content = Get-Content -Path $FilePath -Raw -ErrorAction Stop
        if ($content -match "$FieldName=`"?([^`"\s]+)`"?") {
            return $Matches[1]
        }
    } catch {}
    return $null
}

function Get-LicenseNumber {
    param([string]$FilePath)
    try {
        $head = Get-Content -Path $FilePath -TotalCount 40 -ErrorAction Stop
        foreach ($l in $head) {
            if ($l -match 'License\s*Number\s*:?\s*(\d{4,10})') { return $Matches[1] }
        }
    } catch { return $null }
    return $null
}

function Get-TodayLinesFromFile {
    param([string]$FilePath, [string]$TodayStr)
    if (-not (Test-Path $FilePath)) { return $null }
    try {
        $lines = Get-Content -Path $FilePath -ErrorAction Stop
        $todayLines = $lines | Where-Object { $_ -match [regex]::Escape($TodayStr) }
        if ($todayLines) { return ($todayLines -join "`n") }
        $mtime = (Get-Item $FilePath).LastWriteTime
        if ($mtime.ToString('yyyy-MM-dd') -eq $TodayStr) { return ($lines -join "`n") }
        return $null
    } catch {
        return $null
    }
}

function Test-DnsResolves {
    param([string]$HostName)
    try {
        [System.Net.Dns]::GetHostAddresses($HostName) | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Test-PortOpen {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 3000)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $tcp.Connected
        $tcp.Close()
        return $ok
    } catch {
        return $false
    }
}

function Get-SystemRequirementsSection {
    param([System.Text.StringBuilder]$Report)
    Add-Section $Report 'System Requirements Check'
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $build = [int]$os.BuildNumber
        if ($os.Caption -match 'Windows 11' -and $build -ge 22631) { $verdict = 'PASS' }
        elseif ($os.Caption -match 'Windows 10' -and $build -ge 19045) { $verdict = 'PASS' }
        elseif ($os.Caption -match 'Server 202[25]') { $verdict = 'PASS' }
        else { $verdict = 'WARN (verify against https://kr.mathworks.com/support/requirements/matlab-system-requirements.html - thresholds change per MATLAB release)' }
        Add-Line $Report "OS version: $($os.Caption) (Build $build) -> $verdict"
    } catch {
        Add-Line $Report "Failed to check OS version: $_"
    }

    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        $memGb = [math]::Round($cs.TotalPhysicalMemory / 1GB)
        $memVerdict = if ($memGb -ge 8) { 'PASS' } else { 'WARN' }
        Add-Line $Report "RAM: ${memGb}GB (>= 8GB minimum / 16GB recommended) -> $memVerdict"
    } catch {
        Add-Line $Report "Failed to check RAM: $_"
    }

    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        $freeGb = [math]::Round($disk.FreeSpace / 1GB)
        $diskVerdict = if ($freeGb -ge 10) { 'PASS' } else { 'WARN' }
        Add-Line $Report "Free disk space ($env:SystemDrive): ${freeGb}GB (MATLAB install footprint ranges 4.6-25GB) -> $diskVerdict"
    } catch {
        Add-Line $Report "Failed to check disk space: $_"
    }

    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $cores = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        $cpuVerdict = if ($cores -ge 4) { 'PASS' } else { 'WARN' }
        Add-Line $Report "CPU: $($cpu.Name), $cores logical cores (4+ recommended) -> $cpuVerdict"
    } catch {
        Add-Line $Report "Failed to check CPU: $_"
    }

    try {
        $gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1
        Add-Line $Report "GPU: $($gpu.Name) (informational only - WebGL2 support not checked, see MathWorks requirements page)"
    } catch {
        Add-Line $Report "Failed to check GPU: $_"
    }
}

function Get-MatlabInstallSection {
    param([System.Text.StringBuilder]$Report)
    Add-Section $Report 'MATLAB Installation'
    $found = $false
    try {
        $dirs = Get-ChildItem 'C:\Program Files\MATLAB' -Directory -Filter 'R*' -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            $found = $true
            Add-Line $Report "Found: $($d.Name) at $(Mask-Path $d.FullName)"
        }
    } catch {
        Add-Line $Report "Failed to scan Program Files\MATLAB: $_"
    }
    if (-not $found) {
        Add-Line $Report 'No MATLAB installation found under C:\Program Files\MATLAB'
    }
}

# --- Main ---
$report = New-Object System.Text.StringBuilder
Add-Section $report 'Report Metadata'
Add-Line $report "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line $report 'Independent self-check tool - not affiliated with or endorsed by MathWorks'

Get-SystemRequirementsSection -Report $report
Get-MatlabInstallSection -Report $report

$localMacs = Get-LocalMacs
$localUser = $env:USERNAME
$localHostname = $env:COMPUTERNAME
$srvHost = $null
$srvPort = $null

Add-Section $report 'License File Check'
$patterns = @(
    "$env:AppData\MathWorks\MATLAB\R*_licenses",
    'C:\Program Files\MATLAB\R*\licenses'
)
$anyDir = $false
foreach ($pattern in $patterns) {
    try {
        $dirs = Get-Item -Path $pattern -ErrorAction SilentlyContinue
        foreach ($dir in $dirs) {
            $anyDir = $true
            $files = Get-ChildItem -Path $dir.FullName -File -ErrorAction SilentlyContinue
            if (-not $files) {
                Add-Line $report "Directory exists but no files: $(Mask-Path $dir.FullName)"
                continue
            }
            foreach ($f in $files) {
                $licNum = Get-LicenseNumber -FilePath $f.FullName
                $numText = if ($licNum) { $licNum } else { 'not found - check file manually' }
                Add-Line $report "Exists: $(Mask-Path $f.FullName) | License Number: $numText"

                $hostid = Get-LicenseField -FilePath $f.FullName -FieldName 'HOSTID'
                if ($hostid) {
                    $hostidNorm = ($hostid -replace '[:\-]', '').ToUpper()
                    if ($localMacs -contains $hostidNorm) {
                        Add-Line $report '  Host ID match: PASS'
                    } else {
                        Add-Line $report '  Host ID match: FAIL (this machine does not match the license file)'
                    }
                } else {
                    Add-Line $report '  Host ID match: N/A (no HOSTID field in this license file)'
                }

                $userInFile = Get-LicenseField -FilePath $f.FullName -FieldName 'USER_NAME'
                if ($userInFile) {
                    if ($userInFile.ToLower() -eq $localUser.ToLower()) {
                        Add-Line $report '  Username match: PASS'
                    } else {
                        Add-Line $report '  Username match: FAIL (license was issued to a different OS username)'
                    }
                } else {
                    Add-Line $report '  Username match: N/A (no USER_NAME field in this license file)'
                }

                if (-not $srvHost) {
                    $content = Get-Content -Path $f.FullName -ErrorAction SilentlyContinue
                    $serverLine = $content | Where-Object { $_ -match '^SERVER\s+' } | Select-Object -First 1
                    if ($serverLine -and $serverLine -match '^SERVER\s+(\S+)\s+(\S+)(?:\s+(\d+))?') {
                        $candidate = $Matches[1]
                        if ($candidate.ToLower() -ne 'this_host' -and $candidate.ToLower() -ne $localHostname.ToLower()) {
                            $srvHost = $candidate
                            $srvPort = if ($Matches[3]) { [int]$Matches[3] } else { 27000 }
                        }
                    }
                }
            }
        }
    } catch {
        Add-Line $report "Failed to search $pattern`: $_"
    }
}
if (-not $anyDir) {
    Add-Line $report 'No license directories found in known locations'
}

Add-Section $report 'Network License Server Check'
if ($srvHost) {
    Add-Line $report "Server (from license file): ${srvHost}:${srvPort}"
    if (Test-DnsResolves -HostName $srvHost) {
        Add-Line $report 'DNS resolution: PASS'
        $portOk = Test-PortOpen -HostName $srvHost -Port $srvPort
        Add-Line $report "Port connectivity ($srvPort): $(if ($portOk) { 'PASS' } else { 'FAIL' })"
    } else {
        Add-Line $report 'DNS resolution: FAIL'
        Add-Line $report "Port connectivity ($srvPort): SKIPPED (DNS resolution failed)"
    }
} else {
    Add-Line $report 'No network license server configured (node-locked license, or no license file found)'
}

Add-Section $report 'Logs (today only)'
$today = Get-Date -Format 'yyyy-MM-dd'
$logTargets = @(
    @{ Name = 'Installation log'; Path = "$env:TEMP\mathworks_$env:USERNAME.log" },
    @{ Name = 'Activation log'; Path = "$env:TEMP\aws_$env:USERNAME.log" }
)
foreach ($t in $logTargets) {
    $content = Get-TodayLinesFromFile -FilePath $t.Path -TodayStr $today
    if ($content) {
        Add-Line $report "--- $($t.Name): $(Mask-Path $t.Path) (today) ---"
        Add-Line $report $content
    } else {
        Add-Line $report "$($t.Name) not found or has no entries from today: $(Mask-Path $t.Path) (note: temp logs are deleted on reboot)"
    }
}

$svcDir = "$env:LOCALAPPDATA\MathWorks\ServiceHost\logs"
if (Test-Path $svcDir) {
    $files = Get-ChildItem -Path $svcDir -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $content = Get-TodayLinesFromFile -FilePath $f.FullName -TodayStr $today
        if ($content) {
            Add-Line $report "--- $(Mask-Path $f.FullName) (today) ---"
            Add-Line $report $content
        } else {
            Add-Line $report "$(Mask-Path $f.FullName): no entries from today"
        }
    }
} else {
    Add-Line $report "ServiceHost log dir not found: $(Mask-Path $svcDir)"
}

try {
    $installs = Get-ChildItem 'C:\Program Files\MATLAB' -Directory -Filter 'R*' -ErrorAction SilentlyContinue
    foreach ($inst in $installs) {
        $lmLog = Join-Path $inst.FullName 'etc\lmlog.txt'
        $content = Get-TodayLinesFromFile -FilePath $lmLog -TodayStr $today
        if ($content) {
            Add-Line $report "--- License manager log: $lmLog (today) ---"
            Add-Line $report $content
        } else {
            Add-Line $report "License manager log not found or has no entries from today: $lmLog"
        }
    }
} catch {
    Add-Line $report "Failed to check license manager logs: $_"
}

Add-Section $report 'Environment Variables'
foreach ($name in @('LM_LICENSE_FILE', 'MLM_LICENSE_FILE')) {
    $val = [Environment]::GetEnvironmentVariable($name)
    if ($val) {
        Add-Line $report "$name is set (value masked - may contain license server address)"
    } else {
        Add-Line $report "$name is not set"
    }
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outFile = Join-Path $OutputDir "MATLAB_Diagnostic_${timestamp}.txt"
$report.ToString() | Out-File -FilePath $outFile -Encoding utf8

Write-Host ""
Write-Host "Diagnostic report saved to:"
Write-Host "  $outFile"
Write-Host ""
Write-Host "Next step: attach this file to an email to your MATLAB support contact."
Write-Host "  1. Open your email application and start a new message to your support contact."
Write-Host "  2. Attach the file above (drag it into the message, or use Attach File)."
Write-Host "  3. Briefly describe the problem you are seeing, then send."
Write-Host ""
Read-Host "Press Enter to close this window"
