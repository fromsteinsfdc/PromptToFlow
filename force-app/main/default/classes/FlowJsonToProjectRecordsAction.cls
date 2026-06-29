public with sharing class FlowJsonToProjectRecordsAction {
    public class Request {
        @InvocableVariable(required=true label='JSON Payload')
        public String jsonPayload;
    }

    public class Response {
        @InvocableVariable(label='Risks')
        public List<pse__Risk__c> risks = new List<pse__Risk__c>();

        @InvocableVariable(label='Issues')
        public List<pse__Issue__c> issues = new List<pse__Issue__c>();

        @InvocableVariable(label='Decisions')
        public List<Decision__c> decisions = new List<Decision__c>();

        @InvocableVariable(label='Meeting')
        public Meetings__c meeting;

        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(
        label='Parse Project JSON to SObject Collections'
        description='Parses JSON with pse__Risk__c, pse__Issue__c, Decision__c arrays and Meetings__c object into SObject collections for downstream Flow elements.'
    )
    public static List<Response> parseJson(List<Request> requests) {
        List<Response> results = new List<Response>();
        if (requests == null) {
            return results;
        }

        for (Request requestItem : requests) {
            Response responseItem = new Response();
            responseItem.success = true;

            try {
                Map<String, Object> payload = PromptToFlowParserRuntime.asMap(JSON.deserializeUntyped(requestItem.jsonPayload));

                for (Object item : PromptToFlowParserRuntime.asList(payload.get('pse__Risk__c'))) {
                    pse__Risk__c risk = new pse__Risk__c();
                    PromptToFlowParserRuntime.populateFromMap(risk, PromptToFlowParserRuntime.asMap(item), null);
                    responseItem.risks.add(risk);
                }

                for (Object item : PromptToFlowParserRuntime.asList(payload.get('pse__Issue__c'))) {
                    pse__Issue__c issue = new pse__Issue__c();
                    PromptToFlowParserRuntime.populateFromMap(issue, PromptToFlowParserRuntime.asMap(item), null);
                    responseItem.issues.add(issue);
                }

                for (Object item : PromptToFlowParserRuntime.asList(payload.get('Decision__c'))) {
                    Decision__c decision = new Decision__c();
                    PromptToFlowParserRuntime.populateFromMap(decision, PromptToFlowParserRuntime.asMap(item), null);
                    responseItem.decisions.add(decision);
                }

                Map<String, Object> meetingValues = PromptToFlowParserRuntime.asMap(payload.get('Meetings__c'));
                if (!meetingValues.isEmpty()) {
                    Meetings__c meetingRecord = new Meetings__c();
                    PromptToFlowParserRuntime.populateFromMap(meetingRecord, meetingValues, null);
                    responseItem.meeting = meetingRecord;
                }
            } catch (Exception e) {
                responseItem.success = false;
                responseItem.errorMessage = e.getMessage();
            }

            results.add(responseItem);
        }

        return results;
    }
}
