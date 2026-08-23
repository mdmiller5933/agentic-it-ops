# Freshservice Workflow Automator Reference

## Scope

Use this reference for Contoso Freshservice native Workflow Automator work. It captures implementation details learned while building the active Dorian security approval workflow on 2026-06-30.

Do not output credentials, API keys, cookies, CSRF tokens, or bearer/basic auth values.

## Confirmed Tenant Details

- Tenant: `https://contoso.freshservice.com`
- IT workspace ID: `2`
- EUC Monitoring Team group ID: `34000153387`
- GRC - Security group ID: `34000172540`
- Security - Engineering/Ops group ID: `34000174495`
- Dorian Prescott agent ID: `34002240315`
- Avery Operator agent ID observed in UI/API snippets: `34002018724`
- Active workflow from this work: `34000381035`, `EUC Security Review Approval Gate - Native Approval`

## Important API Boundary

Freshservice public v2 API exposes tickets, approvals, groups, fields, and activities, but not Workflow Automator definitions. These public endpoints returned 404 for workflow definitions during discovery:

- `/api/v2/automations`
- `/api/v2/workflows`
- `/api/v2/workflow_automators`
- `/api/v2/workflow_automations`
- `/api/v2/admin/workflows`
- `/api/v2/admin/automations`

Use the authenticated admin UI/session and internal UI endpoints for native Workflow Automator build/edit work.

## Admin UI Paths

- Workflow Automator list: `/ws/2/admin/automators`
- Ticket Workflow detail JSON/HTML: `/ws/2/admin/ticket_automators/{workflow_id}`
- Edit page: `/ws/2/admin/ticket_automators/{workflow_id}/edit`
- Store data: `/ws/2/admin/ticket_automators/{workflow_id}/store_data`
- Node info: `/ws/2/admin/ticket_automators/{workflow_id}/node_info?stage_id={stage_id}&wf_node={wf_node}`
- Clone workflow: `POST /ws/2/admin/ticket_automators/{workflow_id}/clone_workflow`
- Save event: `PUT /ws/2/admin/ticket_automators/{workflow_id}/event`
- Save normal node: `PUT /ws/2/admin/ticket_automators/{workflow_id}/node`
- Save special node: `PUT /ws/2/admin/ticket_automators/{workflow_id}/create_special_node`
- Publish draft: `PUT /ws/2/admin/ticket_automators/{workflow_id}/publish`
- Soft delete through private API: `PUT /api/_/automation/ws/2/module/1/workflows/{workflow_id}` with `{deleted:true, token}`

Most UI save endpoints expect Rails-style form encoding, not JSON. The private workflow API expects JSON.

## Reading rules: send `Accept: application/json` or you get HTML (verified 2026-08-01)

`GET /ws/{ws}/admin/automators` (and `/ticket_automators`, `/ticket_automators/{id}`, `node_info`)
content-negotiates. Without an explicit `Accept: application/json` the authenticated session gets the
**HTML admin page**, `JSON.parse` fails, and a parser silently yields **zero rules** on a `200` — which
reads as "this workspace has no automations". Always send the header, and treat an empty rule list on a
200 as a bug in your call, not a fact about the tenant. `/api/_/automation/ws/{ws}/module/1/workflows`
returns the same set as clean JSON and is a good cross-check.

The list shape is nested arrays: `[[{wf_base:{…}}, null], …]` → `j.flat().filter(Boolean).map(x=>x.wf_base)`.

## Approval action enums, decoded (verified 2026-08-01)

Read straight out of the workflow `/edit` page's action metadata — do not guess these:

```json
"approval_types":     [["Everyone",1],["Any one",2],["Majority",3],["First Responder",4]],
"proceed_when_types": {"1":"everyone","2":"anyone","3":"majority","4":"first_responder","5":"ticket_approval_status"},
"chain_rules":        {"1":"everyone","2":"anyone","3":"majority","4":"first_responder"}
```

So a "both people must approve" gate is `approval_type: 1` + `proceed_when: 1` + `approval_chain_rule: 1`.
`proceed_when: 5` is a different thing entirely — proceed on the ticket's overall approval status, which
is what the single-approver EUC gate uses. To confirm a live gate's semantics, fetch
`/ws/{ws}/admin/ticket_automators/{id}/edit` and grep `proceed_when_types`.

## Does an approval workflow have outcome branches? Check `target` (verified 2026-08-01)

An approval ACTION node that **branches** looks like this in the graph
(`GET /ws/{ws}/admin/ticket_automators/{id}`):

```json
{"block_type":"ACTION","type":"approval","wf_node":40001,
 "target":{"0":"C2R2","1":"C3R1"},"hidden_stage_id":2}
```

plus a hidden `{"block_type":"EVENT","label":"Approval","wf_node":2,"stage_id":2,"visible":0}` and one
ACTION per outcome (`40002` rejected, `40003` approved). ws2's stock `Approval for requested items`
(`34000310629`) is the reference shape.

An approval node with **`"target": null` and no `hidden_stage_id` is terminal** — approve or reject and
the workflow does nothing. Probing the stage-2 node ids returns **500**, not 404, when they don't exist.
Strategy-Grants gate `34000382847` is built this way, so its approval outcome is visible on the ticket's
`approval_status` but is never announced. Cloning a stock approval workflow (rather than adding an
approval action to a plain rule) is what gets you the branches for free.

## Action payload keys you cannot guess (verified 2026-08-01)

The serializer special-cases only `add_task`, `add_note`, `add_fr_project`, `Integrations::RuleActionHandler`
and `send_approval_mail`. Everything else keeps whatever property its **form template** emits, so the key
comes from the JST template, not from a convention. Two that cost real time:

| Action | Correct payload | Wrong guesses that still return `200` |
| --- | --- | --- |
| `set_description` | `{"name":"set_description","description":"<p>…</p>"}` | `value` (persists, executes, writes **empty**); `body_html_set_description0` + `identity` |
| `add_tag` | `{"name":"add_tag","value":"my-tag"}` | — (this one is the simple shape) |

`set_description` is the nastiest failure mode in the tool after the `any`/`does_not_include` trap: a wrong
key **saves, reads back intact, executes, and logs "Modified Description" in ticket activities** while
storing an empty string. Persistence and an activity line are not evidence.

To find any action's real key, pull the JST out of the workflow bundle rather than guessing:

```js
// grep the bundle referenced by the /edit page for: this.JST["workflow/templates/forms/<domtype>"]
// e.g. forms/description -> var description = data.description; <textarea name="description">
```

Look up the action's `domtype` in the `/edit` page metadata first (`set_description` is `domtype:"description"`),
then read that template. Placeholders available to these bodies are `{{ticket.*}}` only — there are **no
catalog-item custom-field placeholders**, so a description built from an item's own fields is not possible.

## Editing an ACTIVE rule: `/publish` is not enough (verified 2026-08-01)

`PUT …/node` then `PUT …/publish` both return `200`, the readback is correct, **and the live rule keeps
running its previous graph**. Confirmed by two functional tests where routing (a pre-existing action) fired
and the newly added actions did not. The graph only reloads on a status cycle:

```text
PUT /api/_/automation/ws/{ws}/module/1/workflows/{id}   {"status":2,"token":…}   // deactivate
PUT /api/_/automation/ws/{ws}/module/1/workflows/{id}   {"status":1,"token":…}   // reactivate
```

Then **wait ~20-30s before testing.** A ticket created 8 seconds after reactivation missed the rule entirely
(no `Ticket Workflow` activity at all) while its sibling, reactivated 14 seconds earlier, fired correctly.
A "the rule didn't fire" result inside that window is a propagation artefact, not a broken rule.

Reading tags back needs `GET /api/v2/tickets/{id}?include=tags` — plain GET omits `tags` entirely and a
naive check reports a working `add_tag` as missing.

## PRE-FLIGHT: check the notification layer before the first test ticket

A rule's `send_email_to_agent` action is **not** the whole recipient list. Workspace-level agent
notifications fire underneath it, and `Ticket assigned to Group` is **ON by default**, which mails every
member of the receiving group on every routed ticket.

Cost of skipping this on 2026-08-02: 10 test tickets routed into a restricted 10-member group produced
roughly **110 emails**, about 10 each to two executives, when the rule definition named only one recipient.
Reading the rule and reasoning from it was not enough.

Before the first test submission in any workspace:

1. Open `/ws/{ws}/admin/email_notifications` and read the **Agent Notification** toggles in the rendered
   DOM (the raw HTML does not carry the on/off state). Note `Ticket assigned to Group`,
   `Ticket assigned to Agent`, `New ticket created`, `Note added to Ticket`, `Ticket unattended in Group`.
2. Multiply: routed test tickets x group members, plus each rule's own explicit recipients.
3. If that number is not acceptable, **deactivate the intake rules for the duration of the test** so
   tickets never reach the group, then reactivate and re-verify. Recipients drop to zero.

State the expected email volume to the user before running the test, not after.

## Rehearsing an approval gate without emailing the real approvers (verified 2026-08-01)

To validate a gate whose approvers are executives you do not want to spam, **do not edit the live rule**.
Clone it and repoint the clone:

1. Refuse to start unless the queue is empty (`status < 4` count is 0) — otherwise deactivating the live
   gate could strand a real request.
2. Snapshot the live gate's condition and action node data to a file.
3. Deactivate the live gate (status 2) so it cannot double-fire on the test ticket.
4. `clone_workflow`, then save its approval action with `group[0].value` / `init_data` / `group_name`
   repointed to yourself. Activate the clone; wait ~30s.
5. Drive the trigger — for a "ready for review" gate, `PUT /api/v2/tickets/{id}` setting the agent-only
   checkbox custom field to `true`.
6. Assert on `GET /api/v2/tickets/{id}/approvals` and the ticket's `approval_status`.
7. Delete the clone, reactivate the live gate, and **diff the restored condition and action JSON against
   the snapshot** before declaring done.

Result on the Strategy-Grants gate: the approval was raised on the checkbox tick, and recording the
decision moved `approval_status` 0 Requested → 1 Approved. Restored gate verified byte-identical with
approvers Ives Delacroix + Ives Langford and `proceed_when/approval_type/approval_chain_rule` all `1`.

**The `approval_status is 4 (Not Requested)` guard is fine on a Request-type ticket.** The ws2 incident
where that guard blocked the initial approval does not generalise: in ws8 a freshly created catalog
request exposes `approval_status: "not_requested"` from the moment of creation, so the guard matches and
still gives idempotency. Test per workspace rather than assuming either way.

## Approval outcomes: only the approval node's own branches work (verified 2026-08-01)

**An approval decision does not raise a ticket-update event.** Tested end to end: created an approval,
recorded an Approved decision, `approval_status` went to `1 / Approved`, and an ACTIVE rule with
`ticket_action:update` + `approval_status is 1` produced **no activity whatsoever**. Do not try to catch
approval outcomes with an update-triggered rule; it silently never fires.

Nor can the branches be added over the API. On a clone of the gate, all of these returned **500**:
`PUT …/create_special_node` for the hidden `wf_node:2 / stage_id:2` Approval event, and `PUT …/node` for
stage-2 outcome actions `40002`/`40003`. Declaring `next_node:{id:2}` on the approval action saves `200`
but leaves `target:null`. The hidden approval stage appears to be creatable only through the canvas UI, so
**build approval gates by cloning a workflow that already branches** (ws2 `34000310629`) — retrofitting one
is not available through these endpoints.

