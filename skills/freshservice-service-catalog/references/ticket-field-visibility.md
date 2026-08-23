# Ticket field portal visibility / Field Manager (verified 2026-07-31)

How to inspect and change whether a ticket field shows to requesters on the portal form. Verified on
the Contoso IT workspace (ws 2). Needs the authenticated agent session from `authenticated-session.md`.

## Property name mapping

The same flag has two names. Do not mix them up:

| Public REST v2 | Internal / Field Manager | UI checkbox |
| --- | --- | --- |
| `displayed_to_customers` | `visible_in_portal` | Displayed to requester |
| `customers_can_edit` | `editable_in_portal` | Requester can edit |
| `label_for_customers` | `label_in_portal` | Field Label (For Requesters) |

Unticking "Displayed to requester" in the UI cascades: it also clears `editable_in_portal` and greys
out the dependent sub-options.

## Reads

- `GET /api/v2/ticket_form_fields?workspace_id={n}` — public, reliable, use this to **verify** any
  change from an independent surface. Custom fields are workspace-scoped; the record's own
  `workspace_id` tells you the only workspace it can appear in.
- `GET /ws/{n}/ticket_fields` — what the Field Manager reads: an array of `{ticket_field:{...}}` in
  internal naming.
- `GET /api/_/ticket_fields` (no params — `workspace_id` is rejected as an invalid field) and
  `GET /api/_/ticket_form_fields?workspace_id={n}` also work.

## Writes are UI-only — the public API cannot do this

`PUT`/`PATCH` on `/api/v2/ticket_form_fields/{id}`, `/api/_/ticket_fields/{id}`, and
`/ws/{n}/ticket_fields/{id}` all return **404**; there is no `/api/v2/ticket_fields` collection at
all. Budget for driving the UI, or hand the user a manual step.

## Finding the editor (the React admin 404s here)

`/a/admin/home`, `/a/admin/ticket_fields`, and the hyphenated `/a/admin/*ticket-fields` routes all
resolve to a 404 inside the SPA on this tenant — a plain HTML fetch returns the 200 SPA shell, so
check the rendered title/body, not the HTTP status. The working chain is:

`/a/admin` → link `/ws/{n}/admin/home` → tile "Field Manager" → `/ws/{n}/admin/templates` →
link `/ws/{n}/admin/form_fields/ticket` (also `/problem`, `/change`, `/release`).

That page is the **classic jQuery form builder**: `form#ticketCustomFields` > `ul#custom_ticket_form`
> one `li.custom-field[data-id="{field_id}"]` per field, each with `.control-label`, an
`.overlay-field` click shim, and hover controls `.edit-field` / `.archive-field` / `.delete-field`.
A field hidden from the portal renders a `span.private-symbol` in its row — a quick visual check.

## Save mechanics

The page saves the whole form via `POST /ws/{n}/ticket_fields`, form-encoded, with `_method=put`,
`authenticity_token`, and `jsonData` — plus `reorderlist`, `jsonSectionData`, `cmdbJsonData`,
`assetAssociationConfig`, `public_attachment_json_data`.

Two traps:

- `jsonData` carries **only the fields the page considers dirty** (a no-op save still posts the
  `default_workspace` field, so seeing one entry does not mean it worked). The dirty flag is set by
  the properties dialog's **Done** button, not by mutating the model.
- **A hand-built `jsonData` is silently ignored.** Replaying the POST with a correctly-shaped entry
  returns `200` and an HTML page while changing nothing. Don't burn time on it; verify against
  `/api/v2/ticket_form_fields` before believing any write.

Synthetic CDP mouse clicks do not fire the classic page's Save either. Use
`jQuery('.save-custom-form').trigger('click')`.

## Driving it, and where it breaks

Per field: click the row to open "Properties : <label>", untick **Displayed to requester**, click
**Done** (the modal footer button — *not* the page-level Cancel/Save pair, which sits behind the
overlay at the top and will swallow the click), then save the form via jQuery as above.

Known failure: a row whose preview widget is a **checkbox** opens its dialog on a row click, but a
**text** field's row did not open under automation — row click, `.control-label`, `.overlay-field`,
and `.edit-field` (with hover, real mouse events, and jQuery `trigger`) all only toggled the row's
`active` class. Hand that field to the user as a 4-click manual step rather than forcing it.

Two more gotchas:

- A leftover `.modal-backdrop` from a previous dialog swallows every later click while the dialog
  itself reads as closed. Check `document.querySelectorAll('.modal-backdrop').length` and reload.
- **Never call the row widget's `setProperties()` unless its dialog was actually opened.** It reads
  values out of `dialogDOMMap`, so on an unopened dialog it writes `undefined` over `label`,
  `label_in_portal`, `required_in_portal`, and the visibility flags. Read
  `jQuery(li).data('customfield').settings.currentData` (or `getProperties()`) before and after, diff
  the two, and abort without saving if anything outside the flags you intended moved.

## Deleting vs hiding

Deleting a custom ticket field destroys its stored values on every historical ticket and cannot be
undone. Hiding it from the portal keeps field and history and is reversible, so offer hide first and
treat delete as a separate, explicitly-approved step. Archiving (`.archive-field`) is the third
option: it removes the field from the form while retaining data.
