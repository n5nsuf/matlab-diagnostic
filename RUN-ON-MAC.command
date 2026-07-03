#!/bin/bash
# Independent MATLAB self-check diagnostic utility - NOT affiliated with, endorsed by, or
# created by The MathWorks, Inc. "MATLAB" is a registered trademark of The MathWorks, Inc.
#
# Runs local checks useful for a MATLAB support request (system requirements, license file
# validity, network license server reachability, today's log entries) and writes only the
# PASS/FAIL results to a report. Your MAC address, hostname, and disk identifiers are read
# in memory ONLY to compare against your MATLAB license file - they are never written to
# the report. No admin rights required. Nothing is sent over the network except a DNS
# lookup and a TCP connection test against the license server named in your own license
# file. See ../README.md for the full privacy notice.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TODAY="$(date +%Y-%m-%d)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="$SCRIPT_DIR/MATLAB_Diagnostic_${TIMESTAMP}.txt"

section() { printf '\n=== %s ===\n' "$1" >> "$OUT_FILE"; }
line() { printf '%s\n' "$1" >> "$OUT_FILE"; }

# Replaces the home directory and username in a path with placeholders before it is printed.
mask_path() {
    local p="$1"
    p="${p//$HOME/<home>}"
    p="${p//$USER/<user>}"
    echo "$p"
}

# Collects this machine's MAC addresses (no colons, uppercase) for in-memory comparison only.
collect_local_macs() {
    local macs=""
    for iface in en0 en1 en2 en3 en4; do
        local mac
        mac="$(ifconfig "$iface" 2>/dev/null | awk '/ether/{print $2}')"
        [ -n "$mac" ] && macs="$macs $(echo "$mac" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
    done
    echo "$macs"
}

# Extracts a KEY=value or KEY="value" field from a license file's INCREMENT/SERVER lines.
extract_field() {
    local file="$1" field="$2"
    sed -nE "s/.*${field}=\"?([^\" ]+)\"?.*/\1/p" "$file" 2>/dev/null | head -1
}

# Extracts the "License Number: NNNNNN" comment line from the top of a license file, if present.
extract_license_number() {
    local file="$1"
    local num
    num="$(head -n 40 "$file" 2>/dev/null | grep -Eio 'License[[:space:]]*Number[[:space:]:]*[0-9]{4,10}' | grep -Eo '[0-9]{4,10}' | head -n1)"
    [ -n "$num" ] && echo "$num" || echo "not found - check file manually"
}

# Prints only today's lines from a log file, or the whole file if it was modified today
# and has no date-stamped lines, or nothing if it doesn't exist / isn't from today.
today_lines_or_none() {
    local file="$1"
    [ -f "$file" ] || return 1
    local today_lines
    today_lines="$(grep -F "$TODAY" "$file" 2>/dev/null)"
    if [ -n "$today_lines" ]; then
        echo "$today_lines"
        return 0
    fi
    local mtime
    mtime="$(stat -f %Sm -t %Y-%m-%d "$file" 2>/dev/null)"
    if [ "$mtime" = "$TODAY" ]; then
        cat "$file"
        return 0
    fi
    return 1
}

# Checks whether a hostname resolves, without revealing anything about the local machine.
resolve_host() {
    local host="$1"
    if command -v dscacheutil >/dev/null 2>&1; then
        dscacheutil -q host -a name "$host" 2>/dev/null | grep -q "ip_address" && return 0 || return 1
    fi
    if command -v getent >/dev/null 2>&1; then
        getent hosts "$host" >/dev/null 2>&1 && return 0 || return 1
    fi
    return 1
}

# Tests TCP connectivity to host:port with a short timeout. Prints PASS/FAIL/SKIPPED.
check_port() {
    local host="$1" port="$2"
    if ! command -v nc >/dev/null 2>&1; then
        echo 'SKIPPED (nc not available)'
        return
    fi
    if nc -z -w3 "$host" "$port" 2>/dev/null; then
        echo PASS
    else
        echo FAIL
    fi
}

: > "$OUT_FILE"
section 'Report Metadata'
line "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
line 'Independent self-check tool - not affiliated with or endorsed by MathWorks'

section 'System Requirements Check'
line "OS version: $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) (informational - not graded, see README)"
mem_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
if [ "$mem_gb" -ge 8 ]; then mem_verdict=PASS; else mem_verdict=WARN; fi
line "RAM: ${mem_gb}GB (>= 8GB minimum / 16GB recommended) -> $mem_verdict"
disk_kb="$(df -k / 2>/dev/null | tail -1 | awk '{print $4}')"
disk_gb=$(( ${disk_kb:-0} / 1048576 ))
if [ "$disk_gb" -ge 10 ]; then disk_verdict=PASS; else disk_verdict=WARN; fi
line "Free disk space: ${disk_gb}GB (MATLAB install footprint ranges 4.6-25GB) -> $disk_verdict"
cpu_cores="$(sysctl -n hw.ncpu 2>/dev/null || echo unknown)"
if [ "$cpu_cores" != "unknown" ] && [ "$cpu_cores" -ge 4 ]; then cpu_verdict=PASS; else cpu_verdict=WARN; fi
line "CPU: $(uname -m), $cpu_cores logical cores (4+ recommended) -> $cpu_verdict"
gpu_name="$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model/{print $2; exit}')"
line "GPU: ${gpu_name:-not detected} (informational only - WebGL2 support not checked, see MathWorks requirements page)"

section 'MATLAB Installation'
matlab_found=0
for app in /Applications/MATLAB_R*.app; do
    [ -d "$app" ] || continue
    matlab_found=1
    line "Found: $(basename "$app") at $(mask_path "$app")"
