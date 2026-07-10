public with sharing class PromptToFlowController {
    private static final String TOOLING_NAMED_CREDENTIAL = 'PromptToFlow_Tooling';
    private static final String SETUP_PERMISSION_SET_API_NAME = 'PromptToFlow_User';
    public class ObjectOption {
        @AuraEnabled public String label;
        @AuraEnabled public String pluralLabel;
        @AuraEnabled public String apiName;

        public ObjectOption(String label, String pluralLabel, String apiName) {
            this.label = label;
            this.pluralLabel = pluralLabel;
            this.apiName = apiName;
        }
    }

    public class FieldOption {
        @AuraEnabled public String label;
        @AuraEnabled public String apiName;
        @AuraEnabled public String dataType;
        @AuraEnabled public String keyPrefix;

        public FieldOption(String label, String apiName, String dataType, String keyPrefix) {
            this.label = label;
            this.apiName = apiName;
            this.dataType = dataType;
            this.keyPrefix = keyPrefix;
        }
    }

    public class ConfigurationRecordDto {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String configurationJson;
        @AuraEnabled public String templateJson;
        @AuraEnabled public String invocableActionLabel;
        @AuraEnabled public String parserClassName;
        @AuraEnabled public Boolean parserClassNameLocked;
        @AuraEnabled public Boolean generateParserOnSave;
        @AuraEnabled public Datetime lastModifiedDate;
    }

    public class ParserGenerationSetupStatusDto {
        @AuraEnabled public Boolean namedCredentialConfigured;
        @AuraEnabled public Boolean toolingApiReachable;
        @AuraEnabled public Boolean permissionSetExists;
        @AuraEnabled public Boolean permissionSetAssigned;
        @AuraEnabled public Boolean canAutoAssignPermissionSet;
        @AuraEnabled public Boolean ready;
        @AuraEnabled public String permissionSetApiName;
        @AuraEnabled public String message;
    }

    private class ObjectConfig {
        public String apiName;
        // The JSON property name used in the template and read by the parser.
        // For collections this is the object's plural label (e.g. "Opportunities");
        // for single records it is the object API name. Falls back to apiName.
        public String jsonKey;
        public Boolean isCollection;
        public List<String> selectedFields;

        public ObjectConfig(String apiName, String jsonKey, Boolean isCollection, List<String> selectedFields) {
            this.apiName = apiName;
            this.jsonKey = String.isBlank(jsonKey) ? apiName : jsonKey;
            this.isCollection = isCollection;
            this.selectedFields = selectedFields;
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<ObjectOption> getAvailableObjects() {
        List<ObjectOption> objectOptions = new List<ObjectOption>();

        for (Schema.SObjectType objectType : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult describe = objectType.getDescribe();
            if (!describe.isQueryable() || describe.isDeprecatedAndHidden() || describe.isCustomSetting()) {
                continue;
            }
            if (isAuxiliaryObject(describe.getName())) {
                continue;
            }
            objectOptions.add(new ObjectOption(describe.getLabel(), describe.getLabelPlural(), describe.getName()));
        }

        return objectOptions;
    }

    @AuraEnabled(cacheable=true)
    public static List<FieldOption> getFieldsForObject(String objectApiName) {
        if (String.isBlank(objectApiName)) {
            throw new AuraHandledException('Object API name is required.');
        }

        Schema.SObjectType objectType = Schema.getGlobalDescribe().get(objectApiName);
        if (objectType == null) {
            throw new AuraHandledException('Unknown object: ' + objectApiName);
        }

        List<FieldOption> fieldOptions = new List<FieldOption>();
        for (Schema.SObjectField fieldToken : objectType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult fieldDescribe = fieldToken.getDescribe();
            if (!fieldDescribe.isAccessible()) {
                continue;
            }
            fieldOptions.add(new FieldOption(
                fieldDescribe.getLabel(),
                fieldDescribe.getName(),
                String.valueOf(fieldDescribe.getType()),
                resolveKeyPrefix(objectType, fieldDescribe)
            ));
        }

        return fieldOptions;
    }

    private static Boolean isAuxiliaryObject(String objectName) {
        if (String.isBlank(objectName)) {
            return false;
        }
        return objectName.endsWith('Share')
            || objectName.endsWith('History')
            || objectName.endsWith('Feed')
            || objectName.endsWith('Tag')
            || objectName.endsWith('ChangeEvent');
    }

    private static String resolveKeyPrefix(Schema.SObjectType objectType, Schema.DescribeFieldResult fieldDescribe) {
        Schema.DisplayType fieldType = fieldDescribe.getType();
        if (fieldType == Schema.DisplayType.ID) {
            return objectType.getDescribe().getKeyPrefix();
        }
        if (fieldType == Schema.DisplayType.REFERENCE) {
            for (Schema.SObjectType referenced : fieldDescribe.getReferenceTo()) {
                String prefix = referenced.getDescribe().getKeyPrefix();
                if (String.isNotBlank(prefix)) {
                    return prefix;
                }
            }
        }
        return null;
    }

    @AuraEnabled(cacheable=true)
    public static List<ConfigurationRecordDto> getConfigurations() {
        List<ConfigurationRecordDto> result = new List<ConfigurationRecordDto>();
        List<PromptToFlow_Config__c> records = [
            SELECT Id, Name, Configuration_JSON__c, Template_JSON__c, Invocable_Action_Label__c, Parser_Class_Name__c, Generate_Parser_On_Save__c, LastModifiedDate
            FROM PromptToFlow_Config__c
            ORDER BY LastModifiedDate DESC
        ];
        Set<String> candidateClassNames = new Set<String>();
        for (PromptToFlow_Config__c recordItem : records) {
            if (String.isNotBlank(recordItem.Parser_Class_Name__c)) {
                candidateClassNames.add(recordItem.Parser_Class_Name__c);
            }
        }
        Set<String> existingClassNames = existingApexClassNames(candidateClassNames);
        for (PromptToFlow_Config__c recordItem : records) {
            result.add(toDto(recordItem, existingClassNames));
        }
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static ConfigurationRecordDto getConfiguration(Id configurationId) {
        PromptToFlow_Config__c recordItem = [
            SELECT Id, Name, Configuration_JSON__c, Template_JSON__c, Invocable_Action_Label__c, Parser_Class_Name__c, Generate_Parser_On_Save__c, LastModifiedDate
            FROM PromptToFlow_Config__c
            WHERE Id = :configurationId
            LIMIT 1
        ];
        return toDto(recordItem);
    }

    @AuraEnabled
    public static ConfigurationRecordDto saveConfiguration(
        Id configurationId,
        String configurationName,
        String configurationJson,
        String templateJson,
        String invocableActionLabel,
        Boolean generateParserOnSave
    ) {
        if (String.isBlank(configurationName)) {
            throw new AuraHandledException('Configuration name is required.');
        }
        if (String.isBlank(configurationJson)) {
            throw new AuraHandledException('Configuration JSON is required.');
        }
        if (String.isBlank(invocableActionLabel)) {
            throw new AuraHandledException('Invocable action label is required.');
        }
        if (String.isBlank(templateJson)) {
            throw new AuraHandledException('Template JSON is required.');
        }

        String sanitizedActionLabel = invocableActionLabel.trim();
        PromptToFlow_Config__c recordItem;
        Boolean isInsert = configurationId == null;
        if (isInsert) {
            recordItem = new PromptToFlow_Config__c();
        } else {
            recordItem = [
                SELECT Id, Parser_Class_Name__c
                FROM PromptToFlow_Config__c
                WHERE Id = :configurationId
                LIMIT 1
            ];
        }

        // Keep the parser class name in sync with the label until the parser
        // class has actually been generated. Once a real Apex class exists,
        // Flows may reference it by name, so we stop re-deriving to avoid
        // breaking those references. The existence check is SOQL (not a Tooling
        // callout), so it is safe to run in the same transaction as the upsert.
        Boolean classAlreadyGenerated = !String.isBlank(recordItem.Parser_Class_Name__c)
            && apexClassExists(recordItem.Parser_Class_Name__c);
        if (!classAlreadyGenerated) {
            String derivedClassName = deriveClassNameFromActionLabel(sanitizedActionLabel);
            ensureApexClassNameAvailable(derivedClassName);
            recordItem.Parser_Class_Name__c = derivedClassName;
        }

        recordItem.Name = configurationName.trim();
        recordItem.Configuration_JSON__c = configurationJson;
        recordItem.Template_JSON__c = templateJson;
        recordItem.Invocable_Action_Label__c = sanitizedActionLabel;
        recordItem.Generate_Parser_On_Save__c = generateParserOnSave == true;
        upsert recordItem;

        PromptToFlow_Config__c refreshedRecord = [
            SELECT Id, Name, Configuration_JSON__c, Template_JSON__c, Invocable_Action_Label__c, Parser_Class_Name__c, Generate_Parser_On_Save__c, LastModifiedDate
            FROM PromptToFlow_Config__c
            WHERE Id = :recordItem.Id
            LIMIT 1
        ];
        return toDto(refreshedRecord);
    }

    @AuraEnabled
    public static void deleteConfiguration(Id configurationId) {
        if (configurationId == null) {
            throw new AuraHandledException('Configuration Id is required.');
        }
        List<PromptToFlow_Config__c> records = [
            SELECT Id
            FROM PromptToFlow_Config__c
            WHERE Id = :configurationId
            LIMIT 1
        ];
        if (records.isEmpty()) {
            throw new AuraHandledException('Configuration not found. It may have already been deleted.');
        }
        // Note: the generated parser Apex class is intentionally left in place
        // because Flows may still reference it; deleting the config only removes
        // the saved builder configuration record.
        delete records;
    }

    @AuraEnabled
    public static String getInvocableParserSource(String parserClassName, String configurationJson, String invocableActionLabel) {
        if (String.isBlank(parserClassName)) {
            throw new AuraHandledException('Parser class name is required.');
        }
        if (String.isBlank(configurationJson)) {
            throw new AuraHandledException('Configuration JSON is required.');
        }
        if (String.isBlank(invocableActionLabel)) {
            throw new AuraHandledException('Invocable action label is required.');
        }
        return generateInvocableParserSource(sanitizeClassName(parserClassName), configurationJson, invocableActionLabel.trim());
    }

    @AuraEnabled
    public static void generateParserForConfiguration(Id configurationId) {
        if (configurationId == null) {
            throw new AuraHandledException('Configuration Id is required.');
        }
        PromptToFlow_Config__c recordItem = [
            SELECT Id, Configuration_JSON__c, Parser_Class_Name__c, Invocable_Action_Label__c, Generate_Parser_On_Save__c
            FROM PromptToFlow_Config__c
            WHERE Id = :configurationId
            LIMIT 1
        ];
        if (String.isBlank(recordItem.Parser_Class_Name__c)) {
            throw new AuraHandledException('Parser Class Name is required on the configuration record.');
        }
        String parserSource = generateInvocableParserSource(
            recordItem.Parser_Class_Name__c,
            recordItem.Configuration_JSON__c,
            recordItem.Invocable_Action_Label__c
        );
        upsertApexClass(recordItem.Parser_Class_Name__c, parserSource);
    }

    @AuraEnabled(cacheable=true)
    public static ParserGenerationSetupStatusDto getParserGenerationSetupStatus() {
        ParserGenerationSetupStatusDto status = new ParserGenerationSetupStatusDto();
        status.permissionSetApiName = SETUP_PERMISSION_SET_API_NAME;

        status.namedCredentialConfigured = hasNamedCredential();

        PermissionSet setupPermissionSet = getSetupPermissionSet();
        status.permissionSetExists = setupPermissionSet != null;
        status.permissionSetAssigned = setupPermissionSet != null && isPermissionSetAssigned(UserInfo.getUserId(), setupPermissionSet.Id);
        status.canAutoAssignPermissionSet = setupPermissionSet != null && !status.permissionSetAssigned;

        if (!status.namedCredentialConfigured) {
            status.toolingApiReachable = false;
            status.ready = false;
            status.message =
                'Named Credential "' + TOOLING_NAMED_CREDENTIAL + '" is missing. ' +
                'Ask an admin to install/configure package setup and authenticate it once.';
            return status;
        }

        status.toolingApiReachable = canReachToolingApi();
        status.ready = status.toolingApiReachable && (status.permissionSetAssigned || !status.permissionSetExists);

        if (!status.toolingApiReachable) {
            status.message =
                'Named Credential is present but not authenticated (or access is invalid). ' +
                'Open the Named Credential and complete Authenticate.';
        } else if (status.permissionSetExists && !status.permissionSetAssigned) {
            status.message =
                'Assign permission set "' + status.permissionSetApiName + '" before parser generation.';
        } else {
            status.message = 'Setup is ready.';
        }

        return status;
    }

    @AuraEnabled
    public static ParserGenerationSetupStatusDto assignSetupPermissionSetToCurrentUser() {
        PermissionSet setupPermissionSet = getSetupPermissionSet();
        if (setupPermissionSet == null) {
            throw new AuraHandledException(
                'Permission set "' + SETUP_PERMISSION_SET_API_NAME + '" was not found. ' +
                'Install the package metadata that includes this permission set.'
            );
        }

        if (!isPermissionSetAssigned(UserInfo.getUserId(), setupPermissionSet.Id)) {
            try {
                insert new PermissionSetAssignment(
                    AssigneeId = UserInfo.getUserId(),
                    PermissionSetId = setupPermissionSet.Id
                );
            } catch (DmlException e) {
                throw new AuraHandledException(
                    'Unable to auto-assign permission set "' + SETUP_PERMISSION_SET_API_NAME + '". ' +
                    'Ask an admin with Manage Users permission to assign it. ' +
                    'Details: ' + e.getMessage()
                );
            }
        }

        return getParserGenerationSetupStatus();
    }

    private static ConfigurationRecordDto toDto(PromptToFlow_Config__c recordItem) {
        Set<String> existingClassNames = String.isBlank(recordItem.Parser_Class_Name__c)
            ? new Set<String>()
            : existingApexClassNames(new Set<String>{ recordItem.Parser_Class_Name__c });
        return toDto(recordItem, existingClassNames);
    }

    // Bulk-safe overload: callers that map many records pass a pre-computed set
    // of existing Apex class names so we don't issue one SOQL query per record.
    private static ConfigurationRecordDto toDto(
        PromptToFlow_Config__c recordItem,
        Set<String> existingClassNames
    ) {
        ConfigurationRecordDto dto = new ConfigurationRecordDto();
        dto.id = recordItem.Id;
        dto.name = recordItem.Name;
        dto.configurationJson = recordItem.Configuration_JSON__c;
        dto.templateJson = recordItem.Template_JSON__c;
        dto.invocableActionLabel = recordItem.Invocable_Action_Label__c;
        dto.parserClassName = recordItem.Parser_Class_Name__c;
        // "Locked" now means the parser Apex class actually exists; until then
        // the name still tracks the invocable action label.
        dto.parserClassNameLocked = !String.isBlank(recordItem.Parser_Class_Name__c)
            && existingClassNames.contains(recordItem.Parser_Class_Name__c);
        dto.generateParserOnSave = recordItem.Generate_Parser_On_Save__c;
        dto.lastModifiedDate = recordItem.LastModifiedDate;
        return dto;
    }

    @TestVisible
    private static String generateInvocableParserSource(String className, String configurationJson, String invocableActionLabel) {
        List<ObjectConfig> configs = parseObjectConfigs(configurationJson);
        if (configs.isEmpty()) {
            throw new AuraHandledException('At least one object configuration is required.');
        }

        Set<String> usedVariableNames = new Set<String>();
        List<String> responseProperties = new List<String>();
        List<String> parseBlocks = new List<String>();

        for (ObjectConfig config : configs) {
            String variableName = toUniqueVariableName(config.apiName, usedVariableNames);
            String fieldSetLiteral = toFieldSetLiteral(config.selectedFields);
            // The JSON property name (collections use the plural label) must match
            // the template the prompt produces; the SObject type stays the API name.
            String escapedJsonKey = String.escapeSingleQuotes(config.jsonKey);

            if (config.isCollection) {
                responseProperties.add(
                    '        @InvocableVariable(label=\'' + escapedJsonKey + '\')\n' +
                    '        public List<' + config.apiName + '> ' + variableName + ' = new List<' + config.apiName + '>();'
                );
                parseBlocks.add(
                    '                for (Object item : PromptToFlowParserRuntime.asList(payload.get(\'' + escapedJsonKey + '\'))) {\n' +
                    '                    ' + config.apiName + ' recordItem = new ' + config.apiName + '();\n' +
                    '                    PromptToFlowParserRuntime.populateFromMap(recordItem, PromptToFlowParserRuntime.asMap(item), ' + fieldSetLiteral + ');\n' +
                    '                    responseItem.' + variableName + '.add(recordItem);\n' +
                    '                }'
                );
            } else {
                responseProperties.add(
                    '        @InvocableVariable(label=\'' + escapedJsonKey + '\')\n' +
                    '        public ' + config.apiName + ' ' + variableName + ';'
                );
                parseBlocks.add(
                    '                Map<String, Object> ' + variableName + 'Values = PromptToFlowParserRuntime.asMap(payload.get(\'' + escapedJsonKey + '\'));\n' +
                    '                if (!' + variableName + 'Values.isEmpty()) {\n' +
                    '                    ' + config.apiName + ' recordItem = new ' + config.apiName + '();\n' +
                    '                    PromptToFlowParserRuntime.populateFromMap(recordItem, ' + variableName + 'Values, ' + fieldSetLiteral + ');\n' +
                    '                    responseItem.' + variableName + ' = recordItem;\n' +
                    '                }'
                );
            }
        }

        String responsePropertyBlock = String.join(responseProperties, '\n\n');
        String parseBlock = String.join(parseBlocks, '\n\n');
        String escapedActionLabel = String.escapeSingleQuotes(invocableActionLabel);

        return
            'public with sharing class ' + className + ' {\n' +
            '    public class Request {\n' +
            '        @InvocableVariable(required=true label=\'JSON Payload\')\n' +
            '        public String jsonPayload;\n' +
            '    }\n\n' +
            '    public class Response {\n' +
            responsePropertyBlock + '\n\n' +
            '        @InvocableVariable(label=\'Success\')\n' +
            '        public Boolean success;\n\n' +
            '        @InvocableVariable(label=\'Error Message\')\n' +
            '        public String errorMessage;\n' +
            '    }\n\n' +
            '    @InvocableMethod(label=\'' + escapedActionLabel + '\' description=\'Parses configured JSON payload into Flow-ready SObject outputs.\')\n' +
            '    public static List<Response> parseJson(List<Request> requests) {\n' +
            '        List<Response> results = new List<Response>();\n' +
            '        if (requests == null) {\n' +
            '            return results;\n' +
            '        }\n\n' +
            '        for (Request requestItem : requests) {\n' +
            '            Response responseItem = new Response();\n' +
            '            responseItem.success = true;\n' +
            '            try {\n' +
            '                Map<String, Object> payload = PromptToFlowParserRuntime.asMap(JSON.deserializeUntyped(requestItem.jsonPayload));\n\n' +
            parseBlock + '\n' +
            '            } catch (Exception e) {\n' +
            '                responseItem.success = false;\n' +
            '                responseItem.errorMessage = e.getMessage();\n' +
            '            }\n\n' +
            '            results.add(responseItem);\n' +
            '        }\n\n' +
            '        return results;\n' +
            '    }\n' +
            '}';
    }

    private static List<ObjectConfig> parseObjectConfigs(String configurationJson) {
        Object root = JSON.deserializeUntyped(configurationJson);
        List<Object> rawList;
        if (root instanceof List<Object>) {
            rawList = (List<Object>) root;
        } else if (root instanceof Map<String, Object> && ((Map<String, Object>) root).containsKey('selectedObjects')) {
            rawList = (List<Object>) ((Map<String, Object>) root).get('selectedObjects');
        } else {
            throw new AuraHandledException('Configuration JSON must be an array or include selectedObjects.');
        }

        List<ObjectConfig> result = new List<ObjectConfig>();
        for (Object rawItem : rawList) {
            Map<String, Object> configMap = (Map<String, Object>) rawItem;
            String apiName = (String) configMap.get('apiName');
            String jsonKey = (String) configMap.get('jsonKey');
            Boolean isCollection = configMap.containsKey('isCollection') ? (Boolean) configMap.get('isCollection') : true;
            List<String> selectedFields = new List<String>();
            for (Object rawField : (List<Object>) configMap.get('selectedFields')) {
                selectedFields.add((String) rawField);
            }
            if (!String.isBlank(apiName)) {
                result.add(new ObjectConfig(apiName, jsonKey, isCollection, selectedFields));
            }
        }
        return result;
    }

    private static String toFieldSetLiteral(List<String> selectedFields) {
        List<String> quotedFields = new List<String>();
        for (String fieldName : selectedFields) {
            quotedFields.add('\'' + fieldName + '\'');
        }
        return 'new Set<String>{' + String.join(quotedFields, ',') + '}';
    }

    private static String toUniqueVariableName(String apiName, Set<String> usedVariableNames) {
        String baseName = apiName.toLowerCase().replace('__c', '').replace('__', '_').replaceAll('[^a-z0-9_]', '_');
        if (baseName.endsWith('_')) {
            baseName = baseName.substring(0, baseName.length() - 1);
        }
        if (String.isBlank(baseName)) {
            baseName = 'item';
        }

        String variableName = baseName;
        Integer suffix = 2;
        while (usedVariableNames.contains(variableName)) {
            variableName = baseName + suffix;
            suffix++;
        }
        usedVariableNames.add(variableName);
        return variableName;
    }

    private static String sanitizeClassName(String className) {
        String cleaned = className.trim().replaceAll('[^A-Za-z0-9_]', '_');
        if (!Pattern.matches('[A-Za-z_][A-Za-z0-9_]*', cleaned)) {
            throw new AuraHandledException('Parser class name must be a valid Apex class name.');
        }
        return cleaned;
    }

    // Apex class names (identifiers) cannot exceed 40 characters.
    private static final Integer MAX_PARSER_CLASS_NAME_LENGTH = 40;

    private static String deriveClassNameFromActionLabel(String invocableActionLabel) {
        String cleaned = sanitizeClassName(invocableActionLabel);
        if (cleaned.length() > MAX_PARSER_CLASS_NAME_LENGTH) {
            throw new AuraHandledException(
                'The invocable action label is too long. It maps to an Apex class name of ' +
                cleaned.length() + ' characters, but Apex class names are limited to ' +
                MAX_PARSER_CLASS_NAME_LENGTH + '. Please shorten the action label.'
            );
        }
        return cleaned;
    }

    private static void ensureApexClassNameAvailable(String className) {
        if (apexClassExists(className)) {
            throw new AuraHandledException(
                'An Apex class named "' + className + '" already exists. ' +
                'Choose a different invocable action label.'
            );
        }
    }

    // Existence checks use SOQL against ApexClass rather than a Tooling API
    // callout so they can run in the same transaction as DML (e.g. the upsert
    // in saveConfiguration). The Tooling API is still used for create/update
    // of Apex classes, which genuinely require it.
    private static Boolean apexClassExists(String className) {
        if (String.isBlank(className)) {
            return false;
        }
        return existingApexClassNames(new Set<String>{ className }).contains(className);
    }

    private static Set<String> existingApexClassNames(Set<String> candidateNames) {
        Set<String> found = new Set<String>();
        if (candidateNames == null || candidateNames.isEmpty()) {
            return found;
        }
        for (ApexClass cls : [SELECT Name FROM ApexClass WHERE Name IN :candidateNames]) {
            found.add(cls.Name);
        }
        return found;
    }

    private static void upsertApexClass(String className, String classBody) {
        String existingClassId = findApexClassIdByName(className);
        if (existingClassId == null) {
            createApexClass(className, classBody);
        } else {
            // The Tooling API does not allow a direct PATCH on an existing
            // ApexClass (it returns INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY).
            // Updates must go through a MetadataContainer compile request.
            updateApexClassViaContainer(existingClassId, classBody);
        }
    }

    private static void createApexClass(String className, String classBody) {
        HttpResponse response = sendTooling(
            'POST',
            '/sobjects/ApexClass',
            JSON.serialize(new Map<String, Object>{ 'Name' => className, 'Body' => classBody })
        );
        if (response.getStatusCode() >= 300) {
            throwApexWriteError(response);
        }
    }

    private static void updateApexClassViaContainer(String existingClassId, String classBody) {
        String containerId;
        try {
            containerId = createMetadataContainer();
            createApexClassMember(containerId, existingClassId, classBody);
            awaitContainerCompile(createContainerAsyncRequest(containerId));
        } finally {
            if (containerId != null) {
                deleteMetadataContainerQuietly(containerId);
            }
        }
    }

    private static String createMetadataContainer() {
        HttpResponse response = sendTooling(
            'POST',
            '/sobjects/MetadataContainer',
            JSON.serialize(new Map<String, Object>{ 'Name' => 'PromptToFlow_' + String.valueOf(Datetime.now().getTime()) })
        );
        if (response.getStatusCode() >= 300) {
            throwApexWriteError(response);
        }
        return idFromResponse(response);
    }

    private static void createApexClassMember(String containerId, String contentEntityId, String classBody) {
        HttpResponse response = sendTooling(
            'POST',
            '/sobjects/ApexClassMember',
            JSON.serialize(new Map<String, Object>{
                'MetadataContainerId' => containerId,
                'ContentEntityId' => contentEntityId,
                'Body' => classBody
            })
        );
        if (response.getStatusCode() >= 300) {
            throwApexWriteError(response);
        }
    }

    private static String createContainerAsyncRequest(String containerId) {
        HttpResponse response = sendTooling(
            'POST',
            '/sobjects/ContainerAsyncRequest',
            JSON.serialize(new Map<String, Object>{ 'MetadataContainerId' => containerId, 'IsCheckOnly' => false })
        );
        if (response.getStatusCode() >= 300) {
            throwApexWriteError(response);
        }
        return idFromResponse(response);
    }

    private static void awaitContainerCompile(String requestId) {
        for (Integer attempt = 0; attempt < 30; attempt++) {
            HttpResponse response = sendTooling('GET', '/sobjects/ContainerAsyncRequest/' + requestId, null);
            if (response.getStatusCode() >= 300) {
                throwApexWriteError(response);
            }
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
            String state = (String) payload.get('State');
            if (state == 'Completed') {
                return;
            }
            if (state != 'Queued' && state != 'InProgress') {
                throw new AuraHandledException('Apex class compile failed: ' + extractCompileError(payload));
            }
        }
        throw new AuraHandledException('Timed out waiting for the parser class to compile. Please try saving again.');
    }

    private static void deleteMetadataContainerQuietly(String containerId) {
        try {
            sendTooling('DELETE', '/sobjects/MetadataContainer/' + containerId, null);
        } catch (Exception ignored) {
            // Best-effort cleanup; a leftover container does not affect functionality.
        }
    }

    private static HttpResponse sendTooling(String method, String path, String body) {
        HttpRequest request = new HttpRequest();
        request.setMethod(method);
        request.setEndpoint(getToolingApiBaseUrl() + path);
        request.setTimeout(120000);
        if (body != null) {
            request.setHeader('Content-Type', 'application/json');
            request.setBody(body);
        }
        return new Http().send(request);
    }

    private static String idFromResponse(HttpResponse response) {
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
        return (String) payload.get('id');
    }

    private static String extractCompileError(Map<String, Object> payload) {
        Object errorMsg = payload.get('ErrorMsg');
        if (errorMsg != null) {
            return String.valueOf(errorMsg);
        }
        Object deployDetails = payload.get('DeployDetails');
        if (deployDetails instanceof Map<String, Object>) {
            Object failures = ((Map<String, Object>) deployDetails).get('componentFailures');
            if (failures instanceof List<Object>) {
                List<String> messages = new List<String>();
                for (Object failure : (List<Object>) failures) {
                    if (failure instanceof Map<String, Object>) {
                        Object problem = ((Map<String, Object>) failure).get('problem');
                        if (problem != null) {
                            messages.add(String.valueOf(problem));
                        }
                    }
                }
                if (!messages.isEmpty()) {
                    return String.join(messages, '; ');
                }
            }
        }
        return 'Unknown compile error.';
    }

    private static void throwApexWriteError(HttpResponse response) {
        if (response.getStatusCode() == 401) {
            throw new AuraHandledException(
                'Tooling API authentication failed from Named Credential (401). ' +
                'Configure Named Credential "' + TOOLING_NAMED_CREDENTIAL + '" with valid Salesforce OAuth access.'
            );
        }
        throw new AuraHandledException(
            'Failed to upsert Apex class (status ' + String.valueOf(response.getStatusCode()) + '): ' +
            extractToolingError(response.getBody())
        );
    }

    private static String findApexClassIdByName(String className) {
        String query = 'SELECT Id FROM ApexClass WHERE Name = \'' + String.escapeSingleQuotes(className) + '\'';
        String endpoint = getToolingApiBaseUrl() + '/query?q=' +
            EncodingUtil.urlEncode(query, 'UTF-8');

        HttpRequest request = new HttpRequest();
        request.setMethod('GET');
        request.setEndpoint(endpoint);

        HttpResponse response = new Http().send(request);
        if (response.getStatusCode() >= 300) {
            if (response.getStatusCode() == 401) {
                throw new AuraHandledException(
                    'Failed to query Apex classes (401 from Named Credential). ' +
                    'Configure Named Credential "' + TOOLING_NAMED_CREDENTIAL + '" with valid Salesforce OAuth access.'
                );
            }
            throw new AuraHandledException(
                'Failed to query Apex classes (status ' +
                String.valueOf(response.getStatusCode()) +
                '). Ensure your user has API access and Apex authoring permissions. Response: ' +
                response.getBody()
            );
        }

        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
        List<Object> records = (List<Object>) payload.get('records');
        return records.isEmpty() ? null : (String) ((Map<String, Object>) records[0]).get('Id');
    }

    private static Boolean canReachToolingApi() {
        try {
            String endpoint = getToolingApiBaseUrl() + '/query?q=' +
                EncodingUtil.urlEncode('SELECT Id FROM ApexClass LIMIT 1', 'UTF-8');
            HttpRequest request = new HttpRequest();
            request.setMethod('GET');
            request.setEndpoint(endpoint);
            HttpResponse response = new Http().send(request);
            return response.getStatusCode() < 300;
        } catch (Exception e) {
            return false;
        }
    }

    private static Boolean hasNamedCredential() {
        try {
            List<NamedCredential> creds = [
                SELECT Id
                FROM NamedCredential
                WHERE DeveloperName = :TOOLING_NAMED_CREDENTIAL
                LIMIT 1
            ];
            return !creds.isEmpty();
        } catch (Exception e) {
            return false;
        }
    }

    private static PermissionSet getSetupPermissionSet() {
        try {
            List<PermissionSet> rows = [
                SELECT Id, Name
                FROM PermissionSet
                WHERE Name = :SETUP_PERMISSION_SET_API_NAME
                LIMIT 1
            ];
            return rows.isEmpty() ? null : rows[0];
        } catch (Exception e) {
            return null;
        }
    }

    private static Boolean isPermissionSetAssigned(Id assigneeId, Id permissionSetId) {
        return [
            SELECT COUNT()
            FROM PermissionSetAssignment
            WHERE AssigneeId = :assigneeId
            AND PermissionSetId = :permissionSetId
        ] > 0;
    }

    private static String extractToolingError(String responseBody) {
        if (String.isBlank(responseBody)) {
            return 'No response body returned.';
        }
        try {
            Object parsed = JSON.deserializeUntyped(responseBody);
            if (parsed instanceof List<Object>) {
                List<Object> items = (List<Object>) parsed;
                if (!items.isEmpty() && items[0] instanceof Map<String, Object>) {
                    Map<String, Object> first = (Map<String, Object>) items[0];
                    if (first.containsKey('message')) {
                        return String.valueOf(first.get('message'));
                    }
                }
            } else if (parsed instanceof Map<String, Object>) {
                Map<String, Object> payload = (Map<String, Object>) parsed;
                if (payload.containsKey('message')) {
                    return String.valueOf(payload.get('message'));
                }
            }
        } catch (Exception e) {
            // Fall back to raw response for non-JSON payloads.
        }
        return responseBody;
    }

    private static String getToolingApiBaseUrl() {
        return 'callout:' + TOOLING_NAMED_CREDENTIAL + '/services/data/v67.0/tooling';
    }
}
