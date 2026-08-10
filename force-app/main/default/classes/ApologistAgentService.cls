/**
 * Server-side bridge from Service Cloud to the Apologist Agent API.
 * API keys stay in Named Credential / External Credential — never in LWC.
 */
public with sharing class ApologistAgentService {
  private static final String NAMED_CREDENTIAL = 'callout:Apologist_Agent';
  private static final String COMPLETIONS_PATH = '/api/v1/chat/completions';

  /**
   * Generate a draft reply for the Messaging Session.
   * @param messagingSessionId MessagingSession record Id
   * @param messageLimit null / not positive = entire conversation; positive N = N most recent messages
   * @return Draft reply text (does not send; caller populates the composer)
   */
  public class DraftResult {
    @AuraEnabled
    public String draft;
    @AuraEnabled
    public String sessionStatus;
    @AuraEnabled
    public Boolean canFillComposer;
    @AuraEnabled
    public String composerHint;
  }

  @AuraEnabled(cacheable=false)
  public static String generateDraft(Id messagingSessionId, Integer messageLimit) {
    return generateDraftDetailed(messagingSessionId, messageLimit).draft;
  }

  /**
   * Same as generateDraft, plus Messaging Session status hints for the LWC composer step.
   */
  @AuraEnabled(cacheable=false)
  public static DraftResult generateDraftDetailed(Id messagingSessionId, Integer messageLimit) {
    ApologistConversationContext.DraftContext context = ApologistConversationContext.loadContext(
      messagingSessionId,
      messageLimit
    );
    DraftResult result = new DraftResult();
    result.draft = requestCompletion(context);
    result.sessionStatus = context.sessionStatus;
    result.canFillComposer = context.sessionStatus == 'Active';
    result.composerHint = result.canFillComposer
      ? null
      : 'Messaging Session status is "' +
        String.valueOf(context.sessionStatus) +
        '". setAgentInput only works for an Active session you have accepted in Omni-Channel with the Enhanced Conversation panel open. Copy the draft below, or accept/re-open an Active session and try again.';
    return result;
  }

  @TestVisible
  static String requestCompletion(ApologistConversationContext.DraftContext context) {
    if (context == null) {
      context = new ApologistConversationContext.DraftContext();
    }
    String prompt = ApologistConversationContext.buildPrompt(context.messages);

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
    req.setEndpoint(NAMED_CREDENTIAL + COMPLETIONS_PATH);
    req.setMethod('POST');
    req.setHeader('Content-Type', 'application/json');
    req.setTimeout(120000);
    req.setBody(JSON.serialize(body));

    HttpResponse res = new Http().send(req);
    if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
      throw auraError(
        'Agent API error ' + res.getStatusCode() + ': ' + truncate(res.getBody(), 500)
      );
    }

    return extractContent(res.getBody());
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

  private static String truncate(String value, Integer maxLen) {
    if (value == null) {
      return '';
    }
    return value.length() <= maxLen ? value : value.substring(0, maxLen);
  }
}
