import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getAvailableObjects from '@salesforce/apex/PromptToFlowController.getAvailableObjects';
import getFieldsForObject from '@salesforce/apex/PromptToFlowController.getFieldsForObject';
import getConfigurations from '@salesforce/apex/PromptToFlowController.getConfigurations';
import getConfiguration from '@salesforce/apex/PromptToFlowController.getConfiguration';
import saveConfiguration from '@salesforce/apex/PromptToFlowController.saveConfiguration';
import deleteConfiguration from '@salesforce/apex/PromptToFlowController.deleteConfiguration';
import generateParserForConfiguration from '@salesforce/apex/PromptToFlowController.generateParserForConfiguration';
import getParserGenerationSetupStatus from '@salesforce/apex/PromptToFlowController.getParserGenerationSetupStatus';
import assignSetupPermissionSetToCurrentUser from '@salesforce/apex/PromptToFlowController.assignSetupPermissionSetToCurrentUser';

export default class PromptToFlowBuilderCompact extends LightningElement {
    @track objectOptions = [];
    @track configurations = [];
    @track selectedObjects = [];
    @track jsonOutput = '';
    @track setupStatus = {};
    @track isSaving = false;
    @track isLoadingConfig = false;
    @track showPreview = false;

    selectedConfigurationId;
    configurationName = '';
    invocableActionLabel = '';
    parserClassName = '';
    parserClassNameLocked = false;
    activeTab;
    nextId = 1;
    isDirty = false;
    configsLoaded = false;

    connectedCallback() {
        this.initialize();
    }

    async initialize() {
        await Promise.all([this.loadObjects(), this.loadSetupStatus()]);
    }

    @wire(getConfigurations)
    wiredConfigurations(result) {
        this.wiredConfigurationsResult = result;
        if (result.data) {
            this.configurations = result.data.map((item) => ({
                id: item.id,
                name: item.name
            }));
            this.configsLoaded = true;
        } else if (result.error) {
            this.configsLoaded = true;
            this.showError('Unable to load configurations', result.error);
        }
    }

    // ----- Derived state -----
    get isBusy() {
        return this.isSaving || this.isLoadingConfig;
    }

    get isDeleteDisabled() {
        return !this.selectedConfigurationId || this.isBusy;
    }

    get hasSelectedObjects() {
        return this.selectedObjects.length > 0;
    }

    get navItems() {
        return this.selectedObjects.map((item) => ({
            id: item.id,
            shortLabel: item.shortLabel,
            selectedCount: item.selectedCount,
            isConfigured: item.isConfigured,
            showError: item.showError === true,
            iconName: item.isCollection ? 'utility:record_collection' : 'utility:record_alt',
            iconAlt: item.isCollection ? 'Collection' : 'Single record',
            ariaSelected: item.id === this.activeTab ? 'true' : 'false',
            itemClass:
                item.id === this.activeTab
                    ? 'slds-vertical-tabs__nav-item slds-is-active'
                    : 'slds-vertical-tabs__nav-item'
        }));
    }

    isObjectInvalid(objectConfig) {
        if (!objectConfig) {
            return false;
        }
        if (!objectConfig.apiName) {
            return true;
        }
        return (objectConfig.selectedFields || []).length === 0;
    }

    // Flags the given tab with an error dot when it's left in an invalid state.
    flagTabIfInvalid(objectId) {
        if (!objectId) {
            return;
        }
        const objectConfig = this.selectedObjects.find((item) => item.id === objectId);
        if (objectConfig) {
            this.updateObjectConfig(objectId, { showError: this.isObjectInvalid(objectConfig) });
        }
    }

    flagInvalidTabs() {
        this.selectedObjects = this.selectedObjects.map((item) => ({
            ...item,
            showError: this.isObjectInvalid(item)
        }));
    }

    get activeObject() {
        return this.selectedObjects.find((item) => item.id === this.activeTab);
    }

    // Filters only the Available side by the search term; selected fields
    // always stay in the options so the Selected side remains fully visible.
    get activeFieldOptions() {
        const obj = this.activeObject;
        if (!obj) {
            return [];
        }
        const term = (obj.searchTerm || '').trim().toLowerCase();
        if (!term) {
            return obj.fieldOptions;
        }
        const selected = new Set(obj.selectedFields);
        return obj.fieldOptions.filter(
            (option) => selected.has(option.value) || option.label.toLowerCase().includes(term)
        );
    }

