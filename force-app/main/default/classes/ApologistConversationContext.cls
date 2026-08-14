/**
 * Builds Agent API prompt context from Messaging Session conversation entries.
 * Enhanced Messaging stores message bodies off-core — SOQL ConversationEntry.Message
 * is blank — so transcripts are loaded via Connect REST conversation entries.
 * messageLimit null / non-positive => entire conversation; positive N => N most recent.
 */
public with sharing class ApologistConversationContext {
  private static final String CONNECT_API_VERSION = 'v62.0';
  private static final Integer CONNECT_RECORD_LIMIT = 1000;

  public class Message {
    @AuraEnabled
    public String actorType;
    @AuraEnabled
    public String body;
    @AuraEnabled
    public Datetime sentAt;

    public Message() {
    }

    public Message(String actorType, String body, Datetime sentAt) {
      this.actorType = actorType;
      this.body = body;
      this.sentAt = sentAt;
    }
  }

  /** Transcript + Agent API identifiers for a Messaging Session or Case draft request. */
  public class DraftContext {
    public List<Message> messages = new List<Message>();
    /** End-user / MessagingEndUser / Contact Id when available; otherwise running Salesforce user. */
    public String userId;
    /** MessagingSession Id or Case Id. */
    public String sessionId;
    /** Conversation Id/identifier, or Case Id for email cases. */
    public String conversationId;
    /** MessagingSession.Status (Active, Waiting, Ended, ...) or "Case". */
    public String sessionStatus;
    /** "messaging" or "case". */
    public String contextType;
    /** Optional Case subject / description lines prepended to the prompt. */
    public List<String> headerLines;
    /** Suggested email Subject for Case Send Email (e.g. Re: …). */
    public String emailSubject;
  }

  /**
   * Returns messages in chronological order for the prompt.
   * When messageLimit is null or not positive, returns the full list.
   * When messageLimit is positive, returns the N most recent messages (still chronological).
   */
  public static List<Message> applyMessageLimit(
    List<Message> chronologicalMessages,
    Integer messageLimit
  ) {
    List<Message> source = chronologicalMessages == null
      ? new List<Message>()
      : chronologicalMessages;

    if (messageLimit == null || messageLimit <= 0 || source.size() <= messageLimit) {
      return new List<Message>(source);
    }

    List<Message> limited = new List<Message>();
    Integer startIndex = source.size() - messageLimit;
    for (Integer i = startIndex; i < source.size(); i++) {
      limited.add(source[i]);
    }
    return limited;
  }

  public static String buildPrompt(List<Message> chronologicalMessages) {
    return buildPrompt(chronologicalMessages, null);
  }

  public static String buildPrompt(
    List<Message> chronologicalMessages,
    List<String> headerLines
  ) {
    List<String> lines = new List<String>{
      'You are drafting a reply for a human service agent in Salesforce Service Cloud.',
      'Write a helpful, professional customer-facing reply based on the conversation below.',
      'Return only the reply text — no preamble, labels, or markdown fences.',
      ''
    };

    if (headerLines != null) {
      for (String headerLine : headerLines) {
        if (String.isNotBlank(headerLine)) {
          lines.add(headerLine);
        }
      }
      if (!headerLines.isEmpty()) {
        lines.add('');
      }
    }

    lines.add('Conversation:');

    if (chronologicalMessages == null || chronologicalMessages.isEmpty()) {
      lines.add('(No prior messages.)');
    } else {
      for (Message m : chronologicalMessages) {
        String who = labelForActor(m.actorType);
        String body = String.isBlank(m.body) ? '' : m.body.trim();
        lines.add(who + ': ' + body);
      }
    }

    lines.add('');
    lines.add('Draft the agent reply now.');
    return String.join(lines, '\n');
  }

  /** Builds the Agent prompt from a loaded DraftContext (includes Case headers when present). */
  public static String buildPrompt(DraftContext context) {
    if (context == null) {
      return buildPrompt(new List<Message>(), null);
    }
    return buildPrompt(context.messages, context.headerLines);
  }

  @TestVisible
  static String labelForActor(String actorType) {
    if (String.isBlank(actorType)) {
      return 'Unknown';
    }
    String normalized = actorType.toLowerCase();
    if (normalized.contains('enduser') || normalized == 'customer') {
      return 'Customer';
    }
    if (
      normalized.contains('agent') ||
      normalized.contains('system') ||
      normalized == 'bot'
    ) {
      return 'Agent';
    }
    return actorType;
  }

  /**
   * Loads Messaging Session identifiers and conversation transcript.
   * Prefers Connect REST (Enhanced Messaging); falls back to SOQL for legacy channels.
   */
  public static DraftContext loadContext(Id messagingSessionId, Integer messageLimit) {
    if (messagingSessionId == null) {
      throw auraError('Messaging Session Id is required.');
    }

    MessagingSession session = [
      SELECT
        Id,
        Status,
        ConversationId,
        MessagingEndUserId,
        Conversation.ConversationIdentifier
      FROM MessagingSession
      WHERE Id = :messagingSessionId
      LIMIT 1
    ];

    DraftContext context = new DraftContext();
    context.contextType = 'messaging';
    context.sessionId = String.valueOf(session.Id);
    context.sessionStatus = session.Status;
    context.userId = session.MessagingEndUserId != null
      ? String.valueOf(session.MessagingEndUserId)
      : UserInfo.getUserId();
    if (session.ConversationId != null) {
      // Prefer stable conversation identifier when present; fall back to Salesforce Id.
      context.conversationId = String.isNotBlank(session.Conversation.ConversationIdentifier)
        ? session.Conversation.ConversationIdentifier
        : String.valueOf(session.ConversationId);
    }

    if (session.ConversationId == null) {
      throw auraError(
        'This Messaging Session has no Conversation Id, so no transcript is available.'
      );
    }

    List<Message> chronological = new List<Message>();

    // Enhanced Messaging: message bodies are off-core; Connect returns messageText.
    if (String.isNotBlank(session.Conversation.ConversationIdentifier)) {
      chronological = loadMessagesFromConnect(
        session.Conversation.ConversationIdentifier
      );
    }

    // Legacy / standard channels may still populate ConversationEntry.Message.
    if (chronological.isEmpty()) {
      chronological = loadMessagesFromSoql(session.ConversationId);
    }

    context.messages = applyMessageLimit(chronological, messageLimit);

    if (context.messages.isEmpty()) {
      throw auraError(
        'No conversation messages were found for this session. Enhanced Messaging transcripts require Connect API access; confirm the session has customer/agent messages and try again.'
      );
    }

    return context;
  }

  /**
   * Loads Case email-thread context from related EmailMessage rows.
   * messageLimit null / non-positive => entire thread; positive N => N most recent.
   */
  public static DraftContext loadCaseContext(Id caseId, Integer messageLimit) {
    if (caseId == null) {
      throw auraError('Case Id is required.');
    }

    Case c = [
      SELECT Id, Subject, Description, ContactId, Contact.Email, SuppliedEmail
      FROM Case
      WHERE Id = :caseId
      LIMIT 1
    ];

    DraftContext context = new DraftContext();
    context.contextType = 'case';
    context.sessionId = String.valueOf(c.Id);
    context.conversationId = String.valueOf(c.Id);
    context.sessionStatus = 'Case';
    context.userId = c.ContactId != null
      ? String.valueOf(c.ContactId)
      : UserInfo.getUserId();
    context.emailSubject = replySubject(c.Subject);

    List<String> headers = new List<String>();
    if (String.isNotBlank(c.Subject)) {
      headers.add('Case subject: ' + c.Subject.trim());
    }
    if (String.isNotBlank(c.Description)) {
      headers.add('Case description: ' + c.Description.trim());
    }
    context.headerLines = headers;

    List<Message> chronological = loadMessagesFromEmail(c.Id);
    context.messages = applyMessageLimit(chronological, messageLimit);

    if (context.messages.isEmpty() && headers.isEmpty()) {
      throw auraError(
        'No email messages or Case description were found for this Case, so no draft context is available.'
      );
    }

    return context;
  }

  /**
   * EmailMessage rows for a Case, chronological (oldest first).
   * Incoming → Customer; otherwise Agent. Prefers TextBody; falls back to stripped HtmlBody.
   */
  @TestVisible
  static List<Message> loadMessagesFromEmail(Id caseId) {
    List<Message> chronological = new List<Message>();
    if (caseId == null) {
      return chronological;
    }

    List<EmailMessage> emails = [
      SELECT Incoming, TextBody, HtmlBody, MessageDate, Subject
      FROM EmailMessage
      WHERE ParentId = :caseId
      ORDER BY MessageDate ASC NULLS LAST, CreatedDate ASC
    ];

    for (EmailMessage email : emails) {
      String body = emailBodyText(email);
      if (String.isBlank(body)) {
        continue;
      }
      String actorType = email.Incoming == true ? 'Customer' : 'Agent';
      chronological.add(new Message(actorType, body.trim(), email.MessageDate));
    }
    return chronological;
  }

  @TestVisible
  static String emailBodyText(EmailMessage email) {
    if (email == null) {
      return null;
    }
    if (String.isNotBlank(email.TextBody)) {
      return email.TextBody;
    }
    if (String.isNotBlank(email.HtmlBody)) {
      return stripHtml(email.HtmlBody);
    }
    return null;
  }

  @TestVisible
  static String stripHtml(String html) {
    if (String.isBlank(html)) {
      return html;
    }
    String text = html.replaceAll('(?i)<br\\s*/?>', '\n');
    text = text.replaceAll('(?i)</p>', '\n');
    text = text.replaceAll('(?i)<[^>]+>', ' ');
    text = unescapeHtml(text);
    text = text.replaceAll('[ \\t\\x0B\\f\\r]+', ' ');
    text = text.replaceAll('\\n{3,}', '\n\n');
    return text.trim();
  }

  @TestVisible
  static String replySubject(String subject) {
    if (String.isBlank(subject)) {
      return 'Re: Your case';
    }
    String trimmed = subject.trim();
    if (trimmed.toLowerCase().startsWith('re:')) {
      return trimmed;
    }
    return 'Re: ' + trimmed;
  }

  /**
   * GET /services/data/vXX.X/connect/conversation/{conversationIdentifier}/entries
   */
  @TestVisible
  static List<Message> loadMessagesFromConnect(String conversationIdentifier) {
    if (String.isBlank(conversationIdentifier)) {
      return new List<Message>();
    }

    String endpoint =
      Url.getOrgDomainUrl().toExternalForm() +
      '/services/data/' +
      CONNECT_API_VERSION +
      '/connect/conversation/' +
      conversationIdentifier +
      '/entries?queryDirection=FromStart&recordLimit=' +
      String.valueOf(CONNECT_RECORD_LIMIT);

    HttpRequest req = new HttpRequest();
    req.setEndpoint(endpoint);
    req.setMethod('GET');
    // Lightning UserInfo.getSessionId() is not API-enabled (INVALID_SESSION_ID).
    // Use a Visualforce {!$Api.Session_ID} bridge for a REST-capable token.
    req.setHeader('Authorization', 'Bearer ' + apiSessionId());
    req.setHeader('Content-Type', 'application/json');
    req.setTimeout(120000);

    HttpResponse res;
    try {
      res = new Http().send(req);
    } catch (Exception e) {
      throw auraError(
        'Could not load conversation transcript via Connect API: ' + e.getMessage()
      );
    }

    if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
      throw auraError(
        'Connect conversation entries error ' +
          res.getStatusCode() +
          ': ' +
          truncate(res.getBody(), 400)
      );
    }

    return parseConnectEntries(res.getBody());
  }

  /**
   * Parses Connect /conversation/.../entries JSON into chronological Message rows.
   */
  @TestVisible
  static List<Message> parseConnectEntries(String responseBody) {
    List<Message> messages = new List<Message>();
    if (String.isBlank(responseBody)) {
      return messages;
    }

    Object parsed = JSON.deserializeUntyped(responseBody);
    if (!(parsed instanceof Map<String, Object>)) {
      return messages;
    }

    Object entriesObj = ((Map<String, Object>) parsed).get('conversationEntries');
    if (!(entriesObj instanceof List<Object>)) {
      return messages;
    }

    for (Object entryObj : (List<Object>) entriesObj) {
      if (!(entryObj instanceof Map<String, Object>)) {
        continue;
      }
      Map<String, Object> entry = (Map<String, Object>) entryObj;
      String body = extractConnectMessageText(entry);
      if (String.isBlank(body)) {
        continue;
      }

      String actorType = 'Unknown';
      Object senderObj = entry.get('sender');
      if (senderObj instanceof Map<String, Object>) {
        Object role = ((Map<String, Object>) senderObj).get('role');
        if (role != null && String.isNotBlank(String.valueOf(role))) {
          actorType = String.valueOf(role);
        }
      }

      Datetime sentAt = timestampToDatetime(
        entry.get('serverReceivedTimestamp') != null
          ? entry.get('serverReceivedTimestamp')
          : entry.get('clientTimestamp')
      );

      messages.add(new Message(actorType, unescapeHtml(body.trim()), sentAt));
    }

    return messages;
  }

  @TestVisible
  static String extractConnectMessageText(Map<String, Object> entry) {
    if (entry == null) {
      return null;
    }
    Object messageText = entry.get('messageText');
    if (messageText != null && String.isNotBlank(String.valueOf(messageText))) {
      return String.valueOf(messageText);
    }
    // Conversation Data-style nested payload (if Connect shape gains it).
    Object entryPayload = entry.get('entryPayload');
    if (entryPayload instanceof Map<String, Object>) {
      Object abstractMessage = ((Map<String, Object>) entryPayload).get('abstractMessage');
      if (abstractMessage instanceof Map<String, Object>) {
        Object staticContent = ((Map<String, Object>) abstractMessage).get('staticContent');
        if (staticContent instanceof Map<String, Object>) {
          Object text = ((Map<String, Object>) staticContent).get('text');
          if (text != null && String.isNotBlank(String.valueOf(text))) {
            return String.valueOf(text);
          }
        }
      }
    }
    return null;
  }

  static List<Message> loadMessagesFromSoql(Id conversationId) {
    List<Message> newestFirst = new List<Message>();
    // ConversationEntry.Message is not filterable in SOQL — filter blanks in Apex.
    List<ConversationEntry> entries = [
      SELECT ActorType, Message, EntryTime
      FROM ConversationEntry
      WHERE ConversationId = :conversationId
      ORDER BY EntryTime DESC
    ];

    for (ConversationEntry entry : entries) {
      if (String.isBlank(entry.Message)) {
        continue;
      }
      newestFirst.add(new Message(entry.ActorType, entry.Message, entry.EntryTime));
    }

    List<Message> chronological = new List<Message>();
    for (Integer i = newestFirst.size() - 1; i >= 0; i--) {
      chronological.add(newestFirst[i]);
    }
    return chronological;
  }

  @TestVisible
  static Datetime timestampToDatetime(Object raw) {
    if (raw == null) {
      return null;
    }
    Long millis;
    if (raw instanceof Long) {
      millis = (Long) raw;
    } else if (raw instanceof Integer) {
      millis = Long.valueOf(String.valueOf(raw));
    } else if (raw instanceof Decimal) {
      millis = ((Decimal) raw).longValue();
    } else {
      try {
        millis = Long.valueOf(String.valueOf(raw));
      } catch (Exception e) {
        return null;
      }
    }
    return Datetime.newInstance(millis);
  }

  @TestVisible
  static String unescapeHtml(String value) {
    if (String.isBlank(value)) {
      return value;
    }
    return value
      .replace('&amp;', '&')
      .replace('&#39;', '\'')
      .replace('&apos;', '\'')
      .replace('&quot;', '"')
      .replace('&lt;', '<')
      .replace('&gt;', '>');
  }

  /**
   * API-capable session id for same-org REST callouts from Lightning.
   * Lightning UserInfo sessions return INVALID_SESSION_ID for Connect REST.
   */
  @TestVisible
  static String apiSessionId() {
    if (Test.isRunningTest()) {
      return UserInfo.getSessionId();
    }
    String content = Page.ApologistApiSession.getContent().toString();
    Integer startIdx = content.indexOf('SESSION_ID_START');
    Integer endIdx = content.indexOf('SESSION_ID_END');
    if (startIdx < 0 || endIdx < 0 || endIdx <= startIdx) {
      throw auraError(
        'Could not obtain an API session for conversation transcript access.'
      );
    }
    startIdx += 'SESSION_ID_START'.length();
    String sessionId = content.substring(startIdx, endIdx).trim();
    if (String.isBlank(sessionId)) {
      throw auraError(
        'Could not obtain an API session for conversation transcript access.'
      );
    }
    return sessionId;
  }

  /**
   * @deprecated Use loadContext; kept for clarity in older call sites/tests.
   */
  public static List<Message> loadMessages(Id messagingSessionId, Integer messageLimit) {
    return loadContext(messagingSessionId, messageLimit).messages;
  }

  private static AuraHandledException auraError(String message) {
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