Useful for testing an approval flow without involving the real approvers:
`POST /api/v2/tickets/{id}/approvals` `{"approver_id":<id>,"approval_type":1}` (both fields required), then
record the decision with `PUT /api/_/tickets/{id}/approvals/{approval_id}` `{"approval_status":1,"remark":"…"}`.
Both refuse to act on a resolved/closed ticket.

## SLA policies: creatable per workspace, but not headlessly (verified 2026-08-01)

`/ws/{ws}/admin/sla_policies/new` exists and posts to `/ws/{ws}/admin/sla_policies` with
`helpdesk_sla_policy[name|description|conditions]`, `match_type`, and `SlaDetails[i][priority|response_time|
resolution_time|override_bhrs|escalation_enabled]` (times in **seconds** in the hidden inputs;
`override_bhrs:"true"` = calendar hours). Two gotchas: **a non-default policy requires at least one
condition** ("Please choose at least one condition"), and that condition JSON is produced by a React filter
widget — a direct POST returns **500** for every hand-built format tried (filter-array, workflow-style
`{all:[…]}`, hash, flat, namespaced). Note also that `escalation_enabled` is **checked by default** on the
new-policy form, so a naive create introduces escalation email the tenant does not currently use. Treat SLA
policy creation as a UI task.

## Save Token Rule

The workflow edit page exposes:

```js
var workflow_token = '...';
```

Every save includes `token`. Freshservice rotates the token after successful saves. If a save returns "Automator is out of sync. Please refresh the page", refresh/reload the edit page or use the token from the previous successful save response, then retry one node at a time.

After saving node changes, publish the workflow. The edit/node_info surfaces can show the newly saved draft while the active automation still runs the previous published version.

## Useful Existing Workflow Shapes

`SOC Ticket to SEC ENGINEERING`, ID `34000380977`, is a simple event -> condition -> action example.

`Approval for requested items`, ID `34000310629`, is a useful native approval-stage template:

- event `wf_node: 1`
- approval action `wf_node: 40001`
- hidden approval event `wf_node: 2`
- rejected branch `wf_node: 40002`, condition `2`
- approved branch `wf_node: 40003`, condition `1`

Prefer cloning an approval workflow when building an approval gate because the hidden approval stage and branch wiring are already valid.

## Event Payloads

Create/update event node payload shape:

```json
{
  "label": "Ticket is updated",
  "wf_node": 1,
  "c": 1,
  "r": 1,
  "token": "<workflow_token>",
  "data": "{\"performer\":{\"type\":\"3\"},\"events\":[{\"name\":\"ticket_action\",\"value\":\"update\"}]}"
}
```

For Incident-only rules, event data may include both:

```json
[
  {"name":"ticket_action","value":"update"},
  {"name":"incident","value":"update"}
]
```

For rules that must include both Incidents and Service Requests, use `ticket_action:update` and put ticket type in the condition.

## Condition Payloads

Condition node payload shape:

```json
{
  "label": "Security ticket is with Dorian and needs approval",
  "wf_node": 20001,
  "c": 2,
  "r": 1,
  "token": "<workflow_token>",
  "stage_id": 1,
  "prev_node": {"id": 1},
  "next_node": {"id": 40001, "condition": 1},
  "data": "{\"all\":[...]}"
}
```

Useful condition clauses:

```json
[
  {
    "evaluate_on": "ticket",
    "name": "ticket_type",
    "parent_value": "",
    "multilevel_key": "Ticket Fields",
    "multilevel_label": "Ticket Fields.Type",
    "operator": "includes",
    "value": ["Incident", "Service Request"]
  },
  {
    "evaluate_on": "ticket",
    "name": "group_id",
    "parent_value": "",
    "multilevel_key": "Ticket Fields",
    "multilevel_label": "Ticket Fields.Group",
    "operator": "is",
    "value": 34000172540
  },
  {
    "evaluate_on": "ticket",
    "name": "responder_id",
    "parent_value": "",
    "multilevel_key": "Ticket Fields",
    "multilevel_label": "Ticket Fields.Agent",
    "operator": "is",
    "value": 34002240315
  },
  {
    "evaluate_on": "ticket",
    "name": "approval_status",
    "parent_value": "",
    "multilevel_key": "Ticket Fields",
    "multilevel_label": "Ticket Fields.When a service approval",
    "operator": "is",
    "value": 4
  }
]
```

Approval status values observed: Requested `0`, Approved `1`, Rejected `2`, Cancelled `3`, Not Requested `4`.

Use the `approval_status = Not Requested` guard carefully. In the 2026-06-30 controlled test, a freshly created Incident assigned to GRC - Security and Dorian did not fire while this guard was present because the new Incident did not expose service approval status yet. Removing that guard, publishing the workflow, and reassigning the ticket from EUC back to GRC/Dorian allowed the initial approval to fire.

## Action Payloads

Initial approval action node shape:

```json
{
  "label": "Convert incidents to service requests and request Dorian approval",
  "wf_node": 40001,
  "c": 3,
  "r": 1,
  "token": "<workflow_token>",
  "stage_id": 1,
  "prev_node": {"id": 20001, "condition": 1},
  "next_node": {"id": 2},
  "type": "approval",
  "data": "{\"target\":\"ticket\",\"actions\":[...]}"
}
```

To convert incidents to service requests:

```json
{"name":"ticket_type","value":"Service Request"}
```

The action key is `ticket_type`, not `type`.

To request approval from Dorian:

```json
{
  "name": "request_for_approval",
  "group": [
    {
      "name": "send_approval_mail",
      "value": [{"type": "user_data", "value": 34002240315}],
      "meta": {},
      "approval_type": 1,
      "group_name": "Security Review - Dorian Prescott",
      "default_template": 0
    }
  ],
  "proceed_when": 5
}
```

