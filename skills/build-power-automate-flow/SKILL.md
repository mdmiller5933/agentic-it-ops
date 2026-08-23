---
name: build-power-automate-flow
description: Build, edit, or troubleshoot Microsoft Power Automate cloud flows in the web designer (make.powerautomate.com) - driving the browser directly when browser automation is available, otherwise guiding the user step by step. Use when creating or modifying a Power Automate flow, adding triggers/actions/approvals/HTTP calls, wiring dynamic content or expressions, making manual-trigger inputs optional, embedding secrets, or diagnosing a failed flow run in the new designer. Captures hard-won designer gotchas so the build doesn't have to relearn them.
---

# Build Power Automate Flow (via browser)

Power Automate flows are built in the web designer (make.powerautomate.com); there is no API to
author them. So this is a browser-driving task: drive the designer step by step with whatever
browser automation is available, otherwise guide the user through the same steps. The designer is
React-heavy and fights automation — the rules below are the difference between a smooth build and
an hours-long slog.

## Before you start
- Confirm a browser is connected: `list_connected_browsers`. Navigate the working tab to
  `make.powerautomate.com`. If no browser-automation tool is available in this session, walk the
  user through the designer step by step instead, applying the same golden rules below.
- Confirm the user is signed in as the account that owns the flow and has the right license.
  **HTTP and Azure Key Vault are premium connectors**; Forms/Teams/Approvals/Outlook/SharePoint
  are standard. The flow must be owned by an account with Power Automate Premium for HTTP.
- You cannot build the flow for them in a headless way — narrate progress; pull the user in only
  for: entering credentials/secrets, interactive connection sign-in popups, sharing/permissions,
  and approving test runs.

## Golden rules (the gotchas that cost the most time)

1. **Element refs are not stable — read before you act.** `read_page`/`find` mint ref ids for
   elements that exist *at that moment*. You cannot predict a future ref's number, and a click
   that adds DOM (e.g. "Add an input") invalidates later refs. Pattern: read_page → act on those
   refs → if the action created new elements, read_page again. A `read_page` *inside* a
   `browser_batch` does make later same-batch refs usable, but only if you already know the number
   — so mostly: one create per batch, then re-read.

2. **CDP timeouts are normal — retry, don't redo.** `screenshot` often fails with
   "CDP sendCommand ... timed out"; just call it again. A `type` of a long string may report
   "timed out" but **actually complete** — verify with a screenshot before retyping (retyping
   duplicates text).

3. **Use `browser_batch`** to chain clicks/types/waits/screenshots. Put a short `wait` (1s) after
   any click that triggers a render, before the next dependent action.

4. **Reaching off-screen "+" insert points:** the add-action `+` for a nested branch is often
   below the fold. Collapse the action details panel (the `«` button), then click **"Zoom view to
   fit"** (the frame icon in the canvas zoom controls). Now every `+` is visible — click the
   on-canvas `+` directly. Clicking a stale insert-button ref usually does nothing.

5. **Manual-trigger ("Manually trigger a flow") input keys are positional by type.** As you add
   inputs, keys are assigned per type in order: Text → `text`, `text_1`, `text_2`…; Yes/No →
   `boolean`; Number → `number`; etc. Reference them as `triggerBody()?['text_5']`. **Verify the
   exact keys** by opening the trigger's **Code view** before building references.

6. **Make inputs optional via the per-input `...` menu → "Make optional".** Every Text/Number/
   Yes-No input is **required by default**. **NEVER delete or reorder trigger inputs** after
   downstream references exist — that renumbers the positional keys and silently breaks every
   `triggerBody()['text_N']` reference. "Make optional" toggles in place and is safe.

7. **A JSON HTTP Body rejects unquoted `@{}`.** The design-time validator throws
   "Enter a valid JSON" if a value is `"x": @{...}` unquoted. **Quote every dynamic value**:
   `"x": "@{triggerBody()?['text_1']}"`. For values that must be a real number/boolean, either
   confirm the target API accepts a stringified value, or build the whole body with an expression.
   (The token/oauth body is `x-www-form-urlencoded`, NOT JSON — no quoting needed there.)

