/**
 * Server-side bridge from Service Cloud to the Apologist Agent API.
 * API keys stay in Named Credential / External Credential — never in LWC.
 * Supports Messaging Session (Enhanced Conversation) and Case (email) contexts,
 * each with its own default Named Credential (or a per-instance override).
 */
public with sharing class ApologistAgentService {
  @TestVisible
  static final String CREDENTIAL_MESSAGING = 'Apologist_Agent_Messaging';
  @TestVisible
  static final String CREDENTIAL_CASE = 'Apologist_Agent_Case';
  /** Legacy single-agent credential (still supported via App Builder override). */
  @TestVisible
  static final String CREDENTIAL_LEGACY = 'Apologist_Agent';

  private static final String COMPLETIONS_PATH = '/api/v1/chat/completions';
  private static final Pattern CREDENTIAL_NAME_PATTERN = Pattern.compile(
    '^[A-Za-z][A-Za-z0-9_]{0,79}$'
  );
  /** Per-instance Agents must use this prefix (e.g. Apologist_Agent_Ligonier). */
  private static final Pattern CREDENTIAL_ALLOWLIST_PATTERN = Pattern.compile(
    '^Apologist_Agent(_[A-Za-z0-9_]+)?$'
  );

  public class DraftResult {
    @AuraEnabled
    public String draft;
    @AuraEnabled
    public String sessionStatus;
    @AuraEnabled
    public Boolean canFillComposer;
    @AuraEnabled
    public String composerHint;
    /** "messaging" or "case". */
    @AuraEnabled
    public String contextType;
    /** Suggested Subject when opening Case Send Email. */
    @AuraEnabled
    public String emailSubject;
    /** Named Credential API name used for the callout. */
    @AuraEnabled
    public String namedCredential;
  }

  /**
   * Generate a draft reply for the Messaging Session.
   * @param messagingSessionId MessagingSession record Id
   * @param messageLimit null / not positive = entire conversation; positive N = N most recent messages
   * @return Draft reply text (does not send; caller populates the composer)
   */
  @AuraEnabled(cacheable=false)
  public static String generateDraft(Id messagingSessionId, Integer messageLimit) {
    return generateDraftDetailed(messagingSessionId, messageLimit).draft;
  }

  /**
   * Messaging Session entry point (backward compatible).
   */
  @AuraEnabled(cacheable=false)
  public static DraftResult generateDraftDetailed(Id messagingSessionId, Integer messageLimit) {
    return generateDraftForRecord(messagingSessionId, messageLimit, null);
  }

  /**
   * Unified entry: MessagingSession or Case Id.
   * @param namedCredential optional Named Credential API name for this widget instance.
   *        When blank, uses Apologist_Agent_Messaging or Apologist_Agent_Case by context.
   */
  @AuraEnabled(cacheable=false)
  public static DraftResult generateDraftForRecord(
    Id recordId,
    Integer messageLimit,
    String namedCredential
  ) {
    if (recordId == null) {
      throw auraError('Record Id is required.');
    }

    Schema.SObjectType sot = recordId.getSObjectType();
    ApologistConversationContext.DraftContext context;

    if (sot == MessagingSession.SObjectType) {
      context = ApologistConversationContext.loadContext(recordId, messageLimit);
    } else if (sot == Case.SObjectType) {
      context = ApologistConversationContext.loadCaseContext(recordId, messageLimit);
    } else {
      throw auraError(
        'Unsupported record type for draft generation. Use a Messaging Session or Case.'
      );
    }

    String credentialName = resolveNamedCredential(context.contextType, namedCredential);

    DraftResult result = new DraftResult();
    result.draft = requestCompletion(context, credentialName);
    result.sessionStatus = context.sessionStatus;
    result.contextType = context.contextType;
    result.emailSubject = context.emailSubject;
    result.namedCredential = credentialName;

    if (context.contextType == 'case') {
      result.canFillComposer = true;
      result.composerHint = null;
    } else {
      result.canFillComposer = context.sessionStatus == 'Active';
      result.composerHint = result.canFillComposer
        ? null
        : 'Messaging Session status is "' +
          String.valueOf(context.sessionStatus) +
          '". setAgentInput only works for an Active session you have accepted in Omni-Channel with the Enhanced Conversation panel open. Copy the draft below, or accept/re-open an Active session and try again.';
    }
    return result;
  }

  /**
   * Resolves which Named Credential to use for the callout.
   * Per-instance override wins; otherwise context defaults.
   */
  @TestVisible
  static String resolveNamedCredential(String contextType, String namedCredentialOverride) {
    if (String.isNotBlank(namedCredentialOverride)) {
      return validateNamedCredentialName(namedCredentialOverride.trim());
    }
    if (contextType == 'case') {
      return CREDENTIAL_CASE;
    }
    return CREDENTIAL_MESSAGING;
  }

  @TestVisible
  static String validateNamedCredentialName(String name) {
    if (String.isBlank(name) || !CREDENTIAL_NAME_PATTERN.matcher(name).matches()) {
      throw auraError(
        'Invalid Named Credential name. Use an API name like Apologist_Agent_Messaging.'
      );
    }
    if (!CREDENTIAL_ALLOWLIST_PATTERN.matcher(name).matches()) {
      throw auraError(
        'Named Credential must be Apologist_Agent, Apologist_Agent_Messaging, Apologist_Agent_Case, or Apologist_Agent_*.'
      );
    }
    return name;
  }

  @TestVisible
  static String requestCompletion(ApologistConversationContext.DraftContext context) {
    return requestCompletion(context, CREDENTIAL_MESSAGING);
  }

  @TestVisible
  static String requestCompletion(
    ApologistConversationContext.DraftContext context,
    String namedCredentialName
  ) {
    if (context == null) {
      context = new ApologistConversationContext.DraftContext();
    }
    String credential = validateNamedCredentialName(
      String.isNotBlank(namedCredentialName) ? namedCredentialName : CREDENTIAL_MESSAGING
    );
    String prompt = ApologistConversationContext.buildPrompt(context);

    Map<String, Object> metadata = new Map<String, Object>{
      'device' => 'salesforce',
      // metadata.client maxLength is 11 per Agent API schema
      'client' => 'channel'
    };
    if (String.isNotBlank(context.sessionId)) {
      metadata.put('session', context.sessionId);
    }
    if (String.isNotBlank(context.conversationId)) {
      metadata.put('conversation', context.conversationId);
    }

    Map<String, Object> body = new Map<String, Object>{
      'messages' => new List<Object>{
        new Map<String, Object>{ 'role' => 'user', 'content' => prompt }
      },
      'stream' => false,
      'response_format' => new Map<String, Object>{ 'type' => 'json' },
      'metadata' => metadata
    };
    if (String.isNotBlank(context.userId)) {
      body.put('user', context.userId);
    }

    HttpRequest req = new HttpRequest();
    req.setEndpoint('callout:' + credential + COMPLETIONS_PATH);
    req.setMethod('POST');
    req.setHeader('Content-Type', 'application/json');
    req.setTimeout(120000);
    req.setBody(JSON.serialize(body));

    HttpResponse res = new Http().send(req);
    if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
      throw auraError(safeHttpErrorMessage('Agent API', res.getStatusCode(), res.getBody()));
    }

    return extractContent(res.getBody());
  }

  /**
   * Status-focused Aura message. Avoids leaking HTML / large response bodies to the UI.
   * When the body is compact JSON with error/message, include a short sanitized snippet.
   */
  public static String safeHttpErrorMessage(String source, Integer statusCode, String body) {
    String message = source + ' error ' + String.valueOf(statusCode);
    String detail = safeJsonErrorDetail(body);
    if (String.isNotBlank(detail)) {
      message += ': ' + detail;
    }
    return message;
  }

  @TestVisible
  static String safeJsonErrorDetail(String body) {
    if (String.isBlank(body)) {
      return null;
    }
    String trimmed = body.trim();
    if (trimmed.length() > 400 || trimmed.startsWith('<') || !trimmed.startsWith('{')) {
      return null;
    }
    try {
      Object parsed = JSON.deserializeUntyped(trimmed);
      if (!(parsed instanceof Map<String, Object>)) {
        return null;
      }
      Map<String, Object> root = (Map<String, Object>) parsed;
      Object raw = root.get('error');
      if (raw == null) {
        raw = root.get('message');
      }
      if (raw instanceof Map<String, Object>) {
        Map<String, Object> errMap = (Map<String, Object>) raw;
        Object nested = errMap.get('message');
        if (nested == null) {
          nested = errMap.get('code');
        }
        raw = nested;
      }
      if (raw == null) {
        return null;
      }
      String detail = String.valueOf(raw).trim();
      if (String.isBlank(detail) || detail.contains('<') || detail.length() > 120) {
        return null;
      }
      return detail;
    } catch (Exception ignore) {
      return null;
    }
  }

  @TestVisible
  static String extractContent(String responseBody) {
    if (String.isBlank(responseBody)) {
      throw auraError('Agent API returned an empty body.');
    }

    Object parsed = JSON.deserializeUntyped(responseBody);
    // Some agents wrap the completion envelope as a JSON string.
    if (parsed instanceof String) {
      String encoded = ((String) parsed).trim();
      if (String.isBlank(encoded)) {
        throw auraError('Agent API returned an empty JSON string body.');
      }
      if (encoded.startsWith('{') || encoded.startsWith('[')) {
        parsed = JSON.deserializeUntyped(encoded);
      } else {
        return encoded;
      }
    }

    if (!(parsed instanceof Map<String, Object>)) {
      return String.valueOf(parsed).trim();
    }

    Map<String, Object> root = (Map<String, Object>) parsed;
    Object choicesObj = root.get('choices');
    if (!(choicesObj instanceof List<Object>) || ((List<Object>) choicesObj).isEmpty()) {
      throw auraError('Agent API response missing choices.');
    }

    Object firstChoice = ((List<Object>) choicesObj)[0];
    if (!(firstChoice instanceof Map<String, Object>)) {
      throw auraError('Agent API response choice was malformed.');
    }

    Object messageObj = ((Map<String, Object>) firstChoice).get('message');
    if (!(messageObj instanceof Map<String, Object>)) {
      throw auraError('Agent API response missing message.');
    }

    Object content = ((Map<String, Object>) messageObj).get('content');
    if (content == null || String.isBlank(String.valueOf(content))) {
      throw auraError('Agent API returned empty content.');
    }

    String text = String.valueOf(content).trim();
    // If assistant content is itself a JSON object/string envelope, prefer nested message content.
    if (text.startsWith('{') || text.startsWith('"')) {
      try {
        Object nested = JSON.deserializeUntyped(text);
        if (nested instanceof String) {
          return ((String) nested).trim();
        }
        if (nested instanceof Map<String, Object>) {
          Map<String, Object> nestedMap = (Map<String, Object>) nested;
          Object nestedChoices = nestedMap.get('choices');
          if (nestedChoices instanceof List<Object> && !((List<Object>) nestedChoices).isEmpty()) {
            return extractContent(JSON.serialize(nestedMap));
          }
          Object nestedContent = nestedMap.get('content');
          if (nestedContent != null && String.isNotBlank(String.valueOf(nestedContent))) {
            return String.valueOf(nestedContent).trim();
          }
        }
      } catch (Exception ignore) {
        // Keep original assistant text.
      }
    }
    return text;
  }

  @TestVisible
  static AuraHandledException auraError(String message) {
    // Constructor message is not always surfaced to LWC; setMessage is.
    AuraHandledException e = new AuraHandledException(message);
    e.setMessage(message);
    return e;
  }
}
