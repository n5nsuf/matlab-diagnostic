# MATLAB Self-Check Diagnostic Tool

An independent, offline self-check tool for troubleshooting MATLAB installation, activation, and
license problems. It runs locally, checks a handful of things MathWorks support usually asks about,
and writes the **results** (pass/fail) to a small text report you can attach to a support email.

**This is not an official MathWorks tool.** It is not created, endorsed, or affiliated with The
MathWorks, Inc. "MATLAB" is a registered trademark of The MathWorks, Inc.

## What it checks

- **System requirements** - RAM, free disk space, CPU core count, detected GPU, OS version
- **MATLAB installation** - which version(s) are installed and where
- **License file** - does a license file exist in any of the standard locations, and if so:
  - does the machine's Host ID (MAC address) match what's recorded in the license file
  - does the current OS username match what's recorded in the license file
- **Network license server** (only if your license file points to one) - does the server hostname
  resolve, and is the port it uses reachable
- **Today's log entries** - only lines/files from today, from the standard MATLAB install,
  activation, ServiceHost, and license-manager log locations
- **Whether `LM_LICENSE_FILE` / `MLM_LICENSE_FILE` are set** (not their value)

## Privacy notice

This tool never writes your MAC address, hostname, or disk volume identifier to the report. Those
values are read into memory only, for exactly one purpose: comparing them against what's already
recorded in your own MATLAB license file, so the report can say `Host ID match: PASS/FAIL` instead
of printing the raw value. Your OS username may appear inside a log file path shown in the report
(this is unavoidable on Windows, where the standard temp-log location itself contains the
username) - that occurrence is masked as `<user>` wherever this tool controls the text.

Nothing is sent over the network except two things you can verify by reading the script yourself:
a DNS lookup and a TCP connection attempt against the license server address that is already
written in your own license file (only run if your license is a network/concurrent license).
Nothing is uploaded anywhere - the report is a local file, and it is your choice whether to
attach it to an email.

## Reference articles

- [Log file locations](https://www.mathworks.com/matlabcentral/answers/101927)
- [License file locations](https://www.mathworks.com/matlabcentral/answers/99147)
- [Error 96 - can't reach license server](https://kr.mathworks.com/matlabcentral/answers/95122)
- [Error 9 - username/Host ID mismatch](https://kr.mathworks.com/matlabcentral/answers/99067)
- [MATLAB system requirements](https://kr.mathworks.com/support/requirements/matlab-system-requirements.html)

## How to run

Download the zip, extract it, and run the one file matching your OS - they sit at the top level,
no need to open any subfolder:

| OS | File | How to run |
|---|---|---|
| Windows | `RUN-ON-WINDOWS.bat` | Double-click it. |
| macOS | `RUN-ON-MAC.command` | Double-click it. If macOS blocks it as "unidentified developer," Control-click the file and choose Open. If it won't run, open Terminal and run `chmod +x RUN-ON-MAC.command` once, then double-click again. |
| Linux | `RUN-ON-LINUX.sh` | In a terminal: `chmod +x RUN-ON-LINUX.sh && ./RUN-ON-LINUX.sh` |

No installation is required on any platform - each script only uses tools already built into the OS.
There is no single file that runs on all three operating systems by double-clicking - every OS
decides whether to execute a file by its extension (`.bat`/`.command`/`.sh`), so a truly universal
double-clickable launcher isn't possible. Picking the file named for your own OS is the reliable
equivalent.

The Windows launcher (`RUN-ON-WINDOWS.bat`) is a one-line wrapper that runs
`windows/Get-MatlabDiagnostic.ps1` - that subfolder script holds the actual logic, but you never
need to open it yourself.

## Sending the report to support

Each script prints the path to the report file it created and ends with these steps:

1. Open your email application and start a new message to your MATLAB support contact.
2. Attach the report file (drag it into the message, or use your email client's Attach File option).
3. Briefly describe the problem you're seeing, then send.

## Known limitations

- **License number extraction is best-effort.** MATLAB license files don't have one universally
  documented "license number" field format; the script looks for a `License Number:` comment near
  the top of the file. If it isn't found, the report says so and you can check the file yourself.
- **Linux log paths are estimates.** MathWorks' published log-location article only documents
  Windows and macOS. The Linux script guesses at the same naming pattern (e.g.
  `/tmp/mathworks_$USER.log`) and says so in the report if nothing is found there.
- **macOS/Linux OS version is informational only**, not graded pass/fail, because MathWorks'
  published system requirements page (as checked) only had concrete version numbers for Windows.
- The port-connectivity check needs `nc` (netcat) on macOS/Linux. Nearly all installations have
  it; if it's missing, the report says the check was skipped rather than guessing.