Freshservice may normalize this to an internal `request_for_approval` action with `group`. Fixed users must use `type: "user_data"`. `type: "const_users"` is only for special negative constants such as reporting manager; positive user IDs with `const_users` fail validation.

Do not add `{"name":"status","value":"..."}` unless the user explicitly wants status changes.

## Approval Outcome Branches

Approved branch:

```json
{
  "label": "Return approved security review to EUC",
  "wf_node": 40003,
  "stage_id": 2,
  "prev_node": {"id": 2, "condition": 1},
  "data": "{\"target\":\"ticket\",\"actions\":[{\"name\":\"group_id\",\"value\":34000153387}]}"
}
```

Rejected branch:

```json
{
  "label": "Return rejected security review to EUC",
  "wf_node": 40002,
  "stage_id": 2,
  "prev_node": {"id": 2, "condition": 2},
  "data": "{\"target\":\"ticket\",\"actions\":[{\"name\":\"group_id\",\"value\":34000153387}]}"
}
```

Add status changes only when explicitly requested.

## Current Dorian/EUC Workflow Behavior

As patched on 2026-06-30, workflow `34000381035`:

- Triggers on `Ticket is updated`.
- Applies when ticket type includes Incident or Service Request, group is GRC - Security, and agent is Dorian Prescott.
- Converts the ticket type to Service Request.
- Requests approval from Dorian Prescott.
- Does not change ticket status anywhere.
- On approval or rejection, assigns the ticket to EUC Monitoring Team and does not change status.

## AP Email Portal Auto-Reply Pattern

As drafted on 2026-06-30, Accounts Payable workspace `6` has draft workflow
`34000381078`, `AP Email Portal Auto-Reply - Review Draft`.

Purpose:

- Trigger on `Ticket is created`.
- Condition on ticket source Email only: `source is "1"`.
- Action: `send_email_to_requester` from AP email config `34000013855`
  (`facilities_6@contoso.freshservice.com`) with the requester-approved AP
  portal resubmission wording.
- Do not add status-changing actions.
- Leave as draft for review unless the user explicitly approves activation.

AP workspace gotchas:

- When creating the AP condition via `/ws/6/admin/ticket_automators/{id}/node`,
  save the condition without `next_node` first. Predeclaring a future action
  creates a dangling branch that makes later action saves fail with
  `Request is invalid. Please refresh the page if the issue persists`.
- AP `send_email_to_requester` action saves require `email_from: "34000013855"`.
  IT examples may omit this because the default sender is inferred there.
- Clean save sequence for AP email draft:
  1. Create workflow shell with `POST /ws/6/admin/ticket_automators`.
  2. Save event node `1`.
  3. Save condition node `20001` with only `prev_node: {id: 1}`.
  4. Save action node `40001` with `prev_node: {id: 20001, condition: 1}` and
     `email_from`.
  5. Read back graph and node_info. Expected graph is `C1R1 -> C2R1`, with
     condition target `{ "1": "C3R1" }`, and action `40001` as the final node.

## Testing Safely

Prefer a controlled test ticket, or an existing production ticket only if the user explicitly approves. Avoid noisy duplicate approval emails.

Verification paths:

- `GET /api/v2/tickets/{ticket_id}`
- `GET /api/v2/tickets/{ticket_id}/approvals`
- `GET /api/v2/tickets/{ticket_id}/approval-groups`
- `GET /api/v2/tickets/{ticket_id}/activities`

Ticket activities should show the workflow name and action summary. For the original test on ticket `4474`, the activity showed the workflow executed, set type to Service Request, initiated `Security Review - Dorian Prescott`, and waited for the Approval event.

For the controlled test ticket `10119`, tag-only updates did not fire the workflow. Moving the ticket back to EUC, then assigning it to GRC - Security and Dorian after publishing the workflow did fire it. Evidence showed the workflow executed from `Ticket is updated`, set Type to Service Request, requested `Security Review - Dorian Prescott`, and left status unchanged as Open.

When testing a workflow that should not change status, capture the status before and after and state whether it remained unchanged.

## Build-by-clone mechanics (verified 2026-07-22)

Confirmed while building `34000382353` "EUC - Correct Request Type (DRAFT)" — a simple
created-trigger -> condition -> set-type rule cloned from SOC `34000380977`. Cloning an existing
simple rule is the lowest-risk way to get a valid event->condition->action graph, then rewrite
only the condition and action `data`.

- **Workflow `status` enum:** `1` = ACTIVE (published, running), `2` = INACTIVE (was activated,
  now off), `3` = DRAFT (never published, does NOT execute). Read all rules with a GET to
  `/ws/2/admin/automators` (returns JSON with `wf_base` objects). A freshly cloned/created rule is
  `status:3` with `activated_at:null` — it is inert until you PUT `.../publish`. Verified: every
  live rule (SOC, the EUC Security gate `34000381035`, PhishER/Expel routing) is `status:1`.
- **Clone needs a name or it 400s.** `POST /ws/2/admin/ticket_automators/{id}/clone_workflow` with
  no body returns `{"status":false,"errors":{"name":["can't be blank"]}}`. Send form body
  `name=<url-encoded>` (Content-Type `application/x-www-form-urlencoded`). The success response
  returns the new workflow object (new id, `status:3`) AND a usable `token`.
- **Editing an existing (cloned) node:** `PUT /ws/2/admin/ticket_automators/{id}/node`,
  form-encoded, keyed by `wf_node`, upserts that node's data. `data` is a STRINGIFIED JSON value;
  nested wiring uses Rails bracket notation (`prev_node[id]`, `next_node[id]`,
  `next_node[condition]`). When the target branch already exists (editing a clone), predeclaring
  `next_node` is safe — the AP dangling-branch gotcha only applies to fresh nodes pointing at a
  not-yet-created action.
