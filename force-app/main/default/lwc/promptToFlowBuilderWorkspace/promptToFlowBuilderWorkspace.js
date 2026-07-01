import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getAvailableObjects from '@salesforce/apex/PromptToFlowController.getAvailableObjects';
import getFieldsForObject from '@salesforce/apex/PromptToFlowController.getFieldsForObject';
import getConfigurations from '@salesforce/apex/PromptToFlowController.getConfigurations';
import getConfiguration from '@salesforce/apex/PromptToFlowController.getConfiguration';
import saveConfiguration from '@salesforce/apex/PromptToFlowController.saveConfiguration';
import generateParserForConfiguration from '@salesforce/apex/PromptToFlowController.generateParserForConfiguration';
import getParserGenerationSetupStatus from '@salesforce/apex/PromptToFlowController.getParserGenerationSetupStatus';
import assignSetupPermissionSetToCurrentUser from '@salesforce/apex/PromptToFlowController.assignSetupPermissionSetToCurrentUser';

export default class PromptToFlowBuilderWorkspace extends LightningElement {
    @track objectOptions = [];
    @track configurations = [];
    @track selectedObjects = [];
    @track jsonOutput = '';
    @track setupStatus = {};
    @track isSaving = false;
    @track showPreview = false;

    selectedConfigurationId;
    configurationName = '';
    invocableActionLabel = '';
    parserClassName = '';
    parserClassNameLocked = false;
    objectToAdd;
    activeSection;
    nextId = 1;
    isDirty = false;

    connectedCallback() {
        this.initialize();
    }

    async initialize() {
        await Promise.all([this.loadObjects(), this.loadConfigurations(), this.loadSetupStatus()]);
    }

    // ----- Derived state -----
    get disableAddObject() {
        return !this.objectToAdd;
    }

    get hasSelectedObjects() {
        return this.selectedObjects.length > 0;
    }

    get hasConfigurations() {
        return this.configurations.length > 0;
    }

    get configurationItems() {
        return this.configurations.map((item) => ({
            id: item.id,
            name: item.name,
            isActive: item.id === this.selectedConfigurationId,
            itemClass:
                item.id === this.selectedConfigurationId
                    ? 'slds-nav-vertical__item slds-is-active'
                    : 'slds-nav-vertical__item'
        }));
    }

    get accordionSections() {
        return this.selectedObjects.map((item) => item.id);
    }

    get editorTitle() {
        return this.configurationName ? this.configurationName : 'New configuration';
    }

    get derivedParserClassName() {
        if (this.parserClassNameLocked && this.parserClassName) {
            return this.parserClassName;
        }
        return this.toSafeClassName(this.invocableActionLabel);
    }

    get parserClassHelpText() {
        const name = this.derivedParserClassName;
        if (!name) {
            return 'A parser Apex class will be generated automatically from the action label.';
        }
        return this.parserClassNameLocked
            ? `Parser class: ${name} (locked now that the class is generated)`
            : `Parser class will be generated as: ${name}`;
    }

    get setupMessage() {
        return this.setupStatus && this.setupStatus.message ? this.setupStatus.message : '';
    }

    get showSetupBanner() {
        return this.setupStatus && this.setupStatus.ready === false;
    }

    get canAutoAssignPermissionSet() {
        return this.setupStatus && this.setupStatus.canAutoAssignPermissionSet === true;
    }

    get previewToggleLabel() {
        return this.showPreview ? 'Hide generated JSON' : 'Show generated JSON';
    }

    // ----- Data loading -----
    async loadObjects() {
        try {
            const objects = await getAvailableObjects();
            this.objectOptions = objects
                .map((item) => ({
                    label: `${item.label} (${item.apiName})`,
                    value: item.apiName
                }))
                .sort((a, b) => a.label.localeCompare(b.label, undefined, { sensitivity: 'base' }));
        } catch (error) {
            this.showError('Unable to load objects', error);
        }
    }

