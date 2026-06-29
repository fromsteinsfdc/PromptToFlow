public with sharing class PromptToFlowSetupCheckAction {
    public class Request {
        @InvocableVariable(label='Include Details')
        public Boolean includeDetails;
    }

    public class Response {
        @InvocableVariable(label='Ready')
        public Boolean ready;

        @InvocableVariable(label='Named Credential Configured')
        public Boolean namedCredentialConfigured;

        @InvocableVariable(label='Tooling API Reachable')
        public Boolean toolingApiReachable;

        @InvocableVariable(label='Permission Set Exists')
        public Boolean permissionSetExists;

        @InvocableVariable(label='Permission Set Assigned')
        public Boolean permissionSetAssigned;

        @InvocableVariable(label='Can Auto Assign Permission Set')
        public Boolean canAutoAssignPermissionSet;

        @InvocableVariable(label='Permission Set API Name')
        public String permissionSetApiName;

        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(
        label='Check PromptToFlow Setup'
        description='Checks whether Named Credential auth and permission setup are ready for parser generation.'
    )
    public static List<Response> checkSetup(List<Request> requests) {
        PromptToFlowController.ParserGenerationSetupStatusDto status =
            PromptToFlowController.getParserGenerationSetupStatus();

        Response row = new Response();
        row.ready = status.ready;
        row.namedCredentialConfigured = status.namedCredentialConfigured;
        row.toolingApiReachable = status.toolingApiReachable;
        row.permissionSetExists = status.permissionSetExists;
        row.permissionSetAssigned = status.permissionSetAssigned;
        row.canAutoAssignPermissionSet = status.canAutoAssignPermissionSet;
        row.permissionSetApiName = status.permissionSetApiName;
        row.message = status.message;

        return new List<Response>{ row };
    }
}
