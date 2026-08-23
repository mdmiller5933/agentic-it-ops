# FedEx Ship Manager (ShippingPlus) web flow

Walkthrough captured 2026-08-05 by driving the live site end to end and stopping at the
purchase button. Use this when creating a label through the browser instead of the Ship API.

Entry: `https://www.fedex.com/shippingplus/en-us/shipment/create`
(also reachable from the logged-in home page > Quick links > **SHIP A PACKAGE**).

The page needs roughly 10-15 seconds to hydrate. A right-hand rail tracks the eight sections and
is the reliable source of truth for progress and current values — read it to confirm state rather
than trusting that a click landed.

## Automation gotchas — read before writing any selector

1. **Field IDs are randomly regenerated on every render.** Observed: `fedex-input-text-field-408197`,
   `fedex-input-address-search-553737`, and a GUID on the shipment-type select. Never hardcode an
   id, name, or index. Locate every field by its visible label text.
2. **COUNTRY/TERRITORY does not default.** It reads `undefined` on a fresh form even though it is
   required. Set it explicitly and set it *before* the address fields — choosing United States
   relabels POSTAL CODE to ZIP CODE and adds a STATE OR PROVINCE field.
3. **STATE auto-fills from the ZIP** once country is United States — but only when the ZIP was
   entered as real keystrokes (see gotcha 7). A programmatic ZIP write does not trigger the
   lookup, and STATE stays `undefined`; set it explicitly in that case.
4. **CITY is an autocomplete, not a text box.** Typing "Houston" is not enough — the suggestion
   must be clicked or the field stays empty and the section will not advance.
5. **Screenshot capture times out often** on this SPA (`Page.captureScreenshot` CDP timeout).
   Prefer reading page text, the accessibility tree, or DOM introspection; fall back to
   screenshots only for visual confirmation.
6. Each section has its own **NEXT** button whose caption names the next section ("to 'Service'"),
   which is a cheap way to confirm the form actually advanced.
7. **Programmatic value writes do not register with Angular** (verified 2026-08-12). Setting
   `input.value` via the native setter, or via a harness's DOM-level form-fill helper, leaves the
   control `ng-pristine`: the text is visible on screen and the character counter updates, yet the
   model is empty, so the section refuses to advance and shows "<Field> is required" / "The
   required information was not filled in correctly" / "Invalid address." The only reliable entry
   is: real click on the field, real typing, then **Tab to blur** — the blur is what commits.
   Verify per field with `ng-dirty` in its class list before trusting it; `ng-pristine` means the
   value is cosmetic. This is the single biggest time sink on this form.
8. **Measure each field's coordinates immediately before clicking it.** Filling one field inserts
   a character counter or error line beneath it and pushes every later field down, so a batch of
   clicks computed from one measurement lands on the wrong rows partway through. Also click the
   field's **value line, not its label** — the input box is ~50px tall and its top half is the
   label, so the rect centre from `getBoundingClientRect` can land on the label and focus nothing.
9. **Toggle ids (`form-field-N`) are reassigned per render.** On one render `form-field-5` was
   "Email outbound shipment label"; on the next it was "Add shipment references" and the email
   toggle had become `form-field-4`. Always resolve toggles by their label text, then re-read
   every toggle's checked state after clicking, because turning the wrong one on reveals extra
   fields and shifts the rest of the section.
10. **Leaving a step with pending edits raises a "You have unsaved changes" modal** (UPDATE /
   DO NOT UPDATE / CANCEL). UPDATE commits the step and continues. If it is dismissed or missed,
   the edit is silently discarded — which is easy to mistake for the write never landing.

## Section sequence

**1. Ship from** — pre-filled from the signed-in account (Avery Operator, 811 Main St). Use EDIT
only to override the from-address for one shipment.

**2. Deliver to** — check **SEARCH IN ADDRESS BOOK** first; repeat recipients may already exist.
Fields: CONTACT NAME\*, COMPANY, STATE TAX ID/I.E., PHONE NUMBER\*, PHONE EXTENSION, EMAIL,
COUNTRY/TERRITORY\*, ADDRESS LINE 1\*, ADDRESS LINE 2, ADDRESS LINE 3, ZIP CODE\*,
STATE OR PROVINCE\*, CITY\*, and a **This is a residential address** checkbox.
Also here: **PERFORM ADDRESS CHECK** (validate before paying) and **SAVE AS NEW RECIPIENT**.

**3. Package details** — a **Ship with FedEx One Rate®** toggle, PACKAGING\* (default
"Your Packaging"), a higher-liability checkbox, then a per-package row of PACKAGES\*, WEIGHT\* (lb)
and DIMENSIONS L x W x H (in). Weight is required; dimensions are not. **ADD PACKAGE OPTIONS**
holds hazmat / dry ice / batteries / non-standard packaging. **ADD NEW PACKAGE** for multi-piece.

