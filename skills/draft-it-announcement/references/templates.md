# Templates

Fill the `<angle brackets>`, delete sections that don't apply, keep the rest. Slack mrkdwn
(`*bold*`, `<url|label>`). Each template is generalized from the real posts in `corpus.md`.

---

## Silent rollout

Nothing for users to do; something new appears on the device.

```
Hi Contosonians :contoso:

Over the coming days, the IT team will be rolling out <tool / what it does> :hammer_and_wrench:
to all company devices. This is part of <the program this belongs to> and supports our ongoing
effort to <benefit 1>, <benefit 2>, and support you more efficiently :white_check_mark:

*What to expect:*
• :white_check_mark: The installation will happen quietly in the background - no action needed from you
• :raised_hands: You should not see any pop-ups, interruptions, or reboot prompts
• :computer: Once installed, you may notice a new system tray icon & a new application in your
  start menu. That's it!

Everything else will continue as normal :slightly_smiling_face:

If you see anything unusual or experience behavior that doesn't feel right, please reach out
anytime at servicedesk@contoso.com :envelope_with_arrow:

Thank you for your continued partnership as we strengthen our in-house support capabilities.

- Contoso IT
```

---

## Visible rollout

Users *will* see something. Show them the artifact and tell them it's fine.

```
:information_source: Heads up, everyone - <today / Monday, <date>> we'll be rolling out
<change> across company devices. :computer:

As part of the deployment, you may see <the popup / notification / prompt> appear on your
computer (see the attached image below as an example of what you may see). This is expected
behavior. If it appears, you can simply close or minimize the window. No further action is
required.

The change is intended to improve <benefit>, and no disruption is expected as part of this change.

If you notice anything unusual or run into issues after the rollout, please contact
servicedesk@contoso.com for assistance.

Thank you for your patience and support while we complete this update.
```

Attach the screenshot. "See the attached image below" with nothing attached is the one formatting
mistake that makes a post useless.

---

## Outage notice (planned)

Aim for ~2 days notice. Answer "does this hit me?" per working location.

```
Hi Contosonians! :wave:

:red_circle: UPCOMING OUTAGE | <Day, Month D> | <start> - <end> <TZ> | <site>

<Planned network maintenance> means <plain-language impact> during this window,
<specifics - e.g. Wi-Fi and wired both down while equipment restarts>.

:house: Working <that day>? If working from home: email, Teams, Slack, etc. will work normally.
:office: Need to be in the office? Plan around <impact> <start> - <end>.
:satellite: <Edge case that surprises people - e.g. remoting into a server at that site? Those
   servers will be unreachable during the window, even from home, since they lose network
   connection too. Plan any server work before <start> or after <end>.>

All-clear will be posted here when we're done.
```

## All-clear

Short. Post it as a reply in the announcement's thread, ticking *Also send to #channel*.

```
<Network Maintenance> Complete | <site>
Hi Contosonians! :wave:
Our planned <maintenance> at <site> has been successfully completed, and all services are back online.
```

```
Change is completed and network is back to normal. If you see any issues please reach out to us
by submitting a ticket - servicedesk@contoso.com
```

---

## IT Alert (emergency / same-day)

```
:warning: IT Alert :warning:

Hi Contosonians - we need to perform emergency <maintenance type> tonight, which may require a
brief outage.

:clock1: Start: <H:MM> <TZ>
:clock9: End (estimated): <H:MM> <TZ>

Impact: During this window, you may be unable to access <systems>.

:white_check_mark: Action recommended: Please save your work and plan accordingly before <start>.

If you have questions or are still having trouble after <end>, please reach us at
servicedesk@contoso.com.

Once maintenance is complete, we'll post another update in this channel.

Thank you for your understanding and patience!

- Contoso IT
```

---

## Policy change

Something gets restricted. Lead with the date and time, justify it, give the exception path.

```
Good morning, Contosonians! :slightly_smiling_face:

*<Upcoming Change in <system> - <what>>*

Starting <Day, M/D/YYYY at H:MM PM>, <what will no longer be possible>.

*Why we're making this change*
• Helps protect company data
• Ensures <thing> meets security and compliance standards

*What this means for you*
• Core <system> features will continue to work as normal.
• You won't be able to <specific lost ability> (e.g. <concrete examples users recognize>).
• <Existing X may continue to work for some users; we'll reach out if changes are required.>

*<If you need an exception>*
Please email servicedesk@contoso.com with:
• The <app/thing> name
• A brief description of how you plan to use it

If you have any questions or concerns, contact servicedesk@contoso.com.
```

For a broad baseline change, group the settings under emoji sub-headers - `:closed_lock_with_key:
Security & Locking`, `:floppy_disk: Storage & Cleanup`, `:window: Windows Experience Changes`,
`:zap: Power & Sleep Behavior`, `:package: How to Access the Company Portal`, `:sos: When to
Contact IT` - and state the new default plus how to request an adjustment.

