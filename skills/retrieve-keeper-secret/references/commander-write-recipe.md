# Commander write recipe (verified 2026-08-01, after four failed approaches)

Only needed when adding or updating a record through **Keeper Commander**. Reads and record
creation inside the KSM write folder go through the KSM path in SKILL.md instead.

Writes are production-impacting: get explicit approval from the vault owner first.

Set `PYTHONUTF8=1` and `PYTHONIOENCODING=utf-8` before invoking. Without them the frozen Python
dies on `UnicodeDecodeError: 'charmap' codec can't decode byte 0x90` and then prompts, hitting
`EOFError` in a non-interactive shell.

**`import --format=json` is a DEAD END — do not spend time on it.** `--dry-run` succeeds and prints
a correct table of records to be created, then the real run creates **nothing**: once with the
cp1252 crash above, and once with **exit 0, no output, and no records**. A clean dry run proves
nothing here.

**Use `run-batch <file>` instead.** One Keeper command per line in a UTF-8 (no BOM) file. This is
strictly better than a bare `record-add` because the secret lives only in a file you delete, never
on a command line visible to other processes.

Then build the record in two passes, because the rich form fails:

1. **Create with the bare minimum only** — `-t`, `-rt login`, `login=`, `password=`. Adding
   `--folder`, `url=`, or `text.<Label>=<value>` custom fields in the same `record-add` throws a
   bare `An unexpected error occurred: <class 'AttributeError'>` and creates nothing. (Untested
   which of the three is at fault, and whether the documented `c.text.LABEL=` prefix would
   survive where a bare `text.Label with spaces=` did not.)
2. **Enrich with `record-update -r <uid> -n "<single-line note>"`.** Put the IDs, endpoints, and
   limits in the note rather than fighting custom fields.

A successful `record-add` prints the new record UID on stdout — capture it for step 2.

**Double quotes inside a `-n` note value break batch parsing** (`<class 'ValueError'>`); they
terminate the argument early. Strip all `"` from note text before writing the batch file.

## Field syntax

Field syntax is `[f|c].<TYPE>.<LABEL>=<VALUE>`. Anything not a predefined field becomes custom, so
`c.text.MY_LABEL=value`. Useful types: `password`, `secret` (masked single line), `note` (masked
multiline), `text`, `url`, `login`.

- **`record-add` needs `-f`** when the value is an API key. The enterprise password policy validates
  the `password` field and rejects non-passphrase values with
  "First passphrase word must end with a digit".
- **`record-update` takes the UID via `-r`, not positionally.** A positional UID is silently
  swallowed as a field and the real field errors as "unrecognized arguments".
- Omit `--folder` to create in the personal vault root. Passing a shared-folder UID shares the
  secret with that folder's whole membership.
- Avoid embedded newlines in `-n/--notes`: they break process spawn on this host with
  "operation was canceled by the user". Keep notes single-line.

Verify the round trip by comparing a length + short SHA-256 prefix of the retrieved value against
the source, then delete the plaintext source file.
