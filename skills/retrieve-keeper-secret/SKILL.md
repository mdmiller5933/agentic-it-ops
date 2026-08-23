---
name: retrieve-keeper-secret
description: Retrieves passwords, API keys, and connection secrets from the Keeper vault on this
  workstation - through Keeper Secrets Manager by default, falling back to Keeper Commander for
  vault admin - without exposing values in transcripts, logs, or files. Use when the user asks to
  "get the password for", "what's the API key for", "look up the credentials for", "grab the secret
  for", "pull it from Keeper", "check Keeper for", mentions "KSM" or "Keeper Secrets Manager", or
  names a Keeper record, vault, or shared folder; and before running any script or API call that
  needs a credential, so it comes from Keeper instead of a plaintext env file. Covers the
  non-expiring KSM profile, SSO session recovery for Commander, masked-by-default retrieval, which
  commands silently dump plaintext, and the approval-gated recipe for storing a new secret. Keeper
  vault only - for Microsoft Graph or Intune access tokens use the acquire-graph-token skill.
---

# Retrieve Keeper Secret

**Read secrets through Keeper Secrets Manager (KSM), not Commander.** The KSM device keypair does
not expire and never touches SSO, so it works from a non-interactive agent shell. Commander is now
only for vault admin: creating KSM apps, sharing records into them, adding records.

Verified 2026-08-04: KSM CLI 1.4.0 / core 17.3.0, Commander 18.0.13. Credentials live in Windows
Credential Manager, not a plaintext file. Do not pull the `z_admin` PAM password to mint
Graph tokens — use the acquire-graph-token skill (TAP remint / app-only cert).

## The KSM read path (use this first)

Profile `contoso`, stored in Credential Manager as `ksm-cli-profile-contoso@KSM-cli` (plus an
`-integrity` companion), bound to app `Contoso Automation` (UID `KEEPERUID000000000004`) and client
device `euc-workstation`. The device is deliberately **IP-unlocked** — Cato hands out different
egress addresses, and IP-locking would recreate the SSO-lapse problem it was built to solve.

```powershell
$env:PYTHONUTF8 = '1'; $env:PYTHONIOENCODING = 'utf-8'
function ksm { & py -m keeper_secrets_manager_cli @args }
ksm -p contoso secret list
ksm -p contoso secret get --uid <UID> --field password
```

**Bash-side path when the PowerShell wrapper dies (verified 2026-08-12).**
`scripts\Invoke-WithKsmEnv.ps1` failed on the very first KSM read with a bare
`py.exe : ` / `NativeCommandError` at its `function ksm { & py -m ... }` line, exit 1, injecting
nothing — so every repo `.mjs` script it wraps was unrunnable. Bare `py` on PATH is the fault, not
KSM. From a Bash tool shell, call the **absolute launcher** `C:/Windows/py.exe` instead and it works
first try:

```bash
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
key=$("C:/Windows/py.exe" -m keeper_secrets_manager_cli -p contoso \
        secret get --uid <UID> --field password 2>/dev/null | tr -d '\r\n')
```

Put that in a **`.sh` file and run `bash file.sh`** rather than a long inline `-c`: an inline
version of the same pipeline returned `EUNKNOWN: unknown error, uv_spawn` once and then succeeded
unchanged on retry, so treat inline spawn as flaky here (same failure family as
[[win-shell-flaky-spawn]]). Export the values and exec the Node script from that one script, so the
secret stays in that process. Freshservice consumers want `FRESHWORKS_API_KEY` +
`FRESHWORKS_DOMAIN`; if the `FRESHWORKS_DOMAIN` custom-field read comes back empty or `[]`, fall
back to `contoso.freshservice.com`. Confirm with a length + SHA-256 prefix, never the value (the
Freshservice key is 20 chars).

Invoke it as the module. `ksm.exe` exists under `%APPDATA%\Python\Python3xx\Scripts` but is **not on
PATH**. The profile flag is `-p` / `--profile-name`; **there is no `--profile`** — passing it fails
with a usage error, not a silent fallback.

