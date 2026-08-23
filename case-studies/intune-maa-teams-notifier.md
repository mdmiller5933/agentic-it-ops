# Case study: Intune Multi Admin Approval → Teams notifier

## The problem

Intune Multi Admin Approval (MAA) is good governance with a bad feedback loop: when one admin submits a protected change, the approving admins find out by... checking the portal. Approvals sat for hours-to-days not because anyone objected but because nobody knew they existed. Change control was quietly becoming change *friction*.

## The automation

A scheduled job that:

1. Authenticates to Microsoft Graph **app-only, with a certificate** — no user account, no stored password, and an app registration scoped to exactly the Intune read permissions the job needs and nothing else.
2. Reads pending `operationApprovalRequests` (the MAA queue).
3. Diffs against what it has already announced, so each request is posted once, not every run.
4. Posts an adaptive card into a dedicated Teams group chat for the approver group: who requested what change, on which object, how long it's been pending, and a deep link to the approval.

Runs on a schedule; the interesting engineering is all in the edges.

## Edges that mattered

- **Least privilege took iteration.** The same app identity later got asked (by other tooling) to read directory objects it had no business reading; the 403s were correct, and keeping the notifier's app narrowly Intune-scoped meant a compromised credential would be boring. The failure mode of over-scoped automation identities is the quiet one.
- **Dedup state has to live somewhere durable** or a restart re-announces the whole queue. Announced-request IDs persist across runs.
- **A silent notifier is indistinguishable from a healthy quiet day.** The runner has a health path (the agent skill includes "verify the notifier is alive" as a first-class operation), because the worst state for an approval pipeline is a notifier that died three weeks ago with nobody noticing.
- Approvals themselves stay human. The bot announces; it holds no approval permission at all. Announcement and authority deliberately never share an identity.

## Result

Pending approvals became a chat message approvers see within minutes, and MAA stopped being a reason to batch changes into risky bundles. Governance kept its second pair of eyes; the pipeline lost its stall.

## Where the agent fits

`run-intune-maa-teams-notifier` in the skills catalog wraps operating this: checking the queue on demand, posting missed cards, and the health checks. The scheduled job does the routine work; the skill makes the exceptional work (why didn't X get announced?) a one-prompt task.
