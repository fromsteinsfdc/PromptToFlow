public with sharing class PromptToFlowBootstrapController {
    // Runtime-created OAuth client (per-subscriber local ECA) + the Auth Provider /
    // External Credential / Named Credential it is wired into.
    @TestVisible
    private static final String ECA_NAME = 'PromptToFlow_Local';
    @TestVisible
    private static final String ECA_OAUTH_NAME = 'PromptToFlow_Local_oauth';
    // The runtime Auth Provider we create with the real per-org secret. It is
    // deliberately distinct from the deploy-only placeholder AuthProvider
    // (PromptToFlow_Tooling) that lets the External Credential deploy: an
    // AuthProvider's consumerSecret is immutable after creation, so the real one
    // must be created fresh here and the External Credential repointed to it.
    @TestVisible
    private static final String AUTH_PROVIDER = 'PromptToFlow_Tooling_Local';
    @TestVisible
    private static final String NAMED_CREDENTIAL = 'PromptToFlow_Tooling';
    @TestVisible
    private static final String EXTERNAL_CREDENTIAL = 'PromptToFlow_Tooling_Cred';
    @TestVisible
    private static final String PRINCIPAL_NAME = 'PromptToFlow_Principal';
    private static final String SETUP_PERMISSION_SET_API_NAME = 'PromptToFlow_User';
    private static final String SCOPES = 'refresh_token api';
    private static final String METADATA_API_VERSION = '60.0';
    private static final String REST_API_VERSION = 'v60.0';

    // Deep link to where the admin completes the one-time Authenticate click.
    private static final String EXTERNAL_CREDENTIAL_URL = '/lightning/setup/NamedCredential/home';

    // --- Visualforce-bound state -------------------------------------------------
    // The setup action runs from a Visualforce page so UserInfo.getSessionId()
    // returns an API-enabled session (Lightning/LWC sessions cannot call the
    // Metadata or Connect REST APIs).
    public Boolean isReady { get; private set; }
    public Boolean toolingReachable { get; private set; }
    public String statusMessage { get; private set; }
    public Boolean setupRan { get; private set; }
    public Boolean setupSucceeded { get; private set; }
    public String setupMessage { get; private set; }
    public String externalCredentialUrl { get; private set; }

    // --- Test seams --------------------------------------------------------------
    @TestVisible
    private static String domainOverride;
    // When set, findEcaId() dequeues from this list instead of querying, so both
    // the "create new ECA" and "ECA already exists" branches are unit-testable.
    @TestVisible
    private static List<String> testEcaIdResults;
    private static Integer ecaQueryCount = 0;

    public PromptToFlowBootstrapController() {
        this.isReady = false;
        this.toolingReachable = false;
        this.setupRan = false;
        this.setupSucceeded = false;
        this.externalCredentialUrl = EXTERNAL_CREDENTIAL_URL;
    }

    // Invoked from the page's action attribute so the status callout is allowed.
    public PageReference init() {
        this.externalCredentialUrl = resolveExternalCredentialUrl();
        refreshStatus();
        return null;
    }

    public PageReference runSetup() {
        BootstrapResult result = applyBootstrapCore();
        this.setupRan = true;
        this.setupSucceeded = result.success;
        this.setupMessage = result.message;
        refreshStatus();
        // DML must come after all callouts above (Apex forbids callouts once there
        // is uncommitted DML). Best-effort: grant the installing admin the access
        // they need, since unlocked packages can't run a post-install script.
        assignSetupPermissionSetToCurrentUser();
        return null;
    }

    // Deep-links straight to the packaged External Credential record so the admin
    // can Authenticate without first navigating the Named Credentials list.
    // ExternalCredential is not a SOQL-queryable SObject, so its Id is read via
    // the Tooling API using the (API-enabled) Visualforce session.
    private static String resolveExternalCredentialUrl() {
        try {
            String query =
                'SELECT+Id+FROM+ExternalCredential+WHERE+DeveloperName=\'' + EXTERNAL_CREDENTIAL + '\'+LIMIT+1';
            HttpResponse response =
                httpGet(getMyDomainUrl() + '/services/data/' + REST_API_VERSION + '/tooling/query/?q=' + query);
            if (response.getStatusCode() == 200) {
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
                List<Object> records = (List<Object>) body.get('records');
                if (records != null && !records.isEmpty()) {
                    String ecId = (String) ((Map<String, Object>) records[0]).get('Id');
                    if (String.isNotBlank(ecId)) {
                        return '/lightning/setup/NamedCredential/ExternalCredential/' + ecId + '/view';
                    }
                }
            }
        } catch (Exception ignored) {
            // Fall back to the Named Credentials home below.
        }
        return EXTERNAL_CREDENTIAL_URL;
    }

    private static void assignSetupPermissionSetToCurrentUser() {
        try {
            List<PermissionSet> permissionSets = [
                SELECT Id FROM PermissionSet WHERE Name = :SETUP_PERMISSION_SET_API_NAME LIMIT 1
            ];
            if (permissionSets.isEmpty()) {
                return;
            }
            Integer alreadyAssigned = [
                SELECT COUNT()
                FROM PermissionSetAssignment
                WHERE AssigneeId = :UserInfo.getUserId()
                AND PermissionSetId = :permissionSets[0].Id
            ];
            if (alreadyAssigned == 0) {
                insert new PermissionSetAssignment(
                    AssigneeId = UserInfo.getUserId(),
                    PermissionSetId = permissionSets[0].Id
                );
            }
        } catch (Exception ignored) {
            // Best-effort; the admin can still assign the permission set manually.
        }
    }

    private void refreshStatus() {
        try {
            PromptToFlowController.ParserGenerationSetupStatusDto status =
                PromptToFlowController.getParserGenerationSetupStatus();
            this.isReady = status.ready == true;
            this.toolingReachable = status.toolingApiReachable == true;
            this.statusMessage = status.message;
        } catch (Exception e) {
            this.isReady = false;
            this.toolingReachable = false;
            this.statusMessage = 'Unable to read setup status: ' + e.getMessage();
        }
    }

    @TestVisible
    private BootstrapResult applyBootstrapCore() {
        String dom = getMyDomainUrl();
        String authorizeUrl = dom + '/services/oauth2/authorize';
        String tokenUrl = dom + '/services/oauth2/token';
        String callbackUrl = dom + '/services/authcallback/' + AUTH_PROVIDER;

        List<String> failures = new List<String>();
        try {
            enableSecretRestAccess();
            String ecaId = ensureLocalEca(callbackUrl);
            Credentials creds = readEcaCredentials(dom, ecaId);
            ensureAuthProvider(creds.key, creds.secret, authorizeUrl, tokenUrl);
            wireExternalCredential();
            wireNamedCredentialEndpoint(dom);
        } catch (Exception e) {
            failures.add(e.getMessage());
        }

        BootstrapResult result = new BootstrapResult();
        result.success = failures.isEmpty();
        result.message = result.success
            ? 'Setup complete. Now click Authenticate on the "' + PRINCIPAL_NAME +
              '" principal of the External Credential to finish the one-time OAuth handshake.'
            : 'Setup could not be completed: ' + String.join(failures, ' | ');
        return result;
    }

    // --- Step 1: allow reading the ECA consumer secret via Connect REST ----------
    private static void enableSecretRestAccess() {
        String body =
            '<met:metadata xsi:type="met:ExternalClientAppSettings">' +
            tag('fullName', 'ExternalClientApp') +
            tag('enableClientSecretInRestApiAccess', 'true') +
            tag('enablePackageEcaOauthFromDevOrg', 'false') +
            '</met:metadata>';
        MetaResult result = sendMetadata('updateMetadata', body);
        if (!result.success) {
            throw new BootstrapException('Enable secret access: ' + describe(result));
        }
    }

    // --- Step 2: create the per-org local ECA (idempotent) -----------------------
    // Each component is created with duplicates tolerated so a re-run (or a
    // partially-completed prior run) converges. Order matters: the OAuth Settings
    // (enablement) must exist before the Global OAuth Settings (key/secret/callback).
    private static String ensureLocalEca(String callbackUrl) {
        createExternalClientApp();
        createOauthSettings();
        createGlobalOauthSettings(callbackUrl);

        String ecaId = findEcaId();
        if (ecaId == null) {
            throw new BootstrapException(
                'The local External Client App was created but could not be located. Click Run Setup again.'
            );
        }
        return ecaId;
    }

    private static String findEcaId() {
        if (testEcaIdResults != null) {
            Integer idx = ecaQueryCount < testEcaIdResults.size()
                ? ecaQueryCount
                : testEcaIdResults.size() - 1;
            ecaQueryCount++;
            return testEcaIdResults[idx];
        }
        List<SObject> rows = Database.query(
            'SELECT Id FROM ExternalClientApplication WHERE DeveloperName = \'' + ECA_NAME + '\' LIMIT 1'
        );
        return rows.isEmpty() ? null : String.valueOf(rows[0].get('Id'));
    }

    private static void createExternalClientApp() {
        String email = UserInfo.getUserEmail();
        if (String.isBlank(email)) {
            email = 'noreply@example.com';
        }
        String body =
            '<met:metadata xsi:type="met:ExternalClientApplication">' +
            tag('fullName', ECA_NAME) +
            tag('contactEmail', email) +
            tag('distributionState', 'Local') +
            tag('isProtected', 'false') +
            tag('label', 'PromptToFlow Local') +
            '</met:metadata>';
        MetaResult result = sendMetadata('createMetadata', body);
        if (!result.success && !isTolerableDuplicate(result)) {
            throw new BootstrapException('External Client App: ' + describe(result));
        }
    }

    private static void createGlobalOauthSettings(String callbackUrl) {
        String body =
            '<met:metadata xsi:type="met:ExtlClntAppGlobalOauthSettings">' +
            tag('fullName', ECA_NAME) +
            tag('callbackUrl', callbackUrl) +
            tag('externalClientApplication', ECA_NAME) +
            tag('isClientCredentialsFlowEnabled', 'false') +
            tag('isConsumerSecretOptional', 'false') +
            tag('isDeviceFlowEnabled', 'false') +
            tag('isIntrospectAllTokens', 'false') +
            tag('isPkceRequired', 'false') +
            tag('isRefreshTokenRotationEnabled', 'false') +
            tag('isSecretRequiredForRefreshToken', 'false') +
            tag('isSecretRequiredForTokenExchange', 'true') +
            tag('isTokenExchangeEnabled', 'false') +
            tag('label', 'PromptToFlow Local') +
            tag('shouldRotateConsumerKey', 'false') +
            tag('shouldRotateConsumerSecret', 'false') +
            '</met:metadata>';
        MetaResult result = sendMetadata('createMetadata', body);
        if (!result.success && !isTolerableDuplicate(result)) {
            throw new BootstrapException('ECA OAuth settings: ' + describe(result));
        }
    }

    private static void createOauthSettings() {
        String body =
            '<met:metadata xsi:type="met:ExtlClntAppOauthSettings">' +
            tag('fullName', ECA_OAUTH_NAME) +
            tag('commaSeparatedOauthScopes', 'Api, RefreshToken') +
            tag('externalClientApplication', ECA_NAME) +
            tag('label', 'PromptToFlow Local oauth') +
            '</met:metadata>';
        MetaResult result = sendMetadata('createMetadata', body);
        if (!result.success && !isTolerableDuplicate(result)) {
            throw new BootstrapException('ECA OAuth enablement: ' + describe(result));
        }
    }

    // --- Step 3: read the generated key + secret via Connect REST ----------------
    private static Credentials readEcaCredentials(String dom, String ecaId) {
        String baseUrl = dom + '/services/data/' + REST_API_VERSION + '/apps/oauth/credentials/' + ecaId;

        HttpResponse listResponse = httpGet(baseUrl);
        if (listResponse.getStatusCode() >= 300) {
            throw new BootstrapException(
                'Could not read OAuth credentials (HTTP ' + listResponse.getStatusCode() + '): ' +
                listResponse.getBody().abbreviate(300)
            );
        }
        Map<String, Object> listBody = (Map<String, Object>) JSON.deserializeUntyped(listResponse.getBody());
        List<Object> consumers = (List<Object>) listBody.get('consumers');
        if (consumers == null || consumers.isEmpty()) {
            throw new BootstrapException('No OAuth consumer was found on the local External Client App.');
        }
        String consumerId = (String) ((Map<String, Object>) consumers[0]).get('id');

        HttpResponse secretResponse = httpGet(baseUrl + '/' + consumerId + '?part=keyandsecret');
        if (secretResponse.getStatusCode() >= 300) {
            throw new BootstrapException(
                'Could not read consumer secret (HTTP ' + secretResponse.getStatusCode() + '): ' +
                secretResponse.getBody().abbreviate(300)
            );
        }
        Map<String, Object> secretBody = (Map<String, Object>) JSON.deserializeUntyped(secretResponse.getBody());
        String key = (String) secretBody.get('key');
        String secret = (String) secretBody.get('secret');
        if (String.isBlank(key) || String.isBlank(secret)) {
            throw new BootstrapException(
                'The consumer secret was not returned. Confirm "Allow access to External Client App ' +
                'consumer secrets via REST API" is enabled, then click Run Setup again.'
            );
        }
        return new Credentials(key, secret);
    }

    // --- Step 4: create the Auth Provider with the real secret (immutable after) -
    private static void ensureAuthProvider(String key, String secret, String authorizeUrl, String tokenUrl) {
        String body =
            '<met:metadata xsi:type="met:AuthProvider">' +
            tag('fullName', AUTH_PROVIDER) +
            tag('authorizeUrl', authorizeUrl) +
            tag('consumerKey', key) +
            tag('consumerSecret', secret) +
            tag('defaultScopes', SCOPES) +
            tag('friendlyName', 'PromptToFlow Tooling') +
            tag('includeOrgIdInIdentifier', 'true') +
            tag('isPkceEnabled', 'false') +
            tag('providerType', 'Salesforce') +
            tag('requireMfa', 'false') +
            tag('sendAccessTokenInHeader', 'false') +
            tag('sendClientCredentialsInHeader', 'false') +
            tag('sendSecretInApis', 'true') +
            tag('tokenUrl', tokenUrl) +
            '</met:metadata>';
        MetaResult result = sendMetadata('createMetadata', body);
        if (!result.success && !isTolerableDuplicate(result)) {
            throw new BootstrapException('Auth Provider: ' + describe(result));
        }
    }

    // --- Step 5: link the External Credential to the Auth Provider ---------------
    private static void wireExternalCredential() {
        String body =
            '<met:metadata xsi:type="met:ExternalCredential">' +
            tag('fullName', EXTERNAL_CREDENTIAL) +
            tag('authenticationProtocol', 'Oauth') +
            '<met:externalCredentialParameters>' +
                tag('parameterGroup', PRINCIPAL_NAME) +
                tag('parameterName', PRINCIPAL_NAME) +
                tag('parameterType', 'NamedPrincipal') +
                tag('sequenceNumber', '1') +
            '</met:externalCredentialParameters>' +
            '<met:externalCredentialParameters>' +
                tag('parameterGroup', 'DefaultGroup') +
                tag('parameterName', 'Scope') +
                tag('parameterType', 'AuthParameter') +
                tag('parameterValue', SCOPES) +
            '</met:externalCredentialParameters>' +
            '<met:externalCredentialParameters>' +
                tag('authProvider', AUTH_PROVIDER) +
                tag('parameterGroup', 'DefaultGroup') +
                tag('parameterName', 'AuthProvider') +
                tag('parameterType', 'AuthProvider') +
            '</met:externalCredentialParameters>' +
            tag('label', 'PromptToFlow Tooling Credential') +
            '</met:metadata>';
        MetaResult result = sendMetadata('updateMetadata', body);
        if (!result.success) {
            throw new BootstrapException('External Credential: ' + describe(result));
        }
    }

    // --- Step 6: point the Named Credential at this org --------------------------
    private static void wireNamedCredentialEndpoint(String dom) {
        String body =
            '<met:metadata xsi:type="met:NamedCredential">' +
            tag('fullName', NAMED_CREDENTIAL) +
            tag('allowMergeFieldsInBody', 'false') +
            tag('allowMergeFieldsInHeader', 'false') +
            tag('calloutStatus', 'Enabled') +
            tag('generateAuthorizationHeader', 'true') +
            tag('label', 'PromptToFlow Tooling') +
            '<met:namedCredentialParameters>' +
                tag('parameterName', 'DefaultEndpoint') +
                tag('parameterType', 'Url') +
                tag('parameterValue', dom) +
            '</met:namedCredentialParameters>' +
            '<met:namedCredentialParameters>' +
                tag('externalCredential', EXTERNAL_CREDENTIAL) +
                tag('parameterName', 'DefaultAuthentication') +
                tag('parameterType', 'Authentication') +
            '</met:namedCredentialParameters>' +
            tag('namedCredentialType', 'SecuredEndpoint') +
            '</met:metadata>';
        MetaResult result = sendMetadata('updateMetadata', body);
        if (!result.success) {
            throw new BootstrapException('Named Credential: ' + describe(result));
        }
    }

    // --- HTTP helpers ------------------------------------------------------------
    private static HttpResponse httpGet(String endpoint) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpoint);
        request.setMethod('GET');
        request.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        request.setTimeout(120000);
        return new Http().send(request);
    }

    private static MetaResult sendMetadata(String operation, String metadataBody) {
        String envelope =
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" ' +
            'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ' +
            'xmlns:met="http://soap.sforce.com/2006/04/metadata">' +
            '<soapenv:Header><met:SessionHeader><met:sessionId>' +
            UserInfo.getSessionId() +
            '</met:sessionId></met:SessionHeader></soapenv:Header>' +
            '<soapenv:Body><met:' + operation + '>' +
            metadataBody +
            '</met:' + operation + '></soapenv:Body></soapenv:Envelope>';

        HttpRequest request = new HttpRequest();
        request.setEndpoint(getMyDomainUrl() + '/services/Soap/m/' + METADATA_API_VERSION);
        request.setMethod('POST');
        request.setHeader('Content-Type', 'text/xml; charset=UTF-8');
        request.setHeader('SOAPAction', '""');
        request.setTimeout(120000);
        request.setBody(envelope);

        HttpResponse response = new Http().send(request);
        return parseMetadataResponse(response);
    }

    private static MetaResult parseMetadataResponse(HttpResponse response) {
        MetaResult result = new MetaResult();
        result.statusCode = response.getStatusCode();
        result.problems = new List<String>();
        String responseBody = response.getBody();

        if (response.getStatusCode() >= 300) {
            result.success = false;
            result.problems.add(extractSoapFault(responseBody));
            return result;
        }

        try {
            Dom.Document doc = new Dom.Document();
            doc.load(responseBody);
            Dom.XmlNode root = doc.getRootElement();
            Boolean sawResult = false;
            for (Dom.XmlNode resultNode : findNodes(root, 'result')) {
                sawResult = true;
                if (childText(resultNode, 'success') == 'true') {
                    result.success = true;
                }
                for (Dom.XmlNode errorNode : childElements(resultNode, 'errors')) {
                    String message = childText(errorNode, 'message');
                    if (String.isNotBlank(message)) {
                        result.problems.add(message);
                    }
                }
            }
            if (!sawResult) {
                result.success = false;
                result.problems.add('No result element. Raw: ' + responseBody.abbreviate(300));
            }
        } catch (Exception e) {
            result.success = false;
            result.problems.add('Could not parse Metadata API response: ' + e.getMessage());
        }
        return result;
    }

    private static Boolean isTolerableDuplicate(MetaResult result) {
        for (String problem : result.problems) {
            String lower = problem == null ? '' : problem.toLowerCase();
            if (lower.contains('already') || lower.contains('duplicate') || lower.contains('exist')) {
                return true;
            }
        }
        return false;
    }

    private static String describe(MetaResult result) {
        return result.problems.isEmpty()
            ? 'No detail returned (HTTP ' + result.statusCode + ').'
            : String.join(result.problems, '; ');
    }

    // --- XML helpers -------------------------------------------------------------
    private static List<Dom.XmlNode> findNodes(Dom.XmlNode node, String localName) {
        List<Dom.XmlNode> matches = new List<Dom.XmlNode>();
        for (Dom.XmlNode child : node.getChildElements()) {
            if (child.getName() == localName) {
                matches.add(child);
            }
            matches.addAll(findNodes(child, localName));
        }
        return matches;
    }

    private static List<Dom.XmlNode> childElements(Dom.XmlNode parent, String localName) {
        List<Dom.XmlNode> matches = new List<Dom.XmlNode>();
        for (Dom.XmlNode child : parent.getChildElements()) {
            if (child.getName() == localName) {
                matches.add(child);
            }
        }
        return matches;
    }

    private static String childText(Dom.XmlNode parent, String localName) {
        for (Dom.XmlNode child : parent.getChildElements()) {
            if (child.getName() == localName) {
                return child.getText();
            }
        }
        return null;
    }

    private static String extractSoapFault(String responseBody) {
        if (String.isBlank(responseBody)) {
            return 'No response body.';
        }
        try {
            Dom.Document doc = new Dom.Document();
            doc.load(responseBody);
            for (Dom.XmlNode node : findNodes(doc.getRootElement(), 'faultstring')) {
                return node.getText();
            }
        } catch (Exception e) {
            // fall through to raw body
        }
        return responseBody.abbreviate(500);
    }

    private static String getMyDomainUrl() {
        if (String.isNotBlank(domainOverride)) {
            return domainOverride;
        }
        return URL.getOrgDomainUrl().toExternalForm();
    }

    private static String tag(String name, String value) {
        return '<met:' + name + '>' + escapeXml(value) + '</met:' + name + '>';
    }

    private static String escapeXml(String value) {
        if (value == null) {
            return '';
        }
        return value
            .replace('&', '&amp;')
            .replace('<', '&lt;')
            .replace('>', '&gt;')
            .replace('"', '&quot;')
            .replace('\'', '&apos;');
    }

    // --- Inner types -------------------------------------------------------------
    @TestVisible
    private class Credentials {
        public String key;
        public String secret;
        public Credentials(String key, String secret) {
            this.key = key;
            this.secret = secret;
        }
    }

    @TestVisible
    private class MetaResult {
        public Boolean success = false;
        public Integer statusCode;
        public List<String> problems;
    }

    @TestVisible
    private class BootstrapResult {
        public Boolean success;
        public String message;
    }

    public class BootstrapException extends Exception {}
}