    async loadConfigurations() {
        try {
            const configs = await getConfigurations();
            this.configurations = configs.map((item) => ({
                id: item.id,
                name: item.name
            }));
        } catch (error) {
            this.showError('Unable to load configurations', error);
        }
    }

    async loadSetupStatus() {
        try {
            this.setupStatus = await getParserGenerationSetupStatus();
        } catch (error) {
            this.setupStatus = {
                ready: false,
                message: this.extractErrorMessage(error)
            };
        }
    }

    async handleConfigurationSelect(event) {
        event.preventDefault();
        const configId = event.currentTarget.dataset.id;
        if (!configId || configId === this.selectedConfigurationId) {
            return;
        }
        const proceed = await this.confirmDiscardIfDirty();
        if (!proceed) {
            return;
        }
        this.selectedConfigurationId = configId;
        this.loadConfiguration(configId);
    }

    async loadConfiguration(configurationId) {
        try {
            const dto = await getConfiguration({ configurationId });
            this.configurationName = dto.name || '';
            this.invocableActionLabel = dto.invocableActionLabel || '';
            this.parserClassName = dto.parserClassName || '';
            this.parserClassNameLocked = dto.parserClassNameLocked === true;

            const parsed = dto.configurationJson ? JSON.parse(dto.configurationJson) : [];
            const objectConfigs = Array.isArray(parsed) ? parsed : parsed.selectedObjects || [];
            await this.hydrateSelectedObjects(objectConfigs);
            this.activeSection = this.selectedObjects.length ? this.selectedObjects[0].id : undefined;
            this.handleGenerateTemplate();
            this.isDirty = false;
        } catch (error) {
            this.showError('Unable to load configuration', error);
        }
    }

    async hydrateSelectedObjects(objectConfigs) {
        const hydrated = await Promise.all(
            objectConfigs.map(async (rawConfig) => {
                const id = String(this.nextId++);
                const option = this.objectOptions.find((item) => item.value === rawConfig.apiName);
                const fields = await getFieldsForObject({ objectApiName: rawConfig.apiName });
                const mappedFields = this.mapFields(fields);
                const selectedFields = [...(rawConfig.selectedFields || [])];

                return {
                    id,
                    apiName: rawConfig.apiName,
                    label: option ? option.label : rawConfig.apiName,
                    sectionName: id,
                    isCollection: rawConfig.isCollection !== false,
                    isLoading: false,
                    fieldOptions: mappedFields,
                    selectedFields,
                    selectedCount: selectedFields.length
                };
            })
        );

        this.selectedObjects = hydrated;
    }

    mapFields(fields) {
        return fields
            .map((field) => ({
                label: `${field.label} (${field.apiName})`,
                value: field.apiName,
                dataType: field.dataType,
                keyPrefix: field.keyPrefix
            }))
            .sort((a, b) => a.label.localeCompare(b.label, undefined, { sensitivity: 'base' }));
    }

    // ----- Form handlers -----
    handleConfigurationNameChange(event) {
        this.configurationName = event.detail.value;
        this.isDirty = true;
    }

    handleInvocableActionLabelChange(event) {
        this.invocableActionLabel = event.detail.value;
        this.isDirty = true;
    }

    handleSectionToggle(event) {
        this.activeSection = event.detail.openSections;
    }

    async confirmDiscardIfDirty() {
        if (!this.isDirty) {
            return true;
        }
        return LightningConfirm.open({
            message: 'You have unsaved changes that will be lost. Do you want to continue?',
            label: 'Discard unsaved changes?',
            theme: 'warning',
            variant: 'header'
        });
    }

    async handleNewConfiguration() {
        const proceed = await this.confirmDiscardIfDirty();
        if (!proceed) {
            return;
        }
        this.resetForm();
    }

    resetForm() {
        this.selectedConfigurationId = null;
        this.configurationName = '';
        this.invocableActionLabel = '';
        this.parserClassName = '';
        this.parserClassNameLocked = false;
        this.selectedObjects = [];
        this.jsonOutput = '';
        this.activeSection = undefined;
        this.isDirty = false;
    }

