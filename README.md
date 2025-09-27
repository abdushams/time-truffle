# time-truffle
Time-traveling repo diver that restores dead files and feeds them to TruffleHog.

Clone. Resurrect. Scan.  
evo-scanner trawls every repo in a GitHub account/org, restores deleted & unreachable files
(packfiles, dangling commits/blobs), then unleashes TruffleHog on both the *history* and the
*resurrected filesystem*. One command, one `secrets.txt`.

> 🛡️ Use only where you have explicit authorization. Deleted ≠ consent.

# Quick start
```
# with defaults
./time-truffle.sh <account_or_org>

# or interactive
./time-truffle.sh
```
# Requirements

[gh](https://cli.github.com/), git, trufflehog (and optionally bash, awk, tee which you already have on Linux/macOS).


![bash](https://img.shields.io/badge/made%20with-bash-1f425f.svg)
![git](https://img.shields.io/badge/git-forensics-orange)
![trufflehog](https://img.shields.io/badge/trufflehog-enabled-success)
![status](https://img.shields.io/badge/status-experimental-purple)
