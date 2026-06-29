@IsTest
private class PromptToFlowParserRuntimeTest {
    @IsTest
    static void asMap_returnsMapOrEmptyOrThrows() {
        System.assertEquals(true, PromptToFlowParserRuntime.asMap(null).isEmpty(), 'Null should yield empty map.');

        Map<String, Object> source = new Map<String, Object>{ 'a' => 1 };
        System.assertEquals(source, PromptToFlowParserRuntime.asMap(source), 'Map should pass through.');

        try {
            PromptToFlowParserRuntime.asMap('not a map');
            System.assert(false, 'Expected TypeException.');
        } catch (TypeException e) {
            System.assert(e.getMessage().contains('JSON object'), 'Unexpected message: ' + e.getMessage());
        }
    }

    @IsTest
    static void asList_returnsListOrEmptyOrThrows() {
        System.assertEquals(true, PromptToFlowParserRuntime.asList(null).isEmpty(), 'Null should yield empty list.');

        List<Object> source = new List<Object>{ 1, 2 };
        System.assertEquals(2, PromptToFlowParserRuntime.asList(source).size(), 'List should pass through.');

        try {
            PromptToFlowParserRuntime.asList('not a list');
            System.assert(false, 'Expected TypeException.');
        } catch (TypeException e) {
            System.assert(e.getMessage().contains('JSON array'), 'Unexpected message: ' + e.getMessage());
        }
    }

    @IsTest
    static void coerceFieldValue_coercesEachType() {
        System.assertEquals(null, PromptToFlowParserRuntime.coerceFieldValue(null, Schema.DisplayType.STRING), 'Null in, null out.');
        System.assertEquals(null, PromptToFlowParserRuntime.coerceFieldValue('   ', Schema.DisplayType.STRING), 'Blank in, null out.');

        System.assertEquals('hello', PromptToFlowParserRuntime.coerceFieldValue('hello', Schema.DisplayType.STRING));
        System.assertEquals(Date.newInstance(2026, 1, 15), PromptToFlowParserRuntime.coerceFieldValue('2026-01-15', Schema.DisplayType.DATE));
        System.assertEquals(42, PromptToFlowParserRuntime.coerceFieldValue('42', Schema.DisplayType.INTEGER));
        System.assertEquals(123456789L, PromptToFlowParserRuntime.coerceFieldValue('123456789', Schema.DisplayType.LONG));
        System.assertEquals(12.5, PromptToFlowParserRuntime.coerceFieldValue('12.5', Schema.DisplayType.CURRENCY));
        System.assertEquals(12.5, PromptToFlowParserRuntime.coerceFieldValue('12.5', Schema.DisplayType.DOUBLE));
        System.assertEquals(12.5, PromptToFlowParserRuntime.coerceFieldValue('12.5', Schema.DisplayType.PERCENT));
        System.assertEquals(true, PromptToFlowParserRuntime.coerceFieldValue('TRUE', Schema.DisplayType.BOOLEAN));
        System.assertEquals(false, PromptToFlowParserRuntime.coerceFieldValue('no', Schema.DisplayType.BOOLEAN));

        Object dt = PromptToFlowParserRuntime.coerceFieldValue('2026-01-15T12:00:00.000Z', Schema.DisplayType.DATETIME);
        System.assert(dt instanceof Datetime, 'Expected Datetime.');

        Object t = PromptToFlowParserRuntime.coerceFieldValue('12:00:00.000Z', Schema.DisplayType.TIME);
        System.assert(t instanceof Time, 'Expected Time.');

        Object refId = PromptToFlowParserRuntime.coerceFieldValue(UserInfo.getUserId(), Schema.DisplayType.REFERENCE);
        System.assertEquals(UserInfo.getUserId(), refId, 'Reference should coerce to Id.');
    }

    @IsTest
    static void populateFromMap_respectsAllowListAndFieldRules() {
        Account acct = new Account();
        Map<String, Object> values = new Map<String, Object>{
            'Name' => 'Acme',
            'AnnualRevenue' => '1000',
            'CreatedDate' => '2026-01-15T12:00:00.000Z',
            'NotARealField__x' => 'ignored'
        };
        Set<String> allowed = new Set<String>{ 'Name', 'AnnualRevenue', 'CreatedDate', 'NotARealField__x' };

        PromptToFlowParserRuntime.populateFromMap(acct, values, allowed);

        System.assertEquals('Acme', acct.Name, 'Allowed, writable field should be set.');
        System.assertEquals(1000, acct.AnnualRevenue, 'Currency should be coerced.');
        System.assertEquals(null, acct.CreatedDate, 'Non-writable field should be skipped.');
    }

    @IsTest
    static void populateFromMap_allowListFiltersUnlistedFields() {
        Account acct = new Account();
        Map<String, Object> values = new Map<String, Object>{ 'Name' => 'Acme', 'Phone' => '555' };
        PromptToFlowParserRuntime.populateFromMap(acct, values, new Set<String>{ 'Name' });

        System.assertEquals('Acme', acct.Name);
        System.assertEquals(null, acct.Phone, 'Field not in allow list should be skipped.');
    }

    @IsTest
    static void populateFromMap_nullAllowListSetsKnownFields() {
        Account acct = new Account();
        PromptToFlowParserRuntime.populateFromMap(acct, new Map<String, Object>{ 'Name' => 'Acme' }, null);
        System.assertEquals('Acme', acct.Name, 'Null allow list should permit all known writable fields.');
    }

    @IsTest
    static void populateFromMap_emptyInputsAreNoOps() {
        Account acct = new Account();
        PromptToFlowParserRuntime.populateFromMap(acct, new Map<String, Object>(), new Set<String>{ 'Name' });
        PromptToFlowParserRuntime.populateFromMap(null, new Map<String, Object>{ 'Name' => 'x' }, null);
        System.assertEquals(null, acct.Name, 'Empty values should be a no-op.');
    }
}
