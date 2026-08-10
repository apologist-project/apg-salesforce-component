/**
 * Builds Agent API prompt context from Messaging Session conversation entries.
 * messageLimit null / non-positive => entire conversation; positive N => N most recent.
 */
public with sharing class ApologistConversationContext {
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

  /** Transcript + Agent API identifiers for a Messaging Session draft request. */
  public class DraftContext {
    public List<Message> messages = new List<Message>();
    /** End-user / MessagingEndUser Id when available; otherwise running Salesforce user. */
    public String userId;
    /** MessagingSession Id. */
    public String sessionId;
    /** Conversation Id or ConversationIdentifier when available. */
    public String conversationId;
    /** MessagingSession.Status (Active, Waiting, Ended, ...). */
    public String sessionStatus;
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
    List<String> lines = new List<String>{
      'You are drafting a reply for a human service agent in Salesforce Service Cloud.',
      'Write a helpful, professional customer-facing reply based on the conversation below.',
      'Return only the reply text — no preamble, labels, or markdown fences.',
      '',
      'Conversation:'
    };

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
   * Loads Messaging Session identifiers and ConversationEntry transcript.
   * TODO: Adjust EntryType / field filters for your Messaging channel configuration.
   */
  public static DraftContext loadContext(Id messagingSessionId, Integer messageLimit) {
    if (messagingSessionId == null) {
      throw new AuraHandledException('Messaging Session Id is required.');
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
      return context;
    }

    Id conversationId = session.ConversationId;

    // ConversationEntry.Message is not filterable in SOQL — filter blanks in Apex.
    // Newest-first so a positive messageLimit can stop after N non-blank messages.
    List<ConversationEntry> entries = [
      SELECT ActorType, Message, EntryTime
      FROM ConversationEntry
      WHERE ConversationId = :conversationId
      ORDER BY EntryTime DESC
    ];

    List<Message> newestFirst = new List<Message>();
    for (ConversationEntry entry : entries) {
      if (String.isBlank(entry.Message)) {
        continue;
      }
      newestFirst.add(
        new Message(entry.ActorType, entry.Message, entry.EntryTime)
      );
      if (messageLimit != null && messageLimit > 0 && newestFirst.size() >= messageLimit) {
        break;
      }
    }

    for (Integer i = newestFirst.size() - 1; i >= 0; i--) {
      context.messages.add(newestFirst[i]);
    }
    return context;
  }

  /**
   * @deprecated Use loadContext; kept for clarity in older call sites/tests.
   */
  public static List<Message> loadMessages(Id messagingSessionId, Integer messageLimit) {
    return loadContext(messagingSessionId, messageLimit).messages;
  }
}