**Keep the wrapper a simple function, exactly as written above.** Adding a `param()` block with a
`[Parameter()]` attribute (for example `[Parameter(ValueFromRemainingArguments = $true)]`) promotes it
to an *advanced* function, which inherits PowerShell's common parameters, and `-p` then dies with
`Parameter cannot be processed because the parameter name 'p' is ambiguous. Possible matches include:
-ProgressAction -PipelineVariable.` Verified both forms side by side 2026-08-04: bare `@args` works,
the `param()` variant fails every time. If a wrapper is inconvenient, call the module directly and
quote the flags: `& py -m keeper_secrets_manager_cli '-p' 'contoso' 'secret' 'get' '--uid' $uid '--field' 'password'`.

**Windows child-process fallback (verified 2026-08-06):** if PowerShell launch repeatedly returns
OS error 1223 but a persistent Node process is already available, call Node's `execFile` with the
absolute launcher `C:\Windows\py.exe`; resolving bare `py.exe` through PATH returned `spawn UNKNOWN`.
Keep any Python `-c` program on one physical line because embedded newlines triggered the same spawn
failure. Filter inside that child process and emit only safe metadata or a no-value proof, never a
decrypted secret.

Verified 2026-08-09: a one-line Python `-c` program can still fail with `spawn UNKNOWN` when another
argument contains a multiline endpoint payload, including its base64 form when the combined command
line grows. Keep the `-c` argument tiny and stream the full helper program over stdin instead:
launch `C:\Windows\py.exe -c "exec(__import__('sys').stdin.read())"`, capture stdout and stderr, and
end the child stdin with the helper source. Retrieve and use the KSM value inside that streamed
program; emit only the sanitized result of the authenticated API call.

### Field mapping, the `[]` trap, and the SDK fallback

| Record type | Where the secret is | Retrieve with |
| --- | --- | --- |
| `login` | `password` field | `--field password` |
| `sshKeys` | `notes` (declared `password` field is EMPTY) | `-q notes --raw` |

`notes` is a top-level record property, **not** an entry in `fields[]`, so `--field notes` always
returns `[]`.

**CLI query regression observed 2026-08-06:** `-q notes --raw` also returned `[]` for the
ScreenConnect `sshKeys` record even though the decrypted SDK record still contained 217 characters
in `record.dict["notes"]`. If the documented query returns an empty sentinel, do not try to treat
`keyPair` as the connection profile. Read the same record through the KSM SDK in the consuming
process and keep the notes value in memory:

```python
from keeper_secrets_manager_cli import KeeperCli

record = KeeperCli(profile_name="contoso")._client.get_secrets([uid])[0]
notes = record.dict.get("notes", "")
if not notes.strip():
    raise RuntimeError("KSM record notes are empty")
# Parse/use notes here. Never print the value or write it to disk.
```

**Blast radius, and the fix that shipped (2026-08-06):** `Invoke-WithKsmEnv.ps1` parsed ScreenConnect's
notes with exactly that `-q notes --raw` call, so it **hard-failed and injected nothing** —
`FAILED to resolve 3 value(s)`, exit 1, naming `SCREENCONNECT_RESTFUL_AUTHENTICATION_SECRET`,
`SCREENCONNECT_BASE_URI`, `SCREENCONNECT_EXTENSION_ID`. The other 12 resolved fine, so the symptom
was all-or-nothing failure of every script wrapped by it, not just the ScreenConnect ones.

**Patched:** the wrapper's notes branch is now `Get-KsmNotesBlob`, which tries the CLI first and
falls back to the SDK read only when the CLI returns an empty sentinel. Verified the same day —
16/16 values resolve and a ScreenConnect command runs end to end, while the bare CLI query still
returns `[]`. CLI-first is deliberate: it keeps the Python SDK off the happy path for the other
records, and a CLI-side fix silently takes back over with no further edit. If a future SDK bump
breaks the import, the failure is now loud (`SDK notes fallback FAILED for record <uid>`) instead
of an empty value scoring as success.

**The SDK is pinned (2026-08-06).** `keeper-secrets-manager-cli==1.4.0` and
`keeper-secrets-manager-core==17.3.0` in `%APPDATA%\pip\constraints.txt`, wired in user-wide via
`%APPDATA%\pip\pip.ini` (`[install] constraint = ...`), so **every** `pip install` for this user
honours it — including `pip install -U`. Enforcement verified: an explicit
`pip install keeper-secrets-manager-cli==1.3.0` is refused with `ResolutionImpossible`. The pin
exists because the fallback calls `KeeperCli(...)._client.get_secrets(...)` and `record.dict` —
surface an upstream bump could rename without considering it breaking.

