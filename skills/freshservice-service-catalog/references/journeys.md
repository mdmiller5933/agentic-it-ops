# Freshservice Journeys — build/edit procedure (verified 2026-08-20 on contoso.freshservice.com)

How the Employee Termination Form journey was extended with new stakeholder fields and tasks,
entirely through session-authenticated internal APIs. All calls are in-page `fetch(path,
{credentials:'include', headers:{'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content}})`
run through the authenticated CDP session (see `authenticated-session.md`). Never print cookies or
tokens. Publishing is production-impacting — explicit approval first.

## Model

- Journey config list: `GET /api/_/journeys/configs?page=1&per_page=30`. "Employee Termination
  Form" is journey_id 6; the *config id* changes on every publish cycle (draft id becomes the
  published id — e.g. 59452 was superseded by 68017 on 2026-08-20). Always resolve the current
  config id from the list, never reuse a remembered one.
- Structure: initiator config (requester group HR Team + initiator form "Employee Details") →
  phases ("Initiate separation" → "Last working day" → "Offboarding Completion") → activities per
  phase (EMAIL / TASK / SERVICE_REQUEST). TASKs with `task_type: FORM` assign a small form to a
  stakeholder; the assignment email is "the blast".
- Stakeholders are journey-level objects; CUSTOM ones bind to an initiator-form employee field
  (`type 501`) by `field_name`. Task `configuration.stakeholder_id` = the stakeholder's
  **display_id** (not id).
- The standing pattern for "N people must confirm X": N initiator-form 501 picker fields → N
  stakeholders → N cloned TASK forms (see HSE Stakeholder / HSE Stakeholder 2).
- Task forms follow one shape: Section (type 1015) headline "Please confirm ..." containing one
  required single-line text (type 1001) "Please enter the date that ... and then submit this
  form." Dates are captured as text by design (matches Rowan Braddock's May 2026 process email:
  stakeholders "confirm the date" then submit).

## Edit cycle

1. `Edit journey` on the published board (`/b/admin/journey-configs/{id}/board/activities`) →
   "Create draft" → new draft config id in the URL. The draft is disposable; published journey is
   untouched until republish. (The click needs a real `button.click()`; the wizard stepper is
   `[data-testid="wizard-item-1"]` for initiator config.)
2. Make changes against the DRAFT id (below).
3. Publish: board "Publish" button → confirm modal → `POST /api/_/journeys/configs/{draft}/publish`
   (empty JSON body). Poll the configs list until status PUBLISHED (~30-60s).

## Endpoints that worked (draft id = {cfg})

- Read config + initiator form: `GET /api/_/journeys/configs/{cfg}?initiator_form=true`
- Phases: `GET /api/_/journeys/configs/{cfg}/phase` — **gotcha:** once the draft is first
  modified, "version bump" materializes draft-owned phase rows with NEW ids (Last working day
  115088 → 129637). Activity routes embed a phase id; on "Phase not exists for journey" re-fetch
  the phase list and use the draft's id. A created activity's `current_phase_ref_id` is
  authoritative for its own routes.
- Stakeholders: `GET|POST /api/_/journeys/configs/{cfg}/stakeholders`. POST body:
  `{title, source:"INITIATOR_FORM", type:"CUSTOM", values:{source:"INITIATOR_FORM",
  form_name:"Initiator form", activity_id:null, field_name:"cf_...", field_label:"...",
  field_type_id:501, fs_user_field:true}}` → 200 with new display_id.
- Initiator form save: `PUT /api/_/journeys/configs/{cfg}/config` with the FULL initiator config
  object (same shape the GET returns / the UI "Save and next" sends — capture one no-op save if
  unsure). Existing fields carry `action:"UPDATE"`; new fields `action:"CREATE"` with a fresh
  client-side UUID `id`, `column_name:null`, `field_options.journey_column_name:null` — the
  server allocates the column (`lf_bigint_NN`) and renumbers positions 1..N.Employee picker
  fields (type 501) CANNOT be added via the builder palette (it has no employee item — existing
  ones came from the vendor template); clone an existing 501 field JSON: `field_options`
  `{link:"/lookup_choices", conditions:"{\"agent\":[],\"requester\":[]}", col_span:2,
  same_as_agent:"true", data_source:"5", field_name:<name>}`, `required:true`,
  `field_class:"INITIATOR_FORM"`.
- Activities: `GET .../phase/{ph}/activity/list?page=1&page_size=50` (no form detail; response
  is `response_data.activities`), `GET .../phase/{ph}/activity/{act}?include=lookup_enrichment`
  (full form), `POST .../phase/{ph}/activity` (creates the activity but **ignores form_config**),
  then attach the form with `POST .../phase/{ph}/activity/{act}/child-activities` — body
  `{parent_activity:{name, is_mandatory:true, type:"TASK", activity_category:"STANDARD",
  is_child_activity:false, configuration:{type:"TASK", journey_data:[{form_type:"INITIATOR_FORM",
  field_name, activity_id:null}...], task_type:"FORM", stakeholder_id:<display_id>, form_title,
  due_date:{days:1, operator:"after", time:"12:00",
  field_name:"{{INITIATOR_FORM.cf_offboarding_last_working_date}}"}},
  form_config:{task_form:{account_id, service_form_id:null, form_id:null, organisation_id:0,
  imported:false, fields:[section-with-nested-child]}, service_form:null}},
  child_activities:{create:[],update:[],delete:[]}}`. Form fields use the same CREATE semantics
  as the initiator form (UUID ids, `parent_id` = section's UUID for the nested field,
  `field_class:"ACTIVITY_FORM"`, `column_type_blob:true`); the server wraps them in an auto-root
  and allocates `cf_blobNN` columns. Verify EVERY write by re-GET before moving on.
- Standard task config to clone: due 1 day after `{{INITIATOR_FORM.cf_offboarding_last_working_date}}`
  at 12:00, form_title `EMPLOYEE OFFBOARDED: {{INITIATOR_FORM.request_for}} on
  {{INITIATOR_FORM.cf_offboarding_last_working_date}}`, journey_data = request_for,
  cf_offboarding_reporting_manager, cf_offboarding_last_working_date, cf_offboarding_department.

## 2026-08-20 change (for context)

Rowan Braddock's ask "another field for the Brex Termination + Bank account termination with two
fields, dates to confirm access was cut, so both Casey and Hugo get the blast" was implemented
as: initiator fields + stakeholders + cloned date-confirmation tasks for "Credit Card
Cancellation Stakeholder 2", "Bank Account Termination Stakeholder", "Bank Account Termination
Stakeholder 2" (Rowan Kingsley = Senior Treasury Manager handles Brex/credit card; Hugo Lockhart =
Treasury Analyst handles bank accounts). All initiator stakeholder pickers are required.
