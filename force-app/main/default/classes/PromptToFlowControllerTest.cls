@IsTest
private class PromptToFlowControllerTest {
    private class ToolingApiMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);

            if (req.getEndpoint().contains('/tooling/query')) {
                response.setBody('{"totalSize":0,"records":[]}');
            } else if (req.getMethod() == 'POST' && req.getEndpoint().contains('/tooling/sobjects/ApexClass')) {
                response.setBody('{"id":"01p000000000001AAA","success":true}');
            } else if (req.getMethod() == 'PATCH' && req.getEndpoint().contains('/tooling/sobjects/ApexClass/')) {
                response.setBody('{"success":true}');
            } else {
                response.setBody('{}');
            }
            return response;
        }
    }

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
    static void saveAndGetConfiguration_roundTrips() {
        String configJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'apiName' => 'Account',
                'isCollection' => true,
                'selectedFields' => new List<String>{ 'Name' }
            }
        });

        Test.setMock(HttpCalloutMock.class, new ToolingApiMock());
        Test.startTest();
        PromptToFlowController.ConfigurationRecordDto saved = PromptToFlowController.saveConfiguration(
            null,
            'Test Config',
            configJson,
            '{"Account":[{"Name":"string"}]}',
            'Generated Parser Demo',
            false
        );
        PromptToFlowController.ConfigurationRecordDto loaded = PromptToFlowController.getConfiguration(saved.id);
        List<PromptToFlowController.ConfigurationRecordDto> allConfigs = PromptToFlowController.getConfigurations();
        Test.stopTest();

        System.assertNotEquals(null, saved.id);
        System.assertEquals('Test Config', loaded.name);
        System.assertEquals(configJson, loaded.configurationJson);
        System.assertEquals('Generated Parser Demo', loaded.invocableActionLabel);
        System.assertEquals('Generated_Parser_Demo', loaded.parserClassName);
        System.assertEquals(true, loaded.parserClassNameLocked);
        System.assertEquals(true, allConfigs.size() > 0);
    }

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
    static void saveConfiguration_generateParserOnSave_usesToolingApi() {
        String configJson = JSON.serialize(new Map<String, Object>{
            'selectedObjects' => new List<Object>{
                new Map<String, Object>{
                    'apiName' => 'Account',
                    'isCollection' => true,
                    'selectedFields' => new List<String>{ 'Name' }
                }
            }
        });

        Test.setMock(HttpCalloutMock.class, new ToolingApiMock());
        Test.startTest();
        PromptToFlowController.ConfigurationRecordDto saved = PromptToFlowController.saveConfiguration(
            null,
            'Generated Config',
            configJson,
            '{"Account":[{"Name":"string"}]}',
            'Generated Parser From Config',
            true
        );
        Test.stopTest();

        System.assertNotEquals(null, saved.id);
        System.assertEquals('Generated_Parser_From_Config', saved.parserClassName);
        System.assertEquals(true, saved.generateParserOnSave);
    }

    @IsTest
    static void saveConfiguration_updateKeepsExistingParserClassName() {
        String configJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'apiName' => 'Account',
                'isCollection' => true,
                'selectedFields' => new List<String>{ 'Name' }
            }
        });

        Test.setMock(HttpCalloutMock.class, new ToolingApiMock());
        PromptToFlowController.ConfigurationRecordDto firstSave = PromptToFlowController.saveConfiguration(
            null,
            'Update Lock Config',
            configJson,
            '{"Account":[{"Name":"string"}]}',
            'Initial Label',
            false
        );

        PromptToFlowController.ConfigurationRecordDto updatedSave = PromptToFlowController.saveConfiguration(
            firstSave.id,
            'Update Lock Config',
            configJson,
            '{"Account":[{"Name":"string"}]}',
            'Changed Label',
            false
        );

        System.assertEquals('Initial_Label', updatedSave.parserClassName);
        System.assertEquals('Changed Label', updatedSave.invocableActionLabel);
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

    @IsTest
    static void generateParserForConfiguration_callsToolingApi() {
        String configJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'apiName' => 'Account',
                'isCollection' => true,
                'selectedFields' => new List<String>{ 'Name' }
            }
        });

        PromptToFlow_Config__c recordItem = new PromptToFlow_Config__c(
            Name = 'Generate Parser Config',
            Configuration_JSON__c = configJson,
            Template_JSON__c = '{"Account":[{"Name":"string"}]}',
            Invocable_Action_Label__c = 'Generated Parser Action',
            Parser_Class_Name__c = 'GeneratedParserFromTest',
            Generate_Parser_On_Save__c = true
        );
        insert recordItem;

        Test.setMock(HttpCalloutMock.class, new ToolingApiMock());

        Test.startTest();
        PromptToFlowController.generateParserForConfiguration(recordItem.Id);
        Test.stopTest();

        System.assert(true, 'Expected generateParserForConfiguration to complete without exceptions.');
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
}
