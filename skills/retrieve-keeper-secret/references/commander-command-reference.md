# Keeper Commander Command Reference (offline copy)

A lapsed session blocks `keeper help <command>`, so this file exists to keep the command surface
available without authenticating. Syntax verified 2026-07-31 against Commander 18.0.13 plus the
vendor command reference.

Only `--help`, top-level `help`, and `version` work while unauthenticated.

## Invocation: use the .exe when capturing output

`keeper` on PATH resolves to `keeper.bat`, whose entire body is `keeper-commander.exe %*` with no
`@echo off`. cmd therefore echoes the command line to stdout, and a captured secret comes back as
`C:\path>keeper-commander.exe get <uid> --format=password  <secret>`. Call
`C:\Program Files (x86)\Keeper Commander\keeper-commander.exe` directly for anything captured.

## Field names are record-type-specific

`--field` and `--format=password` return an empty string, exit code 0, and no error when the field
does not exist. Inspect the masked record first (`get <UID>`) to read the real field names. Verified
on this vault: `login` -> `password`; `encryptedNotes` -> `note` (singular, not `notes`); `sshKeys`
-> `keyPair` plus a `notes` field that frequently holds the actual connection profile. `Notes` fields
are rendered unmasked by plain `get`.

## Global options

| Flag | Effect |
| --- | --- |
| `--server, -ks` | Region or host: `US`, `EU`, `AU`, `CA`, `JP`, `GOV` |
| `--user, -ku` | Account email |
| `--config CONFIG` | Alternate config file |
| `--data-dir DIR` | Override the Commander data directory |
| `--config-file` | Store credentials in plaintext `config.json` instead of the OS keychain. Equivalent to `KEEPER_CONFIG_STORAGE=file`. Intended for headless/Docker/CI. **Do not use on a workstation.** |
| `--batch-mode` | Non-interactive/basic UI mode. Does **not** suppress the SSO login prompt. |
| `--new-login` | Force a full login, bypassing persistent login |
| `--silent` | Suppress logging statements |
| `--unmask-all` | Disable masking of sensitive output. **Never use.** |
| `--fail-on-throttle` | Error instead of pausing and retrying on server throttling |

## Session and device

```
keeper login-status                 # "Logged in" / "Not logged in"; safe to poll
keeper whoami [--verbose] [--json]  # identity, account type, data center; no secrets
keeper login [email] [--new-login] [--server SERVER]
keeper logout
keeper keep-alive                   # forestall an idle timeout during a long job
keeper sync-down                    # re-download and decrypt the vault (alias: d)
keeper this-device                  # show device settings
keeper this-device persistent-login on|off
keeper this-device timeout <MINUTES|12h>
keeper this-device register         # register this device for silent/biometric login
keeper this-device ip-auto-approve on|off
keeper this-device 2fa_expiration forever
keeper biometric register|list|verify|unregister|update-name
```

`this-device timeout` is capped by the enterprise timeout; on this tenant that cap is 12 hours.

### SSO Cloud login flow

Interactive only, owner-performed. `keeper login <email>` prints an SSO login URL, then offers:

| Key | Action |
| --- | --- |
| `o` | Open the SSO URL in the default browser |
| `c` | Copy the SSO URL to the clipboard |
| `p` | Paste the SSO token back into Commander |
| `a` | Log in as an SSO user with a Master Password (requires the role enforcement policy "Allow users who login with SSO to create a Master Password", plus `sso_master_password: true`) |
| `q` | Cancel |

Device approval, when prompted, accepts `email_send`/`es`, `email_code=<code>`, `keeper_push`,
`approval_check`, `2fa_send`, `2fa_code=<code>`. 2FA duration accepts
`2fa_duration=30_days` or `2fa_duration=forever`.

## Retrieval

```
keeper get <UID|PATH>                       # masked password; safe for structure
keeper get <UID> --format=password          # value only
keeper get <UID> --format=json              # LEAKS: no masking, dumps all fields
keeper get <UID> --unmask                   # LEAKS by design
keeper get <UID> --legacy                   # legacy JSON shape for typed records
keeper get <UID> --include-dag --format=json  # PAM launch/admin credentials

keeper find-password <UID|PATH>
keeper find-password <UID> --output clipboard|stdout
keeper find-password <UID> --username <REGEX>
keeper find-password <UID> -l                # login instead of password

keeper clipboard-copy <UID|PATH>                          # clipboard by default
keeper clipboard-copy <UID> --output stdout|clipboard|stdouthidden|variable
keeper clipboard-copy <UID> --field <FIELD_NAME>
keeper clipboard-copy <UID> -l                            # login
keeper clipboard-copy <UID> -t                            # TOTP
keeper clipboard-copy <UID> --output variable --name <VAR>

keeper totp <UID> [--details] [--range N] [--format table|json]
keeper download-attachment <UID> [--out-dir DIR] [-r] [--preserve-dir] [--record-title]
```

`--output stdouthidden` is **not** redaction — captured output is identical to `stdout`.

Keeper notation (`keeper://<UID>/field/password`) is a KSM/SDK feature. Commander's `get` rejects
it with `Cannot find any object with UID`.

## Discovery

```
keeper ls [-l] [-f]                  # folder contents; plain output is safe
keeper list [PATTERN] [-v]           # all records, optional regex
keeper search <KEYWORDS> [--regex] [--format table|json] [-c CATEGORY]
keeper tree                          # folder structure
keeper cd <UID>
keeper list-sf                       # shared folders
keeper record-history <UID>          # revision history
```

`ls --format=json` and `search --format=json` render login records as `<login> @ <url>`, exposing
any credential stored in a non-hidden field. Prefer plain output.

## Writes — approval required

```
keeper record-add / record-update / rm / mkdir / mv / trash
keeper share-record / share-folder / record-permission / one-time-share
keeper export / import
keeper secrets-manager app create|list|get|remove|update
keeper secrets-manager client add --app <APP> [--name N] [--first-access-expires-in-min M]
                                  [--access-expire-in-min M] [--unlock-ip]
                                  [--config-init json|b64|k8s] [--count N]
keeper secrets-manager client remove|revoke
keeper secrets-manager share add|remove|update --app <APP> --secret <UID> [--editable|--readonly]
```

The client-token subcommand is `client add --app <APP>`, not `token add <APP>`. Older Contoso
runbooks have this wrong.

## Batch and scripting

```
keeper run-batch [-d SECONDS] [-q] [-n|--dry-run] <FILE>
keeper shell           # interactive
keeper supershell      # full-screen TUI vault browser
keeper generate [-c LENGTH] [-d DIGITS] [-u UPPER] [-l LOWER] [-s SYMBOLS] [--passphrase]
```

One-shot invocation works directly: `keeper <command> [options]` runs and exits, which is the
normal way to script retrieval.

## Docs

- https://docs.keeper.io/en/keeperpam/commander-cli
- https://docs.keeper.io/en/keeperpam/commander-cli/command-reference/record-commands
- https://docs.keeper.io/llms-full.txt — full corpus, useful for scripted lookups
