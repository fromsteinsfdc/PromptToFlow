# Auth & Packaging Guide (PromptToFlow)

PromptToFlow generates Apex parser classes by calling **each subscriber org's own
Tooling API** (a self-callout). That requires an OAuth-authenticated Named
Credential in every org. This guide documents the **validated**, near-zero-touch
way that auth is established after install.

Distribution: **unlocked package, no namespace** (not AppExchange, not monetized).

## Subscriber Experience (validated end-to-end)

1. Install the package.
2. Open the **PromptToFlow** app (App Launcher) → **PromptToFlow Setup** tab.
3. Click **Run Setup**. (Creates the per-org OAuth client and wires everything.
   No keys or secrets to copy.)
4. Click **Open External Credentials** → `PromptToFlow_Tooling_Cred` → Principals →
   **Authenticate** the `PromptToFlow_Principal` (one OAuth consent click).
5. Assign the `PromptToFlow_User` permission set to users who will generate parsers.
6. Use the **PromptToFlow Builder** tab.

Only steps 3 and 4 are clicks; everything else is automated. There is no manual
Connected App / Auth Provider / Named Credential creation.

## Why a one-time Authenticate click is unavoidable

A Salesforce-type **Auth Provider always sends a client secret** during the OAuth
token exchange (PKCE is additive, not a replacement), and live OAuth consent is
org-specific and not portable. So a browser-based Authenticate click is required
once per org. Everything *around* that click is automated. (Full analysis in
`DESIGN_NOTES.md`.)

## How Run Setup works (PromptToFlowBootstrapController via a Visualforce page)

Run Setup is a **Visualforce** action, not LWC, because `UserInfo.getSessionId()`
in a Lightning/LWC context is not API-enabled (Metadata/Tooling/Connect REST
reject it). A VF page yields an API-enabled session for the self-callouts.

Sequence (all self-callouts, idempotent, no Remote Site Setting needed):

1. Enable `ExternalClientAppSettings.enableClientSecretInRestApiAccess = true`
   (Metadata API) so the consumer secret can be read back via REST.
2. Create the per-org **local** External Client App + OAuth settings
   (`PromptToFlow_Local`): create the ExternalClientApplication, then the OAuth
   Settings (enablement), then the Global OAuth Settings
   (`callbackUrl = <myDomain>/services/authcallback/PromptToFlow_Tooling_Local`).
   Order matters; OAuth Settings must exist before Global OAuth Settings.
3. Read the generated key + secret via Connect REST:
   `/services/data/vXX/apps/oauth/credentials/{ecaId}/{consumerId}?part=keyandsecret`.
4. **Create** the Auth Provider `PromptToFlow_Tooling_Local` with that key+secret
   (an Auth Provider's secret is immutable after creation, so it must be created
   fresh here — the packaged `PromptToFlow_Tooling` Auth Provider is a deploy-only
   placeholder).
5. Repoint the External Credential's `AuthProvider` parameter to
   `PromptToFlow_Tooling_Local`, and point the Named Credential endpoint at this org.

## What is packaged vs. created at runtime

### Packaged in source
- Apex (`PromptToFlowController`, `PromptToFlowBootstrapController`, parser/action
  classes) + tests
- LWC `promptToFlowBuilder`; Visualforce `PromptToFlowSetup`
- Custom object + fields (`PromptToFlow_Config__c`)
- Permission set `PromptToFlow_User` (class + page + tab + external-credential-
  principal access)
- External Credential `PromptToFlow_Tooling_Cred` (ships referencing the placeholder
  Auth Provider so it can deploy)
- Named Credential `PromptToFlow_Tooling`
- **Placeholder** Auth Provider `PromptToFlow_Tooling` (deploy-only; unused at runtime)
- Tabs `PromptToFlow_Builder`, `PromptToFlow_Setup`; Lightning app `PromptToFlow`

### Created/updated at runtime by Run Setup (per subscriber org)
- External Client App `PromptToFlow_Local` (+ its OAuth settings)
- Auth Provider `PromptToFlow_Tooling_Local` (the real OAuth client)
- Org setting `enableClientSecretInRestApiAccess = true`
- External Credential repointed; Named Credential endpoint set to the org domain

## Stable developer names (keep across versions)
- Named Credential: `PromptToFlow_Tooling`
- External Credential: `PromptToFlow_Tooling_Cred`
- External Credential Principal: `PromptToFlow_Principal`
- Placeholder Auth Provider: `PromptToFlow_Tooling`
- Runtime Auth Provider: `PromptToFlow_Tooling_Local`
- Local ECA: `PromptToFlow_Local` (+ `PromptToFlow_Local_oauth`)
- Permission Set: `PromptToFlow_User`

## Troubleshooting
- **Setup tab errors / not in App Launcher** → the `PromptToFlow_User` permission set
  (which grants tab visibility) isn't assigned, or open via `/apex/PromptToFlowSetup`.
- **Authenticate fails with `InvalidClientCredentials`** (check Setup → Identity
  Provider Event Log → `OauthTokenExchange`) → the Auth Provider secret doesn't match
  the ECA. Re-run **Run Setup** (it recreates/repoints to `PromptToFlow_Tooling_Local`).
- **`redirect_uri_mismatch`** → the ECA callback URL doesn't match the Auth Provider
  name. Re-run **Run Setup**.
- **Run Setup reports "consumer secret was not returned"** → the
  `enableClientSecretInRestApiAccess` org setting didn't apply; click Run Setup again.
- **Status shows "not authenticated"** after authenticating → confirm the running user
  has `PromptToFlow_User` (external credential principal access) assigned.

## Verifying an org from the CLI
```bash
# OAuth events (expect OauthAuthorize + OauthTokenExchange = Success)
sf data query --target-org <org> \
  --query "SELECT Timestamp, ErrorCode, InitiatedBy FROM IdpEventLog ORDER BY Timestamp DESC LIMIT 4"
```
Live Tooling reachability can be checked from anonymous Apex via
`callout:PromptToFlow_Tooling/services/data/v60.0/tooling/query?q=SELECT+Id+FROM+ApexClass+LIMIT+1`.
