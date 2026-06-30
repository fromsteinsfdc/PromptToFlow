# Building a Salesforce Package That Deploys Dynamic Apex With Minimal Admin Setup

> **How to use this document (for the human).** If you're about to build a similar tool,
> don't read this top-to-bottom — instead, hand the whole file to your AI coding agent as
> context and have it drive, then read §3 (the Decision log) yourself so you understand
> *why* the architecture is shaped this way and can veto deviations intelligently. Skim §1–2
> for the mental model, use §10 (Reproduction checklist) as the actual build order, keep §11
> (Pitfalls) open while debugging, and point your agent at Appendix A for working skeleton
> code (read its ⚠️ caveats first). The fastest path is: confirm the steady-state Tooling
> path before the bootstrap, ship nothing to a real org until the perm-set and External
> Credential principal access are wired, and promote the package out of beta before you
> test installs in a sandbox.

> **Audience:** an AI coding agent (or experienced Salesforce engineer) that needs to
> reproduce, from scratch, a distributable package whose runtime can **generate and
> deploy Apex classes inside the subscriber org**, while requiring the installing admin
> to do **as close to zero manual configuration as possible**.
>
> This document is intentionally generic. It contains no product names. Treat every
> `Your*` / `<App>` token as something you rename for your own tool. Everything here is
> the distilled result of building, breaking, and re-architecting a real tool; the
> "Decision log" sections explain *why* each path was chosen so you can deviate
> intelligently rather than cargo-cult.

---

## 1. The two hard problems

You are solving two independent problems that happen to combine badly:

1. **Dynamic Apex deployment at runtime.** Apex cannot write Apex. There is no
   synchronous "compile this string into a class" call in the Apex runtime. The only
   supported way for code running in an org to create/modify an Apex class in that same
   org is to call the **Tooling API** (or Metadata API) over HTTP. That means a
   **self-callout**: the org makes an authenticated HTTP request back to itself.

