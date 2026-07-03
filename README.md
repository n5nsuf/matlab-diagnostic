# MATLAB Self-Check Diagnostic Tool

A standalone, offline self-check tool for diagnosing your own MATLAB installation, activation,
and license problems. It runs locally and writes the **results** (pass/fail) to a small text
report so you can see what might be wrong.

**This is an independent, community-made tool, not an official MathWorks product.** It has no
connection to, and is not created, endorsed, or affiliated with, The MathWorks, Inc. "MATLAB" is
a registered trademark of The MathWorks, Inc.

## What it checks

- **System requirements** - RAM, free disk space, CPU core count, detected GPU, OS version
- **MATLAB installation** - which version(s) are installed and where
- **MathWorks Service Host** - whether it's running (required by MATLAB R2024a+ for
  licensing and account sign-in)
- **License file** - whether a license file exists in the standard locations, its license
  number, issue date, and expiration date, and whether it matches this machine and the
  current user (pass/fail only). Files that use online account-based licensing or are just a
  network-connection config (rather than a full license) are recognized as such instead of
  being reported as errors.
- **Network license server** (only if your license points to one) - whether it's reachable
- **Today's log errors** - only error-looking entries from today's MATLAB logs, deduplicated
- **Whether `LM_LICENSE_FILE` / `MLM_LICENSE_FILE` are set** (not their value)

While it runs, each script prints a short progress line to the console so a several-second run
doesn't look like it's frozen.

## Privacy notice

This tool never writes identifying details of your machine (MAC address, hostname, disk/volume
identifiers) or your OS username to the report. Any such value is used only in memory, only to
compare against what your own MATLAB license file expects, and the report records just the
result: a match or a mismatch. Nothing is sent over the network except a reachability check
against the license server address already written in your own license file, and only when your
license is a network/concurrent one. The report never leaves your computer.

## Reference articles

All from MathWorks' own documentation and support site:

- [Log file locations](https://www.mathworks.com/matlabcentral/answers/101927)
- [License file locations](https://www.mathworks.com/matlabcentral/answers/99147)
- [Error 96 - can't reach license server](https://kr.mathworks.com/matlabcentral/answers/95122)
- [Error 9 - username/Host ID mismatch](https://kr.mathworks.com/matlabcentral/answers/99067)
- [MATLAB system requirements](https://kr.mathworks.com/support/requirements/matlab-system-requirements.html)
- [network.lic file format](https://kr.mathworks.com/matlabcentral/answers/1843038)
- [license_info.xml explained](https://kr.mathworks.com/matlabcentral/answers/116637)
- [What is MathWorks Service Host?](https://kr.mathworks.com/help/install/ug/what-is-mathworks-service-host.html)

## How to run

Download the zip, extract it, and run the one file matching your OS - they sit at the top level,
no need to open any subfolder:

| OS | File | How to run |
|---|---|---|
| Windows | `RUN-ON-WINDOWS.bat` | Double-click it. |
| macOS | `RUN-ON-MAC.command` | Double-click it. If macOS blocks it as "unidentified developer," Control-click the file and choose Open. If it won't run, open Terminal and run `chmod +x RUN-ON-MAC.command` once, then double-click again. |
| Linux | `RUN-ON-LINUX.sh` | In a terminal: `chmod +x RUN-ON-LINUX.sh && ./RUN-ON-LINUX.sh` |

No installation is required on any platform - each script only uses tools already built into the OS.
There's no single file that runs on all three operating systems by double-clicking (every OS decides
whether to run a file by its extension), so pick the file named for your own OS.

## After it runs

Each script prints the path to the report file it created. Open it and read through the
PASS/FAIL/WARN results to see what might be causing your MATLAB problem.

## Known limitations

- Some fields (like the license number) can't always be extracted - if so, the report says
  so rather than guessing.
- Not every possible license-lock format is recognized; an unrecognized one is reported as N/A
  rather than compared incorrectly.
- Linux log locations are best-effort estimates, since MathWorks only publishes them for
  Windows and macOS.
- macOS/Linux OS version is shown for information only, not graded pass/fail.
- The network server reachability check needs `nc` (netcat) on macOS/Linux; if missing, the
  report says the check was skipped.

## License

[MIT](LICENSE) for the code in this repository. "MATLAB" and "MathWorks" are registered
trademarks of The MathWorks, Inc. and are not covered by this license.