8. **Optional fields need the `?` operator.** A blank optional input is *omitted* from
   `triggerBody()`; `triggerBody()['text_5']` (no `?`) then **throws and fails the run**. Use
   `triggerBody()?['text_5']` — a blank renders as `""` (not the literal `"null"`) in an `@{}`
   string. Force-empty with `@{coalesce(triggerBody()?['text_5'],'')}` if you want a guarantee.

9. **Type expressions inline; don't trust the fx chip through Save.** The fx expression editor's
   "Add" produces a chip that has been seen to **revert to `null` after Save**. More reliable:
   type the expression as `@{...}` **directly into the field** (works for HTTP body, header values,
   email attachment `ContentBytes`, etc.). Verify via the action's **Code view** after saving.
   **Editing an EXISTING chip is worse than creating one** (verified 2026-08-03): clicking the chip,
   rewriting the expression in the editor, and clicking **Update** closes the editor and the toolbar
   still reports "Your flow is ready to go" — but the **old** expression is what persists, and it
   survives a full page reload, so nothing signals the failure except Code view. There is no error
   to notice. Working sequence: click the chip's **`×`** to clear the field, then type the whole new
   expression **directly into the empty field** (leading `@`, no braces, for a boolean/native value),
   click blank space in the details panel to blur, Save, then **reload the page and re-open Code
   view** to confirm. Treat any expression edit as unverified until Code view shows it post-reload.

10. **Secrets:** turn on the action's **Settings → Secure Inputs** (hides inputs from run
    history). **Do not open Code view or screenshot a body/panel while a secret is in it** — it
    lands in the transcript. The **HTTP action's Active Directory OAuth `Secret` field (and the
    Client-certificate/Raw fields) render the value in PLAINTEXT in the designer — NOT masked** — so
    any screenshot of that open panel leaks it, even one taken to check something else. Have the
    user paste the secret themselves and **collapse the details panel (`«`) or click blank canvas
    before the next screenshot**; verify success via the node losing its error / the Save banner,
    not by viewing the field. Prefer feeding secrets by clipboard-paste (`ctrl+v`) so the value
    never passes through chat. Diagnose credential problems by comparing **lengths and first/last
    chars** against a known-good source rather than displaying the value. Watch for the classic
    `l` vs `1` and `O` vs `0` paste mix-ups and trailing whitespace/newlines.

11. **Duplicate actions auto-name `X` then `X 1`.** In expressions, spaces become underscores:
    `body('HTTP')`, `body('HTTP_1')`.

12. **Approvals:** add **"Start and wait for an approval"** (Approve/Reject – First to respond).
    The Approvals connection auto-creates with the signed-in account. During a test, approve via
    **Approvals → Received** in the left nav (or the Teams/Outlook card). Branch on the approval's
    `Outcome` with a Condition (`Outcome is equal to Approve`).

13. **Connections** (Outlook, Approvals, etc.) usually auto-create silently. If a sign-in/consent
    popup appears, **hand it to the user** — never enter their credentials.

14. **Background designer tabs freeze permanently (seen in Edge).** If screenshots/read_page on a
    make.powerautomate.com tab start timing out ("Script injection timed out", "renderer frozen")
    after the tab sat in the background, the tab is dead — waiting and navigate() do NOT revive
    it. Create a NEW tab, load the flow URL there, and continue; saved work is intact. So: Save
    before switching away from a designer tab, and expect to burn a tab per long detour.

