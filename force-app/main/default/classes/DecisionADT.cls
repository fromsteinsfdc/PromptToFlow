public class DecisionADT {
    @AuraEnabled public Id id { get; set; } // Id
    @AuraEnabled public Id ownerid { get; set; } // OwnerId
    @AuraEnabled public Boolean isdeleted { get; set; } // IsDeleted
    @AuraEnabled public String name { get; set; } // Name
    @AuraEnabled public String currencyisocode { get; set; } // CurrencyIsoCode
    @AuraEnabled public Datetime createddate { get; set; } // CreatedDate
    @AuraEnabled public Id createdbyid { get; set; } // CreatedById
    @AuraEnabled public Datetime lastmodifieddate { get; set; } // LastModifiedDate
    @AuraEnabled public Id lastmodifiedbyid { get; set; } // LastModifiedById
    @AuraEnabled public Datetime systemmodstamp { get; set; } // SystemModstamp
    @AuraEnabled public Date lastactivitydate { get; set; } // LastActivityDate
    @AuraEnabled public Datetime lastvieweddate { get; set; } // LastViewedDate
    @AuraEnabled public Datetime lastreferenceddate { get; set; } // LastReferencedDate
    @AuraEnabled public String status { get; set; } // Status__c
    @AuraEnabled public String commentsNotes { get; set; } // Comments_Notes__c
    @AuraEnabled public String explanation { get; set; } // Explanation__c
    @AuraEnabled public Date finalizedDate { get; set; } // Finalized_Date__c
    @AuraEnabled public String options { get; set; } // Options__c
    @AuraEnabled public Id project { get; set; } // Project__c
    @AuraEnabled public String decisionName { get; set; } // Decision_Name__c
    @AuraEnabled public Boolean internal { get; set; } // Internal__c
    @AuraEnabled public String dicisionNameHyperLink { get; set; } // Dicision_Name_HyperLink__c
}
