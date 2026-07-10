# PromptToFlow

PromptToFlow lets a Salesforce admin turn the JSON output of a prompt template into native, typed Salesforce records and fields that a Flow can act on — no code required.

## Key resources

- **Demo video:** [Prompt To Flow demo v1](https://salesforce.vidyard.com/watch/ayhXodKBFStR8PYgSkM3VZ)
- **Install the latest version (0.1.1-3):**
  - Production / Developer Edition: [Install PromptToFlow](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000LvXxAAK)
  - Sandbox: [Install PromptToFlow](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000LvXxAAK)

## Install & set up

- **Install the package** using the link above; install for **Admins Only** (or All Users) when prompted.
- **Open the `PromptToFlow Setup` tab** and click **Run Setup**. This automatically assigns the included Permission Set and creates the per‑org OAuth client and wires the Auth Provider, External Credential, and Named Credential — there are no keys or secrets to copy.
- **Authenticate once:** Also on the `PromptToFlow Setup` page, click **Open External Credentials** and on the `PromptToFlow_Principal` click **Authenticate** to complete the one‑time OAuth handshake.

## Using the app

- **Open the builder:** go to the **`PromptToFlow Builder`** tab (the *JSON Template Builder*).
- **Name the configuration:** enter a **Configuration Name** and an **Invocable Action Label** (40 characters max — this label also becomes the generated Apex parser class name and the Flow action you'll call).
- **Add objects and fields:** click **+** to add each object the response should contain, pick the object, toggle **Collection (array)** if it should return multiple records, and choose the fields to include.
- **Preview & copy:** expand the preview to review the generated JSON, and use **Copy Output** to grab the template.
- **Save:** click **Save** to store the configuration (as Custom Metadata) and generate its Apex parser invocable action. Saving requires the setup steps above to be complete.
- **Feed the template into your prompt:** in your Prompt Template, add the **`PromptToFlow JSON Template Retriever`** flow and pass it the configuration (by Name or record). It injects your JSON template into the prompt instructions so the model returns output in exactly that shape.
- **Parse the response in a Flow:** in your Flow, call the generated invocable action (named by your **Invocable Action Label**) to parse the prompt's JSON response into the typed sObjects and collections your Flow can then use.

---

For internal design and packaging details, see `DESIGN_NOTES.md` and `AUTH_PACKAGING_2GP.md`.