15. **HTTP-trigger flows called by external services (Slack events, webhooks): set the trigger's
    "Who can trigger the flow?" to "Anyone"** — the default "Any user in my tenant" requires Entra
    auth and the external POST fails. The URL's SAS `sig` is the secret. The generated URL can't
    be read from the a11y tree — click its copy button and ctrl+v it directly where needed. For
    Slack Events API verification, make the FIRST action a Response 200 with body
    `@{coalesce(triggerBody()?['challenge'],'')}` (also satisfies Slack's 3-second ack).

16. **Clipboard "Copy" buttons only work on the ACTIVE browser tab.** Clicking a copy button on a
    backgrounded tab silently no-ops (navigator.clipboard needs document focus) — the clipboard
    keeps its old contents, which then get pasted as the "secret" and fail with invalid_auth-style
    errors while the flow run still shows Succeeded. Create a fresh tab (it becomes active)
    immediately before clicking Copy, and verify the page flashes its "Copied!/Success!"
    confirmation (find can read it without screenshotting the secret) before pasting elsewhere.

17. **Each field type mangles a typed expression differently — always confirm in Code view.**
    `@{expr}` (braces) forces a **string**; `@expr` (no braces) keeps the **native type**. The
    Parameters tab renders both as an identical `fx` chip and the Flow checker reports 0 errors
    either way, so only Code view reveals these:
    - **Condition rows:** typing `@{greater(...)}` persists as `equals: ["@{greater(...)}", true]`
      — string vs JSON boolean, which **never matches**, so the branch silently never fires and
      nothing downstream ever runs. Type the left side **without braces** (`@greater(...)`) and
      leave the right box as plain `true` (stored as a real JSON boolean). You want
      `["@expr", true]`. Do **not** "fix" it by putting `@{true}` on the right — that just inverts
      the mismatch. Editing one side of a row can silently re-normalise the other, so re-check
      Code view after every condition edit. Verified 2026-08-19: a legacy row stored as
      `["@{and(...)}", "@{true}"]` (both sides stringified — which works) had its untouched right
      side silently rewritten to `@true` (native boolean) the moment the left chip was replaced
      and saved — leaving string-vs-boolean, never-match. The repair is to re-type the LEFT side
      without braces so both sides are native booleans; don't try to restore `@{true}` on the
      right.
    - **Select's "text mode" Map** validates as JSON: `@item()?['id']` fails with "Enter a valid
      JSON". Type it **double-quoted** — `"@item()?['id']"` — which parses to the string the
      engine wants and persists as `"select": "@item()?['id']"`.
    - **Filter array's basic-mode Filter Query** string-wraps what you type: `@{contains(...)}`
      becomes `@equals('@{contains(...)}',true)` and Save fails with "contains invalid
      expression(s)". Click **"Edit in advanced mode"** *first*, then type one clean boolean
      expression (`@contains(body('Member_ids'), item()?['userId'])`, or `@not(contains(...))`
      instead of fighting the editor for "is equal to false").

18. **Calling Microsoft Graph on a schedule — choose the app-only credential deliberately.** The
    default **"Log in with Microsoft Entra ID"** connection is delegated and tied to the human
    connection owner. For an unattended admin scope such as `DeviceManagementRBAC.Read.All`, use a
    dedicated single-tenant app with the smallest Graph **Application** permission and admin
    consent. Two supported patterns:
    - Preferred when an exportable PFX is available: **HTTP with Microsoft Entra ID
      (preauthorized)** → **Log in using a Client Certificate Auth**. Set both resource fields to
      `https://graph.microsoft.com`, then provide tenant, app client ID, PFX and its password. A
      Windows certificate-store thumbprint is not enough; Power Automate needs the PFX private key.
    - Fallback: premium **HTTP** action 1 POSTs the OAuth `client_credentials` form to the tenant
      token endpoint; action 2 calls Graph with the returned bearer token. URL-encode the secret.
      Turn on **Secure Inputs and Secure Outputs for both actions** and never inspect the token
      action in Code view or screenshots.

    Chromium extension uploads can fail with `Not allowed` until file-URL access is enabled in the
    extension settings. Do not keep retrying. Ask the user to enable that setting, or—when the user
    already authorized the migration—use the dedicated client-secret fallback, store the recovery
    copy encrypted, and remove any unused certificate credential/PFX created during staging. Never
    fall back to delegated authentication just because certificate upload is blocked.

19. **Intune MAA app-only reads are silently filtered by protected workload permission (verified
    2026-08-12).** `DeviceManagementRBAC.Read.All` authorizes GET
    `deviceManagement/operationApprovalRequests`, but it does not make every request payload
    visible. With RBAC read alone, Graph returned HTTP 200 plus an empty collection and HTTP 404 for
    an exact mobile-app request. Adding `DeviceManagementApps.Read.All` made that same natural
    request visible immediately. A tenant-wide poller also needs the read-only application role for
    each protected resource family it monitors: `DeviceManagementConfiguration.Read.All`,
    `DeviceManagementManagedDevices.Read.All`, `DeviceManagementScripts.Read.All`, and
    `DeviceManagementServiceConfig.Read.All`. Treat a Succeeded flow and HTTP 200 as insufficient:
    compare workload-family inventory and validate on a naturally occurring request. Never overlap
    delegated and app-only posters, and never manufacture an Intune change just to test the poller.

20. **A Recurrence/Scheduled flow cannot be manually test-run while it is Off.** Test → Run flow
    returns *"This flow is currently turned off. If you own it, turn it on…"*. Turning the flow
    **On is a prerequisite to testing**, not the post-test victory lap the checklists imply — so
    say that when asking approval for a first production run, because On also arms the schedule and
    the next interval fires unattended. Upside: the next scheduled run is the real **idempotency**
    proof (it should be a no-op); a first run only proves the write path.

21. **`item()` binds to the INNERMOST repeating scope.** A Filter array nested inside an
    `Apply to each` evaluates its condition with `item()` = the element being filtered, not the
    loop's current item — so filtering `@body('Get_device_object')?['registeredOwners']` on
    `@contains(body('Member_ids'), item()?['id'])` reads owner ids, as intended.

22. **There is no paste on an insert point in the new designer.** Right-clicking a *node* offers
    "Copy action", but right-clicking an insert `+` offers only Add an action / Add generative
    action / Add AI prompts — no Paste — so plans that say "copy the first HTTP action and edit it"
    don't work. Add each action fresh; the premium HTTP connector needs no connection, so
    re-adding it is cheap.

23. **Set a fixed window size before a long build.** The designer re-lays out on every panel
    open/close and the browser window can resize mid-session, which silently shifts every
    coordinate — several "the value didn't take" failures are really clicks landing one field off.
    Prefer `ref`-based clicks from `find`/`read_page`, and after any dropdown selection re-read
    refs rather than reusing coordinates from the previous screenshot.

24. **Rich-text fields (e.g. the Teams Message box): clicking beside a chip silently no-ops.**
    A click next to an inline token chip often fails to focus the contenteditable — typed keys go
    nowhere, and the action's Code view shows the body unchanged (check there, not the canvas,
    whenever typing "didn't take"). Reliable insertion: click into plain TEXT in the field, then
    move the caret with keyboard keys (End / Down / End) to the target spot, then type the
    `@{...}` literal. It stays visible as literal text until Save, then becomes an fx chip. The
    editor may bold-wrap the inserted run depending on caret formatting state, and on save it
    re-serialises the whole body with `editor-paragraph`/`editor-text-bold` classes — cosmetic,
    harmless (verified 2026-08-19).