Two consequences worth knowing before touching it: that constraint file governs **all** pip
installs for this user, not just Keeper, so deleting it while `pip.ini` still points at it makes
every `pip install` fail; and taking a Keeper upgrade is now a deliberate act — edit the version in
`constraints.txt`, upgrade, then re-run `Invoke-WithKsmEnv.ps1 -Check` and confirm 16/16 resolve.
Remove the pin entirely by deleting `pip.ini` (`constraints.txt` is inert without it).

This uses the same Credential Manager-backed profile as the CLI and needs no Commander session.
When invoking Python from another process, capture stdout rather than inheriting it; better still,
make the authenticated API call inside that Python process so the notes never cross process output.
For a safe no-value verification, use `scripts/Get-KsmNotesProof.py` inside this skill's folder; it
prints only the notes length and a 12-character SHA-256 prefix.

**An absent-but-declared field returns the JSON literal `[]`** — length 2, sha256 prefix
`4F53CDA18C2B`. That is not an error, not a non-zero exit, and not whitespace, so an
`IsNullOrWhiteSpace` guard scores an empty read as success (it did, for two records, on
2026-08-04). Reject `[]`, `{}`, `""`, and `null` explicitly. Also parse structured candidates:
`{"privateKey":"\n"}` is an empty `keyPair`, not a 20-character secret (false-positive observed
2026-08-06).

To learn field names without exposing values, query the metadata rather than the record:

```powershell
ksm -p contoso secret get --uid <UID> -q "fields[*].type"
ksm -p contoso secret get --uid <UID> -q "custom[*].label"
```

Never `--json` or `--unmask` on a KSM read — same leak behavior as Commander's.

Keeper notation (`keeper://<UID>/field/password`) works on this path, and `ksm exec` /
`ksm interpolate` can inject secrets without them landing in a variable.

### Two lanes: read-only credentials, editable write folder

The app deliberately holds **two different permission levels** (set 2026-08-04):

| Share type | UID | Permission |
| --- | --- | --- |
| The 7 credential records | see table below | **Read-Only** |
| Folder `Contoso Automation Writes` | `KEEPERUID000000000006` | **Editable** |

**KSM can only create records inside a shared folder the app can edit** — that folder is the entire
reason it exists. If `ksm -p contoso folder list` is empty, there is no write target and
`secret add` cannot work, no matter what record permissions say. Write new automation records into
the folder; never widen a credential record to editable to get a write done.

```powershell
ksm -p contoso secret add field --sf KEEPERUID000000000006 --rt login -t 'Title' -p login=svc
ksm -p contoso secret delete --uid <UID>
```

**Flag collision:** the global profile flag `-p` must come **before** the subcommand. Inside
`secret add field`, `-p` means `--password-generate`. `--sf`, `--rt`, and `-t` are all required.

**Verify permissions with `keeper secrets-manager app get <AppName>`** — it prints a
Share Type / UID / Title / Permissions table plus client-device state (expiry, IP lock). Never test
read-only by attempting a write against a live credential. That command is also throttle-prone;
wait ~75s and retry rather than assuming failure.

To change a permission, use `secrets-manager share update --app <A> --secret <UID> --readonly`
(or `--editable`). It updates in place, so there is **no window where the app loses read access** —
strictly better than `share remove` + `share add`. `--secret` accepts a shared-folder **path** as
well as a UID, so no UID parsing is needed when sharing a folder by name.

### Rebuilding or re-verifying the profile

Inside this skill's folder: `scripts/Build-KsmProfile.ps1` does the one-time build (needs a live
Commander session), `scripts/Verify-KsmProfile.ps1` is the no-values read proof (needs neither
Commander nor SSO), `scripts/Set-KsmReadOnly.ps1` sets the two-lane permissions above, and
`scripts/Test-KsmWriteLane.ps1` proves the write folder works by creating, reading, and deleting a
throwaway record. Enabling KSM required a role change: before 2026-08-04, `app create` returned
`Permission denied: Secrets Manager is not permitted for this user`. Note that
`secrets-manager app list` **succeeded with an empty list while that denial was in force**, so it is
not a permission test — only `app create` proves the entitlement.

