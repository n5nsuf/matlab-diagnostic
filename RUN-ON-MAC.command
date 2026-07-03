#!/bin/bash
# Independent, community-made MATLAB self-check diagnostic utility - no connection to, and NOT
# affiliated with, endorsed by, or created by, The MathWorks, Inc. "MATLAB" is a registered
# trademark of The MathWorks, Inc.
#
# Runs local checks to help you self-diagnose a MATLAB problem (system requirements, license file
# validity, network license server reachability, today's log errors) and writes only the
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
ERR_RE='(error|fail(ed|ure)?|fatal|exception|denied|unable|cannot|invalid|expired|unlicensed|refused|timed? ?out|no such feature)'

section() { echo "Checking: $1..."; printf '\n=== %s ===\n' "$1" >> "$OUT_FILE"; }
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

# Joins backslash-continuation lines of a license file into one logical line per statement.
join_continuations() {
    awk '{
        gsub(/\r$/,"")
        buf = buf $0
        if (buf ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, " ", buf); next }
        print buf; buf=""
    } END { if (buf != "") print buf }' "$1" 2>/dev/null
}

# Returns the joined INCREMENT statement for the MATLAB feature (or the first INCREMENT
# statement of any feature as a fallback), so HOSTID/USER_NAME/ISSUED/SN can be extracted
# regardless of which continuation line they physically wrapped onto.
get_increment_stmt() {
    local joined
    joined="$(join_continuations "$1")"
    local stmt
    stmt="$(printf '%s\n' "$joined" | awk '/^INCREMENT[ \t]+MATLAB[ \t]/{print; exit}')"
    [ -z "$stmt" ] && stmt="$(printf '%s\n' "$joined" | awk '/^INCREMENT[ \t]/{print; exit}')"
    printf '%s' "$stmt"
}

# Extracts a KEY=value or KEY="value" field from an already-joined INCREMENT statement string.
extract_field() {
    printf '%s' "$1" | sed -nE "s/.*${2}=\"?([^\" ]+)\"?.*/\1/p" | head -1
}

# License number: "# LicenseNo:"/"# License Number:" comment first, SN= field as fallback.
extract_license_number() {
    local file="$1" stmt="$2"
    local num
    num="$(sed -nE 's/^#[[:space:]]*[Ll]icense[[:space:]]*(No|Number)\.?:?[[:space:]]*([0-9][0-9]*).*/\2/p' "$file" 2>/dev/null | head -1)"
    if [ -z "$num" ] && [ -n "$stmt" ]; then
        num="$(printf '%s' "$stmt" | grep -Eo 'SN=[0-9]+' | head -1 | sed 's/SN=//')"
    fi
    [ -n "$num" ] && echo "$num" || echo "not found - check file manually"
}

