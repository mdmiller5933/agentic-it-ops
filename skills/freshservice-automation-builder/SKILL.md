---
name: freshservice-automation-builder
description: Build, inspect, update, test, or troubleshoot Contoso Freshservice native Workflow Automator rules and ticket automations. Use when the user asks to create Freshservice automations, approval gates, workflow automator rules, ticket routing, incident/service-request conversion, Dorian/security approval flows, EUC handoffs, or any Freshservice automation behavior that must run inside Freshservice rather than as a local sidecar script.
---

# Freshservice Automation Builder

## Core Workflow

Use this with the it-operations skill when the task is Contoso-specific. Read
`references/workflow-automator.md` before changing native Freshservice Workflow
Automator rules.

1. Confirm the target workspace, ticket module, trigger, conditions, actions, and testing scope.
2. Use live Freshservice API for ticket state and verification. Do not print API keys, cookies, CSRF tokens, or auth headers.
3. For native Workflow Automator definitions, use the authenticated Freshservice admin UI/session; the public v2 API does not expose workflow definitions. To obtain that session on Avery's workstation (CDP browser + Outlook magic-link login), see `references/authenticated-session.md` in the freshservice-service-catalog skill. That sibling skill covers service catalog items, categories, and requester→agent conversion; this skill stays scoped to Workflow Automator rules and ticket automations.
4. Prefer cloning an existing workflow or creating a draft/version before editing an active workflow. Keep changes tightly scoped.
5. Save nodes one at a time and refresh/use the newest workflow token after each save.
6. Publish or activate the workflow only when the user explicitly asks for activation/publishing or confirms it at handoff. Otherwise leave the workflow drafted or deactivated and tell the user what to activate manually. A node can read back correctly from the edit surface while the active workflow still runs the previous published version.
7. Verify by reading back every affected node through `node_info` and checking ticket activities after a controlled trigger.
8. Leave the Freshservice workflow tab open when useful for user review.

## Contoso Defaults

- Tenant: `https://contoso.freshservice.com`
- IT workspace ID: `2`
- EUC Monitoring Team group ID: `34000153387`
- GRC - Security group ID: `34000172540`
- Dorian Prescott agent ID: `34002240315`
- Known active workflow created from this work: `34000381035`, `EUC Security Review Approval Gate - Native Approval`

## Approval Gate Pattern

For security review tickets sent to Dorian:

- Trigger on `ticket_action:update` when the rule must apply to both Incidents and Service Requests.
- Gate on `ticket_type includes ["Incident", "Service Request"]`, `group_id = GRC - Security`, `responder_id = Dorian Prescott`.
- Use `approval_status = Not Requested` only when the field is known to exist for the target tickets. Freshly created Incidents may not expose an approval status before the first service approval, so that guard can prevent the initial approval from firing.
- Initial action should request approval from Dorian. Convert Incidents to Service Requests only if the user wants conversion; do not change status unless explicitly requested.
- Approval outcome branches may route back to EUC. Do not change status unless explicitly requested.

## Validation

Read back:

- workflow graph from `/ws/2/admin/ticket_automators/{workflow_id}`
- each node from `/ws/2/admin/ticket_automators/{workflow_id}/node_info?stage_id={stage_id}&wf_node={wf_node}`
- ticket evidence from `/api/v2/tickets/{ticket_id}`, `/approvals`, `/approval-groups`, and `/activities`

Success evidence should include the workflow name in ticket activities, the expected ticket type/group/status, and a requested approval group with the expected approver.

For controlled tests, change a meaningful ticket field such as group/agent assignment to trigger the workflow. Tag-only updates may not execute the native Workflow Automator even when they appear in ticket activities.