## Commander (vault admin, and the legacy read path)

**Always invoke the executable directly when capturing output:**

```powershell
$keeper = 'C:\Program Files (x86)\Keeper Commander\keeper-commander.exe'
```

The `keeper` launcher on PATH is a `.bat` with no `@echo off`, so it **prepends the echoed command
line to stdout** and silently corrupts any captured value. `keeper` is fine for interactive use and
for eyeballing `login-status`; it is never safe for capture.

## Non-negotiables

1. **Never print a secret value** — not to chat, logs, tickets, files, commit messages, or command
   arguments. Prove retrieval with a character count plus a short SHA-256 prefix instead.
   After filling a secret into a browser form, do not emit a page or locator DOM snapshot until the
   field is cleared: some sites include the live password value in accessibility diagnostics. Check
   only the title, URL, or narrowly selected non-input status text while a secret remains populated.
2. **Never pass `--format=json` to `get`, and never pass `--unmask` or `--unmask-all`.** See the
   leak list below.
3. **Never attempt to log in.** The account is SSO; re-auth needs a browser round-trip and a token
   paste only the owner can do. Ask them.
4. Resolve secrets into process-scoped environment variables at the moment of use, and clear them
   in a `finally` block. Prefer this over any file on disk.
5. **Always validate that the retrieved value is non-empty.** Wrong or absent field names return an
   empty string with no error and exit code 0.

## 1. Check the session first

```powershell
keeper login-status
```

`Logged in` means proceed. An empty/bare-CR reply, or any output containing an SSO login URL, means
the session is gone. `login-status` can also be **stale** (observed 2026-07-31): it returned
`Logged in` while the session was already dead, `search` then returned a bare ANSI escape with no
rows and no error, and the next real vault call dropped into the SSO prompt mid-script. Treat an
empty `search`/`ls` result as a probable lapse rather than "no matches", and expect any real vault
operation to be the true session test.

### Persistent login does not work non-interactively — plan around it

Commander says so outright when a non-interactive process tries to re-auth:

```text
Persistent login is not working in this non-interactive environment
(possibly due to an IP/location change).
```

Consequences, all confirmed 2026-07-31:

- An automated/agent shell can **never** re-establish a lapsed session — not with `--batch-mode`,
  not by piping `q` into `keeper shell`, not by retrying. Only an interactive terminal can.
- Persistent login *does* silently re-auth when the owner launches `keeper shell` themselves. That
  refreshes the session, and one-shot commands then work until it lapses again.
- The usable window observed was roughly 25-30 minutes, **shorter than the 1-hour idle timeout** —
  do not budget for the full hour.
- Egress IP movement is a suspected trigger, which matters on a Cato SASE network.

So: **batch-retrieve every secret the task needs in one pass, right after the owner authenticates.**
Do not lazily fetch one credential at a time across a long task; the session will die mid-way. Call
`keeper keep-alive` to hold the window open during long work. **The idle timeout is already at the
12 h enterprise cap** (raised from 1 h on 2026-08-01), so don't offer to raise it — it cannot go
higher, and the ~25-30 min lapses were observed under the old 1 h setting anyway, meaning the
timeout value was never the cause. Egress IP movement is the suspected trigger.

Workstation keep-alive was tried 2026-08-17 and **removed the same day**. An Interactive
Task Scheduler launch of `pwsh.exe` flashes a console every cycle even with `-WindowStyle Hidden`,
and `Start-Process keeper-commander.exe` orphaned visible `powershell.exe` windows. Do not
reinstall `KeeperSessionKeepAlive` unless the action is a window-style-0 WScript/`CREATE_NO_WINDOW`
wrapper that has been proven not to flash. Persistent login, IP auto-approve, and the 12 h
timeout are already ON. If the session is gone, ask the owner to run `keeper shell` once.
Never try to drive the SSO flow.

A lapsed session also blocks `keeper help <command>`, so the vault command surface is not
discoverable offline. Use `references/commander-command-reference.md` inside this skill's folder
instead.

## 2. Find the record

```powershell
keeper ls
keeper search <text>
```

Use plain output. Do **not** dump `keeper ls --format=json` or `keeper search --format=json` into a
transcript: for login records the summary renders as `<login> @ <url>`, so any credential parked in
a non-hidden field appears with no unmask flag.

