# App Store Legal Links Check

## Goal
Confirm Apple-required public links exist for Norviq App Store submission: Privacy Policy, Terms of Service / License Agreement, and Support URL.

## Current findings
- Privacy Policy gist exists and is public:
  - https://gist.github.com/FACorreiaa/a60bcbf818a50a0e60df625f10021ef4
  - File verified: privacy-policy.md
- Support gist exists and is public:
  - https://gist.github.com/FACorreiaa/87d5c81b0378d5e9ad42048dd8de7c09
  - File verified: support.md
- Terms of Service source file exists locally:
  - docs/legal/terms-of-service.md
- No public terms/service gist found in latest 100 gists by `gh gist list --limit 100 | grep -i 'terms\|service\|norviq\|privacy'`.

## Plan
1. If you still want a separate Terms of Service URL, create a public gist from:
   - docs/legal/terms-of-service.md
   - filename: terms-of-service.md
2. Copy its gist URL.
3. In App Store Connect:
   - App Information -> Privacy Policy URL:
     https://gist.github.com/FACorreiaa/a60bcbf818a50a0e60df625f10021ef4
   - App version -> Support URL:
     https://gist.github.com/FACorreiaa/87d5c81b0378d5e9ad42048dd8de7c09
   - License Agreement:
     keep Apple Standard License Agreement unless you specifically need custom terms.
4. Keep Terms of Service URL handy, but Apple standard EULA is acceptable for MVP if ASC does not expose a separate Terms field.

## Validation
- Re-open both gist URLs in a private/incognito browser to confirm public access.
- In App Store Connect, verify no missing metadata warning remains for Privacy Policy URL or Support URL.
- Verify License Agreement says Apple Standard License Agreement or equivalent.

## Risk / note
Terms of Service is highly recommended, not always required as a separate App Store Connect field. Missing item appears to be only the ToS gist, not Apple-required support/privacy links.