- **Nested condition logic works.** `{"all":[clauseA, clauseB, {"any":[...]}]}` saves and reads
  back intact — you can AND top-level clauses with an OR block. Subject keyword match:
  `{"evaluate_on":"ticket","name":"subject","multilevel_key":"Ticket Fields",
  "multilevel_label":"Ticket Fields.Subject","operator":"contains","value":"<kw>"}`, one per
  keyword inside an `{"any":[...]}`.
- **Set ticket type** (again): action `{"target":"ticket","actions":[{"name":"ticket_type",
  "value":"Service Request"}]}`. Action key is `ticket_type`, not `type`.
- **`node_info` can return a transient 500** when fetched from the workflow's own `/edit` page
  context; the same call succeeds from another admin page, and the node save response already
  echoes the stored `item.data` — treat that echo as authoritative for what persisted.
- **Other ws2 rules that exist (2026-07-22, 22 total):** `34000310628` "Category-Based Ticket
  Routing" is currently INACTIVE (`status:2`) — relevant before any category-field cleanup;
  `34000374077`/`34000374079` route PhishER/Expel to Security; `34000379866`/`34000379868` are the
  onboarding checklist rules. Re-enumerate live rather than trusting this list.

## Catalog-item-triggered task checklists (verified 2026-07-28)

The tenant's standard shape for "when someone submits catalog form X, put a checklist of tasks on
the ticket". Live examples: `34000379868` Full-time Employee Onboarding Checklist and
`34000379866` Contractor Onboarding Checklist (both ACTIVE) — clone or copy their node payloads
rather than reinventing. Graph is a straight chain: event -> condition -> action -> action -> ...,
each `add_task` its own ACTION node, last node `target: null`.

**Event — "Service request is raised"** (fires only on catalog-form submission, not on emailed or
agent-created tickets):

```json
{"performer":{"type":"3"},"events":[{"name":"service_request","value":"create"}]}
```

### Catalog tickets created with Type=Request (verified 2026-07-31)

Do not assume every catalog submission emits `service_request:create`. In Strategy - Grants
workspace `8`, Publication Review Request `139` and Data Access Request `140` created genuine
portal tickets with top-level Type=`Request`, not `Service Request`. Four active rules using
`service_request:create` never executed: there was no `Ticket Workflow` activity, group assignment,
or automation note.

#### Root cause: Type choices are per-workspace (verified 2026-08-01)

`GET /api/v2/ticket_form_fields?workspace_id={n}` → the `ticket_type` field's `choices` differ per
workspace. This is the whole explanation, and it changes which patterns are even available:

| ws | name | `ticket_type` choices |
| --- | --- | --- |
| 2 | IT | `Incident`, `Service Request`, `Major Incident` |
| 5 | Supply Chain | `Request` only |
| 8 | Strategy - Grants | `Request` only |
| 9 | Data & AI | `Request` only |

(4/6/7 returned 403 to the admin REST key — re-probe from an account scoped to them.)

Consequences, all of which bite:

- **The Incident→Service Request conversion action is a ws2-only tool.** The action
  `{"name":"ticket_type","value":"Service Request"}` (used live by `34000381035`) can only set a
  value that exists in that workspace's choice list. In ws5/8/9 there is no `Incident` and no
  `Service Request` — every ticket is `Request`, so there is nothing to convert *to* and nothing to
  convert *from*. Confirmed by listing ws8 tickets: Type distribution `{"Request":4}`; ws2 for
  contrast `{"Incident":96,"Service Request":4}`.
- **"Approvals only work on service requests" is not a usable rule of thumb here.** In a
  Request-only workspace the type cannot be the discriminator, so do not design an approval gate
  around converting type first. Test the approval action directly on a `Request` ticket.
- Before writing any rule that keys on, or sets, ticket Type, read that workspace's choice list
  first. Do not carry a ws2 condition value into another workspace.

#### What actually distinguishes a catalog submission from a plain portal ticket

Not the Type. The two real differences are `requested_catalog_items` (populated only by a catalog
submission) and the catalog item's own custom fields, which exist only on the requested item and are
**not** ticket fields. A ticket raised through the portal's generic new-ticket form can never carry
them. Any plan that swaps catalog intake for generic-ticket intake is therefore a plan to rebuild
every catalog field as a workspace ticket custom field in Field Manager — and those writes are
UI-only (see `ticket-field-visibility.md`).

For catalog items with this behavior, use the proven generic create event and keep the requested
item as the positive condition:

```json
{"performer":{"type":"3"},"events":[{"name":"ticket_action","value":"create"}]}
```

Active IT workflow `34000310633` (`Multistage Approval`) is a live example of
`ticket_action:create` followed by a `requested_catalog_items` condition. After changing an active
rule, deactivate and reactivate it through the UI so the edited graph is reloaded; verify
`wf_base.status == 1`, a fresh `activated_at`/`updated_at`, and the event node readback.

If the action routes into a restricted group, a verifier who is not a group member may immediately
receive `403 access_denied` for the new ticket. That is useful evidence that group routing occurred,
but it does not prove a private note or notification email; have a member agent verify those.

**Condition — match the catalog item.** `value` is the item's **`id`** from
`GET /api/v2/service_catalog/items` (the big `34000xxxxxx` number), NOT its `display_id`. One
clause with several ids in the array covers several forms:

```json
{"any":[{"evaluate_on":"ticket","name":"requested_catalog_items","parent_value":"",
  "multilevel_key":"Ticket Fields","multilevel_label":"Ticket Fields.Requested items",
  "operator":"includes_any","value":["34000334340","34000335941"],"subconditions":{}}]}
```

Contoso joiner/leaver item ids (re-verify against the live catalog before reuse):
FTE Onboarding `34000334339` (display 97), FTE Offboarding `34000334340` (98),
Contractor Offboarding `34000335941` (101), Contractor Onboarding `34000335942` (102).