**4. Service** — SHIP DATE\* (defaults to today), then radio options grouped by delivery date with
**live negotiated rates for the real account**. Example for a 5 lb parcel, Houston to Houston:
Ground $13.96 next-day End of Day, Standard Overnight $36.91, Priority Overnight $40.12,
2Day $24.24, Express Saver $21.83. Selecting one populates expected delivery and estimated total
in the right rail. Unlike the residential/Ground rejection the Ship API returns, the web form
simply prices whatever is valid — the service list is already filtered to what the address allows.

**5. Service options** — all toggles, all off by default: Signature options, Hold at location,
Add shipment references, **Email outbound shipment label**, Include a return label. Turning on
*Email outbound shipment label* reveals one required EMAIL field and mails the label straight to
that address, which is the cleanest way to fulfill someone else's label request — no PDF to
download, attach, or store.

**6. Pickup/drop-off** — defaults to **"I'll drop off my shipment at a FedEx location"**, not a
courier pickup. Confirm this matches intent. It shows the nearest drop box (with a Nearest /
Latest opening hours switch), that location's last onsite pickup time, and its package
restrictions (the 811 Main drop box caps at 55 lb and 20 x 12 x 6 in). The alternatives are
"I have already scheduled a pickup at my location" and "Schedule a new pickup" — the latter
books a real courier visit, so treat it as a production action and confirm first.

**7. Notifications** — a single **Add shipment notifications** toggle, off by default.

**8. Billing details** — BILL TRANSPORTATION COST TO\* (Recipient | My account | Third-party |
Collect, Authorized Ground Accounts only), defaulting to **My account**, plus a
Bill duties, taxes and fees to selector. Bill to Recipient or Third-party when the requester's
cost centre should carry the shipment rather than IT's.

## Inbound / return labels (someone else ships to us on our account)

Common case: a departing employee or contractor returns a laptop. Sam-style requests give the
*destination* first, so confirm which end is which before building — a label from 811 Main to
811 Main is the failure mode.

Do NOT switch the top dropdown to Return shipment. Stay on **Outbound shipment** and override the
sender: right rail > **Ship from** > **EDIT**, replace the contact and address with the person who
will hand the box over, then **UPDATE**. Verified working 2026-08-05. Note that entering a section
via EDIT changes its button from NEXT to **UPDATE**; the flow otherwise continues normally.
Mark the sender residential when it is an apartment — it is also what makes the drop-off list
resolve near *them*, not near the office. Leave **SET AS DEFAULT** alone; it would permanently
change the account's default ship-from.

## Address book: assume it is nearly empty

Verified 2026-08-05: the account's saved contacts held only 12 entries, all Contoso field sites
(Riverton, Reno, Cedar City, Oakland, Las Vegas, Brewster, Salt Lake City) — no Houston/811 Main
entry and no IT staff. Search matches saved recipients only; it will not fuzzy-match a first name
or fall back to the Microsoft 365 directory. Do not promise a phone number or address from "the
address book" without checking, and note that Contoso email signatures carry no phone number either,
so a missing phone usually has to come from the user. Open the full list via the small
**Saved contacts** icon beside the search box rather than trusting the inline search.

## Notifications

**Notifications > Add shipment notifications > ADD EMAIL ADDRESS** offers Recipient / Shipper /
Other email address. Picking Recipient does **not** auto-populate the address from the recipient
record — the EMAIL field renders blank and must be typed. Then tick the five *Notify for* boxes
individually; there is no select-all: shipment created, received by FedEx, updates on estimated
delivery, delivered, and delivery exceptions. "Notify them about everything" means all five.

## The purchase step

**VIEW SUMMARY** opens a "Let's review your shipment" panel listing every section, expected
delivery, estimated total, and a **View breakdown** link. Its **FINALIZE** button is the
purchase — clicking it buys a real, billable shipment and accepts the FedEx Terms of Use and
Service Guide on the user's behalf. Never click it without the user's explicit go-ahead for that
specific shipment and price. **SAVE** beside it stores the draft without buying; **RESET FORM** in
the top toolbar clears a walkthrough cleanly.

## "Email outbound shipment label" silently sends nothing if the address didn't commit

The toggle and the EMAIL address behind it commit **independently** (verified 2026-08-12). Turning
the toggle on is a real click so it always registers, but if the address is written
programmatically it stays `ng-pristine` per gotcha 7 — and the review panel still cheerfully lists
"Option(s): Email outbound shipment label", because that line reflects the toggle, not the address.
The shipment finalizes, the label is valid and billed, and **no email is ever sent**. The only
tell before purchase is `ng-dirty` on the EMAIL input; `invalid: false` is not sufficient, since an
empty optional-looking field is not "invalid". Check the email field the same way as every other:
click, type, Tab, confirm `ng-dirty`.

