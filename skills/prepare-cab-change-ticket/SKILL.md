---
name: prepare-cab-change-ticket
description: Draft, complete, or review a Contoso IT change ticket (Freshservice change
  request) so it passes CAB review under the Change Ticket Content Requirements
  standard (IT-CHG-STD-001). Use when the user asks to "submit a change", "write a
  change request", "create a change ticket", "prep this for CAB", asks what a change
  submission requires or why a change was returned, or mentions change types (normal,
  urgent, emergency, standard, informational), rollback plans, risk levels, PIR notes,
  or CAB deadlines. Covers the six required content sections, per-type approvals and
  timing, and practical expectations like attaching the scripts used and pilot-group
  test evidence. For Freshservice Workflow Automator rules or ticket automations, use
  the freshservice-automation-builder skill instead.
---

# Prepare CAB Change Ticket

Authoritative source: `references/it-chg-std-001.md` inside this skill's folder — the full
Contoso standard IT-CHG-STD-001 v1.0 (captured 2026-07-02 from the docx issued by Dorian,
GRC/CAB Manager). If a newer version of the standard exists, the newer version wins;
update the reference file from it.

## Drafting a change ticket

1. Classify the change type — normal, urgent, emergency, standard, or informational —
   and the risk level (Low / Medium / High / Very High; emergency is auto Very High).
   Definitions and the per-type requirements table are in the reference file.
2. Ask the requester for the planned change window (start date/time and end date/time)
   before setting `planned_start_date`/`planned_end_date` — never infer or guess a
   duration. A guessed window that's too long (or too short) is a real failure mode: it
   was caught only after a change had already been submitted, too late to fix. If the
   requester has no preference, propose a specific window and get explicit confirmation
   before writing it into the draft — don't silently pick one. Same rule for the CAB date
   if it isn't obviously "next Tuesday" per the standard's normal-change timing.
3. Write the six core sections required on EVERY ticket. Each must be substantive —
   one-line entries get the ticket returned by the CAB Manager:
   - What is changing and why (plain language; tie to incident/problem/project if any)
   - Definition of success (expected outcome + how it will be verified)
   - Risk and impact assessment (what could go wrong, who is affected, downtime,
     risk level with rationale, dependencies)
   - Implementation plan (step-by-step, ordered, with owners, timing, prerequisites —
     detailed enough that another qualified engineer could execute from the ticket alone)
   - Rollback plan (mandatory on ALL tickets: trigger criteria, revert steps, duration,
     point of no return, confirmed backups/snapshots)
   - Stakeholder communication (who was notified, when, what channel — before AND after
     the change, required even when impact is minimal)
4. Add the per-type extras, approval path, and timing from the reference table
   (e.g. normal needs documented peer review before CAB submission and PIR notes after;
   urgent/emergency need the triggering incident and Senior Director of IT approval).
5. Practical CAB expectations beyond the written standard (per Dorian, the CAB Manager):
   - Attach the actual scripts, commands, or policy exports the change will run —
     "deploy update" with nothing attached is not reviewable.
   - Where feasible, test on a smaller pilot group first and document the result in the
     ticket before requesting approval for broad rollout.
   - If the change will be noticeable to end users, advance communication to impacted
     users is necessary, not optional — document who, when, and through what channel.
   - Write at the altitude a CAB reviewer needs, not the altitude the requester works at
     day to day. Leave out personal-only implementation detail that doesn't change what's
     being approved or how it's scoped — the requester's local folder layout, personal
     packaging-directory conventions (e.g. a Test/Prod or Input/Output split on their own
     machine), exact file paths on their OneDrive, or literal build/CLI commands. The
     attached scripts (previous bullet) already carry that detail for whoever executes
     the change; the narrative sections should describe what changes, for whom, and how
     it's verified/rolled back — not the requester's personal working layout.
6. Self-check before submission: could a reviewer with no prior knowledge understand the
   change, and could another engineer execute AND roll it back from the ticket alone?
   Also check the reverse: does the draft contain detail only the requester would know
   that isn't pertinent to the change (their own folder/naming conventions, local paths) —
   if so, cut it. If any answer is no, the ticket is not ready.
7. Apply the seven Cs of communication (clear, concise, concrete, correct, coherent,
   complete, courteous) to the complete Freshservice Details tab before every create or
   update. (There is no `apply-seven-cs-communication` skill on disk — an earlier version
   of this file pointed at one that does not exist; work from the principles plus the
   house-style anchor below.)
   - Give each fact one primary home across Description, Reason for Change, Impact, Rollout
     Plan, and Backout Plan; remove repeated readiness, scope, timing, and communication text.
   - Re-read the live change immediately before drafting and reconcile the status, CAB date,
     planned start/end, risk, impact, and current notes. User-edited live values take precedence
     over earlier drafts. State dates, times, and timezone explicitly.
   - Write for a CAB reviewer who must scan and act: lead with the change, use plain language,
     make tests and rollback triggers concrete, and cut internal process narration.
   - After writing, read the live record again and verify every revised field. For a
     Details-only request, also prove the existing notes were not changed.
