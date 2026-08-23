# Power Apps canvas studio — Contoso safe workflow

Verified 2026-08-09.

Use this for Contoso Power Apps canvas work, especially the SharePoint-backed ITAM pilot. Read the newest `POWER-APPS-ITAM-*-LIVE-RECEIPT.md` in `C:\temp\NodeJS\stock-list` before resuming; `POWER-APPS-ITAM-V2-LIVE-RECEIPT.md` is the known-good example as of the verification date.

## Safety boundary

- Treat **Save**, **Publish**, and **Share** as separate actions. Saving an explicitly requested unpublished pilot does not authorize publishing or sharing it.
- Default to browse-only formulas. Do not add `Patch`, `SubmitForm`, `Remove`, flow `.Run`, mail, notification, Intune, MAA, Rapid7, or external-launch actions unless the user explicitly authorizes that exact behavior.
- Confirm the environment, app ID, and every SharePoint list GUID before editing. A connector URL can point at a different list even when the display title looks right.
- Never treat hidden controls, form formatting, or app navigation as an authorization boundary. Production writes require governed roles and a server-side command processor.

## Build pattern

1. Keep a local source contract and a standalone child-control paste artifact. Validate unique control names, supported schemas, screen references, formula targets, and forbidden write tokens before opening Studio.
2. Paste child controls only into the exact intended screen. Keep the prior screen as rollback until the replacement compiles and previews.
3. Put connector reads, `ClearCollect`, and global `Set` initialization in `App.OnStart`. Keep screen-local navigation/filter defaults in one `UpdateContext` in `Screen.OnVisible`. Do not define the same name globally and locally; local context shadows the global value and can leave galleries blank.
4. The Studio formula bar displays the leading equals sign separately. When replacing a formula through the Monaco editor, paste the formula body **without** an extra leading `=`.
5. After changing initialization, run `App.OnStart`. Studio preview can retain stale context on the already-visible screen; run or retrigger `OnVisible`, or explicitly exercise the default filter buttons during validation.

## Validation gate

- Preview wide desktop and a restored compact browser width below the app breakpoint. Verify wrapping, scrolling, navigation, search/filter behavior, drill-down, and back behavior.
- Exercise every workspace and any status-specific visual states with known live read-only records.
- Rerun App Checker. Confirm the formula bar says `No formula errors present`, then open the Formula group and distinguish **Warnings** from **Errors**. Record Accessibility and Performance counts separately.
- Save only after preview and checker pass. Reread the Studio document name and save timestamp and require `Saved (Unpublished)` when publication was not authorized.
- Write a live receipt containing exact source scope, observed values, checker counts, screenshots, limitations, and an explicit statement that Publish and Share were not invoked.

## Windows recovery

Use the authenticated Work Edge window for the maker portal. Prefer normal browser control. If the Power Apps tab is already claimed by another session or Windows control reports `node_repl exec context not found`, stop repeated input attempts and use a fresh runtime/read-only discovery first.

On this workstation, direct process launches can fail with Windows error 1223. A reliable fallback is to launch `cmd.exe` and have it run PowerShell with a UTF-16LE `-EncodedCommand`. For UI Automation:

- Match the single window whose title contains both `Power Apps Studio` and the exact app name.
- Enumerate elements before invoking anything; prefer stable `AutomationId` values such as `commandBar_preview`, `preview-edit-button`, `commandBar_appChecker`, and `commandBar_save`.
- Never invoke `commandBar_publish`, `preview-publish-button`, or `commandBar_share` without explicit user approval.
- Use UI Automation patterns first. If a coordinate click is unavoidable, capture current window state, use one exact bounded click, verify the resulting state, and stop if it differs from expectation.
- For responsive testing, record the window bounds, restore and resize the exact Edge window, capture the compact state, then maximize it again.

Do not report the workflow complete from local/static tests alone. The final claim requires a live preview, a fresh App Checker result, and a verified unpublished save state.
