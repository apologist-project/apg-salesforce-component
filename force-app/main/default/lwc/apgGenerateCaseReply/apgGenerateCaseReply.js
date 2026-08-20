import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';
import generateDraftForRecord from '@salesforce/apex/ApologistAgentService.generateDraftForRecord';

const DEFAULT_TITLE = 'Apologist Generate Reply';
const DEFAULT_DESCRIPTION = 'Generate a draft reply from the Apologist Agent API.';
const DEFAULT_ICON = 'standard:sparkles';
const DEFAULT_BUTTON_COLOR = '#7137ff';
const DEFAULT_ICON_BACKGROUND_COLOR = '#7137ff';

/**
 * Case record-page card. Intentionally does not import lightning/conversationToolkitApi
 * (Messaging-only) — that static import prevents the LWC from loading on Case pages.
 */
export default class ApgGenerateCaseReply extends NavigationMixin(LightningElement) {
  @api recordId;
  @api messageLimit;
  @api cardTitle;
  @api cardDescription;
  @api cardIcon;
  @api buttonColor;
  @api iconBackgroundColor;
  @api namedCredential;

  isBusy = false;
  draftText = '';
  errorMessage = '';

  get resolvedCardTitle() {
    return this.cardTitle || DEFAULT_TITLE;
  }

  get resolvedCardDescription() {
    return this.cardDescription || DEFAULT_DESCRIPTION;
  }

  get resolvedCardIcon() {
    return this.cardIcon || DEFAULT_ICON;
  }

  get resolvedButtonColor() {
    return this.buttonColor || DEFAULT_BUTTON_COLOR;
  }

  get resolvedIconBackgroundColor() {
    return this.iconBackgroundColor || DEFAULT_ICON_BACKGROUND_COLOR;
  }

  get buttonColorStyle() {
    const color = this.resolvedButtonColor;
    return [
      `--slds-c-button-brand-color-background: ${color}`,
      `--slds-c-button-brand-color-border: ${color}`,
      `--slds-c-button-brand-color-background-hover: ${color}`,
      `--slds-c-button-brand-color-border-hover: ${color}`,
      `--sds-c-button-brand-color-background: ${color}`,
      `--sds-c-button-brand-color-border: ${color}`
    ].join('; ');
  }

  get iconBackgroundStyle() {
    const color = this.resolvedIconBackgroundColor;
    return [
      `--slds-c-icon-color-background: ${color}`,
      `--sds-c-icon-color-background: ${color}`
    ].join('; ');
  }

  get buttonLabel() {
    return this.isBusy ? 'Generating…' : 'Generate Draft Reply';
  }

  resolvedMessageLimit() {
    const value = this.messageLimit;
    if (value === undefined || value === null || value === '') {
      return null;
    }
    const parsed = Number(value);
    if (Number.isNaN(parsed) || parsed <= 0) {
      return null;
    }
    return parsed;
  }

  async handleGenerate() {
    this.errorMessage = '';
    this.draftText = '';

    if (!this.recordId) {
      this.fail('No record Id on this page.');
      return;
    }
    if (this.isBusy) {
      return;
    }

    this.isBusy = true;
    let result;
    try {
      result = await generateDraftForRecord({
        recordId: this.recordId,
        messageLimit: this.resolvedMessageLimit(),
        namedCredential: this.namedCredential || null
      });
    } catch (error) {
      this.fail('Agent call failed: ' + this.reduceError(error), error);
      this.isBusy = false;
      return;
    }

    const draft = result && result.draft;
    if (!draft) {
      this.fail('The Agent API returned an empty draft.');
      this.isBusy = false;
      return;
    }

    this.draftText = draft;

    try {
      await this.openCaseEmailComposer(draft, result.emailSubject);
    } catch (error) {
      // eslint-disable-next-line no-console
      console.error('apgGenerateCaseReply composer step', error);
      this.errorMessage =
        'Draft ready below, but Send Email could not be opened: ' +
        this.reduceError(error);
    } finally {
      this.isBusy = false;
    }
  }

  async openCaseEmailComposer(draft, emailSubject) {
    const defaults = { HtmlBody: draft };
    if (emailSubject) {
      defaults.Subject = emailSubject;
    }

    const state = {
      recordId: this.recordId,
      defaultFieldValues: encodeDefaultFieldValues(defaults)
    };

    try {
      await this[NavigationMixin.Navigate]({
        type: 'standard__quickAction',
        attributes: { apiName: 'Case.SendEmail' },
        state
      });
    } catch (caseActionError) {
      await this[NavigationMixin.Navigate]({
        type: 'standard__quickAction',
        attributes: { apiName: 'Global.SendEmail' },
        state
      });
    }
  }

  fail(message, error) {
    this.errorMessage = message;
    // eslint-disable-next-line no-console
    console.error('apgGenerateCaseReply', message, error || '');
  }

  reduceError(error) {
    if (!error) {
      return 'Unknown error';
    }
    if (typeof error === 'string') {
      return error;
    }
    if (Array.isArray(error.body)) {
      return error.body.map((e) => e && e.message).filter(Boolean).join(', ') || 'Unknown error';
    }
    if (error.body && error.body.message) {
      return error.body.message;
    }
    if (error.message && error.message !== 'Unknown error') {
      return error.message;
    }
    try {
      return JSON.stringify(error);
    } catch (e) {
      return 'Unknown error';
    }
  }
}
