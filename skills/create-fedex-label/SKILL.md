---
name: create-fedex-label
description: Create a FedEx shipping label by collecting shipment details conversationally and calling the FedEx REST Ship API. Use when the user says "I need a shipping label", "ship a package", "create a FedEx label", "send something via FedEx", or asks to generate a label / tracking number for an outbound shipment.
---

# Create FedEx Label

Generates a FedEx shipping label (PDF) and tracking number from the FedEx REST Ship API.
The bundled Node helper handles OAuth, request building, and saving the label.

Helper location: `C:\temp\NodeJS\fedex\fedex-label.js`
Config: `C:\temp\NodeJS\fedex\config.json` (shipper defaults, environment).

**Credentials come from Keeper, not a file.** The source of truth is the Keeper record
**"Fedex Bot"** — `FEDEX_CLIENT_ID` and `FEDEX_CLIENT_SECRET` live in its `notes` field and
`FEDEX_ACCOUNT_NUMBER` in a custom field of the same name. Retrieve them with the
retrieve-keeper-secret skill and export them as process-scoped environment variables before
invoking the helper, then clear them. `fedex\.env` is a legacy fallback holding only
`REPLACE_ME` placeholders (the helper skips those) — it is readable by any authenticated account
on the box, so do not add or refresh secrets there. The older `C:\AI Workspace\env.local` bridge
is gone (verified 2026-08-05); `config.json` `envFiles` is now empty by design.

## Workflow

When the user wants a shipping label, collect the details below by asking short questions.
Use stored defaults so you only ask what's missing.

1. **Recipient (the "to")** — ask for: name, company (optional), phone, street address,
   city, state, ZIP, country (default US), and whether it's a residential address.
2. **Package** — ask for: weight (lb), and dimensions L×W×H in inches if known.
3. **Service** — default `FEDEX_GROUND`. Offer faster options if they ask
   (`FEDEX_2_DAY`, `STANDARD_OVERNIGHT`, `PRIORITY_OVERNIGHT`, `FEDEX_EXPRESS_SAVER`).
4. **Notifications ("who should be notified")** — ask for any email addresses to notify on
   shipment / delivery / exception. Optional.
5. **Reference / message** — optional PO number or note for the email.

The shipper ("from") address and account number come from `config.json` + `.env` by default —
do NOT ask for these unless the user wants to override the from-address for this shipment.

### Run it

Write the collected details to a JSON file (or pipe via stdin) in this shape:

```json
{
  "to": { "name": "", "company": "", "phone": "", "street": ["",""], "city": "", "state": "", "zip": "", "country": "US", "residential": false },
  "package": { "weight": 5, "weightUnit": "LB", "length": 12, "width": 9, "height": 6, "dimUnit": "IN" },
  "service": "FEDEX_GROUND",
  "notify": [ { "email": "", "events": ["ON_SHIPMENT","ON_DELIVERY","ON_EXCEPTION"] } ],
  "reference": "",
  "message": ""
}
```

Then **always do a dry-run first** and show the user the summary for confirmation:

```bash
node "C:\temp\NodeJS\fedex\fedex-label.js" --input shipment.json --dry-run
```

After the user confirms, create the real label:

```bash
node "C:\temp\NodeJS\fedex\fedex-label.js" --input shipment.json
```

