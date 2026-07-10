import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAvailableObjects from '@salesforce/apex/PromptToFlowController.getAvailableObjects';
import getFieldsForObject from '@salesforce/apex/PromptToFlowController.getFieldsForObject';
import getConfigurations from '@salesforce/apex/PromptToFlowController.getConfigurations';
import getConfiguration from '@salesforce/apex/PromptToFlowController.getConfiguration';
import saveConfiguration from '@salesforce/apex/PromptToFlowController.saveConfiguration';
import generateParserForConfiguration from '@salesforce/apex/PromptToFlowController.generateParserForConfiguration';
import getParserGenerationSetupStatus from '@salesforce/apex/PromptToFlowController.getParserGenerationSetupStatus';
import assignSetupPermissionSetToCurrentUser from '@salesforce/apex/PromptToFlowController.assignSetupPermissionSetToCurrentUser';

export default class PromptToFlowBuilder extends LightningElement {
    @track objectOptions = [];
    @track configurationOptions = [];
    @track selectedObjects = [];
    @track jsonOutput = '';
    @track setupStatus = {};
    @track isSaving = false;

    selectedConfigurationId;
    configurationName = '';
    invocableActionLabel = '';
    parserClassName = '';
    parserClassNameLocked = false;
    generateParserOnSave = true;
    objectToAdd;
    nextId = 1;

    connectedCallback() {
        this.initialize();
    }

    async initialize() {
        await Promise.all([this.loadObjects(), this.loadConfigurations(), this.loadSetupStatus()]);
    }

    get disableAddObject() {
        return !this.objectToAdd;
    }

    get hasSelectedObjects() {
        return this.selectedObjects.length > 0;
    }

    get derivedParserClassName() {
        if (this.parserClassNameLocked && this.parserClassName) {
            return this.parserClassName;
        }
        return this.toSafeClassName(this.invocableActionLabel);
    }

    get setupMessage() {
        return this.setupStatus && this.setupStatus.message ? this.setupStatus.message : '';
    }

    get showSetupBanner() {
        return this.generateParserOnSave && this.setupStatus && this.setupStatus.ready === false;
    }

    get canAutoAssignPermissionSet() {
        return this.setupStatus && this.setupStatus.canAutoAssignPermissionSet === true;
    }

    async loadObjects() {
        try {
            const objects = await getAvailableObjects();
            this.objectOptions = objects
                .map((item) => ({
                    label: `${item.label} (${item.apiName})`,
                    value: item.apiName,
                    pluralLabel: item.pluralLabel
                }))
                .sort((a, b) => a.label.localeCompare(b.label, undefined, { sensitivity: 'base' }));
        } catch (error) {
            this.showError('Unable to load objects', error);
        }
    }

