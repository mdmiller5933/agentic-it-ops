---
name: freshservice-service-catalog
description: Build, fix, or draft Contoso Freshservice service catalog items, request forms, requester portals, categories, and Journeys (the employee onboarding/offboarding journey forms), manage external requester magic-link access, and convert requesters to agents, using an authenticated agent session for internal endpoints the public REST API cannot reach. Use when the user asks to "create a service catalog item", "build a Freshservice form", update "the offboarding journey form" / "term form" / "Employee Termination Form", add stakeholder or date fields to an offboarding task, "create a requester portal", test an "external magic link", "convert a requester to an agent", or draft/publish a service item or journey. For native Workflow Automator rules, approval-gate automations, or ticket routing use the freshservice-automation-builder skill.
---

# Freshservice Service Catalog Builder

Use with the it-operations skill for shared Contoso context. Tenant, workspace IDs, and the
API creds file are shared facts — see [[freshservice-instance-discovery-2026-07]] and
[[freshservice-rapid7-api-access]] in memory. Do not print API keys, cookies, CSRF tokens, or auth headers.

## Approval gate

Creating, editing, publishing, or deleting service catalog items, requester portals, requesters,
categories, or agents in Freshservice is production-impacting. Get Avery's explicit approval before any write, and keep
new items at **draft (visibility 1)** and workflows deactivated unless the user explicitly says to publish/activate.

## Requester portals and clean magic-link tests (verified 2026-08-01)

Freshservice treats **Deactivate Requester** and **Forget User** as materially different actions.
Deactivation is reversible, removes the requester from groups, and blocks portal login; it also
prevents that same email from receiving a new magic link or self-registering as a clean identity.
**Forget User** is irreversible personal-data erasure and may affect historical tickets or notes.
Never infer approval to forget a user from a request to remove, delete, reset, or retest the
requester: show the impact and get explicit action-time confirmation. Prefer a fresh external test
address when an exact-address reset is not required. After any temporary open-signup test, restore
and verify the intended restricted portal audience before ending the task.

Do not treat **Who can submit tickets = Everyone** as anonymous service-catalog access. It exposes
the portal's generic `/support/tickets/new` incident form, but an anonymous visit to
`/support/catalog/items/{display_id}` still redirects to login. Likewise, passwordless magic-link
login does not just-in-time enroll an unknown email: Freshworks may show a generic success message
without sending mail. A first-time catalog requester must self-register and activate, arrive through
an already-valid SSO identity, or be provisioned. Mapping the portal to **All users** and publishing
items to **All Requesters** removes manual Title/group administration but does not remove that login
requirement. If the requirement is zero account before submitting a service request, stop and get an
explicit architecture decision; satisfying it requires a different public intake plus a secure
server-side service-request creation path, not another portal audience setting. Roll back any
temporary `Everyone` setting if it only exposes an unintended public incident form.

### The server-side path, concretely: `place_request` (vendor docs read 2026-08-01)

`POST /api/v2/service_catalog/items/{display_id}/place_request` is the supported way to create a
**genuine** service request — `requested_items` populated, so every rule that conditions on
`requested_catalog_items` still fires and none of the hand-built form fields are lost.

- Attributes: `quantity`, `email` (requester), `requested_for` (requester on whose behalf),
  `custom_fields`, `child_items`, `workspace_id`. OAuth scope `freshservice.tickets.create`.
- Vendor Note 1: "The service requested will be created with the requester specified in `email`. If
  no email is provided, the request is created on behalf of the agent."
- Vendor Note 2: **"If a field is not visible in self service portal, you can still provide a value
  for that field using the api. If a field is marked mandatory but not visible in portal in service
  item, you must provide a value for it in the api."** So an external front end may collect a
  different/smaller field set than the portal shows.
- Attachments work: `Content-Type: multipart/form-data`, e.g.
  `-F 'custom_fields[attachment_test][]=@/path/file.pdf' -F 'email=...' -F 'quantity=1'`.
- Contrast: `POST /api/v2/tickets` documents `type` as **"[Support for only type 'incident' as of
  now]"** — the plain ticket API cannot produce a service request. Use `place_request`.