8. Before creating or submitting the change (this runs every time, not only on request):
   play devil's advocate against your own draft, then hand the requester a gameplan doc
   they can bring into the room. See "Devil's-advocate gameplan" below.

## House style — read real submissions before drafting (length anchor)

The standard's "must be substantive; a one-line entry is not sufficient" is a floor, NOT a
target. Read it as a floor and you will overshoot badly: a draft built only from Section 4
came back from Avery as "way overboard on technical and literal detail" (2026-08-07).
Approved Contoso changes are far shorter than that rubric implies.

Before drafting, pull 4-5 recent changes and match their length and altitude:

```powershell
# key: KSM notation, NOT -q JSONPath (that returns [])
$key = (& py -m keeper_secrets_manager_cli -p contoso secret notation `
  "keeper://KEEPERUID00000000000B/field/password" 2>$null | Out-String).Trim()
$b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($key):X"))
$hdr = @{ Authorization = "Basic $b64" }
# list: GET https://contoso.freshservice.com/api/v2/changes?per_page=100&page=N
# body: GET .../changes/{id}  -> .change.description + .change.planning_fields
```

Freshservice field names on the Details tab: `description`, then under `planning_fields`:
`reason_for_change`, `change_impact`, `rollout_plan`, `backout_plan`. Those five ARE the
ticket — there is no separate "definition of success" or "stakeholder communication" field,
so fold those into Description (see CHN #10021). Codes: risk 1=Low 2=Medium; change_type
1=Normal; impact 1=Low 3=High.

Calibration from real approved changes:

- **CHN #10021 "Enable SSPR Organization-Wide" is the best template.** Description carries
  bolded mini-headers: Change summary / Implementation window / Success criteria / User
  impact and communication. Reason for Change uses `Business need:` + `Readiness:`. Backout
  uses `Rollback triggers:` + `Rollback steps:`. Copy this shape.
- **CHN #10007 (device rename) is the CEILING for detail**, and it was risk=Medium touching
  the whole Windows fleet. It phases the rollout (Assessment / Execution / Monitoring) and
  lists risks with mitigations inline. Do not exceed it.
- **CHN #146 (Cato) and #10014 (Purview) are typical.** #146's entire backout plan is one
  line: "Disable the Client Connectivity Policy". #10014's entire impact is "Members of the
  IT department". These were approved.
- **Completed prep goes in the rollout plan marked `(done)`** with what was proven and
  when — #10014 and #10021 both do this. Testing already performed is rollout evidence, not
  background; don't bury it in Reason for Change. Naming the people/devices tested on is
  house convention (#10014 names Lane, Avery, Kane).

What to leave out entirely, however true: API/object type names, approval-workflow
mechanics (MAA), policy priority/precedence behaviour, assignment-filter internals,
pre-change export procedures. That is execution detail for the attachments.

## Devil's-advocate gameplan (every change, before submission)

The requester has to be able to speak to the change out loud in CAB, not just hand over
a ticket. Before creating/updating the change in Freshservice, produce a short standalone
gameplan doc next to the ticket draft (e.g. `<ticket-name>-gameplan.md`):

1. Re-read the drafted ticket as a skeptical CAB reviewer would, hunting for the same gaps
   the six-section rubric and per-type rules check for: a thin backout plan, an un-phased
   fleet-wide rollout, missing test/pilot evidence, an unstated assumption, a risk/impact
   rating that undersells the blast radius, a dependency nobody mentioned. List every hole
   found, even minor ones — do not stop at the first pass.
2. For each hole, decide: fix it in the ticket itself, or flag it as a defensible tradeoff.
   Either way, write down the answer — "fixed by adding X" or "acceptable because Y."
3. Compile the gameplan as anticipated-question -> prepared-answer pairs, ordered by how
   likely a reviewer is to ask each one first. Lead with the single hardest question a
   skeptical approver would ask and its honest answer — do not bury it.
4. Share the gameplan doc with the requester alongside the ticket draft, before asking for
   approval to submit to Freshservice.

## Reviewing an existing ticket for completeness

Walk the reference file's core sections and per-type requirements as a checklist and
report gaps the way the CAB Manager would: name the missing section and what it must
answer, rather than a generic "incomplete".

## Key facts

- Normal changes: submit by Monday 12 PM; execution may begin Tuesday 5 PM after CAB.
- Urgent vs emergency: urgent changes are approved, then executed; emergency changes are
  executed with approval obtained simultaneously or immediately after.
- Standard changes are pre-approved (reference the template used, note deviations);
  informational changes require stakeholder notification BEFORE the ticket is created.
- Exceptions to the standard need written approval from the Senior Director of IT.
- Change records are retained in Freshservice for a minimum of 24 months.

## Freshservice writes

Drafting content in chat or files is safe. Creating or updating the change ticket in
Freshservice is a production write — get explicit approval from the user first, per the
core rules in the it-operations skill. Keep API keys out of chat output. Do the
devil's-advocate gameplan pass above before this write, not after.

On the live New Change form, typing a requester name is not enough: the field can display
the name while its underlying selection remains blank. Select the returned requester option,
confirm the blank-field warning clears, and verify the requester ID on the created record.
