---
name: draft-it-announcement
description: Drafts Contoso IT company-wide Slack communications in the established Contoso IT
  voice - rollout announcements, outage and maintenance notices, all-clear updates, policy
  changes, weekly reminders, and multi-item IT digests for #general and #help-it. Use when
  the user asks to "write an announcement", "draft a comms post", "announce this to the
  company", "notify everyone", "post an outage notice", "send a maintenance notice", "write
  the all-clear", "draft a heads up for Slack", asks how to tell users about a change they
  will see, or mentions Contosonians/Contosorians. Drafts only - posting to Slack needs explicit
  approval each time. For Word/PowerPoint brand deliverables use the WKS-5063 skill.
---

# Draft a Contoso IT Announcement

House style for Contoso IT's all-company Slack comms, reverse-engineered from the Manager of
End User Compute's posts (22-post corpus, 2025-09 through 2026-07; see `references/corpus.md`).
Match this voice whether the user drafting is the original author or someone covering for IT.

## Where it goes

| Channel | ID (verified 2026-08-04) | Role |
|---|---|---|
| `#general` | `C8UEK0E7N` | All-company broadcast. Primary. |
| `#help-it` | `C01UKU0HKS4` | Identical cross-post. IT's own channel; users are told to subscribe here for centralized updates. |

Post the **same text, verbatim** to both within the same minute (`#general` usually first by
~15 s). Never `@channel` / `@here` - the corpus has zero instances; reach comes from the
channel, not a ping.

**Close the loop, always.** Every outage or maintenance notice ends with a promise ("All-clear
will be posted here when we're done"), and that all-clear is always posted. Follow-ups go as
**replies in the original announcement's thread** (the July 11 all-clear and July 13 day-of note
are both replies to the July 9 digest) - tell the user to tick *Also send to #channel* so the
all-clear reaches people who aren't following the thread.

## Pick the shape

| Situation | Template in `references/templates.md` |
|---|---|
| Software/agent landing on devices, nothing for users to do | **Silent rollout** |
| User-visible change (popup, new icon, new lock behavior) | **Visible rollout** |
| Planned outage or maintenance window | **Outage notice** → **All-clear** |
| Emergency/same-day maintenance | **IT Alert** |
| Policy tightening (passwords, app installs, baselines) | **Policy change** |
| New capability / SSO enabled / self-service unlocked | **Good-news launch** |
| Nagging toward a deadline, repeated weekly | **Metric reminder** |
| Several unrelated items at once | **Multi-item digest** |
| Long program with phases (migrations) | **Progress update** |

## Universal skeleton

1. **Emoji + bold headline** - `:tada:`, `:lock:`, `:warning:`, `:rocket:`, `:email:`, `:mega:`.
2. **Greeting** - "Hi Contosonians! :wave:" and variants (`references/voice-and-formulas.md`).
   Both *Contosonians* and *Contosorians* appear in the corpus; 2026 posts favor **Contosonians**.
   Ask the user which they want if it matters; there's a custom `:contoso:` emoji too.
3. **One-line what and when** - name the system, name the date/window, in plain words.
4. **Emoji-headed sections**, only the ones that apply, in this order:
   *What's changing* → *Why we're making this change* → *What to expect* → *What this means for
   you* → *What you need to do* → *What you should not notice* → *How to get help*.
5. **Reassurance** - "No action is required from you." / "This is expected." / "That's it -
   everything else continues as normal." Never let a user wonder if their machine is broken.
6. **KB link** if there's a procedure. Articles live in the IT SharePoint Knowledge Base folder
   (`KB-<AREA>-NNN – Title.docx`); for the exact path see the sharepoint-it-doc-locations memory
   note or the it-operations skill. Link it inline, or say "see the attached guide below
   :arrow_down:" when attaching.
7. **Contact footer** - always `servicedesk@contoso.com`, never a personal address or a
   bare "ask IT". Never publish an announcement without a contact path.
8. **Sign-off** - "- Contoso IT" / "- IT Team" / "- Your IT Team", or a thanks line.

## Voice rules

- **First-person plural, blame-free.** "We're enabling..." Problems are never the user's fault:
  "not your hardware, not your settings."
- **Warm, lightly funny, self-aware.** The recurring bit is "it's me again"; jokes land on the
  annoyance, not on people ("the dreaded reply-all storm", "an ill-timed reboot request :smile:").
  One joke per post, maximum.
- **Emoji as structure, not decoration.** One per section header, one in the greeting. Dense but
  purposeful.
- **Numbered steps** for anything a user performs; **bullets** for what they'll observe.
- **Own the trade-off.** State the annoyance and the reason together, then thank people for it:
  "Thank you for your continued partnership as we strengthen our in-house support capabilities."
- **Encourage tickets even when there's no fix yet** - and say why: "it helps us track how many
  people are affected and prioritize the fix. :ticket:"
- **Em dashes are on-brand here.** The corpus uses them heavily; keep them in this voice even
  though the avoid-ai-writing-tells preference trims them elsewhere.
- Slack mrkdwn: `*bold*`, `:emoji:`, `<url|label>`, `>` blockquote. Not Markdown `**bold**`.

## Hard rules

- **Drafting only.** Produce the text and hand it over. Posting to `#general` or `#help-it` is a
  company-wide, effectively irreversible action - get explicit approval for each post, and prefer
  handing the user the draft to send themselves. Never post because a plan or thread said to.
- **Never announce a change that hasn't shipped or isn't scheduled.** Every corpus post names a
  real date, window, or "over the coming days".
- **Don't invent counts, dates, or ETAs.** Metric reminders quote real numbers ("137 accounts →
  122"); if the user hasn't supplied one, ask or leave a clearly marked `<placeholder>`.
- **No secrets, internal hostnames, ticket numbers, or vendor blame** in an all-company post.
- **Time zones spelled out** - "8:00 PM CDT", not "8 PM".

## Timing (observed)

Planned outage: ~2 days notice. Emergency: ~2.5 hours. Hard cutover: a day-before "tomorrow is
the day" reminder. Deadline campaigns: weekly, same body, fresh number. Post late morning
(09:00-12:00 CT) or late afternoon (~16:10 CT).

## References

- `references/voice-and-formulas.md` - greeting, sign-off, section-header, and reassurance phrase banks; the color-coded status-line format.
- `references/templates.md` - fill-in-the-blank template per comm type.
- `references/corpus.md` - the real posts with dates and permalinks, plus the search query to refresh the corpus.
