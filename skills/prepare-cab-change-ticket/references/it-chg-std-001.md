# IT-CHG-STD-001 — Change Ticket Content Requirements (v1.0)

Contoso Energy IT Standard | Information Technology / Change Advisory Board
Parent policy: Contoso Energy Change Management Policy (IT-CHG-000) | Review cycle: annual
Applies to: all Contoso Energy employees, contractors, and third parties who submit or
review IT change tickets.

Captured 2026-07-02 from `contoso_Change_Ticket_Content_Requirements_v2.docx`
(issued by Dorian, GRC/CAB Manager). If a newer version of the standard exists, it
supersedes this file.

## 1. Purpose

Defines the minimum content requirements for all IT change tickets submitted in
Freshservice — not just which fields to complete, but what each section must actually
communicate. A complete ticket lets the CAB assess and approve efficiently, lets any
qualified engineer execute the change from the ticket alone, and provides an audit trail
traceable to business objectives.

A standard defines minimum requirements — the "what." It is not a policy (direction and
accountability) or a procedure (step-by-step how-to).

## 2. Scope

All change types under IT-CHG-000: normal, urgent, emergency, standard, informational.
Applies to everyone who submits, reviews, approves, or implements changes to Contoso IT
systems, applications, infrastructure, security configurations, and cloud environments.

## 3. Standard statement

Every change ticket must contain sufficient information for a reviewer with no prior
knowledge to fully understand:

- What is changing and why
- What a successful outcome looks like
- What risks exist and who is affected
- How the change will be executed, step by step
- What will happen if the change fails
- Who has been notified and when

Tickets that do not meet these requirements are returned by the CAB Manager with a note
on what is missing. Changes must not proceed until the ticket is complete and approved
per the applicable change type.

## 4. Core content requirements (all change types)

Every section must be substantive; a one-line entry is not sufficient.

### 4.1 What is changing and why

Plain language — a title or system name alone is not sufficient. Must answer:

- What specific system, service, configuration, or process is being changed?
- What is the reason or business need driving this change?
- What problem does it solve, or what improvement does it deliver?
- Is it tied to an incident, problem record, project, or compliance requirement?
  If so, reference it.

### 4.2 Definition of success

Must answer:

- What is the expected outcome once the change is complete?
- How will you verify the change worked (tests, checks, monitoring, user confirmation)?
- What state should the system or service be in when the change is done?

### 4.3 Risk and impact assessment

Risks must be thought through, not just acknowledged. Must answer:

- What could go wrong during or after this change?
- Which users, teams, systems, or services could be affected if something fails?
- Is there any expected downtime? If so, when and for how long?
- What is the risk level (Low / Medium / High / Very High), with documented rationale?
- Are there dependencies on other systems, teams, or scheduled events?

Risk level definitions (emergency changes are automatically Very High — no selection):

| Risk level | Definition | Typical change type |
|---|---|---|
| Low | Non-critical system or small number of users. No downtime expected. Rollback straightforward and fast. Failure causes minor inconvenience, no business disruption. | Standard |
| Medium | Business system or moderate number of users. Brief downtime may occur in a maintenance window. Rollback possible but may take time. Failure causes noticeable disruption to a team or process, not a full outage. | Normal |
| High | Critical system, core infrastructure, or large number of users. Downtime expected or likely if something goes wrong. Rollback exists but may be complex. Failure causes significant business disruption or degradation. | Normal or Urgent |
| Very High | Mission-critical system where failure means full outage, data loss, security kilbourne, or regulatory impact. Downtime has direct business/financial consequences. Rollback may be difficult or have a point of no return. | Urgent or Emergency (auto) |

### 4.4 Implementation plan

Detailed enough that another qualified engineer could carry out the change from the
ticket alone. Vague plans ("deploy update", "apply patch") are not acceptable. Must
answer:

- What are the step-by-step actions, in order?
- Who is responsible for each step if multiple people are involved?
- What is the planned start time, end time, and maintenance window?
- What prerequisites must be completed or confirmed before the change begins?