    async handleSaveConfiguration() {
        if (!this.configurationName) {
            this.showToast('Validation', 'Configuration name is required.', 'warning');
            return;
        }
        if (!this.invocableActionLabel) {
            this.showToast('Validation', 'Invocable action label is required.', 'warning');
            return;
        }
        const configurationModel = this.exportConfigurationModel();
        if (configurationModel.length === 0) {
            this.showToast('Validation', 'Add at least one object configuration before saving.', 'warning');
            return;
        }

        this.isSaving = true;
        try {
            const configurationModelJson = JSON.stringify(configurationModel);
            const templateJson = this.buildTemplateJson();
            const saved = await saveConfiguration({
                configurationId: this.selectedConfigurationId,
                configurationName: this.configurationName,
                configurationJson: configurationModelJson,
                templateJson,
                invocableActionLabel: this.invocableActionLabel,
                generateParserOnSave: true
            });

            this.selectedConfigurationId = saved.id;
            this.configurationName = saved.name;
            this.invocableActionLabel = saved.invocableActionLabel || '';
            this.parserClassName = saved.parserClassName || '';
            this.parserClassNameLocked = saved.parserClassNameLocked === true;

            if (this.parserClassName) {
                await this.loadSetupStatus();
                if (!this.setupStatus.ready) {
                    throw new Error(this.setupMessage || 'Parser generation setup is incomplete.');
                }
                await generateParserForConfiguration({ configurationId: saved.id });
            }

            await Promise.all([this.loadConfigurations(), this.loadSetupStatus()]);
            this.isDirty = false;
            this.showToast('Saved', 'Configuration saved successfully.', 'success');
        } catch (error) {
            this.showError('Unable to save configuration', error);
        } finally {
            this.isSaving = false;
        }
    }

    exportConfigurationModel() {
        return this.selectedObjects.map((item) => ({
            apiName: item.apiName,
            isCollection: item.isCollection,
            selectedFields: [...item.selectedFields]
        }));
    }

    async handleAutoAssignPermissionSet() {
        try {
            this.setupStatus = await assignSetupPermissionSetToCurrentUser();
            if (this.setupStatus.ready) {
                this.showToast('Setup Ready', 'Permission set assigned. Parser generation is ready.', 'success');
            } else {
                this.showToast('Setup Updated', this.setupMessage, 'info');
            }
        } catch (error) {
            this.showError('Unable to assign permission set', error);
        }
    }

    // ----- Object / field handlers -----
    handleObjectChange(event) {
        this.objectToAdd = event.detail.value;
    }

    async handleAddObject() {
        if (!this.objectToAdd || this.selectedObjects.some((obj) => obj.apiName === this.objectToAdd)) {
            return;
        }

        const objectOption = this.objectOptions.find((option) => option.value === this.objectToAdd);
        const id = String(this.nextId++);
        const newObject = {
            id,
            apiName: this.objectToAdd,
            label: objectOption ? objectOption.label : this.objectToAdd,
            sectionName: id,
            isCollection: true,
            isLoading: true,
            fieldOptions: [],
            selectedFields: [],
            selectedCount: 0
        };

        this.selectedObjects = [...this.selectedObjects, newObject];
        this.activeSection = id;
        this.objectToAdd = null;
        this.isDirty = true;

        try {
            const fields = await getFieldsForObject({ objectApiName: newObject.apiName });
            this.updateObjectConfig(id, {
                fieldOptions: this.mapFields(fields),
                isLoading: false
            });
        } catch (error) {
            this.updateObjectConfig(id, { isLoading: false });
            this.showError(`Unable to load fields for ${newObject.apiName}`, error);
        }
    }

    handleRemoveObject(event) {
        const id = event.currentTarget.dataset.id;
        this.selectedObjects = this.selectedObjects.filter((item) => item.id !== id);
        this.isDirty = true;
        this.handleGenerateTemplate();
    }