**Action — `add_task`.** `title` must be duplicated into `add_task0`, and `identity` must match
that suffix (`add_task0`); the save succeeds without them but the task renders blank in the UI.

```json
{"target":"ticket","actions":[{"name":"add_task","title":"<task title>","workspace_id":"0",
  "note":"<HTML body>","group_belongs":"34000153387","assign_to":"","notify_before":"0",
  "due_in":"1800","add_task0":"<task title>","identity":"add_task0","custom_field":{}}]}
```

- `group_belongs` = agent group id, or `"0"` for none; `assign_to` `""`/`"0"` leaves it unassigned.
- `due_in` is `"1800"` on every existing onboarding task — treat as the tenant default and mirror
  it unless the user asks for a specific due date; the unit is not confirmed.
- `note` accepts full HTML (links, `<ul>`, `<b>`). Workflow tasks are agent-internal, so this is
  the right place to put "go check system Y" instructions the requester should never see.

Worked example of this exact shape built 2026-07-28: `34000382739` "Offboarding - Collect Assigned
IT Hardware (DRAFT)" — one condition covering both offboarding items, one `add_task` for EUC
hardware recovery. Read its nodes back for a copyable minimal chain.

## Note authorship: the "system" principal (verified 2026-07-26)

Use this when a requirement says a note must NOT appear to come from the operator's own account.

### Verify requester visibility separately (verified 2026-07-31)

- A Workflow Automator `Add Note` action being system-authored does **not** prove the note is
  private. Strategy - Grants portal tests `REQ-30716` and `REQ-30734` each sent the external
  requester a `Ticket Updated` email containing the complete under-30-day note text.
- For text intended only for agents, inspect the action's public/private setting and validate it
  from both sides: an agent must read the stored note, and a real requester portal/inbox session
  must prove that the note and an update email are absent. A non-member verifier receiving
  `403 access_denied` after restricted-group routing is not enough.
- In this tenant, the proven serialized action fields for a private Add Note are strings, not
  booleans. Keep the note body only in `body_html_add_note0`:

  ```json
  {
    "private_add_note": "true",
    "private_add_note0": "true",
    "body_html_add_note0": "<p>agent-only note body</p>"
  }
  ```

  Strategy - Grants workflows `34000382842` and `34000382843` exposed the failure mode: saving
  `private_add_note: true` as a boolean and putting the note body in `private_add_note0` produced
  a requester-visible public note plus a `Ticket Updated` email. Unchecking and rechecking the UI
  option **Add as Private Note, and don't notify the requester**, then saving, produced the string
  flags above. Read back `node_info` before activation; do not normalize those strings to booleans.
- If requester visibility is unintended, deactivate and patch the rule before widening the pilot.
  Do not infer privacy from the system author, an `Add Note` label, or the admin canvas alone.

- **A note written by a Workflow Automator `Add Note` action is authored by an internal system
  principal, `user_id 34001080775`** — not the rule author, not the ticket assignee. Evidence:
  scanned 180 tickets; that id returns **404 on both** `/api/v2/agents/{id}` and
  `/api/v2/requesters/{id}`, and every note it wrote is the same canned automation text across
  tickets `6378`, `6592`, `6506`. So **letting the automator post the note is the supported way to
  get a "system"-authored note.**
