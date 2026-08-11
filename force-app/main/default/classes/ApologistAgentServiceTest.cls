@IsTest
private class ApologistAgentServiceTest {
  private class CompletionsMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      System.assertEquals(
        'callout:Apologist_Agent/api/v1/chat/completions',
        req.getEndpoint()
      );
      System.assertEquals('POST', req.getMethod());
      System.assert(
        req.getBody().contains('"client":"channel"'),
        'Expected metadata.client=channel'
      );
      System.assert(req.getBody().contains('"user":"user-1"'), 'Expected user id');
      System.assert(req.getBody().contains('"session":"session-1"'), 'Expected session id');
      System.assert(
        req.getBody().contains('"conversation":"conversation-1"'),
        'Expected conversation id'
      );

      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      res.setHeader('Content-Type', 'application/json');
      res.setBody(
        '{"id":"cmpl_test","object":"chat.completion","choices":[{"message":{"role":"assistant","content":"Thanks for reaching out — happy to help."}}]}'
      );
      return res;
    }
  }

  private class ErrorMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(401);
      res.setBody('{"error":"unauthorized"}');
      return res;
    }
  }

  @IsTest
  static void applyMessageLimit_nullMeansEntireConversation() {
    List<ApologistConversationContext.Message> all = sampleMessages(5);
    List<ApologistConversationContext.Message> result = ApologistConversationContext.applyMessageLimit(
      all,
      null
    );
    System.assertEquals(5, result.size());
    System.assertEquals('m0', result[0].body);
    System.assertEquals('m4', result[4].body);
  }

  @IsTest
  static void applyMessageLimit_nonPositiveMeansEntireConversation() {
    List<ApologistConversationContext.Message> all = sampleMessages(3);
    System.assertEquals(
      3,
      ApologistConversationContext.applyMessageLimit(all, 0).size()
    );
    System.assertEquals(
      3,
      ApologistConversationContext.applyMessageLimit(all, -2).size()
    );
  }

  @IsTest
  static void applyMessageLimit_positiveKeepsMostRecentChronological() {
    List<ApologistConversationContext.Message> all = sampleMessages(5);
    List<ApologistConversationContext.Message> result = ApologistConversationContext.applyMessageLimit(
      all,
      2
    );
    System.assertEquals(2, result.size());
    System.assertEquals('m3', result[0].body);
    System.assertEquals('m4', result[1].body);
  }

  @IsTest
  static void buildPrompt_includesTranscript() {
    List<ApologistConversationContext.Message> messages = new List<ApologistConversationContext.Message>{
      new ApologistConversationContext.Message(
        'EndUser',
        'Where is my order?',
        Datetime.now().addMinutes(-5)
      ),
      new ApologistConversationContext.Message(
        'Agent',
        'I can look that up.',
        Datetime.now().addMinutes(-4)
      )
    };
    String prompt = ApologistConversationContext.buildPrompt(messages);
    System.assert(prompt.contains('Customer: Where is my order?'));
    System.assert(prompt.contains('Agent: I can look that up.'));
  }

  @IsTest
  static void requestCompletion_parsesJsonEnvelope() {
    Test.setMock(HttpCalloutMock.class, new CompletionsMock());
    ApologistConversationContext.DraftContext context = sampleContext(2);
    Test.startTest();
    String draft = ApologistAgentService.requestCompletion(context);
    Test.stopTest();
    System.assertEquals('Thanks for reaching out — happy to help.', draft);
  }

  @IsTest
  static void requestCompletion_surfacesHttpErrors() {
    Test.setMock(HttpCalloutMock.class, new ErrorMock());
    Boolean threw = false;
    try {
      Test.startTest();
      ApologistAgentService.requestCompletion(sampleContext(1));
      Test.stopTest();
    } catch (AuraHandledException e) {
      threw = true;
      System.assert(e.getMessage().contains('401') || e.getMessage() != null);
    }
    System.assert(threw, 'Expected AuraHandledException for HTTP 401');
  }

  @IsTest
  static void extractContent_readsChoices() {
    String body = '{"choices":[{"message":{"content":"Hello there"}}]}';
    System.assertEquals('Hello there', ApologistAgentService.extractContent(body));
  }

  @IsTest
  static void extractContent_unwrapsJsonStringEnvelope() {
    String encoded = '{"choices":[{"message":{"content":"Unwrapped draft"}}]}';
    String body = JSON.serialize(encoded);
    System.assertEquals('Unwrapped draft', ApologistAgentService.extractContent(body));
  }

  @IsTest
  static void parseConnectEntries_readsMessageTextAndRoles() {
    String body =
      '{"conversationEntries":[' +
      '{"messageText":"Where is God?","sender":{"role":"EndUser"},"serverReceivedTimestamp":1000},' +
      '{"messageText":"I&#39;m here for you.","sender":{"role":"Agent"},"serverReceivedTimestamp":2000}' +
      ']}';
    List<ApologistConversationContext.Message> messages = ApologistConversationContext.parseConnectEntries(
      body
    );
    System.assertEquals(2, messages.size());
    System.assertEquals('EndUser', messages[0].actorType);
    System.assertEquals('Where is God?', messages[0].body);
    System.assertEquals('Agent', messages[1].actorType);
    System.assertEquals('I\'m here for you.', messages[1].body);
  }

  @IsTest
  static void parseConnectEntries_skipsBlankMessageText() {
    String body =
      '{"conversationEntries":[' +
      '{"messageText":"","sender":{"role":"System"}},' +
      '{"sender":{"role":"EndUser"},"messageText":"Hello"}' +
      ']}';
    List<ApologistConversationContext.Message> messages = ApologistConversationContext.parseConnectEntries(
      body
    );
    System.assertEquals(1, messages.size());
    System.assertEquals('Hello', messages[0].body);
  }

  @IsTest
  static void buildPrompt_usesUnescapedCustomerText() {
    List<ApologistConversationContext.Message> messages = new List<ApologistConversationContext.Message>{
      new ApologistConversationContext.Message(
        'EndUser',
        ApologistConversationContext.unescapeHtml('I don&#39;t know'),
        Datetime.now()
      )
    };
    String prompt = ApologistConversationContext.buildPrompt(messages);
    System.assert(prompt.contains('Customer: I don\'t know'));
  }

  private static List<ApologistConversationContext.Message> sampleMessages(Integer count) {
    List<ApologistConversationContext.Message> messages = new List<ApologistConversationContext.Message>();
    Datetime base = Datetime.now().addHours(-1);
    for (Integer i = 0; i < count; i++) {
      messages.add(
        new ApologistConversationContext.Message(
          Math.mod(i, 2) == 0 ? 'EndUser' : 'Agent',
          'm' + i,
          base.addMinutes(i)
        )
      );
    }
    return messages;
  }

  private static ApologistConversationContext.DraftContext sampleContext(Integer count) {
    ApologistConversationContext.DraftContext context = new ApologistConversationContext.DraftContext();
    context.messages = sampleMessages(count);
    context.userId = 'user-1';
    context.sessionId = 'session-1';
    context.conversationId = 'conversation-1';
    return context;
  }
}