# Formats a FlexLM exp_date field, recognizing the "all-zero year" / "0" / "permanent" sentinels.
format_expiry() {
    local exp="$1"
    [ -z "$exp" ] && { echo "unknown"; return; }
    local exp_lc
    exp_lc="$(echo "$exp" | tr '[:upper:]' '[:lower:]')"
    if echo "$exp_lc" | grep -Eq '^(permanent|0|[0-9]{1,2}-[a-z]{3}-0+)$'; then
        echo "permanent (never expires)"
    else
        echo "$exp"
    fi
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

# Filters text down to error-looking lines and collapses exact duplicates to "<line> ..xN",
# preserving first-occurrence order. Prints nothing (and returns 1) if nothing matches.
filter_errors_dedup() {
    local matched
    matched="$(printf '%s\n' "$1" | grep -Ei "$ERR_RE")"
    [ -z "$matched" ] && return 1
    local keys=() counts=()
    while IFS= read -r raw; do
        [ -z "$raw" ] && continue
        local ln
        ln="$(printf '%s' "$raw" | sed -E '
            s/^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?[[:space:]]*//;
            s/^[0-9]{1,2}:[0-9]{2}:[0-9]{2}[[:space:]]*//
        ')"
        local idx=-1 i
        for ((i = 0; i < ${#keys[@]}; i++)); do
            if [ "${keys[$i]}" = "$ln" ]; then idx=$i; break; fi
        done
        if [ "$idx" -ge 0 ]; then
            counts[$idx]=$(( counts[idx] + 1 ))
        else
            keys+=("$ln")
            counts+=(1)
        fi
    done <<< "$matched"
    local n=${#keys[@]}
    for ((i = 0; i < n; i++)); do
        if [ "${counts[$i]}" -gt 1 ]; then
            printf '%s ..x%d\n' "${keys[$i]}" "${counts[$i]}"
        else
            printf '%s\n' "${keys[$i]}"
        fi
    done
    return 0
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

echo "MATLAB self-check running - this takes about 10-20 seconds, please wait..."
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

section 'MathWorks Service Host Check'
if pgrep -f "MathWorksServiceHost" >/dev/null 2>&1; then
    line 'MathWorks Service Host: RUNNING -> PASS'
else
    line 'MathWorks Service Host: NOT RUNNING -> WARN (required by MATLAB R2024a+ for licensing/account sign-in - try restarting MATLAB, or reinstalling Service Host if this persists)'
fi

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
        fname="$(basename "$f")"

        if [ "$fname" = "license_info.xml" ]; then
            line "Exists: $(mask_path "$f") | Online/account-based licensing marker (MathWorks account login required at MATLAB startup) - no offline license data to check"
            continue
        fi

        if [ "$fname" = "network.lic" ]; then
            line "Exists: $(mask_path "$f") | Network client config - defines this machine's license server (see Network License Server Check below)"
        else
            stmt="$(get_increment_stmt "$f")"
            num="$(extract_license_number "$f" "$stmt")"
            line "Exists: $(mask_path "$f") | License Number: $num"

            if [ -n "$stmt" ]; then
                exp_date="$(printf '%s' "$stmt" | awk '{print $5}')"
                issued_val="$(extract_field "$stmt" ISSUED)"
                [ -z "$issued_val" ] && issued_val="unknown"
                line "  Issued: $issued_val | Expires: $(format_expiry "$exp_date")"

                hostid="$(extract_field "$stmt" HOSTID)"
                uname_in_file="$(extract_field "$stmt" USER_NAME)"
                if [ -z "$hostid" ]; then
                    line '  Host ID match: N/A (no HOSTID field in this license file)'
                elif echo "$hostid" | grep -qi '^DISK_SERIAL_NUM='; then
                    line '  Host ID match: N/A (Windows disk-serial lock - not applicable on macOS)'
                elif echo "$hostid" | grep -Eq '^[0-9A-Fa-f]{8}:[0-9A-Fa-f]+$'; then
                    # MATLAB_HOSTID composite: <disk serial hex>:<username, hex-encoded ASCII>.
                    hex_user_part="${hostid#*:}"
                    line '  Host ID match: N/A (Windows disk-serial composite lock - not applicable on macOS)'
                    if [ -z "$uname_in_file" ]; then
                        decoded_user="$(printf "$(echo "$hex_user_part" | sed 's/../\\x&/g')" 2>/dev/null)"
                        [ -n "$decoded_user" ] && uname_in_file="$decoded_user"
                    fi
                elif echo "$hostid" | grep -Eq '^[0-9A-Fa-f]{12}$'; then
                    hostid_norm="$(echo "$hostid" | tr '[:lower:]' '[:upper:]')"
                    if echo "$local_macs" | grep -qw "$hostid_norm"; then
                        line '  Host ID match: PASS'
                    else
                        line '  Host ID match: FAIL (this machine does not match the license file)'
                    fi
                else
                    line '  Host ID match: N/A (HOSTID format not recognized)'
                fi

                if [ -n "$uname_in_file" ]; then
                    if [ "$(echo "$uname_in_file" | tr '[:upper:]' '[:lower:]')" = "$(echo "$local_user" | tr '[:upper:]' '[:lower:]')" ]; then
                        line '  Username match: PASS'
                    else
                        line '  Username match: FAIL (license was issued to a different OS username)'
                    fi
                else
                    line '  Username match: N/A (no USER_NAME field in this license file)'
                fi
            else
                line '  Host ID match: N/A (no INCREMENT statement found in this file)'
            fi
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

section 'Logs (today, errors only)'
any_log_content=0

install_log="${TMPDIR:-/tmp}mathworks_${USER}.log"
content="$(today_lines_or_none "$install_log")" && [ -n "$content" ] && filtered="$(filter_errors_dedup "$content")" && [ -n "$filtered" ] && {
    any_log_content=1
    line "--- Installation log: $(mask_path "$install_log") ---"
    line "$filtered"
}

activation_log="${TMPDIR:-/tmp}aws_${USER}.log"
content="$(today_lines_or_none "$activation_log")" && [ -n "$content" ] && filtered="$(filter_errors_dedup "$content")" && [ -n "$filtered" ] && {
    any_log_content=1
    line "--- Activation log: $(mask_path "$activation_log") ---"
    line "$filtered"
}

lm_log="/var/tmp/lm_TMW.log"
content="$(today_lines_or_none "$lm_log")" && [ -n "$content" ] && filtered="$(filter_errors_dedup "$content")" && [ -n "$filtered" ] && {
    any_log_content=1
    line "--- License manager log: $lm_log ---"
    line "$filtered"
}

svchost_dir="$HOME/Library/Application Support/MathWorks/ServiceHost/logs"
if [ -d "$svchost_dir" ]; then
    for f in "$svchost_dir"/*; do
        [ -f "$f" ] || continue
        content="$(today_lines_or_none "$f")" && [ -n "$content" ] && filtered="$(filter_errors_dedup "$content")" && [ -n "$filtered" ] && {
            any_log_content=1
            line "--- $(mask_path "$f") ---"
            line "$filtered"
        }
    done
fi

[ "$any_log_content" -eq 0 ] && line 'No error-level log entries found for today in the standard locations.'

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
echo "Open it and review the PASS/FAIL/WARN results to see what might be wrong."
echo
read -n 1 -s -r -p "Press any key to close this window..."
echo