### 4.5 Rollback plan

Mandatory on ALL change tickets. Must answer:

- At what point during execution would you decide to roll back (trigger criteria)?
- What are the step-by-step actions to revert the change?
- How long will a rollback take? Is there a point of no return?
- Have backups, snapshots, or restore points been confirmed and are they accessible?

### 4.6 Stakeholder communication

A requirement of the standard, not a courtesy — applies even when expected impact is
minimal. Must answer:

- Which teams or individuals are affected by this change?
- Were they notified in advance? When and through what channel?
- Did any stakeholder need to provide approval before the change could proceed?
- After the change, who was notified of completion and when?

## 5. Additional requirements by change type

| Change type | Additional content required | Approvals required | Timing |
|---|---|---|---|
| Normal | Peer review sign-off documented before CAB submission; post-implementation review (PIR) notes added after completion | CAB approval | Submit by Monday 12 PM; changes may begin Tuesday 5 PM after CAB |
| Urgent | Name and description of the critical incident requiring urgent action; reference to the triggering incident ticket; PIR completed and documented after execution | Senior Director of IT or delegate — before execution | Approval required prior to execution |
| Emergency | Specific description of the outage or critical failure being prevented; actual start and end times recorded in the ticket | Senior Director of IT or delegate — expedited | Immediate; approval obtained as quickly as possible |
| Standard | Reference to the pre-approved standard change template used; note of any deviations from the defined repeatable process | Pre-approved; no CAB review | No CAB submission deadline; proceed per defined process |
| Informational | Vendor name and description of the vendor-initiated change; confirmation that advance stakeholder notification was sent before ticket creation; CAB classification as informational noted in the ticket | CAB classification required (reviewed post-implementation) | Notify stakeholders before creating the ticket |

Urgent vs emergency (CAB Manager clarification): urgent changes are approved, then
executed; emergency changes are executed and approved at the same time, or approval
follows immediately after.

## 6. Roles and responsibilities

- **Requesters** — ensure the ticket meets Sections 4 and 5 before submission; complete
  peer review before submitting normal changes to CAB; respond promptly to CAB
  inquiries; communicate change details to affected stakeholders and document it in the
  ticket; complete and document the PIR where required.
- **CAB Manager** — reviews tickets for completeness before the CAB meeting; returns
  incomplete tickets with specific notes; ensures correct change type categorization and
  approval path; archives CAB meeting records per retention requirements.
- **CAB Members** — evaluate quality and completeness during review; request
  clarification before approving; document dissenting opinions or conditions of approval
  in the ticket.
- **IT Leadership** — provides pre-execution approval for urgent and emergency changes;
  reviews patterns of incomplete or returned tickets and escalates recurring issues.

## 7. Compliance and enforcement

- Changes that do not meet content requirements are returned by the CAB Manager and
  must not proceed until complete and approved.
- Repeated submission of incomplete tickets may result in escalation to IT leadership
  and disciplinary review.
- Exceptions require written approval from the Senior Director of IT, documented in the
  corresponding change record.
- All change records are retained in Freshservice for a minimum of 24 months per
  IT-CHG-000.

## 8. Definitions

| Term | Definition |
|---|---|
| CAB | Change Advisory Board — reviews and approves normal and informational change requests at Contoso Energy |
| CHN | Change ticket identifier assigned by Freshservice to each change request |
| Freshservice | The ITSM platform used to log and track all change requests (contoso.freshservice.com) |
| PIR | Post-Implementation Review — post-change assessment confirming the outcome, documenting lessons learned, and closing the ticket |
| Rollback plan | Documented, step-by-step procedure to revert a change and restore the prior state |
| Requester | The individual responsible for submitting and documenting a change request in Freshservice |

## 9. Related documents

- Contoso Energy Change Management Policy & Checklist (IT-CHG-000) — parent policy
- Freshservice change management: contoso.freshservice.com