### Contoso automation credentials (records verified 2026-07-31; sourcing 2026-08-04)

These are the records the other skills depend on. **They are now the only copy** —
`C:\AI Workspace\env.local` and `C:\automox-mcp-main\MCP.env` were deleted 2026-08-04 once every
value was confirmed byte-identical in KSM. Do not recreate them; use the wrapper patterns above. If
a script reports a missing key, it was run without the wrapper, not misconfigured.

| System | Record title | UID | Secret location |
| --- | --- | --- | --- |
| Freshservice | `Freshservice API - avery.operator@contoso.com` | `KEEPERUID00000000000B` | `password`; domain/product in custom fields |
| Rapid7 InsightVM | `Rapid7 InsightVM API - avery.operator@contoso.com` | `ekhfX2K9Gf6M6L0vCcfh7A` | `password`; region/base URL in custom fields |
| Automox | `Automox API - MCP Server` | `7rOFNUuckyxKAAs2MVhWfQ` | `password`; account UUID/org ID in custom fields |
| ScreenConnect | `ScreenConnect API Secret` | `KEEPERUID00000000000C` | `notes` field, `KEY=value` lines |
| FedEx | `Fedex Bot` | `KEEPERUID000000000007` | `notes` field; account number in `FEDEX_ACCOUNT_NUMBER` |

Each record carries an `ENV_VAR_NAME` custom field naming the environment variable its consumers
expect. A second shared `Rapid7-Avery` record exists, owned by another user with Avery read-only —
rotate both together.

## 3. Learn the field name before retrieving

`--format=password` only works on records that *have* a password field. Field names are
record-type-specific and not guessable, so inspect the masked structure first — masked `get` is safe
and shows every field name with secrets rendered as `********`:

```powershell
& $keeper get <UID>
```

Verified mappings on this vault:

| Record type | Secret field | Retrieve with |
| --- | --- | --- |
| `login` | `password` | `--format=password`, or `--field password` |
| `encryptedNotes` | `note` (singular) | `--field note` |
| `sshKeys` | `keyPair`, plus a `notes` field that often holds the real connection profile | `--field notes` |

## 4. Retrieve

Each of these returns only the requested value:

| Goal | Command |
| --- | --- |
| Password | `& $keeper get <UID> --format=password` |
| Password | `& $keeper find-password <UID>` |
| Login/username | `& $keeper clipboard-copy <UID> -l --output stdout` |
| Any named field | `& $keeper clipboard-copy <UID> --field <NAME> --output stdout` |
| TOTP code | `& $keeper totp <UID>` |
| Hand off to the user | `& $keeper find-password <UID> --output clipboard` |
| Record structure, masked | `& $keeper get <UID>` |

## 5. Use it, then clear it

```powershell
$secret = (& $keeper get <UID> --format=password | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($secret)) {
    throw 'Empty value - wrong field name, or this record type has no password field. Run: & $keeper get <UID>'
}
if ($secret -match 'keeper-commander\.exe') {
    throw 'Output contaminated by the keeper.bat echo - call the .exe directly.'
}
try {
    Set-Item -Path Env:\SOME_API_KEY -Value $secret
    & .\script-that-needs-it.ps1
}
finally {
    Remove-Item Env:\SOME_API_KEY -ErrorAction SilentlyContinue
    Remove-Variable secret -ErrorAction SilentlyContinue
}
```

When proving retrieval works, hash the value — never print it. Do not name a PowerShell helper
function `h` or `H`: it shadows the `Get-History` alias, and the resulting binding error prints the
offending value into the transcript.

## Commands that leak plaintext

Verified, not theoretical:

- **`keeper get <UID> --format=json` does not mask.** It dumps every field in cleartext, passwords
  included. Plain `keeper get <UID>` *does* mask. Never use JSON to inspect a record.
- `--unmask-all` (global) and `get --unmask` disable masking by design.
- `--output stdouthidden` gives byte-identical output to `--output stdout` when captured. It only
  suppresses on-screen echo; it is not redaction.
- `keeper export` writes decrypted vault data to disk.
- Keeper notation (`keeper://<UID>/field/password`) is KSM-only and fails under Commander. Use it on
  the KSM path above instead.
- **`Notes` fields are not masked.** Plain `get` renders them in full, and several records park
  connection profiles and keys there. Redact before showing any `get` output to anyone.

