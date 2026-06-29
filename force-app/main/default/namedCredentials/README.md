## PromptToFlow Tooling Named Credential (one-time setup)

This project includes a source-tracked named credential file:

- `namedCredentials/PromptToFlow_Tooling.namedCredential-meta.xml`

Because OAuth secrets/tokens are org-specific, the metadata is intentionally committed as a template.

### One-time admin setup after deploy

1. Open the `PromptToFlow_Tooling` Named Credential in Setup.
2. Set the endpoint to your org My Domain host (for example `https://yourDomain.my.salesforce.com`).
3. Confirm it references external credential `PromptToFlow_Tooling_Cred`.
4. Authenticate principal `PromptToFlow_Principal` once.
5. Assign permission set `PromptToFlow_User` to users of the builder.

After that, parser generation runs through Apex callouts using `callout:PromptToFlow_Tooling`.

For full packaging-oriented guidance, see `AUTH_PACKAGING_2GP.md` at the repo root.