done
[ "$matlab_found" -eq 0 ] && line 'No MATLAB installation found under /Applications'

local_macs="$(collect_local_macs)"
local_user="$USER"
local_hostname_short="$(hostname -s 2>/dev/null || hostname)"
srv_host=""
srv_port=""

section 'License File Check'
lic_found=0
for dir in "$HOME/Library/Application Support/MathWorks/MATLAB"/R*_licenses \
           "$HOME/.matlab"/R*_licenses \
           /Applications/MATLAB_R*.app/licenses; do
    [ -d "$dir" ] || continue
    files=("$dir"/*)
    [ -e "${files[0]}" ] || { line "Directory exists but no files: $(mask_path "$dir")"; continue; }
    for f in "${files[@]}"; do
        [ -f "$f" ] || continue
        lic_found=1
        num="$(extract_license_number "$f")"
        line "Exists: $(mask_path "$f") | License Number: $num"

        hostid="$(extract_field "$f" HOSTID)"
        if [ -n "$hostid" ]; then
            hostid_norm="$(echo "$hostid" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
            if echo "$local_macs" | grep -qw "$hostid_norm"; then
                line '  Host ID match: PASS'
            else
                line '  Host ID match: FAIL (this machine does not match the license file)'
            fi
        else
            line '  Host ID match: N/A (no HOSTID field in this license file)'
        fi

        uname_in_file="$(extract_field "$f" USER_NAME)"
        if [ -n "$uname_in_file" ]; then
            if [ "$(echo "$uname_in_file" | tr '[:upper:]' '[:lower:]')" = "$(echo "$local_user" | tr '[:upper:]' '[:lower:]')" ]; then
                line '  Username match: PASS'
            else
                line '  Username match: FAIL (license was issued to a different OS username)'
            fi
        else
            line '  Username match: N/A (no USER_NAME field in this license file)'
        fi

        if [ -z "$srv_host" ]; then
            server_line="$(grep -E '^SERVER[[:space:]]' "$f" 2>/dev/null | head -1)"
            if [ -n "$server_line" ]; then
                candidate="$(echo "$server_line" | awk '{print $2}')"
                candidate_lc="$(echo "$candidate" | tr '[:upper:]' '[:lower:]')"
                if [ "$candidate_lc" != "this_host" ] && [ "$candidate_lc" != "$(echo "$local_hostname_short" | tr '[:upper:]' '[:lower:]')" ]; then
                    srv_host="$candidate"
                    srv_port="$(echo "$server_line" | awk '{print $4}')"
                    [ -z "$srv_port" ] && srv_port=27000
                fi
            fi
        fi
    done
done
[ "$lic_found" -eq 0 ] && line 'No license files found in known locations'

section 'Network License Server Check'
if [ -n "$srv_host" ]; then
    line "Server (from license file): $srv_host:$srv_port"
    if resolve_host "$srv_host"; then
        line 'DNS resolution: PASS'
        line "Port connectivity ($srv_port): $(check_port "$srv_host" "$srv_port")"
    else
        line 'DNS resolution: FAIL'
        line "Port connectivity ($srv_port): SKIPPED (DNS resolution failed)"
    fi
else
    line 'No network license server configured (node-locked license, or no license file found)'
fi

section 'Logs (today only)'
install_log="${TMPDIR:-/tmp}mathworks_${USER}.log"
content="$(today_lines_or_none "$install_log")"
if [ $? -eq 0 ] && [ -n "$content" ]; then
    line "--- Installation log: $(mask_path "$install_log") (today) ---"
    line "$content"
else
    line "Installation log not found or has no entries from today: $(mask_path "$install_log") (note: temp logs are deleted on reboot)"
fi

activation_log="${TMPDIR:-/tmp}aws_${USER}.log"
content="$(today_lines_or_none "$activation_log")"
if [ $? -eq 0 ] && [ -n "$content" ]; then
    line "--- Activation log: $(mask_path "$activation_log") (today) ---"
    line "$content"
else
    line "Activation log not found or has no entries from today: $(mask_path "$activation_log") (note: temp logs are deleted on reboot)"
fi

lm_log="/var/tmp/lm_TMW.log"
content="$(today_lines_or_none "$lm_log")"
if [ $? -eq 0 ] && [ -n "$content" ]; then
    line "--- License manager log: $lm_log (today) ---"
    line "$content"
else
    line "License manager log not found or has no entries from today: $lm_log"
fi

svchost_dir="$HOME/Library/Application Support/MathWorks/ServiceHost/logs"
if [ -d "$svchost_dir" ]; then
    for f in "$svchost_dir"/*; do
        [ -f "$f" ] || continue
        content="$(today_lines_or_none "$f")"
        if [ $? -eq 0 ] && [ -n "$content" ]; then
            line "--- $(mask_path "$f") (today) ---"
            line "$content"
        else
            line "$(mask_path "$f"): no entries from today"
        fi
    done
else
    line "ServiceHost log dir not found: $(mask_path "$svchost_dir")"
fi

section 'Environment Variables'
for name in LM_LICENSE_FILE MLM_LICENSE_FILE; do
    val="$(eval echo "\${$name:-}")"
    if [ -n "$val" ]; then
        line "$name is set (value masked - may contain license server address)"
    else
        line "$name is not set"
    fi
done

echo
echo "Diagnostic report saved to:"
echo "  $OUT_FILE"
echo
echo "Next step: attach this file to an email to your MATLAB support contact."
echo "  1. Open your email application and start a new message to your support contact."
echo "  2. Attach the file above (drag it into the message, or use Attach File)."
echo "  3. Briefly describe the problem you are seeing, then send."
echo
read -n 1 -s -r -p "Press any key to close this window..."
echo