There is **no resend option** on a finalized shipment, so this is only recoverable by hand:

1. Left nav > **Shipments** (a button, not a link — `/shippingplus/en-us/shipments-overview/all-shipments`
   is the real route; `/shipments` and `/shipments/history` both redirect to the create form).
2. Find the row by recipient + tracking id, click its **⋮** kebab.
3. **Print documents > Shipping label(s)** — this is the label. The sibling **Download ▸** submenu
   is a decoy: it only offers "Shipment report (.xlsx)" and "120 transaction report (.out)".
4. The label opens in a new tab as a `blob:` URL (~38 KB `application/pdf`). To get it on disk
   without moving bytes through the agent, run in that tab: fetch the blob URL, build an
   `<a download="...">` on the object URL, click it — it lands in the browser's download folder.
5. Verify the PDF is the right shipment before sending it anywhere. The rendered label is rotated
   180°, but destination ZIP + service ("84101 SLC", "** 2DAY **") usually disambiguates, and the
   TO block gives the recipient name outright.

Repeated clicking of the left-nav **Shipments** button can wedge the renderer (screenshots and
script injection both time out for minutes). Recover with a brand-new tab rather than reloading.

## Second label to the same address — do NOT use REPEAT SHIPMENT

The finalized-shipment page offers **REPEAT SHIPMENT**, which looks like the cheap way to produce a
near-identical label for a different recipient. It is a trap for a changed **contact name**
(verified 2026-08-12): it clones the shipment and drops you on Billing details, but editing
Deliver to via the rail's EDIT renders **no in-section UPDATE button**, so the new name never
commits — the rail and the review panel keep showing the original recipient, and FINALIZE would
buy a second label addressed to the wrong person. Changing the *service* through the same rail EDIT
does commit (via the unsaved-changes modal), so a repeat is only safe when the recipient is
unchanged. For a different person, build from scratch at `/shipment/create`; it is fewer steps than
diagnosing the clone.

Always re-read the review panel's "Deliver to" line against the intended recipient immediately
before FINALIZE. That panel is the last honest view of what will actually be purchased.

## Session additions (verified 2026-08-19, Riverton labels 876016132037 / 876016964685)

1. **The Saved contacts slide dialog can stay open invisibly and eat every click/keystroke on the
   form.** Its Close button, Escape, and synthetic clicks all failed; the reliable close is
   `document.querySelector('dialog.fdx-c-dialog-slide').close()`. Tell: typing lands nowhere and
   `document.elementFromPoint(<field center>)` returns `DIALOG#slide`. Check that before blaming
   Angular.
2. **Verify geometry immediately before every fill pass.** Two separate shifts each silently
   swallowed a full fill batch: (a) setting COUNTRY re-renders the section and the typed text that
   raced it is lost; (b) Chrome's download bar shrinks the viewport and the app's sticky toolbar
   then covers the top form rows — clicks "on" a field hit the toolbar instead. Also, a click at
   coordinates below the viewport bottom silently no-ops (an off-screen UPDATE button absorbed two
   "clicks" this way). Confirm with elementFromPoint/activeElement, not with the click result.
3. **JS-measured CSS px → screenshot px conversion:** multiply by (screenshot width / innerWidth),
   ~0.82 at 1912. Recompute after any download starts (viewport height changes 948→901).
4. **Ground shares the delivery-date card with Express Saver** (both "Monday"): the Ground radio
   input is 1x1 hidden and label-rect measurement collapses to the card, so a click computed from
   it selects Express Saver. Click the visible "FedEx Ground®" text instead, then re-read which
   radio is checked and the rail total before moving on.
5. **Re-entering a completed step via the rail's EDIT flips every later section into
   Update-gated edit mode** — the footer button is UPDATE (caption still names the next section),
   so `/^next/` button searches find nothing and the flow looks stuck.
6. **Text fields often read `ng-pristine` even when the value committed** — the class lags/lies on
   this form. The working loop: real click → type → read value back; treat the section NEXT
   button as the actual validator, and only re-enter a field when NEXT complains. (ADDRESS LINE 1
   passed validation while still reading pristine.)
7. **Getting the label PDF without the kebab dance:** on the finalized page, a synthetic `.click()`
   on the "Shipping label(s)" row's **Download** anchor works (coordinate clicks often miss) and
   saves `<ISO-timestamp>-FedEx-Shipping-Label.pdf` into the browser's Downloads folder. Label
   PDFs have **no extractable text** (vector glyphs), so verify by provenance: download each label
   on its own finalized page before creating the next shipment. Harness JS results BLOCK base64,
   so blob-to-chat extraction is not an option.
