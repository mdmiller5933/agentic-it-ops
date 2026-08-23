# Corpus

The posts this skill was derived from. Read one or two before drafting a new post of the same
type - the phrasing bank in `voice-and-formulas.md` is faster, but the real posts show pacing
and how much detail is enough.

Author: Esme Oakhurst, Manager of End User Compute (Slack `U08EQ2LP733`,
`esme.oakhurst@contoso.com`, America/Chicago).

**Refresh the corpus** - this list is complete as of 2026-08-04. For anything newer, search Slack
for the most recent broadcast posts and read the top results:

```
from:<@U08EQ2LP733> in:#general
```

Sort by timestamp, descending. Same query with `in:#help-it` for the cross-posts (near-duplicates
of the `#general` set). Prefer the newest posts when they conflict with anything written here.

## All-company announcements, newest first

| Date | Type | Subject | Notes on form |
|---|---|---|---|
| 2026-07-30 | Good-news launch | Self-Service Password Reset live | `:tada:` bookends, 5 numbered steps, security caveat, attached guide |
| 2026-07-14 | Multi-item digest | All-Employees email access · Claude auto-updates · new ChatGPT version | Three emoji+bold items, one shared footer; `*What this means for you:*` bullets |
| 2026-07-13 | Visible rollout | Cato Always-On rollout day | Posted as a reply in the July 9 thread; "This is expected behavior" |
| 2026-07-11 | All-clear | Houston network maintenance complete | Three lines total; reply in the July 9 thread |
| 2026-07-09 | Color-coded digest | Outage July 11 · Cato Monday · monitor flickering | The `<color> <STATUS> \| <date> \| <scope>` format; per-location impact lines |
| 2026-05-20 | Cutover reminder | Slack SSO goes live tomorrow | "Tomorrow is the day", known-issues acknowledgment |
| 2026-05-14 | Policy change + launch | Slack SSO / Business+ upgrade | `:key: What's changing` / `:calendar: What to expect` / `:white_check_mark: What you need to do` / `:sparkles: What's new` |
| 2026-04-07 | Progress update | Google Drive → SharePoint migration | Completed / In Progress lists; announced that updates move to `#help-it` |
| 2026-03-26 | Good-news launch | Claude Desktop install instructions | `:warning: License Required` gate before the steps |
| 2026-03-19 | IT Alert + all-clear | Emergency network maintenance, 8-9 PM CDT | ~2.5 h notice; `:clock1:`/`:clock9:`; all-clear posted 21:17 same night |
| 2026-03-10 | Program update | Stop sending IT requests to The20 | "Effective immediately"; autocomplete-cleanup tip; timeline pulled in from 3/15 to 3/12 |
| 2026-03-05 | Visible rollout | Automox patching agent | Explains both popup types and each deadline (9 h apps / 24 h restart) |
| 2026-02-20 | Policy change | Intune Windows Security Baseline | Grouped emoji sub-headers per settings area; "Adjustments can be requested" |
| 2026-02-12 | Silent-ish rollout | Company Portal app | "Why we're rolling it out" benefits; screenshot |
| 2026-02-05 | Temporary mitigation | Old Google Calendar invites held | "What this means for you" + "we'll remove this temporary block" |
| 2026-01-28 | Silent rollout | Cato VPN (standby mode) + CrowdStrike | Canonical silent-rollout wording; "deployed in standby mode" |
| 2026-01-22 | Maintenance notice | Weekend email system change | Four lines; no expected impact, no action needed |
| 2026-01-21 | Policy change | Teams third-party app store disabled | Effective date+time, why, exception path with required fields |
| 2026-01-20 | Silent rollout | Remote support tool (ScreenConnect) | The template the later silent-rollout posts reuse |
| 2026-01-14 | Program kickoff | The20 → in-house IT transition | The long trust-building post: Key Dates / Might Notice / Should Not Notice / Minimizing Impact / Get Help / Thank You |
| 2025-12-23 | Metric reminder | Password expiration - week 3 | Same body as 12-08, number moved 10014 → 122 |
| 2025-12-08 | Metric reminder | Password expiration - week 2 | Same body as 12-01, number moved 172 → 10028 |
| 2025-12-01 | Policy change | Password expiration policy (180 days) | `:pushpin: If we enabled this today, 172 accounts would already be expired.` |
| 2025-11-05 | Security update | Sandblast Threat Extraction retired | "the dreaded ... banners"; "This does not mean you can lower your guard" |
| 2025-11-03 | Cutover reminder | Zoom Pro licenses removed tomorrow | Exception path via Freshservice catalog item; notes ELT approval needed |
| 2025-10-27 | Maintenance notice | Lenovo firmware updates | Short; save work, reboot after |
| 2025-10-20 | Live incident | AWS outage impacting email | No ETA stated honestly; "the team is monitoring" |
| 2025-10-07 | Good-news launch | Brex SSO | `:one:`-`:four:` steps, "Boom - you're in!", mobile version caveat, open invitation for more SSO apps |
| 2025-09-17 | Good-news launch | ChatGPT SSO enabled | Numbered steps + full KB doc link |

## Channels he uses, and how

- `#general` (`C8UEK0E7N`) - all-company broadcast. The announcement corpus above.
- `#help-it` (`C01UKU0HKS4`) - verbatim cross-post of each announcement, plus day-to-day support
  replies and IT-team FYIs (e.g. dropping `status.claude.com` during a vendor outage). Users were
  explicitly asked to subscribe here for centralized updates (2026-04-07).
- `#tailscale-workstation`, `#ai-think-ai-can`, `#houston-social-club` - project, community, and
  social. **Not** announcement channels; different, casual register. Don't apply this skill there.

## Support-reply register (for reference, not announcements)

In `#help-it` threads his replies are short, name the person, commit to a next step, and route to
a ticket when tracking matters:

```
Hi Dale, happy to follow up. I will reach out once i know more about this.
We can certainly help with that. Bare with us @<name> as we work through our internal filtering options.
Hi Ari, The owners of the sharepoint can do that but IT also is able to do so. I will send a
note to the team to have this access granted. in the mean time can you please spin up a ticket so
that we can follow up and properly track this request.
Hi , welcome aboard! Please submit a ticket to servicedesk@contoso.com and we'll reach out to assist.
Roger. We will investigate it further and let you know.
```

Note the register difference: announcements are polished and structured; thread replies are fast,
lowercase-tolerant, and occasionally typo'd. Don't "correct" a support reply into announcement
prose - and don't let announcement drafts inherit the looseness.