- Auto-provisioning is documented for ticket create ("If no contact exists with this email address
  in Freshservice, it will be added as a new contact") but is **not restated** on `place_request`.
  Treat "an unknown external email auto-creates the requester" as **unverified** until tested with a
  throwaway address — it is the single assumption a zero-account design rests on.
- This endpoint already works on this tenant with the admin REST key: ws8 tickets `30453`/`30456`
  were created through it (they carry the generated `Request for <name> : <item>` subject and a
  non-portal `source`).

## REST vs session — pick the right channel (verified 2026-07-09)

The `FRESHWORKS_*` REST key (HTTP Basic, base `https://contoso.freshservice.com/api/v2/`, helper
`fs-api.mjs`) is the first choice but is **read-only for catalog items**: `POST`/`DELETE
/api/v2/service_catalog/items` return **405**. REST **can** create categories and read everything.

Get that key from the Keeper record **"Freshservice API - avery.operator@contoso.com"**
(password field) via the retrieve-keeper-secret skill, exported as a process-scoped
`FRESHWORKS_API_KEY` and cleared afterwards. `C:\AI Workspace\env.local` is a legacy fallback that
any authenticated account on the box can read — never add or refresh a secret there.

What each channel can do:

- **REST v2 (reliable):** list/read items, read `service_catalog/items/{display_id}` (single GET uses
  **display_id**, not the internal id — internal id 404s), create categories
  (`POST /api/v2/service_catalog/categories` with `{name,description,workspace_id}`), and full
  requester/agent CRUD (see Agent conversion below).
- **Authenticated agent browser session (for classic writes):** creating/editing/deleting catalog
  items and their fields. Get the session with the CDP + Outlook magic-link method in
  `references/authenticated-session.md` (bundled `scripts/cdp.mjs` is the generic client). Once
  logged in, run authenticated `fetch()` in-page via CDP.

## Ticket fields on the portal form (Field Manager)

Ticket fields are a different surface from catalog item fields: they live in Field Manager at
`/ws/{wsId}/admin/form_fields/ticket` and appear on the portal's own "Submit a ticket" form. Public
REST is **read-only** for them (`GET /api/v2/ticket_form_fields?workspace_id=`; every write path
404s), and the flag called `displayed_to_customers` there is `visible_in_portal` internally. Before
hiding or deleting one, read `references/ticket-field-visibility.md` — it has the admin route chain,
the save mechanics, and the traps that silently no-op or blank a field's labels.

## Create a category (REST, works)

`POST /api/v2/service_catalog/categories` `{name, description, workspace_id}` → 200 with the new id.

## Create a service item shell (session)

Drive the classic designer at `/ws/{wsId}/catalog/items/new` (React admin has no catalog route;
`/a/admin/service_catalog*` 404s — the classic `/ws/{n}/catalog/*` UI is the real one). Fill
`catalog_item[name]`, set category via `jQuery('#item_category').select2('val', <catId>).trigger('change')`,
and **set the description through the redactor** — `jQuery('#item_description').redactor('code.set', html)`
plus set the `.redactor_editor` div and textarea. jQuery-validate blocks submit if description is
empty; a forced submit with empty description returns **500** (that 500 is a validation-bypass
symptom, not a server outage). Save as draft via the `#save_as_draft` control (sets visibility 1).
Full steps and pitfalls: `references/catalog-item-build.md`.

## Custom fields — working path (verified 2026-08-06 on ws5 item 10021)

Do **not** inject bare `li.custom-field` / `#field_values` JSON and save — that path still
silently drops fields (200 / 0 fields). REST create/update of fields is still 405.

**Working automation (agent browser session on the classic designer):**

1. Open `/ws/{wsId}/catalog/items/{display_id}/edit` (or `/new` after shell create).
2. For each field call
   `serviceCatalogGenericCustomFields.handleFieldClick(scf, { type, fieldType })`
   where `type`/`fieldType` match palette attrs (e.g. `text`/`custom_text`,
   `dropdown`/`custom_dropdown`, `dropdown`/`custom_multi_select_dropdown`,
   `date`/`custom_date_time`, `attachment`/`custom_attachment`,
   `paragraph`/`custom_paragraph`, `decimal`/`custom_decimal`).
3. Fill `input[name="customlabel"]`, set `#agentrequired` for a mandatory field, add choices via
   `scf.dropAddChoices(choice)` / `#addchoice` sibling input, then click `#Commitfieldtype`.
   For a dropdown, commit it, reopen the new `li.custom-field`, trigger its `i.deleteChoice` for
   the default `First Choice`, and commit again; a pre-commit native click did not mark the choice
   for deletion. For date-only fields use `date`/`custom_date_time`; the API normalizes the saved
   field to `custom_date`. On workspace 2, `text`/`custom_email` returned 500 during create, while
   a clearly labeled `custom_text` work-email field persisted; re-test email type in isolation
   before depending on it.
4. Before **every** edit save, repopulate `#catalog_item_requested_for_field` with valid Requested-for
   JSON if the editor rendered it empty. Then use `#save_as_draft` (or publish only with explicit
   approval) and read back with
   `GET /api/v2/service_catalog/items/{display_id}` — field count must match.

Proven on item **144** (Purchase Requisition Form): 23/23 fields persisted. Older injection
attempts and synthetic palette drag remain unreliable; use `handleFieldClick` + Commit. For a
large mixed-type form, save and verify small batches while proving each field-type mapping; this
made a bad mapping fail locally instead of losing the whole staged form.

## Delete a service item (session)

`DELETE /ws/{wsId}/catalog/items/{display_id}` with header `Accept: text/javascript` (Rails UJS).
`application/json` → 406, internal id → 404.

## Convert a requester to an agent (REST, works)

Two calls: `PUT /api/v2/requesters/{id}/convert_to_agent` **with `Content-Type: application/json`
and an empty JSON body `{}`** (omitting the body → 415), then
`PUT /api/v2/agents/{id}` with `{occasional:true, workspace_ids:[wsId], member_of:[groupId],
roles:[{role_id, assignment_scope:"member_groups", workspace_id:wsId}]}`. Choose `occasional:true`
or `occasional:false` from the requested operating model; do not assume an occasional license is
adequate for a recurring reviewer or approver. Before a bulk conversion, verify both the full-time
seat count on **Agents** and the balance on **Day Passes**. For an existing agent license-only
change, send only `{occasional:false}` (or `true`) to minimize scope drift, then read back with
`GET /api/v2/agents/{id}` and confirm workspace, group, and role assignments stayed unchanged.
Business Agent role = 34000151560.

Verified 2026-07-31: REST can return a false maximum-seat validation during a bulk occasional-to-
full-time conversion even while the authenticated Agents editor still shows full-time seats
available. Stop and audit the touched batch. If the editor still offers **Full - Time** and shows
available seats, complete only the blocked account there, then verify the agent through REST and
re-check the Agents counters. Do not free a seat by changing an unrelated agent without separate
approval.

## "Can agent X open this admin page?" — check the privilege, not the role name (verified 2026-08-12)

Role names lie about scope. Answer it with data:

1. **`GET /api/v2/roles/{role_id}` returns a full `privileges[]` array** plus `role_type`
   (`1` = admin role, `2` = agent role). The catalog editor needs `view_admin` +
   `edit_service_catalog`. Confirmed on this tenant: **IT Agent (73 privileges) and IT Supervisor
   (154) have neither**; Workspace Admin (107) and Account Admin (132) have both.
2. **Roles are scoped per workspace and `workspace_id: 1` does NOT cascade.** Proof from
   `/api/_/bootstrap/me` (authenticated session) → `agent.privileged_workspaces`, a
   privilege → `[workspace ids]` map that Freshservice computes itself: Avery holds **Account
   Admin@ws1** — the strongest role in the tenant — and `edit_service_catalog` still resolves to
   `[1, 8, 5, 9]`, **excluding ws2**, where his only role is IT Agent. So admin rights in workspace N
   come strictly from an admin role assigned at workspace N. A ws1 assignment is its own scope, not a
   wildcard. `agent.scoped_privileges` is the same data keyed by workspace id.
3. Only `bootstrap/me` reports the *logged-in* user. For someone else, read their
   `roles[]` from `/api/v2/agents/{id}` and intersect each `role_id`'s `privileges[]` with the
   workspace you care about. Do **not** reach for the `assume_agent_identity` privilege to test a
   colleague's access — impersonation is production-impacting and needs explicit approval.

Worked example: Leif Stallworth (`34001311451`) holds IT Agent@ws5 + IT Supervisor@ws5 +
Workspace Admin@**ws1**, so she has no `view_admin`/`edit_service_catalog` in ws5 and cannot open
`/ws/5/catalog/items/144/edit`. Her ws5 peers who can (Devon Ollivant, Orion Montrose) carry
Workspace Admin explicitly **@ws5**.

Ten agents on this tenant hold Workspace Admin@ws1 with no per-workspace admin — worth a separate
permissions-hygiene review, since that role carries `manage_agents`, `delete_agent`,
`assume_agent_identity`, and `manage_credentials` at the global scope.

## Restricted groups: 403 that no role can fix (verified 2026-08-01)

If an agent gets `403 access_denied` on a ticket in a workspace they clearly have rights to, check the
group before touching roles. `GET /api/v2/groups?workspace_id={n}` → `"restricted": true` means
**only `members` and `observers` can see that group's tickets, and it overrides role scope entirely** —
Avery holds Account Admin plus `assignment_scope:"entire_helpdesk"` on ws8 and was still 403 on every
ticket in `Publication Review` (`34000173261`, restricted, 10 members).

Grant view-only access with **`observers`**, not `members`:

```text
PUT /api/v2/groups/{group_id}   {"observers":[<agent_id>]}
```

An observer can read the group's tickets but cannot be assigned them, does not join the reviewer
roster, and does not enter escalation. A member would. Verified: the PUT left `members` (10) and
`leaders` untouched, and five previously-403 tickets returned `200` immediately after. Snapshot the
group first and diff `members`/`leaders` on readback anyway. Do **not** flip `restricted` to false to
solve one person's access — that exposes the queue to every agent in the workspace.

## Approvers do not need agent licenses (verified 2026-08-05)

Freshservice service-request approvals can target requesters as well as agents. The current
approval framework describes approvers as users, agents, requesters, Change Advisory Boards, and
owners of impacted services. Do not convert a requester or business owner to an agent merely so
they can approve a service request.

Prefer the person's existing Freshservice requester identity and enable email approvals when the
approver should act without entering the agent portal. Requesters can receive approval notifications
and use the requester approval page; email recipients can approve or reject by email even when they
cannot sign into the linked portal.

Agent licensing is relevant only when the person needs agent capabilities. Occasional-agent access
to the agent portal consumes a day pass, and business-agent access to IT-workspace service requests
is limited; neither license should be assigned solely for approval.

For an outside or wholly unprovisioned email address, verify in the current tenant that the chosen
manual or workflow approver source resolves the recipient before activation. Test the approval path
with a draft service request and verify delivery and recorded approval status. Freshservice writes,
workflow activation, and production tests still require explicit approval.

## Journeys — the offboarding "term form" (verified 2026-08-20)

Contoso's employee termination process is the **Journeys** module (Admin > Global Settings >
Journeys, route `/b/admin/journey-configs`), NOT a catalog item and NOT the legacy
`employee_offboarding` module (its `/api/v2/offboarding_requests` API answers "no active actors").
The live journey is **"Employee Termination Form"** (HR Team initiates; stakeholder-picker fields
on the initiator form spawn per-person date-confirmation TASK forms on the "Last working day"
phase — that task email is what People Ops calls "the blast"). Editing a published journey creates
a disposable draft; nothing changes until the draft is republished, and publish takes ~1 minute.

All build/edit calls are session-authenticated in-page `fetch` against `/api/_/journeys/...` with
`X-CSRF-Token` — no JWT needed from page context, and no drag-and-drop required (the palette can't
even create employee 501 fields; the API can). Full endpoint map, payload shapes, the
CREATE-field semantics, and the draft phase-ref gotcha are in `references/journeys.md` inside
this skill's folder. Publishing a journey is production-impacting: explicit approval first.