8. **Address book reality for field sites:** the two Riverton entries are other addresses
   (167 N 400 W; 3969 Jon Ulrich Dr) — the North Field site address `1345 N Highway 257,
   Riverton UT 84751` is NOT saved. Convention on prior field-site shipments: recipient phone =
   Avery's cell 2818810272. ZIP 84751 autofills STATE=UT but leaves CITY empty (autocomplete
   dance required). The 811 Main drop box warns 20x12x6in max — fine to ignore when the shipper
   will use a staffed FedEx location.
9. **Native SELECTs (country) accept programmatic set + change event** — `sel.value=...;
   sel.dispatchEvent(new Event('change',{bubbles:true}))` commits and goes ng-dirty; keyboard
   type-ahead into the select did NOT. Rates quoted 8 lb Houston 77002 → Riverton UT 84751,
   2026-08-19: Ground $22.39 (Mon EOD, 3 business days), Express Saver $52.82, 2Day $71.12,
   Priority Overnight $120.93.

## Rate calibration (8 lb, Houston 77002 -> Salt Lake City 84101, quoted 2026-08-12)

Real negotiated rates on the corporate account, useful for sanity-checking a quote and for advising
on service choice: Ground $18.94 (3 business days, End of Day), Express Saver $49.86, 2Day $68.38,
2Day AM $77.10, Standard Overnight $112.21, Priority Overnight $118.77, First Overnight $260.35.
Ground Houston->SLC lands on the 3rd business day, so for a new hire it must ship at least 4
business days before the start date to be useful on day one.

## Reducing the repetition

Before automating a recurring shipment, check the site's own features: **SAVE AS SHIPMENT
TEMPLATE** (top toolbar) for a recurring shape, the recipient address book, and **Batch shipping**
(`/shippingplus/en-us/shipments-import`) for many labels at once. These are less brittle than
driving the form.

## Synthetic vs trusted clicks (verified 2026-08-18, Denver label 875956383540)

1. **FINALIZE silently ignores synthetic `el.click()`.** The click "lands" (no error, panel stays
   open), nothing is purchased, and navigating away to check resets the whole form. Section NEXT
   buttons *do* accept `el.click()` — only the purchase button filters for a
   trusted gesture (VIEW SUMMARY usually takes `el.click()` but was seen ignoring it once on a
   third same-session label; when the panel doesn't appear, re-click via a real input event).
   Always click FINALIZE with a real input event (harness click on the button's
   ref or coordinates). Success is unambiguous: URL flips to `/shippingplus/en-us/shipment/finalized`
   with "Shipment created successfully" + Tracking ID. If neither appears within ~15 s, do NOT
   re-click — open Shipments in a fresh tab and look for the recipient first (double-purchase risk),
   remembering a wedged renderer and a reset form are the likely costs of that check.
1b. **A fresh `/shipment/create` (new tab, or CREATE NEW SHIPMENT on the finalized page) often
   hangs with the shell rendered but zero form inputs** (~25 s+, verified twice 2026-08-18).
   One F5 reload fixes it both ways; re-check that visible `input[class*="ng-"]` count is >0
   before finding refs. ZIP→City autofill is inconsistent (80220 filled DENVER, 84751 left City
   empty) — always verify City and fill via the autocomplete (type, pause, ArrowDown, Enter)
   when blank.
2. **The service-options EMAIL field needs the entry done twice.** First real-keystroke pass leaves
   the visible value but `ng-pristine` (the control re-renders and swaps elements under the typing).
   Recipe that commits reliably: click the field again → Ctrl+A → Delete → retype → confirm
   `ng-dirty` while still focused → Tab. Same double-entry quirk did not affect the Deliver-to
   text fields.
3. **Navigating away from `/shipment/create` discards the entire draft** (no unsaved-changes
   prompt). Use SAVE first if the form must be left, e.g. to check the Shipments list.
4. **City/State autofill from a real-keystroke ZIP is model-committed** even though the controls
   read `ng-pristine` — the app wrote them itself; the section advances fine. Pristine is only a
   red flag for values *you* typed.
5. **"Use suggested address" in PERFORM ADDRESS CHECK rewrites ZIP to 9 digits and resets fields
   to pristine** — that write is the app's own and passes validation; don't redo the fields.
6. Houston 77002 -> Denver 80220 residential, 3 lb, quoted 2026-08-18: Home Delivery $19.62
   (2 business days), Express Saver $28.45, 2Day $33.90, 2Day AM $39.54, Standard Overnight
   $73.83, Priority Overnight $84.09, First Overnight $196.14.