    async loadConfigurations() {
        try {
            const configs = await getConfigurations();
            this.configurationOptions = configs.map((item) => ({
                label: item.name,
                value: item.id
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

    handleConfigurationSelect(event) {
        const configId = event.detail.value;
        this.selectedConfigurationId = configId;
        if (configId) {
            this.loadConfiguration(configId);
        }
    }

    async loadConfiguration(configurationId) {
        try {
            const dto = await getConfiguration({ configurationId });
            this.configurationName = dto.name || '';
            this.invocableActionLabel = dto.invocableActionLabel || '';
            this.parserClassName = dto.parserClassName || '';
            this.parserClassNameLocked = dto.parserClassNameLocked === true;
            this.generateParserOnSave = dto.generateParserOnSave === true;

            const parsed = dto.configurationJson ? JSON.parse(dto.configurationJson) : [];
            const objectConfigs = Array.isArray(parsed) ? parsed : parsed.selectedObjects || [];
            await this.hydrateSelectedObjects(objectConfigs);
            this.handleGenerateTemplate();
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
                const mappedFields = fields
                    .map((field) => ({
                        label: `${field.label} (${field.apiName})`,
                        value: field.apiName,
                        dataType: field.dataType,
                        keyPrefix: field.keyPrefix
                    }))
                    .sort((a, b) => a.label.localeCompare(b.label, undefined, { sensitivity: 'base' }));

                return {
                    id,
                    apiName: rawConfig.apiName,
                    label: option ? option.label : rawConfig.apiName,
                    pluralLabel: (option && option.pluralLabel) || rawConfig.pluralLabel || rawConfig.apiName,
                    isCollection: rawConfig.isCollection !== false,
                    isLoading: false,
                    fieldOptions: mappedFields,
                    selectedFields: [...(rawConfig.selectedFields || [])]
                };
            })
        );

        this.selectedObjects = hydrated;
    }

    handleConfigurationNameChange(event) {
        this.configurationName = event.detail.value;
    }

    handleInvocableActionLabelChange(event) {
        this.invocableActionLabel = event.detail.value;
    }

    handleGenerateParserToggle(event) {
        this.generateParserOnSave = event.target.checked;
    }

    handleNewConfiguration() {
        this.selectedConfigurationId = null;
        this.configurationName = '';
        this.invocableActionLabel = '';
        this.parserClassName = '';
        this.parserClassNameLocked = false;
        this.generateParserOnSave = true;
        this.selectedObjects = [];
        this.jsonOutput = '';
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
                generateParserOnSave: this.generateParserOnSave
            });

            this.selectedConfigurationId = saved.id;
            this.configurationName = saved.name;
            this.invocableActionLabel = saved.invocableActionLabel || '';
            this.parserClassName = saved.parserClassName || '';
            this.parserClassNameLocked = saved.parserClassNameLocked === true;
            this.generateParserOnSave = saved.generateParserOnSave === true;

            if (this.generateParserOnSave && this.parserClassName) {
                await this.loadSetupStatus();
                if (!this.setupStatus.ready) {
                    throw new Error(this.setupMessage || 'Parser generation setup is incomplete.');
                }
                await generateParserForConfiguration({
                    configurationId: saved.id
                });
            }

            await Promise.all([this.loadConfigurations(), this.loadSetupStatus()]);
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
            jsonKey: this.getJsonKey(item),
            isCollection: item.isCollection,
            selectedFields: [...item.selectedFields]
        }));
    }

    // Collections use the object's plural label as the JSON property name (e.g.
    // "Opportunities"); single records keep the API name (e.g. "Account"). The
    // generated parser reads these same keys, so both must stay in sync.
    getJsonKey(objectConfig) {
        if (objectConfig.isCollection) {
            return objectConfig.pluralLabel || objectConfig.apiName;
        }
        return objectConfig.apiName;
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

    handleObjectChange(event) {
        this.objectToAdd = event.detail.value;
    }

    async handleAddObject() {
        if (!this.objectToAdd || this.selectedObjects.some((obj) => obj.apiName === this.objectToAdd)) {
            return;
        }

        const objectOption = this.objectOptions.find((option) => option.value === this.objectToAdd);
        const newObject = {
            id: String(this.nextId++),
            apiName: this.objectToAdd,
            label: objectOption ? objectOption.label : this.objectToAdd,
            pluralLabel: (objectOption && objectOption.pluralLabel) || this.objectToAdd,
            isCollection: true,
            isLoading: true,
            fieldOptions: [],
            selectedFields: []
        };

        this.selectedObjects = [...this.selectedObjects, newObject];
        this.objectToAdd = null;

        try {
            const fields = await getFieldsForObject({ objectApiName: newObject.apiName });
            const mappedFields = fields
                .map((field) => ({
                    label: `${field.label} (${field.apiName})`,
                    value: field.apiName,
                    dataType: field.dataType,
                    keyPrefix: field.keyPrefix
                }))
                .sort((a, b) => a.label.localeCompare(b.label, undefined, { sensitivity: 'base' }));
            this.updateObjectConfig(newObject.id, {
                fieldOptions: mappedFields,
                isLoading: false
            });
        } catch (error) {
            this.updateObjectConfig(newObject.id, { isLoading: false });
            this.showError(`Unable to load fields for ${newObject.apiName}`, error);
        }
    }

    handleRemoveObject(event) {
        const id = event.currentTarget.dataset.id;
        this.selectedObjects = this.selectedObjects.filter((item) => item.id !== id);
        this.handleGenerateTemplate();
    }

    handleCollectionToggle(event) {
        const id = event.target.dataset.id;
        this.updateObjectConfig(id, { isCollection: event.target.checked });
        this.handleGenerateTemplate();
    }

    handleFieldSelection(event) {
        const id = event.target.dataset.id;
        this.updateObjectConfig(id, { selectedFields: event.detail.value });
        this.handleGenerateTemplate();
    }

    handleGenerateTemplate() {
        this.jsonOutput = this.buildTemplateJson();
    }

    buildTemplateJson() {
        const template = {};

        this.selectedObjects.forEach((objectConfig) => {
            const selectedFieldMap = {};
            objectConfig.selectedFields.forEach((fieldApiName) => {
                const field = objectConfig.fieldOptions.find((option) => option.value === fieldApiName);
                selectedFieldMap[fieldApiName] = this.getPlaceholderValue(field);
            });

            template[this.getJsonKey(objectConfig)] = objectConfig.isCollection ? [selectedFieldMap] : selectedFieldMap;
        });

        return JSON.stringify(template, null, 2);
    }

    async handleCopyOutput() {
        if (!this.jsonOutput) {
            return;
        }

        try {
            await this.copyToClipboard(this.jsonOutput);
            this.showToast('Copied', 'JSON template copied to clipboard.', 'success');
        } catch (error) {
            this.showError('Unable to copy output', error);
        }
    }

    async copyToClipboard(text) {
        if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
            await navigator.clipboard.writeText(text);
            return;
        }
        // Fallback for contexts where navigator.clipboard is unavailable
        // (e.g. non-secure contexts or restricted Lightning environments).
        const textarea = document.createElement('textarea');
        textarea.value = text;
        textarea.setAttribute('readonly', '');
        textarea.style.position = 'fixed';
        textarea.style.top = '-9999px';
        textarea.style.left = '-9999px';
        document.body.appendChild(textarea);
        textarea.focus();
        textarea.select();
        let successful = false;
        try {
            successful = document.execCommand('copy');
        } finally {
            document.body.removeChild(textarea);
        }
        if (!successful) {
            throw new Error('Copy command was unsuccessful.');
        }
    }

    updateObjectConfig(id, updates) {
        this.selectedObjects = this.selectedObjects.map((item) =>
            item.id === id
                ? {
                      ...item,
                      ...updates
                  }
                : item
        );
    }

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
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }

    showError(title, error) {
        const message = this.extractErrorMessage(error);
        this.showToast(title, message, 'error');
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
