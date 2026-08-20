import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import generateDraftForRecord from '@salesforce/apex/ApologistAgentService.generateDraftForRecord';

/**
 * Headless Case Quick Action: generate a draft via the Case Agent Named Credential,
 * then open Send Email with the body pre-filled. Does not send.
 */
export default class ApgGenerateReplyAction extends NavigationMixin(LightningElement) {
  @api recordId;

  /**
   * Invoked when the Case Quick Action is clicked.
   */
  @api
  async invoke() {
    if (!this.recordId) {
      this.toast('Could not generate reply', 'No Case Id on this page.', 'error');
      return;
    }

    let result;
    try {
      result = await generateDraftForRecord({
        recordId: this.recordId,
        messageLimit: null,
        namedCredential: null
      });
    } catch (error) {
      this.toast('Could not generate reply', this.reduceError(error), 'error');
      // eslint-disable-next-line no-console
      console.error('apgGenerateReplyAction', error);
      return;
    }

    const draft = result && result.draft;
    if (!draft) {
      this.toast('Could not generate reply', 'The Agent API returned an empty draft.', 'error');
      return;
    }

    try {
      await this.openCaseEmailComposer(draft, result.emailSubject);
      this.toast(
        'Draft ready',
        'Review the email, then send manually.',
        'success'
      );
    } catch (error) {
      this.toast(
        'Draft generated, but email did not open',
        this.reduceError(error) +
          ' Copy the draft from debug logs or use the page widget.',
        'warning'
      );
      // eslint-disable-next-line no-console
      console.error('apgGenerateReplyAction composer', error);
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

  toast(title, message, variant) {
    this.dispatchEvent(
      new ShowToastEvent({
        title,
        message,
        variant,
        mode: variant === 'error' ? 'sticky' : 'dismissible'
      })
    );
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
