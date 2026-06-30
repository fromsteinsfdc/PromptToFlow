@isTest
private class PromptToFlowBootstrapControllerTest {
    private static final String DOMAIN = 'https://example.my.salesforce.com';

    // Routes the controller's three callout families (Metadata SOAP, Connect REST
    // credentials, and the Tooling status check) to canned responses, with knobs
    // to simulate failures.
    private class Mux implements HttpCalloutMock {
        public String soapMode = 'success'; // success | error | fault
        public Boolean createDuplicate = false;
        public Boolean secretMissing = false;

        public HttpResponse respond(HttpRequest req) {
            String url = req.getEndpoint();
            String body = req.getBody();
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/xml');

            if (url.contains('/services/Soap/m/')) {
                Boolean isCreate = body != null && body.contains(':createMetadata>');
                if (soapMode == 'fault') {
                    res.setStatusCode(500);
                    res.setBody(faultEnvelope());
                    return res;
                }
                res.setStatusCode(200);
                if (isCreate && createDuplicate) {
                    res.setBody(resultEnvelope(false, 'createMetadataResponse', 'Duplicate value found: already exists'));
                } else if (soapMode == 'error') {
                    res.setBody(resultEnvelope(false, 'updateMetadataResponse', 'Something went wrong'));
                } else {
                    res.setBody(resultEnvelope(true, isCreate ? 'createMetadataResponse' : 'updateMetadataResponse', null));
                }
                return res;
            }

            if (url.contains('?part=keyandsecret')) {
                res.setStatusCode(200);
                res.setBody(secretMissing
                    ? '{"id":"888","key":"KEYX"}'
                    : '{"id":"888","key":"KEYX","secret":"SECRETX"}');
                return res;
            }

            if (url.contains('/apps/oauth/credentials/')) {
                res.setStatusCode(200);
                res.setBody('{"consumers":[{"id":"888","key":"KEYX"}]}');
                return res;
            }

            if (url.contains('/tooling/query') && url.contains('ExternalCredential')) {
                res.setStatusCode(200);
                res.setBody('{"size":1,"records":[{"Id":"0ptTEST000000001","DeveloperName":"PromptToFlow_Tooling_Cred"}]}');
                return res;
            }

            // Tooling status check via the Named Credential.
            res.setStatusCode(200);
            res.setBody('{"records":[]}');
            return res;
        }
    }

    private static String resultEnvelope(Boolean ok, String responseName, String errorMessage) {
        return
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">' +
            '<soapenv:Body><' + responseName + ' xmlns="http://soap.sforce.com/2006/04/metadata">' +
            '<result><fullName>PromptToFlow</fullName><success>' + (ok ? 'true' : 'false') + '</success>' +
            (errorMessage == null
                ? ''
                : '<errors><message>' + errorMessage + '</message><statusCode>X</statusCode></errors>') +
            '</result></' + responseName + '></soapenv:Body></soapenv:Envelope>';
    }

    private static String faultEnvelope() {
        return
            '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">' +
            '<soapenv:Body><soapenv:Fault><faultcode>sf:INVALID_SESSION_ID</faultcode>' +
            '<faultstring>INVALID_SESSION_ID: Invalid Session ID</faultstring>' +
            '</soapenv:Fault></soapenv:Body></soapenv:Envelope>';
    }

    @isTest
    static void initLoadsStatusWithoutError() {
        PromptToFlowBootstrapController.domainOverride = DOMAIN;
        Test.setMock(HttpCalloutMock.class, new Mux());
        Test.startTest();
        PromptToFlowBootstrapController ctrl = new PromptToFlowBootstrapController();
        ctrl.init();
        Test.stopTest();

        System.assertNotEquals(null, ctrl.statusMessage, 'Status message should be populated.');
        System.assertEquals(
            '/lightning/setup/NamedCredential/ExternalCredential/0ptTEST000000001/view',
            ctrl.externalCredentialUrl,
            'Should deep-link to the resolved External Credential record.'
        );
    }

    @isTest
    static void runSetupCreatesEcaAndSucceeds() {
        PromptToFlowBootstrapController.domainOverride = DOMAIN;
        PromptToFlowBootstrapController.testEcaIdResults = new List<String>{ '0xITEST000000001' };
        Test.setMock(HttpCalloutMock.class, new Mux());
        Test.startTest();
        PromptToFlowBootstrapController ctrl = new PromptToFlowBootstrapController();
        ctrl.runSetup();
        Test.stopTest();

        System.assertEquals(true, ctrl.setupRan);
        System.assertEquals(true, ctrl.setupSucceeded, ctrl.setupMessage);
        System.assert(ctrl.setupMessage.contains('Authenticate'), ctrl.setupMessage);
    }

    @isTest
    static void runSetupReusesExistingEca() {
        PromptToFlowBootstrapController.domainOverride = DOMAIN;
        PromptToFlowBootstrapController.testEcaIdResults = new List<String>{ '0xITEST000000001' };
        Test.setMock(HttpCalloutMock.class, new Mux());
        Test.startTest();
        PromptToFlowBootstrapController ctrl = new PromptToFlowBootstrapController();
        ctrl.runSetup();
        Test.stopTest();

        System.assertEquals(true, ctrl.setupSucceeded, ctrl.setupMessage);
    }

    @isTest
    static void runSetupToleratesDuplicateComponents() {
        PromptToFlowBootstrapController.domainOverride = DOMAIN;
        PromptToFlowBootstrapController.testEcaIdResults = new List<String>{ '0xITEST000000001' };
        Mux mock = new Mux();
        mock.createDuplicate = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        PromptToFlowBootstrapController ctrl = new PromptToFlowBootstrapController();
        ctrl.runSetup();
        Test.stopTest();

        System.assertEquals(true, ctrl.setupSucceeded, ctrl.setupMessage);
    }

    @isTest
    static void runSetupReportsMetadataError() {
        PromptToFlowBootstrapController.domainOverride = DOMAIN;
        PromptToFlowBootstrapController.testEcaIdResults = new List<String>{ '0xITEST000000001' };
        Mux mock = new Mux();
        mock.soapMode = 'error';
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        PromptToFlowBootstrapController ctrl = new PromptToFlowBootstrapController();
        ctrl.runSetup();
        Test.stopTest();

        System.assertEquals(false, ctrl.setupSucceeded);
        System.assert(ctrl.setupMessage.contains('Something went wrong'), ctrl.setupMessage);
    }

    @isTest
    static void runSetupReportsSoapFault() {
        PromptToFlowBootstrapController.domainOverride = DOMAIN;
        PromptToFlowBootstrapController.testEcaIdResults = new List<String>{ '0xITEST000000001' };
        Mux mock = new Mux();
        mock.soapMode = 'fault';
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        PromptToFlowBootstrapController ctrl = new PromptToFlowBootstrapController();
        ctrl.runSetup();
        Test.stopTest();

        System.assertEquals(false, ctrl.setupSucceeded);
        System.assert(ctrl.setupMessage.contains('Invalid Session ID'), ctrl.setupMessage);
    }

    @isTest
    static void runSetupReportsMissingSecret() {
        PromptToFlowBootstrapController.domainOverride = DOMAIN;
        PromptToFlowBootstrapController.testEcaIdResults = new List<String>{ '0xITEST000000001' };
        Mux mock = new Mux();
        mock.secretMissing = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        PromptToFlowBootstrapController ctrl = new PromptToFlowBootstrapController();
        ctrl.runSetup();
        Test.stopTest();

        System.assertEquals(false, ctrl.setupSucceeded);
        System.assert(ctrl.setupMessage.contains('consumer secret'), ctrl.setupMessage);
    }
}