## Silent failures

None of these raise an error or a non-zero exit code:

- Wrong or absent `--field` name -> empty string.
- `--format=password` on a record type with no password field -> empty string.
- Capturing via the `keeper` `.bat` -> value silently prefixed with the echoed command line.

Guard every retrieval with a non-empty check and a `keeper-commander\.exe` contamination check.

## Writes need approval

Reads are routine. `record-add`, `record-update`, `rm`, `share-record`, `share-folder`,
`one-time-share`, `export`, and anything under `secrets-manager` or `enterprise-*` are
production-impacting — get explicit approval from the vault owner first.

Once approved, the write syntax has its own traps (all verified 2026-07-31):

- Field syntax is `[f|c].<TYPE>.<LABEL>=<VALUE>`. Anything not a predefined field becomes custom, so
  `c.text.MY_LABEL=value`. Useful types: `password`, `secret` (masked single line), `note` (masked
  multiline), `text`, `url`, `login`.
- **`record-add` needs `-f`** when the value is an API key. The enterprise password policy validates
  the `password` field and rejects non-passphrase values with
  "First passphrase word must end with a digit".
- **`record-update` takes the UID via `-r`, not positionally.** A positional UID is silently
  swallowed as a field and the real field errors as "unrecognized arguments".
- Omit `--folder` to create in the personal vault root. Passing a shared-folder UID shares the
  secret with that folder's whole membership.
- Write the record in a script that reads the source value itself, so the secret never passes
  through a chat message. Note that CLI arguments are briefly visible to other same-user processes.
- Avoid embedded newlines in `-n/--notes`: they break process spawn on this host with
  "operation was canceled by the user". Keep notes single-line.

The full Commander write recipe — `run-batch`, the two-pass record build, the field-syntax and
quoting traps — is in `references/commander-write-recipe.md` inside this skill's folder. Read it
before any `record-add` / `record-update`; the obvious approaches all fail silently.

## Feeding secrets to consumers instead of an env file

Never point an app at a plaintext `.env`. Two patterns, both verified 2026-08-04:

**Notation + `ksm exec`** — for anything you can launch. Set env vars to Keeper *notation* (not
secrets, so they are safe in a config file or repo) and let `ksm exec` resolve them for the child:

```powershell
$env:AUTOMOX_API_KEY = 'keeper://<UID>/field/password'          # standard field
$env:AUTOMOX_ORG_ID  = 'keeper://<UID>/custom_field/AUTOMOX_ORG_ID'
ksm -p contoso exec -- <command> <args>
```

`ksm exec` is **stdio-clean** — it adds nothing to stdout/stderr — so it is safe to wrap a stdio
MCP server or any protocol that parses stdout. Do **not** pass `--capture-output`, which buffers and
would break that. Notation cannot address individual `KEY=value` lines inside a `notes` field; for
those, resolve and inject in a wrapper instead.

**A wrapper that resolves then injects** — for consumers that read a file and ignore `process.env`.
See `scripts/Invoke-WithKsmEnv.ps1` and `scripts/ksm-env-shim.mjs` in `C:\automox-mcp-main`, which
serve a whole repo's worth of Node tooling from KSM with no plaintext on disk.

Two PowerShell traps that cost real time when writing such a wrapper:

- **Do not use `[CmdletBinding()]`** on a command wrapper. It adds the common parameters, and a
  child flag like `node -e ...` then fails with "the parameter name 'e' is ambiguous" — even `--`
  is rejected. Without it, unbound arguments land in `$args` verbatim.
- **A `[string]` parameter is implicitly POSITIONAL.** A `-ProfileName` parameter silently captured
  the wrapped command's name (`node`), so every secret lookup ran against a nonexistent profile and
  all 16 reads "failed". Take such settings from the environment, or declare only `[switch]`.

## Related

- Full runbook, record UID inventory, and open findings:
  `C:\automox-mcp-main\docs\keeper-commander-secret-retrieval-runbook.md`
- `references/commander-command-reference.md` inside this skill's folder — offline command surface.
- `references/commander-write-recipe.md` inside this skill's folder — Commander record writes.
- Shared Contoso defaults and cross-system context: the it-operations skill.
- Microsoft Graph and Intune tokens: the acquire-graph-token skill.
