---
name: triage-windows-bsod
description: Diagnose why a Windows machine unexpectedly rebooted, blue-screened, or froze by
  classifying System event-log entries and analyzing minidumps with kd. Use when the user asks
  "why did my computer randomly reboot", "my PC crashed", "blue screen", "BSOD", "what caused
  this restart", or wants a .dmp crash dump analyzed — on the local machine or on dumps copied
  from an endpoint. Covers reboot-classifying event IDs (41, 1074, 6008, 1001), bugcheck codes,
  copying ACL-protected minidumps with elevation, reliable kd invocation, and reading
  driver-vs-hardware crash patterns. For reaching a remote endpoint first, use the
  screenconnect-remote-diagnostics or ssh-access skill; this skill starts once a System
  log or dump file is reachable.
---

# Triage Windows BSOD / unexpected reboot

## 1. Classify the reboot from the System log

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; Id=41,1074,6005,6006,6008,1001} -MaxEvents 30
```

- **1074 (User32)** — someone/something called shutdown; message names the process and user. Not a crash.
- **41 (Kernel-Power)** + **6008** — power was lost without clean shutdown: BSOD, hang, or power cut.
- **1001 (WER-SystemErrorReporting)** right after boot — bugcheck: message has the stop code, params, and dump path.
- In event 41's EventData: `BugcheckCode` is **decimal** (127 = 0x7F); `BugcheckCode=0` means hard hang/power loss with no BSOD; `WHEABootErrorCount>0` means firmware logged a hardware error record — check `Microsoft-Windows-WHEA-Logger` events (mind the exact StartTime window; boundary misses are easy).

## 2. Get the dumps readable

`C:\Windows\Minidump\*.dmp` and `MEMORY.DMP` are Administrators-only; non-elevated reads fail with Access denied. Copy them out via one elevated hop (UAC prompt — tell the user to expect it):

```powershell
Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-Command',
  'Copy-Item C:\Windows\Minidump\*.dmp "<readable dir>" -Force'
```

## 3. Analyze with kd

kd lives at `C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\kd.exe` (verified 2026-07-08; install WinDbg/Debugging Tools from the Windows SDK if absent). Inline invocation mangles the `-c "!analyze -v; q"` argument under both PowerShell `&` and `cmd /c` quoting — **write a .cmd wrapper and run that instead**:

```bat
@echo off
"C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\kd.exe" -z "<dump path>" ^
  -y "srv*C:\symbols*https://msdl.microsoft.com/download/symbols" -c "!analyze -v; q"
```

First run downloads symbols (a minute or two); later dumps are fast. For a multi-dump pattern sweep, pipe each run through `findstr /C:"FAILURE_BUCKET_ID" /C:"BUGCHECK_CODE" /C:"PROCESS_NAME" /C:"IMAGE_NAME" /C:"Debug session time"`.

## 4. Read the pattern, not one crash

- `PROCESS_NAME` is the victim context, not necessarily the culprit.
- Same third-party driver in `FAILURE_BUCKET_ID` across crashes (e.g. `AV_...csagent!...`) → that driver.
- Scattershot buckets inside `nt` across different processes, `IP_MISALIGNED_*`, recursive `KiDoubleFaultAbort` exception-dispatch stacks, `WHEABootErrorCount>0`, or no-bugcheck freezes mixed in → suspect hardware, RAM first, then CPU/firmware.
- `Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-MemoryDiagnostics-Results'}` shows whether a memory test was ever run. Next steps for hardware suspicion: MemTest86/mdsched overnight, BIOS/firmware update, then Driver Verifier only if memory is clean.