    get availableObjectOptions() {
        const used = new Set(this.selectedObjects.filter((item) => item.apiName).map((item) => item.apiName));
        return this.objectOptions.filter((option) => !used.has(option.value));
    }

    get hasConfigurations() {
        return this.configurations.length > 0;
    }

    get showConfigLoading() {
        return !this.configsLoaded;
    }

    get showConfigEmpty() {
        return this.configsLoaded && this.configurations.length === 0;
    }

    get openMenuItems() {
        return this.configurations.map((item) => ({
            id: item.id,
            name: item.name,
            checked: item.id === this.selectedConfigurationId
        }));
    }

    get statusLabel() {
        if (!this.selectedConfigurationId) {
            return 'Draft — not yet saved';
        }
        return this.parserClassNameLocked && this.parserClassName
            ? `Saved · Parser class ${this.parserClassName}`
            : 'Saved';
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
            return 'A parser Apex class is generated automatically from the action label when you save.';
        }
        return this.parserClassNameLocked
            ? `Parser class: ${name} (locked after first save).`
            : `Parser class will be generated as ${name} on save.`;
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
        return this.showPreview ? 'Hide JSON preview' : 'Show JSON preview';
    }

    // ----- Data loading -----
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

    async handleOpenConfiguration(event) {
        const configId = event.detail.value;
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
        this.isLoadingConfig = true;
        try {
            const dto = await getConfiguration({ configurationId });
            this.configurationName = dto.name || '';
            this.invocableActionLabel = dto.invocableActionLabel || '';
            this.parserClassName = dto.parserClassName || '';
            this.parserClassNameLocked = dto.parserClassNameLocked === true;

            const parsed = dto.configurationJson ? JSON.parse(dto.configurationJson) : [];
            const objectConfigs = Array.isArray(parsed) ? parsed : parsed.selectedObjects || [];
            await this.hydrateSelectedObjects(objectConfigs);
            this.activeTab = this.selectedObjects.length ? this.selectedObjects[0].id : undefined;
            this.handleGenerateTemplate();
            this.isDirty = false;
        } catch (error) {
            this.showError('Unable to load configuration', error);
        } finally {
            this.isLoadingConfig = false;
        }
    }

    async hydrateSelectedObjects(objectConfigs) {
        const hydrated = await Promise.all(
            objectConfigs.map(async (rawConfig) => {
                const id = String(this.nextId++);
                const option = this.objectOptions.find((item) => item.value === rawConfig.apiName);
                const fields = await getFieldsForObject({ objectApiName: rawConfig.apiName });
                const selectedFields = [...(rawConfig.selectedFields || [])];
                return {
                    id,
                    apiName: rawConfig.apiName,
                    label: option ? option.label : rawConfig.apiName,
                    shortLabel: this.shortLabel(option ? option.label : rawConfig.apiName),
                    pluralLabel: (option && option.pluralLabel) || rawConfig.pluralLabel || rawConfig.apiName,
                    isConfigured: true,
                    isCollection: rawConfig.isCollection !== false,
                    isLoading: false,
                    fieldOptions: this.mapFields(fields),
                    selectedFields,
                    selectedCount: selectedFields.length,
                    searchTerm: ''
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

    shortLabel(label) {
        if (!label) {
            return label;
        }
        return label.replace(/\s*\(.*\)\s*$/, '');
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

    handleConfigurationNameBlur() {
        const name = (this.configurationName || '').trim();
        const label = (this.invocableActionLabel || '').trim();
        if (name && !label) {
            this.invocableActionLabel = `Parse ${name}`;
            this.isDirty = true;
        }
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

    async handleDeleteConfiguration() {
        if (!this.selectedConfigurationId) {
            return;
        }
        const name = this.configurationName || 'this configuration';
        const confirmed = await LightningConfirm.open({
            message: `Delete “${name}”? This permanently removes the saved configuration and can't be undone. The generated parser Apex class is left in place.`,
            label: 'Delete configuration?',
            theme: 'error',
            variant: 'header'
        });
        if (!confirmed) {
            return;
        }

        this.isSaving = true;
        try {
            await deleteConfiguration({ configurationId: this.selectedConfigurationId });
            await refreshApex(this.wiredConfigurationsResult);
            this.resetForm();
            this.showToast('Deleted', 'Configuration deleted.', 'success');
        } catch (error) {
            this.showError('Unable to delete configuration', error);
        } finally {
            this.isSaving = false;
        }
    }

    resetForm() {
        this.selectedConfigurationId = null;
        this.configurationName = '';
        this.invocableActionLabel = '';
        this.parserClassName = '';
        this.parserClassNameLocked = false;
        this.selectedObjects = [];
        this.jsonOutput = '';
        this.activeTab = undefined;
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
        if (this.selectedObjects.length === 0) {
            this.showToast('Validation', 'Add at least one object before saving.', 'warning');
            return;
        }

        const unconfigured = this.selectedObjects.filter((item) => !item.apiName);
        const missingFields = this.selectedObjects.filter(
            (item) => item.apiName && (item.selectedFields || []).length === 0
        );
        if (unconfigured.length || missingFields.length) {
            this.flagInvalidTabs();
            const firstInvalid = this.selectedObjects.find((item) => this.isObjectInvalid(item));
            if (firstInvalid) {
                this.activeTab = firstInvalid.id;
            }
            const message = unconfigured.length
                ? 'Select an object for every tab, or remove empty “New object” tabs before saving.'
                : 'Each object must have at least one field selected.';
            this.showToast('Validation', message, 'warning');
            return;
        }

        const configurationModel = this.exportConfigurationModel();

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

            await Promise.all([refreshApex(this.wiredConfigurationsResult), this.loadSetupStatus()]);
            this.isDirty = false;
            this.showToast('Saved', 'Configuration saved successfully.', 'success');
        } catch (error) {
            this.showError('Unable to save configuration', error);
        } finally {
            this.isSaving = false;
        }
    }

    exportConfigurationModel() {
        return this.selectedObjects
            .filter((item) => item.apiName)
            .map((item) => ({
                apiName: item.apiName,
                jsonKey: this.getJsonKey(item),
                isCollection: item.isCollection,
                selectedFields: [...item.selectedFields]
            }));
    }

    // Collections use the object's plural label as the JSON key; single
    // records use the API name. The template preview and the generated
    // parser read these same keys, so both must stay in sync.
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

    // ----- Object / field handlers -----
    handleAddObjectTab() {
        const id = String(this.nextId++);
        const newObject = {
            id,
            apiName: '',
            label: '',
            shortLabel: 'New object',
            isConfigured: false,
            isCollection: true,
            isLoading: false,
            fieldOptions: [],
            selectedFields: [],
            selectedCount: 0,
            searchTerm: '',
            showError: false
        };
        this.flagTabIfInvalid(this.activeTab);
        this.selectedObjects = [...this.selectedObjects, newObject];
        this.activeTab = id;
        this.isDirty = true;
    }

    handleSelectTab(event) {
        event.preventDefault();
        const newId = event.currentTarget.dataset.id;
        if (newId !== this.activeTab) {
            this.flagTabIfInvalid(this.activeTab);
        }
        this.activeTab = newId;
    }

    async handleObjectPicked(event) {
        const id = event.target.dataset.id;
        const apiName = event.detail.value;
        if (!apiName) {
            return;
        }
        if (this.selectedObjects.some((obj) => obj.apiName === apiName)) {
            this.showToast('Already added', 'That object is already part of this configuration.', 'warning');
            return;
        }

        const objectOption = this.objectOptions.find((option) => option.value === apiName);
        const label = objectOption ? objectOption.label : apiName;
        this.isDirty = true;
        this.updateObjectConfig(id, {
            apiName,
            label,
            shortLabel: this.shortLabel(label),
            pluralLabel: (objectOption && objectOption.pluralLabel) || apiName,
            isConfigured: true,
            isLoading: true,
            showError: false
        });

        try {
            const fields = await getFieldsForObject({ objectApiName: apiName });
            this.updateObjectConfig(id, {
                fieldOptions: this.mapFields(fields),
                isLoading: false
            });
        } catch (error) {
            this.updateObjectConfig(id, { isLoading: false });
            this.showError(`Unable to load fields for ${apiName}`, error);
        }
        this.handleGenerateTemplate();
    }

    handleRemoveObject(event) {
        const id = event.currentTarget.dataset.id;
        const remaining = this.selectedObjects.filter((item) => item.id !== id);
        this.selectedObjects = remaining;
        if (this.activeTab === id) {
            this.activeTab = remaining.length ? remaining[0].id : undefined;
        }
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
        this.updateObjectConfig(id, { selectedFields: value, selectedCount: value.length, showError: false });
        this.isDirty = true;
        this.handleGenerateTemplate();
    }

    handleFieldSearch(event) {
        const id = event.target.dataset.id;
        this.updateObjectConfig(id, { searchTerm: event.target.value });
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
            if (!objectConfig.apiName) {
                return;
            }
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
