/**
 * Shared runtime used by generated PromptToFlow parser classes (and the
 * sample FlowJsonToProjectRecordsAction). Keeping the invariant JSON-to-SObject
 * coercion logic here means a fix/improvement reaches every parser on package
 * upgrade without regenerating any class.
 *
 * Public (not global) is intentional: this package is unlocked with no
 * namespace, so runtime-generated parser classes can reference these methods
 * directly. If this ever becomes a namespaced managed package, these must
 * become global.
 */
public with sharing class PromptToFlowParserRuntime {
    public static Map<String, Object> asMap(Object value) {
        if (value == null) {
            return new Map<String, Object>();
        }
        if (value instanceof Map<String, Object>) {
            return (Map<String, Object>) value;
        }
        throw new TypeException('Expected a JSON object.');
    }

    public static List<Object> asList(Object value) {
        if (value == null) {
            return new List<Object>();
        }
        if (value instanceof List<Object>) {
            return (List<Object>) value;
        }
        throw new TypeException('Expected a JSON array.');
    }

    public static void populateFromMap(SObject targetRecord, Map<String, Object> values, Set<String> allowedFields) {
        if (targetRecord == null || values == null || values.isEmpty()) {
            return;
        }

        Map<String, Schema.SObjectField> fieldMap = targetRecord.getSObjectType().getDescribe().fields.getMap();
        for (String fieldApiName : values.keySet()) {
            if (allowedFields != null && !allowedFields.contains(fieldApiName)) {
                continue;
            }
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

    public static Object coerceFieldValue(Object value, Schema.DisplayType fieldType) {
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
                return (Datetime) JSON.deserialize('"' + stringValue + '"', Datetime.class);
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
}