---

## Good-news launch

Earned enthusiasm. Numbered steps the user can follow on the first read.

```
:tada: <Capability> has arrived at Contoso Energy! :tada:

<What it is and the one-line payoff - e.g. If you forget your password or your account is
locked, you will now be able to reset it without waiting for IT.>

<How to do it> :key:
1. <Step>
2. <Step>
3. <Step>

For more detailed instructions, see the attached guide below :arrow_down:

<Any safety caveat - e.g. Never share your password or one-time password code with anyone,
including Contoso IT. If you receive a password-reset notice you did not initiate, contact
Contoso IT immediately.>

Have any questions or still need help? Email servicedesk@contoso.com
```

Licensed/limited rollouts get a gate callout before the steps:

```
:warning: License Required: <App> is only available to employees who have been assigned a
<app> license. If you have not been assigned a license yet, your first step is to submit a
license request before proceeding with installation. Contact servicedesk@contoso.com to
request access.
```

---

## Metric reminder

Repeat weekly. Keep the body byte-identical; change only the number. The moving number is the
whole point - it's social proof and a countdown at once.

```
Contosonians,

Quick weekly reminder about the upcoming <policy> going into effect <date>. <One-line restatement
of the rule.>

Progress update: Last week, <N> accounts would have been expired. Today, that number is down to
<M> - thank you to everyone who have already updated their password!

If you haven't yet, please take a moment this week to get it done so you're not locked out in
<month>.

<Repeat the how-to block verbatim from the original announcement.>

Need help?
Reach out to the IT Service Desk.
```

On the first post of a campaign, use the count as the hook: `:pushpin: If we enabled this today,
<N> accounts would already be expired.`

Day before a hard cutover:

```
:rotating_light: Reminder: <change> goes live tomorrow
Hi Contosonians :wave:
Tomorrow is the day - <restate the change>.
If you haven't <done the thing> yet, please do so as soon as possible to avoid any disruption.
We are aware of a few known issues and have workarounds available. If you run into any trouble,
please reach out to the Service Desk (servicedesk@contoso.com) - we're here to help.
We've also published a knowledge base article with step-by-step guidance, which is attached to
this message.
Thanks everyone for your support as we roll this out. :rocket:
```

---

## Multi-item digest

Several unrelated items, one post. Each item gets an emoji + bold headline and 2-4 lines. One
shared contact footer at the end. Order by how much the reader has to care.

```
:email: *<Item 1 headline>*

<2-4 lines. Link the KB if there's a procedure.>

:rocket: *<Item 2 headline>*

<Lead-in line.>

*What this means for you:*
• <bullet>
• <bullet>

No action is required right now. Just be aware that <what they may see>.

:eyes: *Heads Up: <Item 3 headline>*

<2-3 lines. Recruiting testers? Say what the ask is: "the only ask is that you share your
feedback along the way.">

If you have any questions or run into any issues, please contact the IT team at
servicedesk@contoso.com.
```

Variant: the color-coded triage digest, when the items differ in urgency rather than topic - one
`<color> <STATUS> | <date> | <scope>` header per item, then the detail lines. See the status-line
format in `voice-and-formulas.md`.

---

## Progress update (phased program)

```
:rotating_light: <Program> Update: <from> to <to>

Hi everyone,

Here's the latest update on the ongoing <program>.
We will continue to share updates as each <phase unit> completes. <Where future updates will be
posted, if it's changing.>

:white_check_mark: Recently Completed
• <item>
  <Access details / guidance doc link.>

:large_green_circle: Completed <units>
• <item>
• <item>

:large_yellow_circle: In Progress
• <item>

Thank you for your support during this transition. Please reach out to IT
servicedesk@contoso.com if you have any questions or need assistance.
```

---

## Program kickoff (the long one)

For a multi-month change with real user impact, the corpus uses a full expectation-setting post:
`:spiral_calendar_pad: Key Dates` → `:wrench: What's Changing` → `:warning: What You Might
Notice` → `:white_check_mark: What You Should Not Notice` → `:shield: How We're Minimizing
Impact` → `:sos: How to Get Help` → `:pray: Thank You`.

The two sections that earn the trust are the honest ones: name the specific temporary annoyances
under *What You Might Notice* (with an apology and a "tell us if it slips through the cracks"),
and commit to the non-negotiables under *What You Should Not Notice* (access to email, files,
core apps; credential changes without IT contacting you first) with "If any of the above does
happen, please let us know right away."

Escalation block worth reusing verbatim:

```
:sos: How to Get Help
:e-mail: Email servicedesk@contoso.com
:memo: Open a ticket via New Ticket
:frame_with_picture: Include screenshots or error messages if possible
:rotating_light: For urgent issues, use "URGENT - " in the subject
```
