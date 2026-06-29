@IsTest
private class PromptToFlowSetupCheckActionTest {
    @IsTest
    static void checkSetup_returnsSingleResponseWithStatus() {
        Test.startTest();
        List<PromptToFlowSetupCheckAction.Response> results =
            PromptToFlowSetupCheckAction.checkSetup(new List<PromptToFlowSetupCheckAction.Request>{
                new PromptToFlowSetupCheckAction.Request()
            });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Expected a single diagnostics response.');
        System.assertNotEquals(null, results[0].ready, 'Ready flag should always be set.');
        System.assertNotEquals(null, results[0].permissionSetApiName, 'Permission set API name should be populated.');
    }
}
