# Authenticated Freshservice agent browser session (CDP + magic link)

Needed when a task must hit classic/internal Freshservice endpoints the public v2 REST API does not
expose (service catalog item writes, Workflow Automator build/edit, field manager). Verified
2026-07-09 on `contoso.freshservice.com`. Do not print cookies, CSRF tokens, or the magic-link URL.

## Why not the browser-extension automation MCP

A browser-extension automation MCP may be unavailable (extension not connected). This method needs only
a local Chrome/Edge with the DevTools Protocol (CDP) port open, driven by a tiny no-dependency Node
client. It survives that MCP being down.

## Host gotchas on Avery's workstation

This machine has the MSIX child-process env corruption (see [[claude-desktop-msix-spawn-corruption]]):
`SystemRoot` arrives empty in spawned children, which segfaults Chromium at launch. So:

- Launch the CDP browser from a **cmd/.cmd file run by Task Scheduler**, not directly from the agent
  shell, so it inherits a clean environment. Pattern: write a `.cmd` that runs
  `chrome.exe --user-data-dir=<persistent-profile> --remote-debugging-port=9224 --no-first-run --no-default-browser-check`,
  register it with `schtasks //create //tn NAME //sc once //st 23:59 //tr <cmd> //f` then
  `schtasks //run //tn NAME`. Use a **persistent** user-data-dir (e.g. `C:\temp\chrome-cdp-profile`)
  so the login cookie survives restarts.
- Long inline `node -e` strings and piped output are unreliable here (libuv `uv_spawn EUNKNOWN`,
  `fork: Permission denied`, lost stdout). Write `.mjs`/`.sh` script files and run
  `node script.mjs > out.txt 2>&1`, then Read `out.txt`. Retry once on a spurious fork error.
- If Chrome accumulates hung tabs (eval/navigate timeouts pile up), `taskkill //IM chrome.exe //F`
  and re-run the scheduled task; the persistent profile keeps you logged in.

## CDP client

`scripts/cdp.mjs` (bundled) is a dependency-free CDP client over the global `WebSocket`
(Node ≥ 21). Key calls: `CDP.targets(port)`, `CDP.newTab(port,url)`, `c.connect()`,
`c.navigate(url)`, `c.waitForLoad()`, `c.eval(jsExpr)` (returns the value by JSON), and
`c.events` (buffered `Network.*` events after `c.send('Network.enable')`). Connect to a page target
whose `url` matches `freshservice.com`.

## Log in with an Outlook magic link

Contoso Freshservice uses Freshworks SSO. Steps:

1. Navigate a CDP tab to `https://contoso.freshservice.com/a/admin/home`; it redirects to
   `contoso.myfreshworks.com/login`.
2. On the login SPA click **Sign in with magic link**, type `avery.operator@contoso.com`, click
   **Send me a magic link**. The inputs are in shadow DOM — traverse with a `TreeGarrity` that
   recurses `shadowRoot`, and click via `Input.dispatchMouseEvent` at the element's center rect.
3. Fetch the email with the Outlook MCP: search sender `freshworks`, newest, today; read the message
   body and extract the `contoso.myfreshworks.com/org/magiclink/<uuid>/login` URL. It is **single-use
   and ~15-min TTL**, so consume it immediately.
4. Navigate the same CDP tab to that URL, then to `/a/admin/home`. Confirm the session with an
   in-page fetch to `/api/_/bootstrap/me` (200 = logged in). The cookie now persists in the profile.

Once logged in, run authenticated requests as in-page `fetch(path,{credentials:'include'})` via
`c.eval`, adding `X-CSRF-Token` from `document.querySelector('meta[name=csrf-token]').content` for
writes. A reusable `fsfetch.mjs` wrapper that reads a `{method,path,body,form,headers,out}` spec and
runs it in the logged-in tab lives in `C:\temp\NodeJS\freshservice-architect\strategy-grants-build\`
(known-good working copy) — adapt as needed.

## Text-only update to a published catalog item (verified 2026-08-01)

Use the loaded catalog editor instead of reconstructing the item payload when only requester-facing
description text must change:

1. Read the item through `GET /api/v2/service_catalog/items/{display_id}` and record its exact name,
   `visibility`, requester-group ids, attachment setting, description, and custom-field count.
2. Open `/ws/{workspace_id}/catalog/items/{display_id}/edit` in the authenticated CDP session. Abort
   unless the name, published value (`#visibility == 2`), current description marker, and exact custom-
   field count match the baseline. This prevents a stale page or partial editor load from being saved.
3. Change only `#item_description` through its Redactor editor/textarea, then trigger
   `#save_and_publish`. Its built-in handler calls `setJsonData()` so the existing loaded custom fields
   are serialized and preserved. Do not rebuild fields for a text-only change.
4. Re-read the public API and verify the exact stored description, published state, requester-group
   ids, attachment setting, and field count. Treat the write as incomplete until that readback matches.

This is also the safe fallback when browser-extension navigation stalls but the authenticated CDP
session still answers `/api/_/bootstrap/me` with `200`.

## Where the working scripts live

The full set from the 2026-07-09 Strategy-Grants build (session login, catalog create/edit/delete,
agent conversion, readback) is in `C:\temp\NodeJS\freshservice-architect\strategy-grants-build\`
(numbered `NN-*.mjs`). The REST helper is `C:\temp\NodeJS\freshservice-architect\fs-api.mjs`
(Git Bash needs `MSYS_NO_PATHCONV=1` before an `/api/...` path arg). Treat these as known-good
examples, not the only copy — re-verify IDs against live state.