## Build sequence
1. Create → **Instant cloud flow** (or Automated) → name it → pick the trigger.
2. Configure the trigger. For manual triggers, add inputs (record the add-order → key mapping).
3. Add actions via the `+` insert points; **a flow needs ≥1 action before it will Save**.
4. **Save frequently** (protects work against the flaky UI). The banner turns to
   "Your flow is ready to go" when valid; a red banner names validation errors.

## Testing & diagnosing a failed run
1. **Test → Manually → Test → Run flow**, fill the trigger inputs, **Run flow**. (The run form
   does not prefill previous values — re-enter each time.)
2. If there's an approval, it pauses; approve via **Approvals → Received**.
3. Check **flow details → 28-day run history**: green **"succeeded"** vs red **"failed"**.
4. Open a failed run → click the failed action → **Run results** shows the **Status code** and
   error. A `401` on an OAuth/token step = rejected credentials (see rule 10 for safe diagnosis).
5. After a fix, **Save** then **Test** again (or **Resubmit** the run — note it re-fires approval).

## Worked examples
- Teams request → approval → FedEx label → email: `C:\temp\NodeJS\fedex\power-automate-pipeline.md`
  (FedEx side covered by the `create-fedex-label` skill).
- Slack Events API → HTTP trigger → Flow bot post to a Teams group chat (challenge handshake,
  event filtering, Slack app manifest): `C:\temp\NodeJS\slack-teams-bridge\flow-spec.md`.
- Hourly app-only Graph read/write loop — token → list → Select → Filter array → nested
  Apply to each with an owner guard → conditional PATCH → reconcile-and-clear branch, 11 actions,
  every expression recorded verbatim: `C:\temp\NodeJS\it-devices-dynamic-group\flow-spec.md`
  (that file's "Designer gotchas" section is the evidence behind rules 17 and 20–23).
