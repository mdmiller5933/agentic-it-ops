# Building a service catalog item + the custom-field limitation

Verified 2026-07-09 on `contoso.freshservice.com` workspace 8 (`Strategy  - Grants`). Requires the
authenticated session from `authenticated-session.md`.

## Classic designer facts

- Create/list/edit URLs: `/ws/{wsId}/catalog/items` (list), `/ws/{wsId}/catalog/items/new`
  (designer), `/ws/{wsId}/catalog/items/{display_id}/edit`. The React admin has **no** catalog
  route (`/a/admin/service_catalog*` → 404); the classic `/ws/{n}/catalog/*` UI is the live one.
- The designer form is `form#catalogItem`, action `POST /ws/{wsId}/catalog/items` (Rails,
  form-encoded / multipart). Save controls: `#save_as_draft` (visibility 1) and `#save_and_publish`
  (visibility 2); both run `setJsonData(); jQuery('#catalogItem').submit()`.
- Hidden `catalog_item[requested_for]` (id `#catalog_item_requested_for_field`) must hold JSON like
  `{"conditions":"[]","data_source":"5","override_config":true}` — an empty value can 500 the save.
  Recheck and repopulate it before **every edit save**, not only shell creation: the workspace 2
  editor rendered it empty again, and field saves either dropped the new fields or returned 500.
- Description is a redactor rich-text field and is **required** by jQuery-validate. Set it with
  `jQuery('#item_description').redactor('code.set', html)` and also set the `.redactor_editor` div +
  the `#item_description` textarea. Skipping this → validation blocks the genuine submit, and a
  forced native submit with empty description → **500**.

## Working item-shell create (persists)

Fill name, category (`select2('val', catId).trigger('change')` + set the hidden `category_id`),
short_description, description (via redactor), then click `#save_as_draft`. Server returns 200 and
redirects to the list; the item exists as a draft. Read it back with
`GET /api/v2/service_catalog/items/{display_id}` (single GET uses **display_id**).

## Custom fields — use handleFieldClick (verified 2026-08-06)

Bare injection into `#field_values` / `li.custom-field` still silently drops on save (200 / 0
fields). Synthetic palette drag is unreliable. REST field create remains 405.

**Working path:** on the classic designer page, for each field:

```js
const scf = window.serviceCatalogGenericCustomFields;
scf.handleFieldClick(scf, { type: 'text', fieldType: 'custom_text' });
// set input[name="customlabel"], #agentrequired, choices via scf.dropAddChoices('…')
document.querySelector('#Commitfieldtype').click();
// after all fields:
document.querySelector('#catalog_item_requested_for_field').value =
  '{"conditions":"[]","data_source":"5","override_config":true}';
document.querySelector('#save_as_draft').click();
```

Verified: ws5 item **144** kept all 23 fields after draft save. Do not ask the user to build
fields by hand when an authenticated agent browser session is available.

Dropdowns ship with a default **First Choice** row. The reliable workspace 2 path was to commit the
new dropdown, reopen its new `li.custom-field`, trigger `i.deleteChoice` on the `span.dropchoice`
whose input value is `First Choice`, and commit again. Readback then excluded the placeholder.
A pre-commit native click left it intact. Do **not** call `deleteField` casually — a bad delete path
previously soft-removed the whole item.

Date-only fields: call `handleFieldClick` with `type: 'date'` and
`fieldType: 'custom_date_time'`; with the default date-only option, REST readback normalizes it to
`field_type: 'custom_date'`. Calling the builder with `custom_date` returned 500 on workspace 2.

Email-shaped fields: `text`/`custom_email` returned 500 during workspace 2 field creation on
2026-08-06, while the same labels persisted as `custom_text`. Until the email type is re-verified
in isolation, use a clearly labeled work-email text field and validate the Contoso domain downstream.
For a large mixed-type form, save and REST-verify small batches while establishing new type
mappings; do not wait until the whole form is staged to discover one invalid field type.

## Field-spec format (for manual entry or a future working path)

Each field: palette type, custom type code, label, required, and dropdown choices. Custom type map:
text=1001, email=1012, paragraph=1008, dropdown=1003, checkbox=1006, date=1018, attachment=1014,
number=1004, decimal=1010, url=1009.

### Publication Review Request (ws8 draft, display_id 139 as of 2026-07-09)

Required: Requester name (text), Requester email (email), Requester organization (text), Contoso point
of contact (text), Working title of publication (text), Publication type (dropdown: Journal article
/ Conference paper or abstract / Poster / Presentation / Thesis or dissertation / Press release or
blog / Other), Target venue (text), External submission deadline (date), Requested review-by date
(date), Full author list with affiliations (paragraph), Associated project name (text), Includes
Contoso data/results/images/site details? (dropdown Yes/No), Discloses non-public method/design/tool/
result? (dropdown Yes/No), Publicly disclosed or submitted elsewhere already? (dropdown Yes/No),
Funding acknowledgment confirmed (checkbox). Conditional (paragraph, optional): describe included
Contoso data; describe non-public method; describe prior disclosure. Optional: Abstract or short
summary (paragraph), Specific sections where Contoso should focus (paragraph), Suggested Contoso
reviewers (paragraph), Attachment upload (attachment).

### Data Access Request (ws8 draft, display_id 140 as of 2026-07-09)

Required: Requester name (text), Requester email (email), Requester organization (text), Contoso point
of contact or project sponsor (text), Associated agreement (dropdown: CRADA / NDA / Subaward / DOE
award number), Data requested (paragraph), Scope: wells, site, and date range (paragraph), Purpose
and intended use (paragraph), Named individuals who will access the data (paragraph), Any team
members are foreign nationals? (dropdown Yes/No), Access duration needed or project end date (text),
Confidentiality acknowledgment (checkbox), Needed-by date (date), Urgency (dropdown: Standard /
Expedited / Critical - deadline-driven), Commitment to return or delete data at project end
(checkbox). Conditional (attachment, optional): if foreign national, attach CV; attach scope of
work. Optional: Preferred file format (text), Preferred delivery method (text), Storage location and
security controls (paragraph), Supporting attachments (attachment).

The machine-readable spec arrays are `specs.mjs` in
`C:\temp\NodeJS\freshservice-architect\strategy-grants-build\` (known-good example).

## Pilot audience and live-submission gotchas (verified 2026-07-31)

- Create a manual requester group with only `{name, description}`. This tenant rejects a supplied
  `type` field. Add a member with
  `POST /api/v2/requester_groups/{group_id}/members/{requester_id}`, then GET the group members and
  prove the intended pilot identity is the only member.
- A published, requester-group-restricted item reads back with `visibility: 2` and
  `group_visibility: 2`, but the public item response does not identify the selected requester
  group. Verify the selected group in the classic designer and prove the intended member can open
  the item in an actual requester portal session.
- For `POST /api/v2/service_catalog/items/{display_id}/place_request`, omit `workspace_id` if the
  tenant rejects it; the catalog item selects its workspace. Do not use this API path as proof of a
  portal workflow: the Strategy - Grants test requests were recorded as Source=Phone and did not
  exercise the portal/create automations. Submit through the real requester portal and verify
  Source=Portal for a workflow pilot.
