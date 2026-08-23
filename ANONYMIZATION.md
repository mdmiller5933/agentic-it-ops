# Anonymization note

This repository documents real production work. Before publishing, every employer-identifying
value was replaced consistently across all files:

- The company appears as **Contoso** (domains: `contoso.com`, `contoso.screenconnect.com`, etc.)
- People appear under generated names; my own account appears as `avery.operator` in places
- Device names and serials are placeholders (`WKS-SN0042` style), as are GUIDs, org IDs,
  policy IDs, ticket numbers, internal IPs, and MAC addresses
- Certificates, tokens, SSH keys, and other credentials were removed entirely, not substituted

Vendor and product names (Microsoft, Automox, ScreenConnect, CDW, Freshservice, Keeper,
CrowdStrike, Rapid7) are real, because they are the technical substance. Fleet-scale numbers
are approximate. No employer configuration, data, or secrets appear in this repository.
