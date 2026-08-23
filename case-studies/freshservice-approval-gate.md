# Case study: Freshservice security-review approval gate

## The problem

Requests with security implications (new software, access grants, exceptions) were reaching fulfillment without a consistent security review. The review existed as a norm — "loop in the security lead" — but norms don't survive busy weeks. It needed to be structural, inside the ticket system, without adding a stage that stalls every ordinary ticket.

## Constraints

- Must run **natively in Freshservice's Workflow Automator** — no external service to host, no webhook infrastructure to maintain, nothing that breaks when a laptop is off.
- Must not change ticket status out from under the assigned team; the gate inserts a decision, it doesn't hijack the queue.
- Ordinary tickets must never see the gate. Only the flagged lane pays the cost.

## The design

A Workflow Automator rule that fires on ticket update, scoped tightly:

1. **Trigger:** Incident or Service Request tickets assigned to the security review group.
2. **Convert:** incidents entering the lane convert to Service Requests, because approvals in Freshservice hang off the SR object model. (This conversion is the non-obvious move; approval blocks simply aren't available on incidents.)
3. **Request approval** from the named security reviewer through the native approval mechanism, so the decision lands in their approval inbox and their email, with full ticket context.
4. **Route on outcome:** approved and rejected tickets both route back to the end-user computing group with the decision recorded on the ticket, and **without changing ticket status** — the assigned team keeps control of the lifecycle; the gate only contributes the decision.

## Things learned building it

- Workflow Automator's condition model rewards narrow triggers. A broad trigger with internal branching re-fires on its own updates; scoping the trigger to the exact group assignment made the rule inert everywhere else.
- The incident-to-SR conversion is invisible to requesters but essential plumbing; documenting *why* it happens saved the next admin from "simplifying" it away.
- Approval actions send their own notifications; suppressing the redundant generic ones kept the reviewer from getting three emails per ticket.

## Where the agent fits

The `freshservice-automation-builder` skill in this repo encodes the whole procedure: the object-model constraint, the trigger-scoping rule, the notification cleanup, and the test sequence (create a synthetic ticket in the lane, walk it through approve and reject, verify routing both ways). Building the *next* automation starts from executable knowledge instead of archaeology.
