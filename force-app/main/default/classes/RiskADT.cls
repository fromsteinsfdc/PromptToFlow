public class RiskADT {
    @AuraEnabled public Id Id { get; set; }
    @AuraEnabled public Id OwnerId { get; set; }
    @AuraEnabled public Boolean IsDeleted { get; set; }
    @AuraEnabled public String Name { get; set; }
    @AuraEnabled public String CurrencyIsoCode { get; set; }
    @AuraEnabled public Datetime CreatedDate { get; set; }
    @AuraEnabled public Id CreatedById { get; set; }
    @AuraEnabled public Datetime LastModifiedDate { get; set; }
    @AuraEnabled public Id LastModifiedById { get; set; }
    @AuraEnabled public Datetime SystemModstamp { get; set; }
    @AuraEnabled public Datetime LastViewedDate { get; set; }
    @AuraEnabled public Datetime LastReferencedDate { get; set; }
    @AuraEnabled public Id pseAccount { get; set; } // pse__Account__c
    @AuraEnabled public Date pseClosedDate { get; set; } // pse__Closed_Date__c
    @AuraEnabled public Boolean pseClosed { get; set; } // pse__Closed__c
    @AuraEnabled public String pseComments { get; set; } // pse__Comments__c
    @AuraEnabled public String pseContingency { get; set; } // pse__Contingency__c
    @AuraEnabled public Date pseDateRaised { get; set; } // pse__Date_Raised__c
    @AuraEnabled public String pseImpact { get; set; } // pse__Impact__c
    @AuraEnabled public Id pseIssue { get; set; } // pse__Issue__c
    @AuraEnabled public String pseLikelihood { get; set; } // pse__Likelihood__c
    @AuraEnabled public Id pseMilestone { get; set; } // pse__Milestone__c
    @AuraEnabled public String pseMitigationPlan { get; set; } // pse__Mitigation_Plan__c
    @AuraEnabled public Id pseOpportunity { get; set; } // pse__Opportunity__c
    @AuraEnabled public Id pseProjectTask { get; set; } // pse__Project_Task__c
    @AuraEnabled public Id pseProject { get; set; } // pse__Project__c
    @AuraEnabled public String pseRiskDescription { get; set; } // pse__Risk_Description__c
    @AuraEnabled public String pseRiskName { get; set; } // pse__Risk_Name__c
    @AuraEnabled public Id pseRiskOwner { get; set; } // pse__Risk_Owner__c
    @AuraEnabled public Decimal pseSeverity { get; set; } // pse__Severity__c
    @AuraEnabled public String pseStatus { get; set; } // pse__Status__c
    @AuraEnabled public Id agendaItem { get; set; } // Agenda_Item__c
    @AuraEnabled public Id meeting { get; set; } // Meeting__c
    @AuraEnabled public Id pseSourceRisk { get; set; } // pse__Source_Risk__c
    @AuraEnabled public String riskLinkFormula { get; set; } // Risk_LInk_Formula__c
    @AuraEnabled public Boolean internalValue { get; set; } // Internal__c
}
