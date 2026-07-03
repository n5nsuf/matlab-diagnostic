<#
    Independent, community-made MATLAB self-check diagnostic utility - no connection to, and NOT
    affiliated with, endorsed by, or created by, The MathWorks, Inc. "MATLAB" is a registered
    trademark of The MathWorks, Inc.

    Runs local checks to help you self-diagnose a MATLAB problem (system requirements, license file
    validity, network license server reachability, today's log errors) and writes only the
    PASS/FAIL results to a report. Your MAC address, hostname, and disk identifiers are read
    in memory ONLY to compare against your MATLAB license file - they are never written to
    the report. No admin rights required. Nothing is sent over the network except a DNS
    lookup and a TCP connection test against the license server named in your own license
    file. See ../README.md for the full privacy notice.
#>

param(
    [string]$OutputDir = $PSScriptRoot
)

# Normalizes away any trailing backslash/dot quirk introduced by how a caller (e.g. a .bat
# using "%~dp0.") passed this path, so Out-File never sees an illegal path string.
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)

$ErrorActionPreference = 'Continue'
$ErrRe = '(error|fail(ed|ure)?|fatal|exception|denied|unable|cannot|invalid|expired|unlicensed|refused|timed? ?out|no such feature)'

function Add-Section {
    param([System.Text.StringBuilder]$Report, [string]$Title)
    Write-Host "Checking: $Title..."
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

# Collects the system drive's volume serial number (in-memory only - this is what MATLAB
# uses as HOSTID=DISK_SERIAL_NUM= on Windows Individual/Designated Computer licenses).
function Get-LocalVolumeSerial {
    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        if ($disk.VolumeSerialNumber) { return $disk.VolumeSerialNumber.ToUpper() }
    } catch {}
    return $null
}

# Joins backslash-continuation lines of a license file into one logical line per statement.
function Get-JoinedStatements {
    param([string]$FilePath)
    try {
        $raw = Get-Content -Path $FilePath -Raw -ErrorAction Stop
    } catch { return @() }
    $raw = $raw -replace "`r`n", "`n"
    $joined = $raw -replace '\\[ \t]*\n[ \t]*', ' '
    return ($joined -split "`n")
}

# Returns the joined INCREMENT statement for the MATLAB feature (or the first INCREMENT
# statement of any feature as a fallback), so HOSTID/USER_NAME/ISSUED/SN can be extracted
# regardless of which continuation line they physically wrapped onto.
function Get-IncrementStatement {
    param([string]$FilePath)
    $stmts = Get-JoinedStatements -FilePath $FilePath
    $stmt = $stmts | Where-Object { $_ -match '^INCREMENT\s+MATLAB\s' } | Select-Object -First 1
    if (-not $stmt) { $stmt = $stmts | Where-Object { $_ -match '^INCREMENT\s' } | Select-Object -First 1 }
    return $stmt
}