    handleCollectionToggle(event) {
        const id = event.target.dataset.id;
        this.updateObjectConfig(id, { isCollection: event.target.checked });
        this.isDirty = true;
        this.handleGenerateTemplate();
    }

    handleFieldSelection(event) {
        const id = event.target.dataset.id;
        const value = event.detail.value;
        this.updateObjectConfig(id, { selectedFields: value, selectedCount: value.length });
        this.isDirty = true;
        this.handleGenerateTemplate();
    }

    handleGenerateTemplate() {
        this.jsonOutput = this.buildTemplateJson();
    }

    togglePreview() {
        this.showPreview = !this.showPreview;
        if (this.showPreview) {
            this.handleGenerateTemplate();
        }
    }

    buildTemplateJson() {
        const template = {};
        this.selectedObjects.forEach((objectConfig) => {
            const selectedFieldMap = {};
            objectConfig.selectedFields.forEach((fieldApiName) => {
                const field = objectConfig.fieldOptions.find((option) => option.value === fieldApiName);
                selectedFieldMap[fieldApiName] = this.getPlaceholderValue(field);
            });
            template[objectConfig.apiName] = objectConfig.isCollection ? [selectedFieldMap] : selectedFieldMap;
        });
        return JSON.stringify(template, null, 2);
    }

    async handleCopyOutput() {
        this.handleGenerateTemplate();
        if (!this.jsonOutput) {
            return;
        }
        try {
            await navigator.clipboard.writeText(this.jsonOutput);
            this.showToast('Copied', 'JSON template copied to clipboard.', 'success');
        } catch (error) {
            this.showError('Unable to copy output', error);
        }
    }

    updateObjectConfig(id, updates) {
        this.selectedObjects = this.selectedObjects.map((item) =>
            item.id === id ? { ...item, ...updates } : item
        );
    }

    // ----- Placeholder + utility helpers -----
    getIdPlaceholder(keyPrefix) {
        const prefix = keyPrefix && keyPrefix.length === 3 ? keyPrefix : '001';
        return `${prefix}${'X'.repeat(18 - prefix.length)}`;
    }

    getPlaceholderValue(field) {
        const typeName = (field && field.dataType ? field.dataType : '').toLowerCase();
        switch (typeName) {
            case 'boolean':
                return false;
            case 'date':
                return '2026-01-15';
            case 'datetime':
                return '2026-01-15T12:00:00.000Z';
            case 'time':
                return '12:00:00.000Z';
            case 'int':
            case 'integer':
            case 'double':
            case 'currency':
            case 'percent':
            case 'long':
                return 0;
            case 'reference':
            case 'id':
                return this.getIdPlaceholder(field && field.keyPrefix);
            case 'email':
                return 'user@example.com';
            case 'url':
                return 'https://example.com';
            case 'phone':
                return '555-123-4567';
            case 'multipicklist':
                return 'Value A;Value B';
            default:
                return 'string';
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    showError(title, error) {
        this.showToast(title, this.extractErrorMessage(error), 'error');
    }

    extractErrorMessage(error) {
        if (!error) {
            return 'An unexpected error occurred.';
        }
        if (typeof error === 'string') {
            return error;
        }
        if (error.message) {
            return error.message;
        }
        if (error.body) {
            if (Array.isArray(error.body) && error.body.length > 0) {
                return error.body.map((item) => item.message || JSON.stringify(item)).join('; ');
            }
            if (error.body.message) {
                return error.body.message;
            }
        }
        return 'An unexpected error occurred.';
    }

    toSafeClassName(rawValue) {
        if (!rawValue) {
            return '';
        }
        const cleaned = rawValue.trim().replace(/[^A-Za-z0-9_]/g, '_');
        return /^[A-Za-z_]/.test(cleaned) ? cleaned : `_${cleaned}`;
    }
}
