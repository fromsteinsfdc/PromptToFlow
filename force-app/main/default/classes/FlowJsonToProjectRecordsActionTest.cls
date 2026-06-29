@IsTest
private class FlowJsonToProjectRecordsActionTest {
    @IsTest
    static void parseJson_parsesSupportedCollections() {
        String payload = JSON.serialize(new Map<String, Object>{
            'pse__Risk__c' => new List<Object>{
                new Map<String, Object>{
                    'pse__Risk_Name__c' => 'Risk A',
                    'pse__Likelihood__c' => 'High',
                    'pse__Risk_Description__c' => 'Risk details',
                    'pse__Impact__c' => 'Major',
                    'pse__Mitigation_Plan__c' => 'Mitigate',
                    'pse__Comments__c' => 'Fallback'
                }
            },
            'pse__Issue__c' => new List<Object>{
                new Map<String, Object>{
                    'pse__Issue_Name__c' => 'Issue A',
                    'pse__Issue_Description__c' => 'Issue details',
                    'pse__Impact__c' => 'Medium',
                    'pse__Priority__c' => 'P1',
                    'pse__Project__c' => '001000000000001AAA',
                    'pse__Severity__c' => 4,
                    'pse__Status__c' => 'Open',
                    'pse__Action_Plan__c' => 'Action'
                }
            },
            'Decision__c' => new List<Object>{
                new Map<String, Object>{
                    'Decision_Name__c' => 'Decision A',
                    'Options__c' => 'Option 1;Option 2'
                }
            },
            'Meetings__c' => new Map<String, Object>{
                'Name' => 'Weekly Sync',
                'Meeting_Date_Time__c' => '2026-01-15T12:00:00.000Z'
            }
        });

        FlowJsonToProjectRecordsAction.Request requestItem = new FlowJsonToProjectRecordsAction.Request();
        requestItem.jsonPayload = payload;

        Test.startTest();
        List<FlowJsonToProjectRecordsAction.Response> results =
            FlowJsonToProjectRecordsAction.parseJson(new List<FlowJsonToProjectRecordsAction.Request>{ requestItem });
        Test.stopTest();

        System.assertEquals(1, results.size());
        FlowJsonToProjectRecordsAction.Response responseItem = results[0];
        System.assertEquals(true, responseItem.success);
        System.assertEquals(null, responseItem.errorMessage);

        System.assertEquals(1, responseItem.risks.size());
        System.assertEquals('Risk A', responseItem.risks[0].pse__Risk_Name__c);
        System.assertEquals('High', responseItem.risks[0].pse__Likelihood__c);
        System.assertEquals('Fallback', responseItem.risks[0].pse__Comments__c);

        System.assertEquals(1, responseItem.issues.size());
        System.assertEquals('Issue A', responseItem.issues[0].pse__Issue_Name__c);
        System.assertEquals('P1', responseItem.issues[0].pse__Priority__c);
        System.assertEquals('001000000000001AAA', responseItem.issues[0].pse__Project__c);
        System.assertEquals('Open', responseItem.issues[0].pse__Status__c);

        System.assertEquals(1, responseItem.decisions.size());
        System.assertEquals('Decision A', responseItem.decisions[0].Decision_Name__c);
        System.assertEquals('Option 1;Option 2', responseItem.decisions[0].Options__c);

        System.assertNotEquals(null, responseItem.meeting);
        System.assertEquals('Weekly Sync', responseItem.meeting.Name);
        System.assertNotEquals(null, responseItem.meeting.Meeting_Date_Time__c);
    }

    @IsTest
    static void parseJson_handlesInvalidJson() {
        FlowJsonToProjectRecordsAction.Request requestItem = new FlowJsonToProjectRecordsAction.Request();
        requestItem.jsonPayload = '{invalidJson}';

        List<FlowJsonToProjectRecordsAction.Response> results =
            FlowJsonToProjectRecordsAction.parseJson(new List<FlowJsonToProjectRecordsAction.Request>{ requestItem });

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].success);
        System.assertNotEquals(null, results[0].errorMessage);
    }
}