2. **Minimal admin setup.** Self-callouts need credentials. The naive answer ("admin
   creates a Connected App, an Auth Provider, an Auth. setting, a Named Credential, then
   authenticates") is 15+ clicks across 4 setup screens and is the #1 thing that makes
   tools like this fail adoption. The goal is **install → click one button → click
   Authorize → done.**

Everything below is the machinery that makes #1 possible while keeping #2 true.

---

## 2. Architecture at a glance

```
                      ┌────────────────────────────────────────────────────┐
                      │                  Subscriber Org                      │
                      │                                                      │
  Admin clicks        │   ┌──────────────┐   self-callout (session)         │
  "Run Setup"  ─────► │   │  VF Bootstrap │ ───────────────► Metadata API    │  creates ECA,
  (one time)          │   │  Controller   │ ───────────────► Connect REST API │  reads secret,
                      │   └──────────────┘ ───────────────► (same org)        │  wires AuthProvider/
                      │          │                                            │  ExternalCred/NamedCred
                      │          ▼                                            │
                      │   AuthProvider + External Credential + Named Cred     │
                      │          │                                            │
  Admin clicks        │          ▼  (one OAuth Authorize click)               │
  "Authorize" ──────► │   Named Principal OAuth token stored on Ext. Cred     │
  (one time)          │                                                       │
                      │   ┌──────────────┐   self-callout (Named Credential)  │
  End users do        │   │ LWC + Apex    │ ──────────────► Tooling API ──────┼─► creates/updates
  normal work  ─────► │   │ Controller    │   (no session needed)             │   Apex classes
                      │   └──────────────┘                                    │
                      └────────────────────────────────────────────────────┘
```

Two distinct callout contexts, and **getting this split right is the whole game**:

| Context | When | Auth used | Can run from LWC/Aura? |
|---|---|---|---|
| **Bootstrap** | once, admin clicks a button | `UserInfo.getSessionId()` (the *page* session) | **No — must be a Visualforce page** |
| **Steady state** (deploy Apex) | every time the app generates a class | `callout:Your_Named_Credential` | **Yes — works from normal LWC-backed Apex** |

---

## 3. Decision log (read this before you build)

### 3.1 Why the Tooling API for Apex generation — not Metadata API deploy

- **Tooling API** lets you create an `ApexClass` with a single `POST
  /services/data/vXX.0/tooling/sobjects/ApexClass` containing `{ "Name", "Body" }`. It
  compiles synchronously. This is the simplest path for **creating** a class.
- **Metadata API** (deploy) requires zipping a package, base64-encoding it, polling an
  async deploy, and dealing with `package.xml`. Heavier, and async.
- **Verdict:** Tooling API for class create. (Metadata API is still required for the
  *bootstrap* of auth components — see 3.4 — because those component types aren't all
  writable via Tooling.)

### 3.2 Why updates need the MetadataContainer dance (the sharpest trap)

A direct `PATCH`/`POST` to update an existing `ApexClass` via Tooling returns
`INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY`. **You cannot update an ApexClass body
directly.** Updates must go through the asynchronous container pattern:

1. `POST /tooling/sobjects/MetadataContainer` → get `containerId`.
2. `POST /tooling/sobjects/ApexClassMember` with `{ MetadataContainerId, ContentEntityId
   (the existing class Id), Body }`.
3. `POST /tooling/sobjects/ContainerAsyncRequest` with `{ MetadataContainerId,
   IsCheckOnly: false }` → get `requestId`.
4. Poll `GET /tooling/sobjects/ContainerAsyncRequest/{requestId}` until `State ==
   'Completed'` (or surface `ErrorMsg` / `DeployDetails.componentFailures[].problem`).
5. Delete the container (best-effort cleanup).

So your write path is: **create = one POST; update = container compile**. Branch on
"does a class with this name already exist?" (a Tooling SOQL query).

### 3.3 Why the steady-state path uses a Named Credential (and why that rules out the "VF hack" for the main feature)

`UserInfo.getSessionId()` returns a session that is **not API-enabled** when the Apex is
invoked from a Lightning/LWC/Aura context. Self-callouts using that session fail with
`INVALID_SESSION_ID`. Historically people work around this with the **"Visualforce
session hack"**: render a VF page, grab `{!$Api.Session_ID}` / the VF-page session
(which *is* API-enabled), and pass it to Apex.

We deliberately **rejected the VF hack for the main, repeated Apex-generation feature**
because:

- It forces your primary UX into Visualforce or an awkward hidden-iframe handshake.
- The session is short-lived and brittle; you'd re-acquire it constantly.
- It couples every feature call to a page context.

Instead, the steady-state path authenticates with a **Named Credential** (`callout:NC`).
The platform injects a valid OAuth token automatically, no session juggling, and it
works from ordinary `@AuraEnabled` Apex behind an LWC. This is the clean, durable path.

**The VF page survives only for the one-time bootstrap** (next section), where a Named
Credential doesn't exist yet (chicken-and-egg) and you genuinely need an API-enabled
session for a few setup callouts. One page, used once, is an acceptable price; the whole
app being VF is not.

### 3.4 Why bootstrap is a Visualforce page

To set up the Named Credential automatically you must create several metadata
components programmatically *before* any Named Credential exists. Those creation
callouts (Metadata API SOAP + Connect REST) need an **API-enabled session**, which only
a Visualforce page context provides. Hence: a single VF "Setup" page whose controller
action runs the bootstrap. (An LWC "Run Setup" button cannot do this — its session is
not API-enabled.)

### 3.5 Why a *locally-created* OAuth client, not a packaged one

The OAuth client (Connected App / External Client App) needs a **callback URL that
matches the subscriber's My Domain**. Two options:

- **Package the OAuth client** → its callback URL is fixed at packaging time to the
  *publisher's* domain. In every subscriber org you get
  `error=redirect_uri_mismatch`. **Rejected.**
- **Create the OAuth client at runtime, locally, in the subscriber org** → its callback
  URL is built from `URL.getOrgDomainUrl()` of *that* org, so it always matches.
  **Chosen.**

### 3.6 ECA vs legacy Connected App — and why the Auth Provider is re-created at runtime

- The modern primitive is the **External Client App (ECA)**; the legacy primitive is the
  **Connected App**. Both can be created via Metadata API. We used the **ECA** because it
  is the forward-looking model and is fully creatable/configurable through metadata
  (`ExternalClientApplication`, `ExtlClntAppOauthSettings`,
  `ExtlClntAppGlobalOauthSettings`). If you must support very old orgs, a Connected App
  is the fallback; the rest of the architecture is identical.
- **Critical immutability gotcha:** an `AuthProvider`'s `consumerSecret` is **immutable
  after creation**. You cannot deploy a placeholder Auth Provider and later patch in the
  real secret — you'll get `InvalidClientCredentials` / "Problem Logging In" forever.
  Therefore the **real Auth Provider is *created* at runtime** with the secret you read
  back from the freshly-created ECA, and the External Credential is repointed to it.
- You *still* ship a **placeholder Auth Provider** in the package (see 3.7).

### 3.7 Why ship a placeholder Auth Provider at all

An `ExternalCredential` of protocol `Oauth` **won't deploy** unless it references an
existing `AuthProvider` ("must have either an AuthProvider parameter…"). So the package
includes a minimal placeholder Auth Provider purely to satisfy the deploy-time
dependency. At runtime you create the *real* Auth Provider (distinct dev name) and
rewire the External Credential to it. (Watch field limits: `AuthProvider.FriendlyName`
max length is 32 chars.)

### 3.8 Why a per-user "Named Principal" OAuth handshake

The External Credential is configured with a **Named Principal** and the OAuth
authorization-code flow. After bootstrap, the admin clicks **Authenticate** once on the
External Credential's principal; the resulting refresh/access token is stored by the
platform and reused for all subsequent Named-Credential callouts. This is the single
unavoidable human click (OAuth consent must be interactive).

### 3.9 Packaging model: 2GP unlocked, and the post-install limitation

- Use a **second-generation (2GP) unlocked package**. It's installable via a plain link,
  upgradeable, and doesn't require AppExchange/managed-package overhead.
- **Unlocked packages do not run Apex post-install scripts** (the `InstallHandler`
  `metadata`/post-install hook is a *managed*-package feature). So you **cannot
  auto-assign a permission set on install**. The practical substitute: assign the
  permission set to the current user **inside the "Run Setup" button handler** (the admin
  is right there clicking it). See 6.2.
- **Beta vs released:** a newly created package version is **beta** and installs **only in
  scratch/Developer Edition orgs**. To install into sandboxes/production you must
  **promote** the version to *released* (`sf package version promote`). Released versions
  are immutable.

---

## 4. Component inventory

Everything you ship or create. Group A is packaged metadata; Group B is created at
runtime by the bootstrap.

### Group A — packaged metadata (in your `force-app` source)

| Component | Type | Purpose |
|---|---|---|
| `YourSetup` | Visualforce **page** + controller (`with sharing`) | One-time bootstrap UI; runs setup callouts with an API-enabled session. |
| `YourController` | Apex class (`@AuraEnabled`) | Steady-state: generates Apex source, calls Tooling API via Named Credential. |
| `YourParserRuntime` (optional) | Apex class | Shared helper logic referenced by generated classes, so generated code stays tiny. |
| `Your_Tooling` | **Named Credential** | `callout:Your_Tooling` → `/services/data/vXX.0/tooling`. Endpoint set to the org domain at runtime. |
| `Your_Tooling_Cred` | **External Credential** (OAuth, Named Principal) | Holds the principal + OAuth token; referenced by the Named Credential. |
| `Your_Tooling` (placeholder) | **Auth Provider** | Deploy-time dependency only; replaced at runtime. Keep `FriendlyName` ≤ 32 chars. |
| `Your_User` | **Permission Set** | Grants: VF page access, Apex class access, the External Credential **principal access**, tab visibility, any custom object/field/flow access. |
| `Your_App` + tabs | Lightning App + custom tabs | Discoverability (App Launcher). Admins see tabs without the perm set; everyone else needs it. |
| Custom objects/fields | as needed | Your app's data. |

### Group B — created at runtime by the bootstrap (NOT packaged)

| Component | Created via | Notes |
|---|---|---|
| Local **External Client App** (`ExternalClientApplication`) | Metadata API `createMetadata` | `distributionState = Local`. |
| ECA OAuth settings (`ExtlClntAppOauthSettings`) | Metadata API | Scopes e.g. `Api, RefreshToken`. Must exist before global settings. |
| ECA global OAuth settings (`ExtlClntAppGlobalOauthSettings`) | Metadata API | Holds the **callback URL** (built from this org's domain). |
| Org setting `enableClientSecretInRestApiAccess = true` (`ExternalClientAppSettings`) | Metadata API `updateMetadata` | Required to read the consumer secret over REST. |
| Real **Auth Provider** (distinct dev name) | Metadata API `createMetadata` | Created with the real key+secret (secret is immutable, so create — don't patch). |
| Rewired **External Credential** | Metadata API `updateMetadata` | Repointed from placeholder to the real Auth Provider. |
| Rewired **Named Credential** endpoint | Metadata API `updateMetadata` | `DefaultEndpoint = <org domain>`, linked to the External Credential. |

---

## 5. The bootstrap sequence (exact order matters)

Run all of this from the **VF controller action** so `UserInfo.getSessionId()` is
API-enabled. Make every step **idempotent** (tolerate "already exists" duplicates) so the
admin can safely click "Run Setup" again after a partial failure.

```
dom          = URL.getOrgDomainUrl().toExternalForm()
authorizeUrl = dom + '/services/oauth2/authorize'
tokenUrl     = dom + '/services/oauth2/token'
callbackUrl  = dom + '/services/authcallback/<RealAuthProviderDevName>'

1. enableSecretRestAccess()           // updateMetadata ExternalClientAppSettings
2. createExternalClientApp()          // createMetadata ExternalClientApplication (Local)
   createOauthSettings()              // createMetadata ExtlClntAppOauthSettings
   createGlobalOauthSettings(cb)      // createMetadata ExtlClntAppGlobalOauthSettings
3. ecaId   = query ExternalClientApplication by DeveloperName   // SOQL is fine here
4. creds   = readEcaCredentials(dom, ecaId)                     // Connect REST, two GETs
5. ensureAuthProvider(creds.key, creds.secret, authorizeUrl, tokenUrl)  // createMetadata
6. wireExternalCredential()           // updateMetadata ExternalCredential → real AuthProvider
7. wireNamedCredentialEndpoint(dom)   // updateMetadata NamedCredential (endpoint + ExtCred)
```

### 5.1 Metadata API self-callout (SOAP)

`POST <dom>/services/Soap/m/<apiVersion>` with `Content-Type: text/xml`, `SOAPAction:
""`, and an envelope carrying `<met:SessionHeader><met:sessionId>{session}</…>`. Body is
`<met:createMetadata>` or `<met:updateMetadata>` wrapping a typed `<met:metadata
xsi:type="met:<Type>">`. Parse the response for `result/success` and `result/errors/message`.

### 5.2 Reading the ECA consumer key + secret (Connect REST)

After enabling `enableClientSecretInRestApiAccess`:

1. `GET <dom>/services/data/vXX.0/apps/oauth/credentials/{ecaId}` → `consumers[0].id`.
2. `GET …/credentials/{ecaId}/{consumerId}?part=keyandsecret` → `{ key, secret }`.

Authenticate both with `Authorization: Bearer <session>`. If `secret` is missing, the
REST-access setting didn't apply yet — tell the admin to click Run Setup again.

### 5.3 The one human click

After bootstrap succeeds, deep-link the admin straight to the External Credential record
and have them click **Authenticate** on the named principal. (ExternalCredential is *not*
SOQL-queryable in Apex — `sObject type 'ExternalCredential' is not supported`. To build a
deep link, fetch its Id via a **Tooling** query: `SELECT Id FROM ExternalCredential WHERE
DeveloperName = '…'`, then link to
`/lightning/setup/NamedCredential/ExternalCredential/{id}/view`.)

---

## 6. Minimal-setup techniques (the "minimal admin" half)

### 6.1 Idempotent, single-button bootstrap
Tolerate duplicates (`already`, `duplicate`, `exist` substrings in the metadata error)
so re-running converges. Surface one clear success/failure message.

### 6.2 Assign the permission set from the button (since post-install scripts don't run)
In the "Run Setup" handler, after all callouts, insert a `PermissionSetAssignment` for
`UserInfo.getUserId()` (skip if already assigned; wrap in try/catch — best-effort).
**Order constraint:** this is DML, and **Apex forbids callouts once uncommitted DML
exists**. So do the assignment *after* every callout in the request. (See 7.1.)

### 6.3 Deep links instead of "navigate to Setup → … → …"
Replace multi-click instructions with direct URLs (e.g., the External Credential view
link above). Each removed click is a removed support ticket.

### 6.4 Page-wide progress feedback
Bootstrap callouts take seconds. On the VF page use an `<apex:actionStatus>` with a
fixed-position SLDS spinner overlay bound to the command button's `status=` so the admin
sees activity. In LWC, gate a `lightning-spinner` on an `isSaving` tracked property.

### 6.5 Discoverability
Ship a Lightning App + tabs and grant tab visibility in the permission set. Note admins
can often see apps/tabs without the perm set; non-admins cannot, and they also need the
*functional* grants (Apex class access, External Credential principal access), so
assigning the set still matters.

---

## 7. Hard runtime constraints (governor/order rules that will bite you)

### 7.1 Mixed DML + callout ordering
You may not perform a callout after uncommitted DML in the same transaction. Sequence
every transaction as **callouts first, DML last**. If you're testing in anonymous Apex,
split DML and callouts into separate executions, or you'll get *"You have uncommitted
work pending. Please commit or rollback before calling out."*

### 7.2 Callout count & timeouts
Each bootstrap is many sequential callouts; the container-compile poll adds more. Stay
under the per-transaction callout limit (default 100) and set generous `setTimeout`
(e.g., 120000 ms). Cap the compile poll (e.g., 30 attempts) and fail with a clear
message rather than hang.

### 7.3 `with sharing`, FLS, and injection
Run controllers `with sharing`. When generating Apex that writes to SObjects, restrict
to an explicit allow-list of fields and coerce values by `DisplayType`. Escape every
string you interpolate into generated source or into SOQL (`String.escapeSingleQuotes`).
Never interpolate untrusted input directly into a class body.

### 7.4 API version drift
Pin the Tooling/Metadata API versions you call (`/services/data/vXX.0/...`,
`/services/Soap/m/XX.0`). Keep them consistent across helpers.

---

## 8. Generating lean Apex (keep generated classes tiny)

Put all reusable logic (JSON coercion, map→SObject population, type handling) into a
**packaged runtime helper class**, and have generated classes call into it. Benefits:
generated source is small (faster compile, fewer Tooling failures), logic is centralized
and unit-testable once, and regenerating a class is cheap. Generated classes should be
thin shells (e.g., an `@InvocableMethod` that deserializes input and delegates to the
helper).

---

## 9. Testing strategy

- **Mock every callout with a multiplexer.** Implement one `HttpCalloutMock` whose
  `respond()` switches on `req.getEndpoint()` substrings (`/services/Soap/m/`,
  `?part=keyandsecret`, `/apps/oauth/credentials/`, `/tooling/query`,
  `/tooling/sobjects/...`) and returns canned XML/JSON. Add boolean knobs to simulate
  faults (SOAP `Fault`, `success=false`, missing secret, 401, compile failure).
- **Test seams.** Inject the org domain (`domainOverride`) and any queried Ids via static
  `@TestVisible` fields so both "create new" and "already exists" branches are reachable
  without real data.
- **Cover both write paths:** new-class create (POST) and existing-class update
  (MetadataContainer compile), plus the compile-failure and 401 branches.
- **Per-class coverage.** Deploy with `--test-level RunSpecifiedTests --tests <YourTests>`
  and ensure each new method is exercised.

---

## 10. Reproduction checklist

1. **Project + package**: `sf project generate`; add a 2GP package
   (`sf package create --package-type Unlocked`); set the package directory in
   `sfdx-project.json`.
2. **Steady-state path first** (it's the simpler half):
   - Named Credential `Your_Tooling` + External Credential `Your_Tooling_Cred` (OAuth,
     Named Principal) + placeholder Auth Provider (`FriendlyName` ≤ 32).
   - `YourController` with `getToolingApiBaseUrl() = 'callout:Your_Tooling' +
     '/services/data/vXX.0/tooling'`.
   - Implement create (POST `ApexClass`) and update (MetadataContainer →
     ApexClassMember → ContainerAsyncRequest → poll → delete).
   - Branch on a Tooling SOQL existence check (`SELECT Id FROM ApexClass WHERE Name = …`).
3. **Bootstrap path** (the minimal-setup half):
   - VF page `YourSetup` + `with sharing` controller; action method runs the sequence in
     §5; everything idempotent; callouts-before-DML.
   - Implement Metadata SOAP helper, Connect REST secret read, and the runtime creation
     of ECA + real Auth Provider + rewire of External/Named Credential.
   - Assign the permission set to the current user at the end of the handler.
   - Deep-link the admin to the External Credential for the single Authorize click.
4. **Permission set** granting page, classes, tabs, and **External Credential principal
   access**.
5. **Lightning App + tabs** for discoverability.
6. **Tests** per §9; deploy with specified tests.
7. **Package + promote**: `sf package version create --installation-key-bypass --wait 30
   --code-coverage`; verify in a scratch/DE org (beta); `sf package version promote` to
   install into sandbox/production; distribute the install URL.
8. **Subscriber runbook** (the entire manual experience):
   *Install package → open the Setup page → click **Run Setup** → click **Authenticate**
   on the principal → done.*

---

## 11. Pitfalls → fixes (quick reference)

| Symptom | Root cause | Fix |
|---|---|---|
| `redirect_uri_mismatch` | Packaged OAuth client's callback URL ≠ subscriber domain | Create the OAuth client **locally at runtime**; build callback from `URL.getOrgDomainUrl()`. |
| `INVALID_SESSION_ID` on self-callout | Used `UserInfo.getSessionId()` from LWC/Aura (not API-enabled) | Run bootstrap from a **Visualforce page**; run steady-state via **Named Credential**. |
| "Problem Logging In" / `InvalidClientCredentials` | Tried to patch an Auth Provider's secret (immutable) | **Create** a new Auth Provider with the real secret; repoint the External Credential. |
| Consumer secret missing from REST | `enableClientSecretInRestApiAccess` off | `updateMetadata` `ExternalClientAppSettings` to enable, then retry. |
| External Credential won't deploy | OAuth Ext. Cred requires an existing Auth Provider | Ship a **placeholder Auth Provider** for deploy; rewire at runtime. |
| `FriendlyName maximum length is 32` | Auth Provider friendly name too long | Shorten it. |
| `INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY` updating a class | Direct ApexClass update unsupported | Use the **MetadataContainer** compile pattern. |
| "uncommitted work pending… before calling out" | DML before a callout | Reorder: **callouts first, DML last**; split in anon Apex. |
| "Unable to install beta package" in sandbox/prod | Version still beta | `sf package version promote`. |
| Perm set not auto-assigned on install | Unlocked packages don't run post-install scripts | Assign in the **Run Setup** handler. |
| `sObject type 'ExternalCredential' is not supported` | Not SOQL-queryable in Apex | Query its Id via the **Tooling API** instead. |

---

## 12. Mental model to keep

- **Apex can't write Apex → you must self-callout to the Tooling API.**
- **Self-callouts need credentials → Named Credential for steady state, page session for
  bootstrap.**
- **Credentials need an OAuth client whose callback matches the org → create it locally
  at runtime.**
- **Auth Provider secrets are immutable → create, never patch.**
- **Unlocked packages can't auto-configure on install → do it in one button click, make
  it idempotent, and leave exactly one interactive OAuth Authorize for the admin.**

If you hold those five truths, the rest is plumbing.

---

## Appendix A — Copy-paste reference implementation

> These snippets are deliberately generic and stripped to the essentials. Rename
> `Your_Tooling`, `Your_Tooling_Cred`, `Your_AuthProvider_Local`, `Your_Principal`,
> `Your_Local_Eca`, and the API versions. They compile as a coherent set but are meant to
> be lifted piecemeal. Production hardening (logging, retries, FLS enforcement) is left to
> you where noted.

> **⚠️ Read before reusing — this is a skeleton, not production code.** If you are an AI
> generating a real implementation from this, treat the following as *intentionally
> omitted* and add them deliberately:
>
> - **Error handling is minimal.** Failures are surfaced as broad messages; there are no
>   retries/backoff on transient 5xx or `UNABLE_TO_LOCK_ROW`, and partial-failure rollback
>   of half-created bootstrap components is not handled. The bootstrap is idempotent by
>   design, so the recovery model is "fix and click Run Setup again" — make that explicit
>   to the user.
> - **No CRUD/FLS/sharing enforcement on generated writes.** Any Apex you *generate* must
>   enforce object/field permissions (e.g. `Security.stripInaccessible`, `WITH USER_MODE`,
>   or explicit `isAccessible()`/`isCreateable()` checks). The samples assume a trusted
>   admin context; do not assume that for end users.
> - **Injection surface.** `tag()` XML-escapes values, and SOQL uses
>   `String.escapeSingleQuotes`, but you are still interpolating strings into a generated
>   *Apex class body*. Validate/allow-list every identifier (class name, object/field API
>   names) before it reaches generated source. Never put untrusted free text into a body.
> - **Governor limits aren't guarded.** The bootstrap fires many sequential callouts and
>   the container poll adds more; a large batch of generated classes can blow the 100
>   callouts/transaction limit or the 10s-cumulative wait. Chunk work, and consider
>   Queueable/async for bulk generation.
> - **Secrets handling.** The consumer secret is read into Apex memory and sent to the
>   Metadata API. Don't log it, don't persist it, and scope debug logs accordingly.
> - **Concurrency.** Two admins clicking Run Setup simultaneously, or a generate-on-save
>   firing twice, can race on the same `ApexClass`/container. Add a guard (e.g. a lock
>   record or idempotency check) if that's possible in your UX.
> - **API versions are pinned to `v62.0`/`62.0` as a placeholder.** Set them to a version
>   you actually test against and keep them consistent across helpers.
> - **No automated test coverage targets.** Appendix A.5 gives a mock, not a suite; you
>   still need per-class coverage (incl. the update-via-container and 401/compile-failure
>   branches) to deploy.
>
> Everything below works as a learning scaffold and a fast start; budget a hardening pass
> before shipping to real subscriber orgs.

### A.1 `sfdx-project.json` (2GP unlocked package)

```json
{
  "packageDirectories": [
    {
      "path": "force-app",
      "default": true,
      "package": "YourApp",
      "versionName": "ver 0.1",
      "versionNumber": "0.1.0.NEXT"
    }
  ],
  "name": "YourApp",
  "namespace": "",
  "sfdcLoginUrl": "https://login.salesforce.com",
  "sourceApiVersion": "62.0",
  "packageAliases": {}
}
```

CLI lifecycle:

```bash
# one-time: create the package (writes the alias + 0Ho id into sfdx-project.json)
sf package create --name "YourApp" --package-type Unlocked --path force-app --target-dev-hub YourDevHub

# each release: build a version (beta), then promote so it installs in sandbox/prod
sf package version create --package "YourApp" --installation-key-bypass --code-coverage --wait 60 --target-dev-hub YourDevHub
sf package version promote --package "YourApp@0.1.0-1" --target-dev-hub YourDevHub --no-prompt

# distribute this URL (subscriber installs it):
# https://login.salesforce.com/packaging/installPackage.apexp?p0=<04t...version-id>
```

### A.2 Steady-state Tooling client (create + update via container)

```apex
public with sharing class YourToolingClient {
    private static final String NAMED_CREDENTIAL = 'Your_Tooling';
    private static final String API = 'v62.0';

    private static String base() {
        return 'callout:' + NAMED_CREDENTIAL + '/services/data/' + API + '/tooling';
    }

    // Decide create vs update based on existence.
    public static void upsertApexClass(String className, String body) {
        String existingId = findApexClassId(className);
        if (existingId == null) {
            createApexClass(className, body);
        } else {
            updateApexClassViaContainer(existingId, body);
        }
    }

    private static void createApexClass(String className, String body) {
        HttpResponse res = send('POST', '/sobjects/ApexClass',
            JSON.serialize(new Map<String, Object>{ 'Name' => className, 'Body' => body }));
        if (res.getStatusCode() >= 300) { throwWrite(res); }
    }

    // ApexClass cannot be PATCHed directly; you must compile through a container.
    private static void updateApexClassViaContainer(String existingId, String body) {
        String containerId;
        try {
            containerId = idOf(send('POST', '/sobjects/MetadataContainer',
                JSON.serialize(new Map<String, Object>{ 'Name' => 'YourApp_' + Datetime.now().getTime() })));

            HttpResponse member = send('POST', '/sobjects/ApexClassMember',
                JSON.serialize(new Map<String, Object>{
                    'MetadataContainerId' => containerId,
                    'ContentEntityId' => existingId,
                    'Body' => body
                }));
            if (member.getStatusCode() >= 300) { throwWrite(member); }

            String requestId = idOf(send('POST', '/sobjects/ContainerAsyncRequest',
                JSON.serialize(new Map<String, Object>{ 'MetadataContainerId' => containerId, 'IsCheckOnly' => false })));

            awaitCompile(requestId);
        } finally {
            if (containerId != null) {
                try { send('DELETE', '/sobjects/MetadataContainer/' + containerId, null); }
                catch (Exception ignored) { /* best-effort cleanup */ }
            }
        }
    }

    private static void awaitCompile(String requestId) {
        for (Integer i = 0; i < 30; i++) {
            HttpResponse res = send('GET', '/sobjects/ContainerAsyncRequest/' + requestId, null);
            if (res.getStatusCode() >= 300) { throwWrite(res); }
            Map<String, Object> p = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String state = (String) p.get('State');
            if (state == 'Completed') { return; }
            if (state != 'Queued' && state != 'InProgress') {
                throw new CalloutException('Compile failed: ' + compileError(p));
            }
        }
        throw new CalloutException('Timed out waiting for compile.');
    }

    private static String findApexClassId(String className) {
        String q = 'SELECT Id FROM ApexClass WHERE Name = \'' + String.escapeSingleQuotes(className) + '\'';
        HttpResponse res = send('GET', '/query?q=' + EncodingUtil.urlEncode(q, 'UTF-8'), null);
        if (res.getStatusCode() >= 300) { throwWrite(res); }
        List<Object> recs = (List<Object>) ((Map<String, Object>) JSON.deserializeUntyped(res.getBody())).get('records');
        return recs.isEmpty() ? null : (String) ((Map<String, Object>) recs[0]).get('Id');
    }

    private static HttpResponse send(String method, String path, String body) {
        HttpRequest req = new HttpRequest();
        req.setMethod(method);
        req.setEndpoint(base() + path);
        req.setTimeout(120000);
        if (body != null) { req.setHeader('Content-Type', 'application/json'); req.setBody(body); }
        return new Http().send(req);
    }

    private static String idOf(HttpResponse res) {
        return (String) ((Map<String, Object>) JSON.deserializeUntyped(res.getBody())).get('id');
    }

    private static String compileError(Map<String, Object> p) {
        if (p.get('ErrorMsg') != null) { return String.valueOf(p.get('ErrorMsg')); }
        Object dd = p.get('DeployDetails');
        if (dd instanceof Map<String, Object>) {
            Object fails = ((Map<String, Object>) dd).get('componentFailures');
            if (fails instanceof List<Object>) {
                List<String> msgs = new List<String>();
                for (Object f : (List<Object>) fails) {
                    Object prob = ((Map<String, Object>) f).get('problem');
                    if (prob != null) { msgs.add(String.valueOf(prob)); }
                }
                if (!msgs.isEmpty()) { return String.join(msgs, '; '); }
            }
        }
        return 'Unknown compile error.';
    }

    private static void throwWrite(HttpResponse res) {
        if (res.getStatusCode() == 401) {
            throw new CalloutException('Tooling auth failed (401). Authenticate Named Credential "' + NAMED_CREDENTIAL + '".');
        }
        throw new CalloutException('Tooling write failed (' + res.getStatusCode() + '): ' + res.getBody());
    }
}
```

### A.3 Bootstrap controller (Visualforce) — Metadata SOAP + Connect REST

```apex
public with sharing class YourSetupController {
    private static final String ECA_NAME       = 'Your_Local_Eca';
    private static final String ECA_OAUTH_NAME = 'Your_Local_Eca_oauth';
    private static final String AUTH_PROVIDER  = 'Your_AuthProvider_Local';   // real one, created at runtime
    private static final String EXT_CRED       = 'Your_Tooling_Cred';
    private static final String NAMED_CRED     = 'Your_Tooling';
    private static final String PRINCIPAL      = 'Your_Principal';
    private static final String SCOPES         = 'refresh_token api';
    private static final String META_API       = '62.0';
    private static final String REST_API       = 'v62.0';

    public String message { get; private set; }
    public Boolean succeeded { get; private set; }

    // Bind to <apex:page action="{!run}"> OR a commandButton. Runs with an API-enabled
    // session because it executes in a Visualforce context.
    public PageReference run() {
        List<String> failures = new List<String>();
        try {
            String dom = URL.getOrgDomainUrl().toExternalForm();
            String callbackUrl = dom + '/services/authcallback/' + AUTH_PROVIDER;

            enableSecretRestAccess();                       // 1
            createEca(callbackUrl);                          // 2
            String ecaId = findEcaId();                      // 3
            Map<String, String> creds = readEcaCredentials(dom, ecaId); // 4
            createAuthProvider(creds.get('key'), creds.get('secret'),
                dom + '/services/oauth2/authorize', dom + '/services/oauth2/token'); // 5
            wireExternalCredential();                        // 6
            wireNamedCredential(dom);                        // 7
        } catch (Exception e) {
            failures.add(e.getMessage());
        }
        succeeded = failures.isEmpty();
        message = succeeded
            ? 'Setup complete. Now click Authenticate on the "' + PRINCIPAL + '" principal.'
            : 'Setup failed: ' + String.join(failures, ' | ');

        // DML LAST (callouts above forbid prior uncommitted DML). Best-effort perm-set grant.
        assignPermSet('Your_User');
        return null;
    }

    // ---- Step 1: allow reading the consumer secret over REST ----
    private static void enableSecretRestAccess() {
        meta('updateMetadata',
            '<met:metadata xsi:type="met:ExternalClientAppSettings">' +
            tag('fullName', 'ExternalClientApp') +
            tag('enableClientSecretInRestApiAccess', 'true') +
            '</met:metadata>', false);
    }

    // ---- Step 2: create the local ECA (idempotent) ----
    private static void createEca(String callbackUrl) {
        meta('createMetadata',
            '<met:metadata xsi:type="met:ExternalClientApplication">' +
            tag('fullName', ECA_NAME) + tag('contactEmail', UserInfo.getUserEmail()) +
            tag('distributionState', 'Local') + tag('isProtected', 'false') +
            tag('label', 'Your Local ECA') +
            '</met:metadata>', true);

        meta('createMetadata',
            '<met:metadata xsi:type="met:ExtlClntAppOauthSettings">' +
            tag('fullName', ECA_OAUTH_NAME) + tag('commaSeparatedOauthScopes', 'Api, RefreshToken') +
            tag('externalClientApplication', ECA_NAME) + tag('label', 'Your Local ECA oauth') +
            '</met:metadata>', true);

        meta('createMetadata',
            '<met:metadata xsi:type="met:ExtlClntAppGlobalOauthSettings">' +
            tag('fullName', ECA_NAME) + tag('callbackUrl', callbackUrl) +
            tag('externalClientApplication', ECA_NAME) +
            tag('isConsumerSecretOptional', 'false') + tag('isPkceRequired', 'false') +
            tag('isSecretRequiredForRefreshToken', 'false') +
            tag('label', 'Your Local ECA') +
            '</met:metadata>', true);
    }

    private static String findEcaId() {
        List<SObject> rows = Database.query(
            'SELECT Id FROM ExternalClientApplication WHERE DeveloperName = \'' + ECA_NAME + '\' LIMIT 1');
        if (rows.isEmpty()) { throw new SetupException('ECA created but not found yet; click Run Setup again.'); }
        return String.valueOf(rows[0].get('Id'));
    }

    // ---- Step 4: read key + secret via Connect REST ----
    private static Map<String, String> readEcaCredentials(String dom, String ecaId) {
        String urlBase = dom + '/services/data/' + REST_API + '/apps/oauth/credentials/' + ecaId;
        Map<String, Object> list = (Map<String, Object>) JSON.deserializeUntyped(httpGet(urlBase).getBody());
        List<Object> consumers = (List<Object>) list.get('consumers');
        if (consumers == null || consumers.isEmpty()) { throw new SetupException('No OAuth consumer on the ECA.'); }
        String consumerId = (String) ((Map<String, Object>) consumers[0]).get('id');

        Map<String, Object> sec = (Map<String, Object>) JSON.deserializeUntyped(
            httpGet(urlBase + '/' + consumerId + '?part=keyandsecret').getBody());
        String key = (String) sec.get('key');
        String secret = (String) sec.get('secret');
        if (String.isBlank(key) || String.isBlank(secret)) {
            throw new SetupException('Secret not returned; confirm REST secret access is enabled, then re-run.');
        }
        return new Map<String, String>{ 'key' => key, 'secret' => secret };
    }

    // ---- Step 5: create the REAL Auth Provider (secret is immutable -> create, never patch) ----
    private static void createAuthProvider(String key, String secret, String authorizeUrl, String tokenUrl) {
        meta('createMetadata',
            '<met:metadata xsi:type="met:AuthProvider">' +
            tag('fullName', AUTH_PROVIDER) + tag('authorizeUrl', authorizeUrl) +
            tag('consumerKey', key) + tag('consumerSecret', secret) +
            tag('defaultScopes', SCOPES) + tag('friendlyName', 'Your Tooling') + // <= 32 chars!
            tag('includeOrgIdInIdentifier', 'true') + tag('providerType', 'Salesforce') +
            tag('sendAccessTokenInHeader', 'false') + tag('sendClientCredentialsInHeader', 'false') +
            tag('sendSecretInApis', 'true') + tag('tokenUrl', tokenUrl) +
            '</met:metadata>', true);
    }

    // ---- Step 6: repoint the External Credential to the real Auth Provider ----
    private static void wireExternalCredential() {
        meta('updateMetadata',
            '<met:metadata xsi:type="met:ExternalCredential">' +
            tag('fullName', EXT_CRED) + tag('authenticationProtocol', 'Oauth') +
            '<met:externalCredentialParameters>' +
                tag('parameterGroup', PRINCIPAL) + tag('parameterName', PRINCIPAL) +
                tag('parameterType', 'NamedPrincipal') + tag('sequenceNumber', '1') +
            '</met:externalCredentialParameters>' +
            '<met:externalCredentialParameters>' +
                tag('parameterGroup', 'DefaultGroup') + tag('parameterName', 'Scope') +
                tag('parameterType', 'AuthParameter') + tag('parameterValue', SCOPES) +
            '</met:externalCredentialParameters>' +
            '<met:externalCredentialParameters>' +
                tag('authProvider', AUTH_PROVIDER) + tag('parameterGroup', 'DefaultGroup') +
                tag('parameterName', 'AuthProvider') + tag('parameterType', 'AuthProvider') +
            '</met:externalCredentialParameters>' +
            tag('label', 'Your Tooling Credential') +
            '</met:metadata>', false);
    }

    // ---- Step 7: point the Named Credential at this org ----
    private static void wireNamedCredential(String dom) {
        meta('updateMetadata',
            '<met:metadata xsi:type="met:NamedCredential">' +
            tag('fullName', NAMED_CRED) + tag('calloutStatus', 'Enabled') +
            tag('generateAuthorizationHeader', 'true') + tag('label', 'Your Tooling') +
            '<met:namedCredentialParameters>' +
                tag('parameterName', 'DefaultEndpoint') + tag('parameterType', 'Url') +
                tag('parameterValue', dom) +
            '</met:namedCredentialParameters>' +
            '<met:namedCredentialParameters>' +
                tag('externalCredential', EXT_CRED) + tag('parameterName', 'DefaultAuthentication') +
                tag('parameterType', 'Authentication') +
            '</met:namedCredentialParameters>' +
            tag('namedCredentialType', 'SecuredEndpoint') +
            '</met:metadata>', false);
    }

    private static void assignPermSet(String permSetName) {
        try {
            List<PermissionSet> ps = [SELECT Id FROM PermissionSet WHERE Name = :permSetName LIMIT 1];
            if (ps.isEmpty()) { return; }
            Integer n = [SELECT COUNT() FROM PermissionSetAssignment
                         WHERE AssigneeId = :UserInfo.getUserId() AND PermissionSetId = :ps[0].Id];
            if (n == 0) {
                insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = ps[0].Id);
            }
        } catch (Exception ignored) { /* best-effort */ }
    }

    // ---- HTTP helpers ----
    private static HttpResponse httpGet(String endpoint) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId()); // API-enabled because VF context
        req.setTimeout(120000);
        return new Http().send(req);
    }

    // Sends one create/update; if tolerateDup, swallows "already exists" so re-runs converge.
    private static void meta(String op, String body, Boolean tolerateDup) {
        String env =
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" ' +
            'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ' +
            'xmlns:met="http://soap.sforce.com/2006/04/metadata">' +
            '<soapenv:Header><met:SessionHeader><met:sessionId>' + UserInfo.getSessionId() +
            '</met:sessionId></met:SessionHeader></soapenv:Header>' +
            '<soapenv:Body><met:' + op + '>' + body + '</met:' + op + '></soapenv:Body></soapenv:Envelope>';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + '/services/Soap/m/' + META_API);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
        req.setHeader('SOAPAction', '""');
        req.setTimeout(120000);
        req.setBody(env);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() >= 300) { throw new SetupException(fault(res.getBody())); }

        Dom.Document doc = new Dom.Document();
        doc.load(res.getBody());
        Boolean ok = false; String err = null;
        for (Dom.XmlNode n : flatten(doc.getRootElement())) {
            if (n.getName() == 'success' && n.getText() == 'true') { ok = true; }
            if (n.getName() == 'message') { err = n.getText(); }
        }
        if (!ok) {
            String lower = (err == null ? '' : err.toLowerCase());
            Boolean dup = lower.contains('already') || lower.contains('duplicate') || lower.contains('exist');
            if (!(tolerateDup && dup)) { throw new SetupException(err == null ? 'Metadata op failed.' : err); }
        }
    }

    private static List<Dom.XmlNode> flatten(Dom.XmlNode node) {
        List<Dom.XmlNode> out = new List<Dom.XmlNode>();
        for (Dom.XmlNode c : node.getChildElements()) { out.add(c); out.addAll(flatten(c)); }
        return out;
    }
    private static String fault(String b) {
        try { Dom.Document d = new Dom.Document(); d.load(b);
              for (Dom.XmlNode n : flatten(d.getRootElement())) { if (n.getName() == 'faultstring') { return n.getText(); } }
        } catch (Exception e) {}
        return b == null ? 'No body' : b.abbreviate(500);
    }
    private static String tag(String n, String v) {
        v = v == null ? '' : v.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('"','&quot;').replace('\'','&apos;');
        return '<met:' + n + '>' + v + '</met:' + n + '>';
    }

    public class SetupException extends Exception {}
}
```

### A.4 Visualforce page with a full-page spinner

```html
<apex:page controller="YourSetupController" showHeader="true" sidebar="false">
    <apex:slds />
    <div class="slds-scope slds-p-around_large">
        <apex:actionStatus id="busy">
            <apex:facet name="start">
                <div class="slds-spinner_container" style="position:fixed;top:0;left:0;right:0;bottom:0;z-index:9999;">
                    <div role="status" class="slds-spinner slds-spinner_large slds-spinner_brand">
                        <span class="slds-assistive-text">Working…</span>
                        <div class="slds-spinner__dot-a"></div>
                        <div class="slds-spinner__dot-b"></div>
                    </div>
                </div>
            </apex:facet>
        </apex:actionStatus>

        <apex:form>
            <apex:commandButton value="Run Setup" action="{!run}" status="busy"
                                styleClass="slds-button slds-button_brand" />
        </apex:form>

        <apex:outputPanel rendered="{!NOT(ISNULL(message))}">
            <div class="slds-m-top_medium">{!message}</div>
        </apex:outputPanel>
    </div>
</apex:page>
```

### A.5 Test multiplexer (one mock for every callout)

```apex
@isTest
public class YourCalloutMux implements HttpCalloutMock {
    public String soapMode = 'success';   // success | error | fault
    public Boolean tolerateDup = false;   // make create return a duplicate error
    public Boolean secretMissing = false;

    public HttpResponse respond(HttpRequest req) {
        String url = req.getEndpoint();
        HttpResponse res = new HttpResponse();
        res.setStatusCode(200);

        if (url.contains('/services/Soap/m/')) {
            res.setHeader('Content-Type', 'application/xml');
            Boolean isCreate = req.getBody() != null && req.getBody().contains(':createMetadata>');
            if (soapMode == 'fault') { res.setStatusCode(500); res.setBody(faultXml()); return res; }
            if (isCreate && tolerateDup) { res.setBody(resultXml(false, 'Duplicate value found: already exists')); }
            else if (soapMode == 'error') { res.setBody(resultXml(false, 'Something went wrong')); }
            else { res.setBody(resultXml(true, null)); }
            return res;
        }
        if (url.contains('?part=keyandsecret')) {
            res.setBody(secretMissing ? '{"id":"1","key":"K"}' : '{"id":"1","key":"K","secret":"S"}'); return res;
        }
        if (url.contains('/apps/oauth/credentials/')) {
            res.setBody('{"consumers":[{"id":"1","key":"K"}]}'); return res;
        }
        if (url.contains('/tooling/query')) { res.setBody('{"records":[]}'); return res; }
        if (url.contains('/tooling/sobjects/ContainerAsyncRequest')) { res.setBody('{"id":"R","State":"Completed"}'); return res; }
        if (url.contains('/tooling/sobjects/')) { res.setBody('{"id":"X","success":true}'); return res; }

        res.setBody('{"records":[]}'); return res;
    }

    private String resultXml(Boolean ok, String err) {
        return '<?xml version="1.0"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">' +
            '<soapenv:Body><x xmlns="http://soap.sforce.com/2006/04/metadata"><result>' +
            '<success>' + (ok ? 'true' : 'false') + '</success>' +
            (err == null ? '' : '<errors><message>' + err + '</message></errors>') +
            '</result></x></soapenv:Body></soapenv:Envelope>';
    }
    private String faultXml() {
        return '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><soapenv:Body>' +
            '<soapenv:Fault><faultstring>INVALID_SESSION_ID</faultstring></soapenv:Fault></soapenv:Body></soapenv:Envelope>';
    }
}
```

Usage in a test:

```apex
@isTest static void runSetupSucceeds() {
    Test.setMock(HttpCalloutMock.class, new YourCalloutMux());
    Test.startTest();
    YourSetupController c = new YourSetupController();
    c.run();
    Test.stopTest();
    System.assertEquals(true, c.succeeded, c.message);
}
```

### A.6 Permission set essentials

The permission set must grant the **External Credential principal access** (otherwise the
Named Credential callout returns 401 even after Authorize). In the `.permissionset-meta.xml`:

```xml
<externalCredentialPrincipalAccesses>
    <enabled>true</enabled>
    <externalCredentialPrincipal>Your_Tooling_Cred-Your_Principal</externalCredentialPrincipal>
</externalCredentialPrincipalAccesses>
```

Also include `<classAccesses>` for your controllers, `<pageAccesses>` for the VF page,
`<tabSettings>` for your tabs, and any object/field/flow access your app needs.

### A.7 Deep-link to the External Credential (skip two Setup clicks)

`ExternalCredential` is not SOQL-queryable in Apex; read its Id from the Tooling API:

```apex
String q = 'SELECT+Id+FROM+ExternalCredential+WHERE+DeveloperName=\'Your_Tooling_Cred\'+LIMIT+1';
HttpResponse res = new Http().send(toolingGet('/query/?q=' + q)); // uses the page session or NC
String ecId = (String) ((Map<String, Object>)
    ((List<Object>) ((Map<String, Object>) JSON.deserializeUntyped(res.getBody())).get('records'))[0]).get('Id');
String url = '/lightning/setup/NamedCredential/ExternalCredential/' + ecId + '/view';
```

---

## Appendix B — Order-of-operations cheat sheet

```
PACKAGE BUILD (you, once per release)
  author metadata ──► sf package version create (beta) ──► test in scratch/DE
                                                       └─► sf package version promote (released)

SUBSCRIBER (admin, once per org)
  install link ──► open Setup page ──► [Run Setup]
                                          │ enable REST secret access
                                          │ create local ECA (+oauth +global oauth)
                                          │ read key/secret (Connect REST)
                                          │ create real Auth Provider (with secret)
                                          │ rewire External Credential ──► real Auth Provider
                                          │ rewire Named Credential endpoint ──► this org
                                          │ assign permission set (DML, last)
                                          ▼
                                       [Authenticate] on the principal (one OAuth consent)
                                          ▼
                                       READY

RUNTIME (end users, every time)
  app generates Apex source ──► YourToolingClient.upsertApexClass()
                                   ├─ new?      POST /tooling/sobjects/ApexClass
                                   └─ existing? MetadataContainer ► ApexClassMember
                                                ► ContainerAsyncRequest ► poll ► delete
```