Report back the **tracking number** and the saved **label file path** (under `fedex\labels\`).
The last stdout line is `RESULT_JSON={...}` for easy parsing.

## Important details

- Creating a label in **production** is a real, billable shipment. The config defaults to
  `sandbox`. Only switch to production (`config.json` `"environment": "production"`, with
  production credentials in `.env`) when the user explicitly asks to ship for real. Confirm
  before the first production label.
- Verify credentials any time with: `node "C:\temp\NodeJS\fedex\fedex-label.js" --check-auth`
- Never print the FedEx API key, secret, or `.env` contents in chat.
- If the Ship API returns an address/validation error, relay the FedEx error message and ask
  the user to correct the offending field, then retry.
- Sandbox and production each need their own API key/secret pair from developer.fedex.com.

## FedEx Ship API reference (validated against sandbox)

- **OAuth:** `POST {base}/oauth/token`, `Content-Type: application/x-www-form-urlencoded`,
  body `grant_type=client_credentials&client_id=<key>&client_secret=<secret>`. Bases: sandbox
  `https://apis-sandbox.fedex.com`, production `https://apis.fedex.com`.
- **Ship:** `POST {base}/ship/v1/shipments`, headers `Authorization: Bearer <token>`,
  `Content-Type: application/json`, `X-locale: en_US`. Label (base64) is at
  `output.transactionShipments[0].pieceResponses[0].packageDocuments[0].encodedLabel`; master
  tracking at `output.transactionShipments[0].masterTrackingNumber`.
- **Residential gotcha:** `FEDEX_GROUND` to a residential address is REJECTED
  (`REQUESTEDSHIPMENT.SERVICETYPEANDADDRESS.MISMATCH`) — must use `GROUND_HOME_DELIVERY`. The
  helper auto-switches when `residential:true`.
- **Tolerances (all accepted by sandbox):** empty `companyName`; no `dimensions` (weight-only);
  an empty second `streetLines` entry; and weight/`residential` sent as STRINGS ("3", "true") —
  handy when the caller can't send real number/boolean types (e.g. Power Automate).
- Credential auth failures return HTTP `401`. `l`-vs-`1` / `O`-vs-`0` typos and trailing
  whitespace in the key/secret are the usual culprits.

## Self-service pipeline (Power Automate)

A live, tested "helpdesk requests a label → Avery approves → label emailed to requester"
pipeline exists in Power Automate: flow **"FedEx label request"** (Default env) — a Teams-runnable
instant flow: manual trigger → **Start and wait for an approval** → HTTP get-token → HTTP
create-shipment → **Send email (V2)** with the label PDF attached
(`@{base64ToBinary(body('HTTP_1')?['output']?['transactionShipments']?[0]?['pieceResponses']?[0]?['packageDocuments']?[0]?['encodedLabel'])}`).
Full build guide: `C:\temp\NodeJS\fedex\power-automate-pipeline.md`. To build/edit/troubleshoot
that flow in the browser, use the **build-power-automate-flow** skill. Still on sandbox until
production creds are added and both HTTP URIs are swapped to `apis.fedex.com`.

## Setup state — API lane is sandbox only, blocked

Verified 2026-08-05: the API lane is built and sandbox-validated, but **no production key exists**,
so it cannot produce a real label — use the web lane below instead. Never tell the user a label is
"created" while `config.json` says `sandbox`; sandbox labels are not shippable.

The blocker is not fixable from this side: the production key needs a FedEx shipping account
linked to the developer-portal org, the org has none, and linking one is not something we can
complete. Details kept below in case that changes.

Getting to production, in the developer portal (`developer.fedex.com` > My Projects > the
newest project, currently **"Fedex Bot"**, org Contoso Energy 10532685):

1. **Production Key** tab > step 1 "Configure project" > **Add shipping accounts**. This is the
   gate: the org has *no* shipping account linked, so the list reads "No accounts available"
   and step 2 "Get project keys" is unreachable.
2. **ADD SHIPPING ACCOUNT** wants the nine-digit FedEx account number plus the **company billing
   address exactly as FedEx has it on file**. A billing-address mismatch is the usual rejection —
   it is the AP/billing address on the account, which need not match the ship-from address in
   `config.json`. The account Avery ships on interactively is the one ending **8201**; the
   `740561073` in the sandbox key and the Power Automate flow body is FedEx's test account.
3. The user must do steps 1–2 themselves — entering account numbers and billing details into a
   form is theirs to submit, not the agent's.
4. Once the production key/secret exist: store them in the Keeper record **"Fedex Bot"** (do not
   write them to `.env`), then set `config.json` `"environment": "production"` — or pass
   `--env production` per run to try one label without changing the default.
5. Verify with `--check-auth` against production, then ship one cheap real parcel end to end
   before pointing anyone else at it.
6. The Power Automate flow needs the same cutover separately: swap **both** HTTP action URIs
   from `apis-sandbox.fedex.com` to `apis.fedex.com`, replace the key/secret in the token action
   body, and change the hardcoded account number. Use the build-power-automate-flow skill.

Note the portal is a slow SPA: screenshot capture times out often, so prefer reading page text
over screenshots when driving it.

## Lane 2 — the FedEx website (the only lane that makes real labels today)

Because production API credentials are blocked, real labels are created by driving **FedEx Ship
Manager / ShippingPlus** at `fedex.com/shippingplus/en-us/shipment/create` in a signed-in browser.
This lane bills the real corporate account and shows real negotiated rates, which the sandbox API
cannot do. It costs ~20+ browser actions per label and the form is brittle, so read
`references/shippingplus-web-flow.md` in this skill's folder before driving it — it has the full
field map and the traps that waste the most time:

- Field IDs are randomly regenerated per render; locate fields by visible label text only.
- COUNTRY/TERRITORY does not default — set it first; it relabels POSTAL CODE to ZIP CODE and adds
  STATE OR PROVINCE, which then auto-fills from the ZIP.
- CITY is an autocomplete; the suggestion must be clicked or the section will not advance.
- Screenshot capture times out often; prefer page text or DOM reads.

Collect the same details listed under Workflow above. Two extras the web form offers that the API
lane handles differently: **Service options > Email outbound shipment label** mails the label
straight to the requester (no PDF handling), and **Billing details > Bill transportation cost to**
can charge Recipient or Third-party instead of Contoso.

**VIEW SUMMARY > FINALIZE is the purchase.** It buys a real billable shipment and accepts FedEx's
Terms of Use on the user's behalf. Always show the user the recipient, service, and exact price
from the review panel and get an explicit go-ahead for that shipment before clicking it. **SAVE**
stores a draft without buying; **RESET FORM** clears an abandoned one.

Before automating anything recurring, prefer the site's own **Save as shipment template**, the
recipient address book, and **Batch shipping** — all less brittle than driving the form.
