# macOS Apple Configurator diagnostics (via ScreenConnect)

Drive the Mac with the screenconnect-remote-diagnostics skill (REST API session lookup +
`SendCommandToSession` + `GetReport`). macOS specifics that differ from the Windows runbook:

- Commands run as **root**; use the `#!sh` hashbang (not `#!ps`). `#timeout` / `#maxlength`
  hashbangs are still honored. Normalize the command to LF before sending (CR breaks the shell).
- `GetReport` parsing is identical to Windows: result is `{ FieldNames, Items }`, rows are
  **positional arrays** — resolve the `Data` column index and index positionally.
- Unified-log strings are heavily `<private>`-redacted. GUI error text like the
  `MCProfileErrorDomain 1000` message usually will NOT appear in `log show` without a
  private-data logging profile — that error is generated in the ABM/MDM transaction and on the
  target device, not on the Mac.

## Read-only inventory probe (identity, clock, Configurator, attached device)
```sh
#!sh
#timeout=180000
#maxlength=120000
echo "BEGIN MARKER"
sw_vers; echo "arch: $(uname -m)"; date
systemsetup -getusingnetworktime 2>/dev/null; systemsetup -gettimezone 2>/dev/null
defaults read "/Applications/Apple Configurator.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null
CFG="/Applications/Apple Configurator.app/Contents/MacOS/cfgutil"
[ -x "$CFG" ] && "$CFG" version && "$CFG" list
echo "END MARKER"
```

## Filtered Configurator / cloud-config error pull
```sh
log show --last 12h --info \
  --predicate 'process CONTAINS[c] "configurator" OR process == "cloudconfigurationd" OR process == "mdmclient"' \
  | grep -iE "MCProfile|invalid profile|0x3E8|escrow|profile|enroll|assign|prepare|DEP|MDM|server|failed|error" \
  | grep -viE "nw_connection|nw_association|nw_resolver|getaddrinfo|dormant|useractivity|INVALIDATE|Biometry|LocalAuthentication|CarbonCore" \
  | tail -n 120
```

## Update / patch readiness (Apple Silicon caveat)
```sh
sw_vers; uname -m
stat -f "%Su" /dev/console                 # console user
sysadminctl -secureTokenStatus <user> 2>&1 # need a Secure Token holder for OS installs
profiles status -type enrollment 2>/dev/null   # DEP/MDM enrollment state of the Mac itself
softwareupdate -l 2>&1                      # pending OS updates
command -v mas >/dev/null && mas outdated   # App Store app updates (Configurator upgrades here)
```
On Apple Silicon, `softwareupdate -ia --restart` needs a volume-owner Secure Token credential
(`--user <admin> --stdinpass`) unless the Mac is MDM-enrolled with a bootstrap token. Do NOT
put that password in the command (it lands in the ScreenConnect RanCommand event). Have the
owner install interactively, or push via Automox / an MDM the Mac is enrolled in.