- By contrast, `POST /api/v2/tickets/{id}/notes` from a personal API key stamps the **key owner**
  as author. The endpoint does document a `user_id` attribute ("ID of the agent/user who is adding
  the note"), but whether Freshservice honours an override to a non-self id is **untested** — test
  it on a disposable ticket before relying on it, because a silent fallback writes a visibly
  wrong-authored note on a real ticket.
- There is no bot/service agent in the tenant (all agents in `GET /api/v2/agents` are humans), so
  the only no-extra-licence route to a non-personal author is the automator.

## Web Request + JSON Parser nodes (verified 2026-07-26, vendor docs)

- **The Web Request node is synchronous, not fire-and-forget.** It "proceeds to the next node only
  after it has received a response". The HTTP status code is usable in a following condition node,
  and the response body can be consumed by a **JSON Parser node**.
- **JSON Parser node:** drop it on the canvas, map **Source** to the Web Request node's output,
  paste a sample response body into **Payload**, and hit **Generate Output** — it derives the
  schema and exposes each field as a placeholder for later nodes.
- Consequence for integrations: a rule can call an external service and **use the returned text in
  the same run** (e.g. an `Add Note` body). No custom-field round-trip or second rule is needed.
- **Timeout is not documented publicly.** Measure it in a controlled test before depending on a
  long-running callee. Anything calling a Power Automate HTTP-trigger flow also inherits that
  platform's request-response limit (~120 s, then 504) — the shorter of the two wins.
- Web request quota is per plan on a rolling 30-day cycle from activation, not calendar month:
  Starter/Growth 300,000; Pro/Enterprise 720,000.
- Rules that fire on `update` and then write to the ticket can re-trigger themselves. Add a
  positive guard (a tag the condition excludes, or a status narrowing). Note the 2026-06-30
  finding above — tag-only updates did not fire the automator — which makes a tag write a
  reasonable loop-safe marker, but re-confirm it per rule.

## Exclusion lists: `any` + `does_not_include` always matches (verified 2026-07-29)

**The single highest-consequence trap in this tool.** Building "do X to every ticket EXCEPT the ones
from forms A/B/C/D" by adding one `does_not_include` clause per form under **Match any** (`{"any":[...]}`)
produces a condition that is **true for every ticket**, so the exclusion list does nothing.

A ticket carries at most one requested item, so whichever form is submitted, the other three
`does_not_include` clauses are true and carry the OR:

| clause vs a ticket holding form C | result |
| --- | --- |
| does not include A | true |
| does not include B | true |
| does not include C | **false** — the clause meant to protect C |
| does not include D | true |
| `any` (OR) | **true → rule fires anyway** |

De Jordan: negating a set needs AND. `NOT(A or B or C or D)` == `NOT A and NOT B and NOT C and NOT D`.
So an exclusion list **must** be `{"all":[...]}`. Under `all`, a ticket holding C yields false (kept)
and an email with no requested items yields all-true (matched) — the intended behavior.

The UI makes this easy to get wrong: the auto-generated node label reads the same
("...does not include payment request form, accounts payable inquiry form ...") under both wrappers,
so the canvas looks correct while the rule matches everything. **Always simulate the truth table
before publishing**, and treat it as mandatory when a downstream action is `delete_ticket`.

Live case: ws6 rule `34000382698` "Stop Generating emails from AP Mailbox" shipped with `any` and
silently deleted **every** new AP ticket — including the four catalog forms it was written to spare —
for ~3h15m while active. Fixed by flipping the wrapper to `all`; clauses unchanged.

Prefer a **positive** gate over an exclusion list where one exists. For "act on emailed tickets but
not portal/catalog submissions", one source clause is more robust than enumerating forms — it cannot
be broken by publishing a new form, and it does not depend on `requested_catalog_items` being
populated at the moment a create-trigger rule evaluates:

```json
{"all":[{"evaluate_on":"ticket","name":"source","operator":"is","value":"1"}]}
```

Source ids (from `GET /api/v2/ticket_form_fields`, tenant-wide): Email `1`, Portal `2`, Phone `3`,
Chat `4`, Feedback Widget `5`, Walk-up `9`, Slack `10`, MS Teams `15`, Journey `19`. Catalog form
submissions arrive as Portal `2`.

## Activate / deactivate an existing rule (verified 2026-07-29)

The private automation endpoint that the reference above uses for soft delete also flips `status`:

```text
PUT /api/_/automation/ws/{ws}/module/1/workflows/{workflow_id}
Content-Type: application/json
{"status": 2, "token": "<workflow_token>"}
```

- `status` `1` = ACTIVE, `2` = INACTIVE, `3` = DRAFT (see the enum note above). `2` is the correct
  "stop it now, keep it editable" state for a live rule — it sets `deactivated_at`/`deactivated_by`
  and preserves the graph. Response echoes the full `wf_base` plus a rotated `token`.
- **GET on that path returns 405** (`PATCH, PUT` only), so read status from
  `GET /ws/{ws}/admin/automators` instead — it returns a nested array; flatten it and read
  `wf_base` off each entry (`j.flat().filter(Boolean).map(x=>x.wf_base)`).
- Reaching for this beats `/publish` when triaging a misfiring production rule: deactivate first,
  patch nodes second, republish only on explicit user approval. A node save does **not** reactivate
  an inactive rule, so editing after deactivation is safe.
- The token rotates on the deactivate save too. Reload the `/edit` page for a fresh
  `workflow_token` before the next node save, or reuse the token from the deactivate response.

## Rename an active workflow without changing its state (verified 2026-08-01)

For a display-name-only cleanup, open
`/ws/{ws}/admin/ticket_automators/{workflow_id}/edit`, click `#edit_workflow_btn`, change the visible
`input[name="name"]`, and submit `#edit_workflow_modal-submit`. The supported UI sends
`PUT /ws/{ws}/admin/ticket_automators/{workflow_id}` and does not require deactivation or publication.

The page also contains a hidden clone modal whose first `input[name="name"]` can contain
`Copy of <workflow name>`. A bare `querySelector('input[name="name"]')` can therefore target the
wrong field. Select the visible input (non-zero bounding box) or scope the locator to the visible edit
modal, and abort unless its value exactly matches the expected current workflow name.

After the update, re-read `GET /ws/{ws}/admin/automators` and verify the new name, `status == 1`, and
the original `activated_at`. Re-read the graph and any high-risk action nodes when the task requires
proof that routing, approvals, private-note flags, or other behavior was not changed. A rename is not
complete based only on a `200` response.

## Contoso AP workspace (ws 6) catalog item ids (verified 2026-07-29)

Re-verify against `GET /api/v2/service_catalog/items` before reuse; `display_id` is what appears in
`/support/catalog/items/<n>` portal URLs, but conditions need the long `id`.

| id | display_id | name |
| --- | --- | --- |
| `34000338841` | 127 | Accounts Payable Inquiry Form |
| `34000338843` | 128 | Payment Request Form (leading space in the stored name) |
| `34000335543` | 99 | Manual Payment Request Form |
| `34000333961` | 94 | Payment Request |

## Change-module rules (CAB approvals) — different paths, harder traps (verified 2026-08-05)

Change workflows are a separate module from tickets. Everything below was learned swapping a CAB
approver on live rule `34000374083` ("IT notification for Normal Change requests").

- **Module ids:** `1` ticket, `2` problem, `3` change, `4` release, `5` configitem, `6` ittask.
  List per module with `GET /api/_/automation/ws/{ws}/module/{n}/workflows` (clean JSON, includes
  each rule's current `token`).
- **Admin paths mirror the ticket ones** with `change_automators`: list
  `/ws/{ws}/admin/change_automators`, graph `/ws/{ws}/admin/change_automators/{id}`, node detail
  `.../node_info?stage_id=&wf_node=`, save `PUT .../node`, editor `.../edit`. The editor also
  fetches `/ws/{ws}/admin/change_automators/nodes_data?id={id}`, which is a good health probe:
  it returns `{}` when the graph is broken.

### A data-only node save silently strips structure and 500s the rule

`PUT .../node` with only `wf_node` + `stage_id` + `token` + `label` + `data` returns `200` and the
`data` reads back **perfectly** through `node_info` — while dropping the node's structural
attributes. On an approval node that loses `type: "approval"` and its wiring, after which
`GET /ws/{ws}/admin/change_automators/{id}` **and the whole `/edit` page return 500** and
`nodes_data` returns `{}`. A correct `node_info` readback is therefore NOT evidence the save was
clean — always re-read the graph too, and from a page other than the workflow's own `/edit`.

Send the full node definition on every edit, even a one-field change:

```text
wf_node=40010  stage_id=1  c=4  r=1  type=approval
prev_node[id]=40009  next_node[id]=2
token=<current>  label=<unchanged>  data=<stringified JSON>
```

Get `c`, `r`, `type`, and the wiring from the graph response before editing (`target` maps to the
`C{c}R{r}` id of the next node; an approval node's `next_node` is the hidden approval event, id `2`).
Re-saving with these fields repaired the 500 with no other change — the graph came back
byte-identical to the pre-change snapshot.

Also note the **save response echo is misleading here**: it renders the approval action flattened
(`send_approval_mail` hoisted to a top-level action, `approval_chain_rule` as its own pseudo-action,
`proceed_when` at the root of `data`). `node_info` shows the correct nested `request_for_approval`
wrapper. Trust `node_info`, not the save echo, for approval nodes.

### Status-cycle payload: `token` must be a String

The deactivate/reactivate cycle that reloads a live rule's graph rejects the integer token that the
workflows list returns:

```json
{"description":"Validation failed","errors":[{"field":"token","message":"The value provided is of type Integer.It should be of type String","code":"datatype_mismatch"}]}
```

Cast it: `{"status":2,"token":String(wf.token)}` against
`PUT /api/_/automation/ws/{ws}/module/{n}/workflows/{id}`. Both legs `400` harmlessly when the type
is wrong — the rule stays untouched, so a `400` here is safe to retry. Issuing deactivate and
reactivate back-to-back in one in-page script kept the uncovered window to ~400 ms; on success
`activated_at` and `token` both refresh.

### Change approvals must come from a CAB — there is no "specific agent" option

The change module's `send_approval_mail` picker offers only: the two CABs, `-10` Owners of Impacted
Services, `0` Department Head, `-3` Reporting Manager, and change-field placeholders. The ticket
module's `type: "user_data"` (any agent) is **not available**, so an approver is expressed as
`{"type":"cab_agents","value":<agent_id>}` plus `meta.cab_data:[<cab_id>]`.

**CAB membership is resolved at runtime, and stale entries are dropped silently.** A rule listing
three `cab_agents` where one had since been removed from the CAB raised approvals for only the two
current members — no error, no stall, the board just quietly lost a vote. So editing the node is
never enough: the agent must also be on the CAB roster. Verify both, and verify the outcome on real
work items via `GET /api/v2/changes/{id}/approvals` (compare a pre- and post-departure change).

**CABs are administered outside the workspace admin**, under Global Settings → User Management →
CAB: list `/itil/cabs`, edit `/itil/cabs/{cab_id}/edit`. Nothing under `/ws/{ws}/admin/...`,
`/a/admin/cab*`, or `/api/v2/cab*` serves it — those all 404. `GET /api/_/cabs` returns id + name
only (no members); read the roster from the edit page's `tr#user_{agent_id}` rows, or from the
workflow editor's `window.workflowPristineData` → `send_approval_mail` → `nested_choices`, which
maps each CAB id to its current members and is the same list the picker shows.

**Adding a CAB member is additive, removing is not part of the form.** On the edit page the hidden
`AgentGroups[agent_list]` starts empty and accumulates only NEW ids; existing members are separate
rendered rows whose trash icon fires its own immediate Ajax delete. So submitting
`POST /itil/cabs/{id}` with `_method=patch` and `AgentGroups[agent_list]=<new id>` adds that member
and leaves the existing roster alone — it does not replace it. Abort the write unless the loaded
form's name, description, and existing member rows match a recorded baseline first.

## Instance-wide sweep: "does any workflow reference this field?" (verified 2026-07-30)

Before deleting or repurposing a ticket field, prove no rule depends on it. Node conditions are not
in the list response, so this is a three-pass sweep against the authenticated agent session:

1. **List** — `GET /ws/{wsId}/admin/ticket_automators` returns every rule in the workspace,
   including drafts. The shape is nested arrays, not a flat list: `[[{wf_base:{...}}, null], ...]`
   — map `entry[0].wf_base`; a naive `Object.values()` yields useless `{0,1}` objects.
   `wf_base.status`: `1` = active, `2` = deactivated, `3` = draft never activated.
2. **Graph** — `GET /ws/{wsId}/admin/ticket_automators/{id}` returns the node array with
   `block_type` (EVENT/CONDITION/ACTION), `stage_id`, `wf_node`, and a human `label`. Labels are
   auto-generated from the condition, so a field's label usually appears there — a useful first
   filter, but authors can rename them, so it is not proof. Draft rules with no stages built
   return **404 here** — that means empty, not broken.
3. **Node detail** — `node_info?stage_id=&wf_node=` per node is the authoritative condition/action
   payload. Grep it for the field's `name` **and** its numeric id; conditions may store either.

Cost is roughly 5 node calls per rule (123 calls across 25 rules on the Contoso IT workspace).

**Chunk the calls.** Driving these through one in-page `fetch` loop over ~100 paths overruns the
CDP `Runtime.evaluate` timeout and loses the whole batch. Issue ~12 paths per eval and accumulate
across evals; each chunk then returns well inside the timeout.

Sibling surfaces to clear in the same pass, none of which Workflow Automator covers — business
rules (`GET /api/_/business_rules?workspace_id={wsId}`, the form show/hide rules), scenario
automations (`/api/_/scenario_automations?workspace_id={wsId}`), plus SLA policies and catalog items
over public REST. Analytics/report definitions are not exposed on any endpoint found so far; say so
explicitly rather than reporting a clean sweep you could not run.
