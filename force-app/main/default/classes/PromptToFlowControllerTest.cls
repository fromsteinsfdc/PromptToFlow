@IsTest
private class PromptToFlowControllerTest {
    // ------------------------------------------------------------------
    // Callout mocks
    // ------------------------------------------------------------------

    // Tooling API (parser Apex class create). Query returns no existing class
    // so the create branch runs.
    private class ToolingApiMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            if (req.getEndpoint().contains('/tooling/query')) {
                response.setBody('{"totalSize":0,"records":[]}');
            } else if (req.getMethod() == 'POST' && req.getEndpoint().contains('/tooling/sobjects/ApexClass')) {
                response.setBody('{"id":"01p000000000001AAA","success":true}');
            } else {
                response.setBody('{}');
            }
            return response;
        }
    }

    // Tooling API (parser Apex class update via MetadataContainer). Query returns
    // an existing class so the container update branch runs.
    private class ToolingUpdateMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            String endpoint = req.getEndpoint();
            String method = req.getMethod();
            if (endpoint.contains('/tooling/query')) {
                response.setBody('{"totalSize":1,"records":[{"Id":"01p000000000001AAA"}]}');
            } else if (method == 'POST' && endpoint.contains('/sobjects/MetadataContainer')) {
                response.setStatusCode(201);
                response.setBody('{"id":"1dc000000000001AAA","success":true}');
            } else if (method == 'POST' && endpoint.contains('/sobjects/ApexClassMember')) {
                response.setStatusCode(201);
                response.setBody('{"id":"400000000000001AAA","success":true}');
            } else if (method == 'POST' && endpoint.contains('/sobjects/ContainerAsyncRequest')) {
                response.setStatusCode(201);
                response.setBody('{"id":"1dr000000000001AAA","success":true}');
            } else if (method == 'GET' && endpoint.contains('/sobjects/ContainerAsyncRequest/')) {
                response.setBody('{"State":"Completed"}');
            } else if (method == 'DELETE') {
                response.setStatusCode(204);
            } else {
                response.setBody('{"id":"01p000000000001AAA","success":true}');
            }
            return response;
        }
    }

    private class ToolingCompileFailMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            String endpoint = req.getEndpoint();
            String method = req.getMethod();
            if (endpoint.contains('/tooling/query')) {
                response.setBody('{"totalSize":1,"records":[{"Id":"01p000000000001AAA"}]}');
            } else if (method == 'POST' && endpoint.contains('/sobjects/MetadataContainer')) {
                response.setStatusCode(201);
                response.setBody('{"id":"1dc000000000001AAA"}');
            } else if (method == 'POST' && endpoint.contains('/sobjects/ApexClassMember')) {
                response.setStatusCode(201);
                response.setBody('{"id":"400000000000001AAA"}');
            } else if (method == 'POST' && endpoint.contains('/sobjects/ContainerAsyncRequest')) {
                response.setStatusCode(201);
                response.setBody('{"id":"1dr000000000001AAA"}');
            } else if (method == 'GET' && endpoint.contains('/sobjects/ContainerAsyncRequest/')) {
                response.setBody('{"State":"Failed","DeployDetails":{"componentFailures":[{"problem":"Unexpected token"}]}}');
            } else if (method == 'DELETE') {
                response.setStatusCode(204);
            } else {
                response.setBody('{"id":"01p000000000001AAA"}');
            }
            return response;
        }
    }

    private class ToolingCreate401Mock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse response = new HttpResponse();
            if (req.getEndpoint().contains('/tooling/query')) {
                response.setStatusCode(200);
                response.setBody('{"totalSize":0,"records":[]}');
            } else {
                response.setStatusCode(401);
                response.setBody('[{"message":"Session expired or invalid","errorCode":"INVALID_SESSION_ID"}]');
            }
            return response;
        }
    }

    // SOAP Metadata API (custom metadata upsert/delete).
    private class MetadataSoapSuccessMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setHeader('Content-Type', 'text/xml');
            response.setBody(
                '<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope><soapenv:Body>' +
                '<result><fullName>PromptToFlow_Configuration.Test</fullName><success>true</success></result>' +
                '</soapenv:Body></soapenv:Envelope>'
            );
            return response;
        }
    }

    private class MetadataSoapFailFalseMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(
                '<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope><soapenv:Body>' +
                '<result><success>false</success><errors><message>Invalid field value</message></errors></result>' +
                '</soapenv:Body></soapenv:Envelope>'
            );
            return response;
        }
    }

    private class MetadataSoapFaultMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(500);
            response.setBody(
                '<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope><soapenv:Body>' +
                '<soapenv:Fault><faultstring>INVALID_TYPE: metadata type not found</faultstring></soapenv:Fault>' +
                '</soapenv:Body></soapenv:Envelope>'
            );
            return response;
        }
    }

    private class MetadataSoap401Mock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(401);
            response.setBody('Unauthorized');
            return response;
        }
    }

    // ------------------------------------------------------------------
    // Schema helpers (unchanged behavior)
    // ------------------------------------------------------------------

    @IsTest
    static void getAvailableObjects_returnsRows() {
        Test.startTest();
        List<PromptToFlowController.ObjectOption> options = PromptToFlowController.getAvailableObjects();
        Test.stopTest();
        System.assert(options.size() > 0, 'Expected at least one object option.');
    }

    @IsTest
    static void getFieldsForObject_returnsRows() {
        Test.startTest();
        List<PromptToFlowController.FieldOption> fields = PromptToFlowController.getFieldsForObject('Account');
        Test.stopTest();
        System.assert(fields.size() > 0, 'Expected Account fields to be returned.');
    }

    @IsTest
    static void getFieldsForObject_blankThrows() {
        Boolean threw = false;
        try {
            PromptToFlowController.getFieldsForObject('');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw);
    }

    // ------------------------------------------------------------------
    // Parser source generation (pure functions)
    // ------------------------------------------------------------------

    @IsTest
    static void generateInvocableParserSource_containsConfiguredFields() {
        String configJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'apiName' => 'Account',
                'isCollection' => false,
                'selectedFields' => new List<String>{ 'Name', 'Phone' }
            }
        });
        String source = PromptToFlowController.generateInvocableParserSource('DemoGeneratedParser', configJson, 'Demo Action');
        System.assert(source.contains('class DemoGeneratedParser'));
        System.assert(source.contains('payload.get('));
        System.assert(source.contains('Account'));
        System.assert(source.contains('Name'));
        System.assert(source.contains('Phone'));
    }

    @IsTest
    static void generateInvocableParserSource_collectionUsesJsonKey() {
        String configJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'apiName' => 'Opportunity',
                'jsonKey' => 'Opportunities',
                'isCollection' => true,
                'selectedFields' => new List<String>{ 'StageName' }
            }
        });
        String source = PromptToFlowController.generateInvocableParserSource('DemoPluralParser', configJson, 'Demo Plural');
        System.assert(source.contains('payload.get(\'Opportunities\')'), 'Parser should read the plural JSON key.');
        System.assert(source.contains('List<Opportunity>'), 'SObject type should stay the API name.');
        System.assert(source.contains('@InvocableVariable(label=\'Opportunities\')'), 'Output label should use the plural key.');
    }

    @IsTest
    static void getInvocableParserSource_returnsGeneratedClass() {
        String configJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'apiName' => 'Account',
                'isCollection' => false,
                'selectedFields' => new List<String>{ 'Name' }
            }
        });
        String source = PromptToFlowController.getInvocableParserSource('MyParserClass', configJson, 'My Parser Label');
        System.assert(source.contains('class MyParserClass'));
        System.assert(source.contains('payload.get('));
    }

    // ------------------------------------------------------------------
    // Read path + DTO mapping (in-memory __mdt records)
    // ------------------------------------------------------------------

    @IsTest
    static void getConfigurations_returnsList() {
        Test.startTest();
        List<PromptToFlowController.ConfigurationRecordDto> configs = PromptToFlowController.getConfigurations();
        Test.stopTest();
        System.assertNotEquals(null, configs, 'getConfigurations should never return null.');
    }

    @IsTest
    static void toDto_mapsFieldsAndLeavesNameUnlockedWhenClassMissing() {
        PromptToFlow_Configuration__mdt record = new PromptToFlow_Configuration__mdt(
            DeveloperName = 'Sample_Config',
            MasterLabel = 'Sample Config',
            Configuration_JSON__c = '[{"apiName":"Account"}]',
            Template_JSON__c = '{"Account":[]}',
            Invocable_Action_Label__c = 'Sample Action',
            Parser_Class_Name__c = 'ZZ_ParserThatDoesNotExist_ZZ',
            Generate_Parser_On_Save__c = true
        );

        PromptToFlowController.ConfigurationRecordDto dto = PromptToFlowController.toDto(record);

        System.assertEquals('Sample_Config', dto.developerName);
        System.assertEquals('Sample Config', dto.name);
        System.assertEquals('[{"apiName":"Account"}]', dto.configurationJson);
        System.assertEquals('Sample Action', dto.invocableActionLabel);
        System.assertEquals('ZZ_ParserThatDoesNotExist_ZZ', dto.parserClassName);
        System.assertEquals(true, dto.generateParserOnSave);
        System.assertEquals(false, dto.parserClassNameLocked, 'No matching Apex class exists, so name is unlocked.');
    }

    @IsTest
    static void toDto_locksNameWhenClassExists() {
        // Point at a real Apex class so the SOQL existence check treats it as generated.
        PromptToFlow_Configuration__mdt record = new PromptToFlow_Configuration__mdt(
            DeveloperName = 'Locked_Config',
            MasterLabel = 'Locked Config',
            Parser_Class_Name__c = 'PromptToFlowController'
        );
        PromptToFlowController.ConfigurationRecordDto dto = PromptToFlowController.toDto(record);
        System.assertEquals(true, dto.parserClassNameLocked, 'Existing Apex class should lock the name.');
    }

    // ------------------------------------------------------------------
    // DeveloperName derivation
    // ------------------------------------------------------------------

    @IsTest
    static void deriveUniqueDeveloperName_sanitizesInput() {
        String result = PromptToFlowController.deriveUniqueDeveloperName('My Config! 123');
        System.assert(Pattern.matches('[A-Za-z][A-Za-z0-9_]*', result), 'Must be a valid API name: ' + result);
        System.assert(result.length() <= 40, 'Must respect the 40 char ceiling.');
    }

    @IsTest
    static void deriveUniqueDeveloperName_prefixesWhenStartsWithNonLetter() {
        String result = PromptToFlowController.deriveUniqueDeveloperName('123 leading digits');
        System.assert(result.startsWith('Config'), 'Names not starting with a letter get a Config prefix: ' + result);
    }

    @IsTest
    static void deriveUniqueDeveloperName_fallsBackForEmptyInput() {
        String result = PromptToFlowController.deriveUniqueDeveloperName('***');
        System.assert(Pattern.matches('[A-Za-z][A-Za-z0-9_]*', result), 'Must still produce a valid name: ' + result);
    }

    // ------------------------------------------------------------------
    // Save path (SOAP upsert). The record is never persisted in a test, so the
    // read-back after a successful upsert surfaces the "not yet available"
    // guard. The write path (validation, derivation, callout) still executes.
    // ------------------------------------------------------------------

    @IsTest
    static void saveConfiguration_runsWritePathThenReadBackGuard() {
        String configJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'apiName' => 'Account',
                'isCollection' => true,
                'selectedFields' => new List<String>{ 'Name' }
            }
        });

        Test.setMock(HttpCalloutMock.class, new MetadataSoapSuccessMock());
        Boolean threw = false;
        Test.startTest();
        try {
            PromptToFlowController.saveConfiguration(
                null,
                'Round Trip Config',
                configJson,
                '{"Account":[{"Name":"string"}]}',
                'Generated Parser Demo',
                false
            );
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw, 'Read-back guard should fire because __mdt records do not persist in tests.');
    }

    @IsTest
    static void saveConfiguration_validatesRequiredFields() {
        Boolean threw = false;
        try {
            PromptToFlowController.saveConfiguration(null, '', '[]', '{}', 'Label', false);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw);
    }

    @IsTest
    static void saveConfiguration_rejectsOverlongName() {
        String longName = 'X'.repeat(60);
        Boolean threw = false;
        try {
            PromptToFlowController.saveConfiguration(
                null,
                longName,
                '[{"apiName":"Account","isCollection":true,"selectedFields":["Name"]}]',
                '{"Account":[]}',
                'Label',
                false
            );
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Names longer than the metadata label limit should be rejected.');
    }

    // ------------------------------------------------------------------
    // SOAP helpers exercised directly
    // ------------------------------------------------------------------

    @IsTest
    static void upsertConfigMetadata_succeeds() {
        Test.setMock(HttpCalloutMock.class, new MetadataSoapSuccessMock());
        Test.startTest();
        PromptToFlowController.upsertConfigMetadata(
            'Sample_Config',
            'Sample & <Config>',
            new Map<String, Object>{
                'Configuration_JSON__c' => '[{"apiName":"Account"}]',
                'Generate_Parser_On_Save__c' => true
            }
        );
        Test.stopTest();
        System.assert(true, 'Successful SOAP upsert should not throw.');
    }

    @IsTest
    static void upsertConfigMetadata_successFalseThrows() {
        Test.setMock(HttpCalloutMock.class, new MetadataSoapFailFalseMock());
        Boolean threw = false;
        Test.startTest();
        try {
            PromptToFlowController.upsertConfigMetadata('Sample_Config', 'Label', new Map<String, Object>{ 'a' => 'b' });
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @IsTest
    static void upsertConfigMetadata_faultThrows() {
        Test.setMock(HttpCalloutMock.class, new MetadataSoapFaultMock());
        Boolean threw = false;
        Test.startTest();
        try {
            PromptToFlowController.upsertConfigMetadata('Sample_Config', 'Label', new Map<String, Object>{ 'a' => 'b' });
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @IsTest
    static void deleteConfigMetadata_succeeds() {
        Test.setMock(HttpCalloutMock.class, new MetadataSoapSuccessMock());
        Test.startTest();
        PromptToFlowController.deleteConfigMetadata(new List<String>{ 'PromptToFlow_Configuration.Sample_Config' });
        Test.stopTest();
        System.assert(true, 'Successful SOAP delete should not throw.');
    }

    @IsTest
    static void deleteConfigMetadata_unauthorizedThrows() {
        Test.setMock(HttpCalloutMock.class, new MetadataSoap401Mock());
        Boolean threw = false;
        Test.startTest();
        try {
            PromptToFlowController.deleteConfigMetadata(new List<String>{ 'PromptToFlow_Configuration.Sample_Config' });
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @IsTest
    static void deleteConfiguration_nullIdThrows() {
        Boolean threw = false;
        try {
            PromptToFlowController.deleteConfiguration(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'A null configuration Id should surface an error.');
    }

    // ------------------------------------------------------------------
    // Parser generation (Tooling API) using in-memory __mdt records
    // ------------------------------------------------------------------

    @IsTest
    static void generateParserForRecord_createsClass() {
        PromptToFlow_Configuration__mdt record = new PromptToFlow_Configuration__mdt(
            DeveloperName = 'Gen_Config',
            MasterLabel = 'Gen Config',
            Configuration_JSON__c = '[{"apiName":"Account","isCollection":true,"selectedFields":["Name"]}]',
            Invocable_Action_Label__c = 'Generated Parser Action',
            Parser_Class_Name__c = 'GeneratedParserFromTest'
        );
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock());
        Test.startTest();
        PromptToFlowController.generateParserForRecord(record);
        Test.stopTest();
        System.assert(true, 'Create branch should complete without error.');
    }

    @IsTest
    static void generateParserForRecord_updatesExistingClassViaContainer() {
        PromptToFlow_Configuration__mdt record = new PromptToFlow_Configuration__mdt(
            DeveloperName = 'Update_Config',
            MasterLabel = 'Update Config',
            Configuration_JSON__c = '[{"apiName":"Account","isCollection":true,"selectedFields":["Name"]}]',
            Parser_Class_Name__c = 'PTF_ExistingParser',
            Invocable_Action_Label__c = 'PTF Existing Parser'
        );
        Test.setMock(HttpCalloutMock.class, new ToolingUpdateMock());
        Test.startTest();
        PromptToFlowController.generateParserForRecord(record);
        Test.stopTest();
        System.assert(true, 'Update via metadata container should complete without error.');
    }

    @IsTest
    static void generateParserForRecord_compileFailureThrows() {
        PromptToFlow_Configuration__mdt record = new PromptToFlow_Configuration__mdt(
            DeveloperName = 'Fail_Config',
            MasterLabel = 'Fail Config',
            Configuration_JSON__c = '[{"apiName":"Account","isCollection":true,"selectedFields":["Name"]}]',
            Parser_Class_Name__c = 'PTF_CompileFailParser',
            Invocable_Action_Label__c = 'PTF Compile Fail Parser'
        );
        Test.setMock(HttpCalloutMock.class, new ToolingCompileFailMock());
        Boolean threw = false;
        Test.startTest();
        try {
            PromptToFlowController.generateParserForRecord(record);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw, 'A failed compile should surface an error.');
    }

    @IsTest
    static void generateParserForRecord_writeError401Throws() {
        PromptToFlow_Configuration__mdt record = new PromptToFlow_Configuration__mdt(
            DeveloperName = 'Auth_Config',
            MasterLabel = 'Auth Config',
            Configuration_JSON__c = '[{"apiName":"Account","isCollection":true,"selectedFields":["Name"]}]',
            Parser_Class_Name__c = 'PTF_Write401Parser',
            Invocable_Action_Label__c = 'PTF Write 401 Parser'
        );
        Test.setMock(HttpCalloutMock.class, new ToolingCreate401Mock());
        Boolean threw = false;
        Test.startTest();
        try {
            PromptToFlowController.generateParserForRecord(record);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw, 'A 401 from the Tooling API should surface an error.');
    }

    @IsTest
    static void generateParserForRecord_blankClassNameThrows() {
        PromptToFlow_Configuration__mdt record = new PromptToFlow_Configuration__mdt(
            DeveloperName = 'Blank_Config',
            MasterLabel = 'Blank Config',
            Configuration_JSON__c = '[{"apiName":"Account"}]'
        );
        Boolean threw = false;
        try {
            PromptToFlowController.generateParserForRecord(record);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'A blank parser class name should surface an error.');
    }

    @IsTest
    static void generateParserForConfiguration_nullIdThrows() {
        Boolean threw = false;
        try {
            PromptToFlowController.generateParserForConfiguration(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw);
    }

    // ------------------------------------------------------------------
    // Setup status
    // ------------------------------------------------------------------

    @IsTest
    static void getParserGenerationSetupStatus_returnsStatusShape() {
        Test.startTest();
        PromptToFlowController.ParserGenerationSetupStatusDto status =
            PromptToFlowController.getParserGenerationSetupStatus();
        Test.stopTest();
        System.assertNotEquals(null, status);
        System.assertNotEquals(null, status.permissionSetApiName);
        System.assertNotEquals(null, status.ready);
    }
}