# Extracts a KEY=value or KEY="value" field from an already-joined INCREMENT statement string.
function Get-Field {
    param([string]$Text, [string]$FieldName)
    if ($Text -and $Text -match "$FieldName=`"?([^`"\s]+)`"?") {
        return $Matches[1]
    }
    return $null
}

# License number: "# LicenseNo:"/"# License Number:" comment first, SN= field as fallback.
function Get-LicenseNumber {
    param([string]$FilePath, [string]$Stmt)
    try {
        $head = Get-Content -Path $FilePath -TotalCount 40 -ErrorAction Stop
        foreach ($l in $head) {
            if ($l -match '^#\s*License\s*(No|Number)\.?:?\s*(\d{4,10})') { return $Matches[2] }
        }
    } catch {}
    if ($Stmt -and $Stmt -match 'SN=(\d+)') { return $Matches[1] }
    return $null
}

# Formats a FlexLM exp_date (5th field of the INCREMENT statement), recognizing the
# "all-zero year" / "0" / "permanent" sentinels as never-expiring.
function Get-ExpiryDisplay {
    param([string]$Stmt)
    if (-not $Stmt) { return 'unknown' }
    $fields = $Stmt -split '\s+'
    if ($fields.Length -lt 5) { return 'unknown' }
    $exp = $fields[4]
    if ($exp -match '^(?i)(permanent|0|\d{1,2}-[a-z]{3}-0+)$') {
        return 'permanent (never expires)'
    }
    return $exp
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

# Filters text down to error-looking lines and collapses duplicates (ignoring a leading
# timestamp) to "<line> ..xN", preserving first-occurrence order. Returns $null if nothing matches.
function Get-FilteredDedupLines {
    param([string]$Content)
    if (-not $Content) { return $null }
    $lines = $Content -split "`n" | Where-Object { $_ -match "(?i)$ErrRe" }
    if (-not $lines) { return $null }
    $seen = [ordered]@{}
    foreach ($l in $lines) {
        $key = $l -replace '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}([.,]\d+)?\s*', ''
        $key = $key -replace '^\d{1,2}:\d{2}:\d{2}\s*', ''
        if ($seen.Contains($key)) { $seen[$key] = $seen[$key] + 1 } else { $seen[$key] = 1 }
    }
    $out = @()
    foreach ($k in $seen.Keys) {
        if ($seen[$k] -gt 1) { $out += "$k ..x$($seen[$k])" } else { $out += $k }
    }
    return ($out -join "`n")
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

function Get-ServiceHostSection {
    param([System.Text.StringBuilder]$Report)
    Add-Section $Report 'MathWorks Service Host Check'
    $running = Get-Process -Name 'MathWorksServiceHost*' -ErrorAction SilentlyContinue
    if ($running) {
        Add-Line $Report 'MathWorks Service Host: RUNNING -> PASS'
    } else {
        Add-Line $Report 'MathWorks Service Host: NOT RUNNING -> WARN (required by MATLAB R2024a+ for licensing/account sign-in - try restarting MATLAB, or reinstalling Service Host if this persists)'
    }
}

# --- Main ---
Write-Host "MATLAB self-check running - this takes about 10-20 seconds, please wait..."
$report = New-Object System.Text.StringBuilder
Add-Section $report 'Report Metadata'
Add-Line $report "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line $report 'Independent self-check tool - not affiliated with or endorsed by MathWorks'

Get-SystemRequirementsSection -Report $report
Get-MatlabInstallSection -Report $report
Get-ServiceHostSection -Report $report

$localMacs = Get-LocalMacs
$localVolSerial = Get-LocalVolumeSerial
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
                if ($f.Name -eq 'license_info.xml') {
                    Add-Line $report "Exists: $(Mask-Path $f.FullName) | Online/account-based licensing marker (MathWorks account login required at MATLAB startup) - no offline license data to check"
                    continue
                }

                if ($f.Name -eq 'network.lic') {
                    Add-Line $report "Exists: $(Mask-Path $f.FullName) | Network client config - defines this machine's license server (see Network License Server Check below)"
                } else {
                    $stmt = Get-IncrementStatement -FilePath $f.FullName
                    $licNum = Get-LicenseNumber -FilePath $f.FullName -Stmt $stmt
                    $numText = if ($licNum) { $licNum } else { 'not found - check file manually' }
                    Add-Line $report "Exists: $(Mask-Path $f.FullName) | License Number: $numText"

                    if ($stmt) {
                        $issued = Get-Field -Text $stmt -FieldName 'ISSUED'
                        if (-not $issued) { $issued = 'unknown' }
                        Add-Line $report "  Issued: $issued | Expires: $(Get-ExpiryDisplay -Stmt $stmt)"

                        $hostid = Get-Field -Text $stmt -FieldName 'HOSTID'
                        $userInFile = Get-Field -Text $stmt -FieldName 'USER_NAME'
                        if (-not $hostid) {
                            Add-Line $report '  Host ID match: N/A (no HOSTID field in this license file)'
                        } elseif ($hostid -match '(?i)^DISK_SERIAL_NUM=(.+)$') {
                            $diskVal = $Matches[1].ToUpper()
                            if ($localVolSerial -and $diskVal -eq $localVolSerial) {
                                Add-Line $report '  Host ID match: PASS'
                            } else {
                                Add-Line $report '  Host ID match: FAIL (this machine does not match the license file)'
                            }
                        } elseif ($hostid -match '(?i)^MATLAB_HOSTID=([0-9A-Fa-f]+):([0-9A-Fa-f]+)$') {
                            # Composite lock: <disk serial hex>:<username, hex-encoded ASCII>.
                            $diskVal = $Matches[1].ToUpper()
                            $hexUserPart = $Matches[2]
                            if ($localVolSerial -and $diskVal -eq $localVolSerial) {
                                Add-Line $report '  Host ID match: PASS'
                            } else {
                                Add-Line $report '  Host ID match: FAIL (this machine does not match the license file)'
                            }
                            if (-not $userInFile) {
                                try {
                                    $bytes = for ($i = 0; $i -lt $hexUserPart.Length; $i += 2) { [Convert]::ToByte($hexUserPart.Substring($i, 2), 16) }
                                    $decoded = [System.Text.Encoding]::ASCII.GetString([byte[]]$bytes)
                                    if ($decoded) { $userInFile = $decoded }
                                } catch {}
                            }
                        } elseif ($hostid -match '^[0-9A-Fa-f]{12}$') {
                            $hostidNorm = $hostid.ToUpper()
                            if ($localMacs -contains $hostidNorm) {
                                Add-Line $report '  Host ID match: PASS'
                            } else {
                                Add-Line $report '  Host ID match: FAIL (this machine does not match the license file)'
                            }
                        } else {
                            Add-Line $report '  Host ID match: N/A (HOSTID format not recognized)'
                        }

                        if ($userInFile) {
                            if ($userInFile.ToLower() -eq $localUser.ToLower()) {
                                Add-Line $report '  Username match: PASS'
                            } else {
                                Add-Line $report '  Username match: FAIL (license was issued to a different OS username)'
                            }
                        } else {
                            Add-Line $report '  Username match: N/A (no USER_NAME field in this license file)'
                        }
                    } else {
                        Add-Line $report '  Host ID match: N/A (no INCREMENT statement found in this file)'
                    }
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

Add-Section $report 'Logs (today, errors only)'
$today = Get-Date -Format 'yyyy-MM-dd'
$anyLogContent = $false

$logTargets = @(
    @{ Name = 'Installation log'; Path = "$env:TEMP\mathworks_$env:USERNAME.log" },
    @{ Name = 'Activation log'; Path = "$env:TEMP\aws_$env:USERNAME.log" }
)
foreach ($t in $logTargets) {
    $content = Get-TodayLinesFromFile -FilePath $t.Path -TodayStr $today
    $filtered = Get-FilteredDedupLines -Content $content
    if ($filtered) {
        $anyLogContent = $true
        Add-Line $report "--- $($t.Name): $(Mask-Path $t.Path) ---"
        Add-Line $report $filtered
    }
}

$svcDir = "$env:LOCALAPPDATA\MathWorks\ServiceHost\logs"
if (Test-Path $svcDir) {
    $files = Get-ChildItem -Path $svcDir -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $content = Get-TodayLinesFromFile -FilePath $f.FullName -TodayStr $today
        $filtered = Get-FilteredDedupLines -Content $content
        if ($filtered) {
            $anyLogContent = $true
            Add-Line $report "--- $(Mask-Path $f.FullName) ---"
            Add-Line $report $filtered
        }
    }
}

try {
    $installs = Get-ChildItem 'C:\Program Files\MATLAB' -Directory -Filter 'R*' -ErrorAction SilentlyContinue
    foreach ($inst in $installs) {
        $lmLog = Join-Path $inst.FullName 'etc\lmlog.txt'
        $content = Get-TodayLinesFromFile -FilePath $lmLog -TodayStr $today
        $filtered = Get-FilteredDedupLines -Content $content
        if ($filtered) {
            $anyLogContent = $true
            Add-Line $report "--- License manager log: $lmLog ---"
            Add-Line $report $filtered
        }
    }
} catch {
    Add-Line $report "Failed to check license manager logs: $_"
}

if (-not $anyLogContent) {
    Add-Line $report 'No error-level log entries found for today in the standard locations.'
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
Write-Host "Open it and review the PASS/FAIL/WARN results to see what might be wrong."
Write-Host ""
Read-Host "Press Enter to close this window"
