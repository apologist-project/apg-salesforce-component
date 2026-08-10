import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { setAgentInput } from 'lightning/conversationToolkitApi';
import generateDraftDetailed from '@salesforce/apex/ApologistAgentService.generateDraftDetailed';

const DEFAULT_TITLE = 'Apologist Agent';
const DEFAULT_DESCRIPTION = 'Generate a draft reply from the Apologist Agent API.';
const DEFAULT_ICON = 'standard:sparkles';
const DEFAULT_BUTTON_COLOR = '#7137ff';
const DEFAULT_ICON_BACKGROUND_COLOR = '#7137ff';

export default class ApgGenerateReply extends LightningElement {
  /** Messaging Session Id (set by the record page). */
  @api recordId;

  /**
   * Past messages to include when building the Agent API prompt.
   * Null / empty / unset = entire conversation.
   * Positive integer N = N most recent messages.
   */
  @api messageLimit;

  /** Card title shown in the component header. */
  @api cardTitle;

  /** Short description under the title. */
  @api cardDescription;

  /**
   * SLDS icon name for lightning-card, e.g. utility:einstein or standard:bot.
   * See https://www.lightningdesignsystem.com/icons/
   */
  @api cardIcon;

  /** Hex (or CSS) color for the Generate Draft Reply brand button. */
  @api buttonColor;

  /** Hex (or CSS) color for the card header icon background. */
  @api iconBackgroundColor;

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

  /**
   * SLDS styling hooks for lightning-button variant="brand".
   * Custom properties inherit into the base component shadow tree.
   */
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

  /** SLDS styling hooks for the card header lightning-icon background. */
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

  /**
   * Normalize App Builder / @api values: blank means entire conversation (null).
   */
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
      this.fail('No Messaging Session Id on this page.');
      return;
    }
    if (this.isBusy) {
      return;
    }

    this.isBusy = true;
    let result;
    try {
      result = await generateDraftDetailed({
        messagingSessionId: this.recordId,
        messageLimit: this.resolvedMessageLimit()
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

    if (result.canFillComposer === false) {
      this.toast(
        'Draft ready (session not Active)',
        result.composerHint ||
          'Session is not Active, so the reply box cannot be filled automatically.',
        'warning'
      );
      this.isBusy = false;
      return;
    }

    try {
      // Populate the Enhanced Conversation composer; do not send.
      const filled = await setAgentInput(this.recordId, { text: draft }, false);
      this.toast(
        'Draft ready',
        filled === false
          ? 'Draft shown below, but the conversation reply box was not updated.'
          : 'Draft placed in the conversation reply box.',
        filled === false ? 'warning' : 'success'
      );
    } catch (error) {
      this.toast(
        'Draft ready (reply box not updated)',
        'Filling the reply box failed: ' +
          this.reduceError(error) +
          ' Make sure this Messaging Session is Active, owned by you, and the Enhanced Conversation panel is open.',
        'warning'
      );
      // eslint-disable-next-line no-console
      console.error('apgGenerateReply setAgentInput', error);
    } finally {
      this.isBusy = false;
    }
  }

  fail(message, error) {
    this.errorMessage = message;
    this.toast('Could not generate reply', message, 'error');
    // eslint-disable-next-line no-console
    console.error('apgGenerateReply', message, error || '');
  }

  reduceError(error) {
    if (!error) {
      return 'Unknown error';
    }
    if (typeof error === 'string') {
      return error;
    }

    const parts = [];
    if (error.status) {
      parts.push('status=' + error.status);
    }
    if (error.statusText) {
      parts.push(error.statusText);
    }
    if (Array.isArray(error.body)) {
      parts.push(error.body.map((e) => e && e.message).filter(Boolean).join(', '));
    } else if (error.body && typeof error.body === 'object') {
      if (error.body.message) {
        parts.push(error.body.message);
      }
      if (error.body.exceptionType) {
        parts.push(error.body.exceptionType);
      }
      if (Array.isArray(error.body.pageErrors)) {
        parts.push(
          error.body.pageErrors.map((e) => e && e.message).filter(Boolean).join(', ')
        );
      }
      if (error.body.output && Array.isArray(error.body.output.errors)) {
        parts.push(
          error.body.output.errors.map((e) => e && e.message).filter(Boolean).join(', ')
        );
      }
    }
    if (error.message && error.message !== 'Unknown error') {
      parts.push(error.message);
    }

    const detail = parts.filter(Boolean).join(' | ');
    if (detail) {
      return detail;
    }

    try {
      return JSON.stringify(error);
    } catch (e) {
      return 'Unknown error';
    }
  }

  toast(title, message, variant) {
    this.dispatchEvent(
      new ShowToastEvent({
        title,
        message,
        variant,
        mode: 'sticky'
      })
    );
  }
}
