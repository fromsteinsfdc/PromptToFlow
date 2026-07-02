# Design Notes

## Decision: Store configurations as Custom Metadata (CMDT)

- Date: 2026-07-02
- Context: Builder configurations were stored in the `PromptToFlow_Config__c` custom object. Because the app is built in sandboxes and promoted to production, configurations should travel as metadata rather than data.
- Decision: Replaced the custom object with the `PromptToFlow_Configuration__mdt` custom metadata type. A distinct base name (`PromptToFlow_Configuration`, not `PromptToFlow_Config`) is used deliberately so it never collides with the legacy `PromptToFlow_Config__c` object during an upgrade (a custom object and CMDT cannot share a base API name).
- Reads: SOQL against `__mdt` (never `getAll()`/`getInstance()`, which truncate the LongTextArea JSON fields at 255 chars). Note `__mdt` does not expose `LastModifiedDate`, so lists are ordered by `MasterLabel`.
- Writes: custom metadata records cannot be written with DML. The Apex Metadata API (`Metadata.Operations.enqueueDeployment`) is async and cannot delete records, so save/delete use the **synchronous SOAP Metadata API** (`upsertMetadata` / `deleteMetadata`) through the existing `PromptToFlow_Tooling` Named Credential, authenticated via the `{!$Credential.OAuthToken}` merge field.
- Consequence: saving/deleting a configuration now requires the Named Credential setup ("Run Setup → Authenticate") that previously was only needed for parser generation. Configuration names are capped at 40 characters (CMDT `MasterLabel`/`DeveloperName` limit).
- Testability: CMDT records can't be inserted via DML even in tests, so the callout-heavy paths are exercised through `@TestVisible` seams with in-memory `__mdt` records and `HttpCalloutMock`. The live SOAP save/delete cannot be end-to-end verified in an automated test or without completing the manual Named Credential OAuth step.

## Deferred Decision: Parser Versioning Strategy

- Date: 2026-06-28
- Context: Each `PromptToFlow_Config__c` record currently maps 1:1 to a generated parser class, and updates rewrite that class in place.
- Open question: should parser output contract changes (new/removed object outputs or fields) force versioned class generation to avoid breaking existing flows?
- Status: deferred by product decision; keep current in-place rewrite behavior until revisited.
- Next review trigger: before broad rollout to orgs where multiple flows may depend on long-lived parser contracts.

## Decision: Auth Distribution Architecture (move to ECA)

- Date: 2026-06-29
- Context: The tool calls each org's OWN Tooling API (a self-callout) to generate parser Apex. It must be distributable to other SEs and to customer orgs (sandbox -> production) via a simple install link. Not monetized, not AppExchange.
- Required subscriber experience: install -> (optional one-click/automated bootstrap) -> click Authorize once. Considered achievable in principle; MUST be validated by a real test install before relying on it.
- Decisions:
  - Distribute via an UNLOCKED package (no namespace required), not managed 2GP. Avoids the permanent namespace commitment; acceptable for a free internal-ish tool. Revisit managed only if IP protection / upgrade management is needed.
  - Use an External Client App (ECA) as the OAuth client, not a legacy Connected App. Spring '26 restricts new Connected App creation; ECAs are the supported path for multi-org distribution.
  - Use per-org credentials (each install generates its own consumer key/secret). Better security/isolation for a self-callout; no shared secret hosted by us; no runtime dependency on our Dev Hub. Trade-off: needs a small post-install bootstrap (target: a single button click or automated anonymous Apex) to enable OAuth and wire the credential.
  - Move the build/packaging home OFF the customer sandbox (encoreboost) to a dedicated Dev Hub/packaging org. Keep encoreboost only as a test-install target.
  - Keep the existing working legacy Connected App + Auth Provider in source as a fallback until the ECA path is validated. DO NOT delete.
- Unverified item to prove via test install: that the browser-flow External Credential -> Auth Provider -> Named Credential chain packages cleanly into the "install + authorize" experience (most documented ECA packaging covers server-to-server flows, not this chain).
- Key sources: Salesforce "Architecting Inbound Governance with External Client Apps"; Named Credentials Packaging Guide (developer.salesforce.com); Trailhead "Package and Distribute External Client Apps"; salesforce.stackexchange.com Q#431575 (per-org credentials); flxbl-io/external-client-apps-guide (unlocked package + bootstrap).

## VALIDATED: Per-org local-ECA OAuth bootstrap (2026-06-29)

Proven end-to-end in scratch org `ptf-test-install`: `OauthAuthorize: Success`, `OauthTokenExchange: Success`, and a live `callout:PromptToFlow_Tooling` Tooling API query returned HTTP 200. The full chain is automatable in Apex except the single final "Authenticate" click on the External Credential principal.

### Hard constraints discovered (empirically)
- A packaged "Associated" ECA locks the callback URL to the Dev Hub domain -> `redirect_uri_mismatch` for subscriber self-callouts. DEAD-END.
- A Salesforce-type **Auth Provider always sends a client_secret** during token exchange; PKCE is additive, not a replacement. A wrong/placeholder secret -> `InvalidClientCredentials`. So zero-secret PKCE-only is NOT possible with an Auth Provider.
- `AuthProvider.consumerSecret` is **immutable after create** (`updateMetadata` -> "Consumer Secret update is not allowed"). The secret MUST be supplied at `createMetadata` time. (Omitting it preserves the old value; an empty value is a silent no-op.)
- ECA generated `consumerSecret` is NOT returned by Metadata API `readMetadata` (masked by design).
- BUT the secret IS readable via the **Connect REST API** once the org setting is enabled.

### The working sequence (all self-callouts using `UserInfo.getSessionId()`, no Remote Site Setting needed)
1. Enable setting: `updateMetadata` type `ExternalClientAppSettings`, fullName `ExternalClientApp`, set `enableClientSecretInRestApiAccess = true`.
2. Create per-org **local ECA**: `createMetadata` `ExternalClientApplication` (`PromptToFlow_Local`), `ExtlClntAppGlobalOauthSettings` (fullName = ECA name; `callbackUrl = <myDomain>/services/authcallback/<AuthProviderName>`, `isConsumerSecretOptional=false`, `isSecretRequiredForTokenExchange=true`, no PKCE), and `ExtlClntAppOauthSettings` (`<ECA>_oauth`).
3. Find ECA Id: SOQL `SELECT Id FROM ExternalClientApplication WHERE DeveloperName='PromptToFlow_Local'` (regular SOQL works; NOT a Tooling object).
4. Read key+secret via Connect REST:
   - `GET /services/data/v60.0/apps/oauth/credentials/{ecaId}` -> `consumers[0].id`
   - `GET /services/data/v60.0/apps/oauth/credentials/{ecaId}/{consumerId}?part=keyandsecret` -> `key`, `secret`
5. **Create** Auth Provider with that key+secret (Salesforce type, `isPkceEnabled=false`, scopes `refresh_token api`). Name must match the `/authcallback/<name>` in the ECA callback URL.
6. Wire `ExternalCredential` `AuthProvider` param to that provider; wire `NamedCredential` `DefaultEndpoint` = myDomain.
7. Admin clicks **Authenticate** on the External Credential's named principal.

### Packaging implication (for the refactor)
- Do NOT ship a placeholder Auth Provider with a fake secret (immutable -> can never be fixed). Either ship the External Credential WITHOUT the `AuthProvider` param and have the bootstrap add it after creating the provider, OR have the bootstrap create a freshly-named provider and (optionally) repoint. Validation used the "create new provider `PromptToFlow_Tooling_Local` + update ECA callback + repoint External Credential" approach successfully.
