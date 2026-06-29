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
                Map<String, Object> payload = asMap(JSON.deserializeUntyped(requestItem.jsonPayload));

                for (Object item : asList(payload.get('pse__Risk__c'))) {
                    pse__Risk__c risk = new pse__Risk__c();
                    populateFromMap(risk, asMap(item));
                    responseItem.risks.add(risk);
                }

                for (Object item : asList(payload.get('pse__Issue__c'))) {
                    pse__Issue__c issue = new pse__Issue__c();
                    populateFromMap(issue, asMap(item));
                    responseItem.issues.add(issue);
                }

                for (Object item : asList(payload.get('Decision__c'))) {
                    Decision__c decision = new Decision__c();
                    populateFromMap(decision, asMap(item));
                    responseItem.decisions.add(decision);
                }

                Map<String, Object> meetingValues = asMap(payload.get('Meetings__c'));
                if (!meetingValues.isEmpty()) {
                    Meetings__c meetingRecord = new Meetings__c();
                    populateFromMap(meetingRecord, meetingValues);
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

    private static Map<String, Object> asMap(Object value) {
        if (value == null) {
            return new Map<String, Object>();
        }
        if (value instanceof Map<String, Object>) {
            return (Map<String, Object>) value;
        }
        throw new TypeException('Expected a JSON object.');
    }

    private static List<Object> asList(Object value) {
        if (value == null) {
            return new List<Object>();
        }
        if (value instanceof List<Object>) {
            return (List<Object>) value;
        }
        throw new TypeException('Expected a JSON array.');
    }

    private static String asString(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static void populateFromMap(SObject targetRecord, Map<String, Object> values) {
        if (targetRecord == null || values == null || values.isEmpty()) {
            return;
        }

        Map<String, Schema.SObjectField> fieldMap = targetRecord.getSObjectType().getDescribe().fields.getMap();
        for (String fieldApiName : values.keySet()) {
            Schema.SObjectField fieldToken = fieldMap.get(fieldApiName);
            if (fieldToken == null) {
                continue;
            }

            Schema.DescribeFieldResult fieldDescribe = fieldToken.getDescribe();
            if (!(fieldDescribe.isCreateable() || fieldDescribe.isUpdateable())) {
                continue;
            }

            targetRecord.put(fieldApiName, coerceFieldValue(values.get(fieldApiName), fieldDescribe.getType()));
        }
    }

    private static Object coerceFieldValue(Object value, Schema.DisplayType fieldType) {
        if (value == null) {
            return null;
        }

        String stringValue = String.valueOf(value);
        if (String.isBlank(stringValue)) {
            return null;
        }

        switch on fieldType {
            when DATE {
                return Date.valueOf(stringValue);
            }
            when DATETIME {
                return asDatetime(stringValue);
            }
            when TIME {
                return (Time) JSON.deserialize('"' + stringValue + '"', Time.class);
            }
            when DOUBLE, CURRENCY, PERCENT {
                return Decimal.valueOf(stringValue);
            }
            when INTEGER {
                return Integer.valueOf(stringValue);
            }
            when LONG {
                return Long.valueOf(stringValue);
            }
            when BOOLEAN {
                return stringValue.toLowerCase() == 'true';
            }
            when REFERENCE, ID {
                return (Id) stringValue;
            }
            when else {
                return stringValue;
            }
        }
    }

    private static Datetime asDatetime(String value) {
        return (Datetime) JSON.deserialize('"' + value + '"', Datetime.class);
    }
}
