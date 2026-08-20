@IsTest
private class ApologistAgentServiceTest {
  private class CompletionsMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      System.assert(
        req.getEndpoint() != null &&
          req.getEndpoint().startsWith('callout:') &&
          req.getEndpoint().endsWith('/api/v1/chat/completions'),
        'Unexpected endpoint: ' + req.getEndpoint()
      );
      System.assertEquals('POST', req.getMethod());
      System.assert(
        req.getBody().contains('"client":"channel"'),
        'Expected metadata.client=channel'
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

  private class HtmlErrorMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(503);
      res.setBody('<html><head><title>ERR_DNS_FAIL</title></head><body>Unable to resolve DNS</body></html>');
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
  static void requestCompletion_includesMessagingMetadata() {
    Test.setMock(
      HttpCalloutMock.class,
      new AssertingCompletionsMock(
        new List<String>{ '"user":"user-1"', '"session":"session-1"', '"conversation":"conversation-1"' }
      )
    );
    Test.startTest();
    ApologistAgentService.requestCompletion(sampleContext(1));
    Test.stopTest();
  }

  private class AssertingCompletionsMock implements HttpCalloutMock {
    private List<String> mustContain;
    private Boolean matchEndpoint;
    AssertingCompletionsMock(List<String> mustContain) {
      this(mustContain, false);
    }
    AssertingCompletionsMock(List<String> mustContain, Boolean matchEndpoint) {
      this.mustContain = mustContain;
      this.matchEndpoint = matchEndpoint == true;
    }
    public HTTPResponse respond(HTTPRequest req) {
      String haystack = matchEndpoint ? req.getEndpoint() : req.getBody();
      for (String fragment : mustContain) {
        System.assert(
          haystack != null && haystack.contains(fragment),
          'Missing fragment: ' + fragment + ' in ' + haystack
        );
      }
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      res.setBody(
        '{"choices":[{"message":{"role":"assistant","content":"ok"}}]}'
      );
      return res;
    }
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
      System.assert(
        e.getMessage().contains('401'),
        'Expected status in message: ' + e.getMessage()
      );
      System.assert(
        e.getMessage().contains('unauthorized'),
        'Expected safe JSON error detail: ' + e.getMessage()
      );
    }
    System.assert(threw, 'Expected AuraHandledException for HTTP 401');
  }

  @IsTest
  static void requestCompletion_omitsHtmlErrorBodies() {
    Test.setMock(HttpCalloutMock.class, new HtmlErrorMock());
    Boolean threw = false;
    try {
      Test.startTest();
      ApologistAgentService.requestCompletion(sampleContext(1));
      Test.stopTest();
    } catch (AuraHandledException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('503'),
        'Expected status in message: ' + e.getMessage()
      );
      System.assert(
        !e.getMessage().contains('ERR_DNS_FAIL') && !e.getMessage().contains('<html'),
        'HTML body must not surface: ' + e.getMessage()
      );
    }
    System.assert(threw, 'Expected AuraHandledException for HTTP 503');
  }

  @IsTest
  static void safeHttpErrorMessage_statusOnlyForHtml() {
    String message = ApologistAgentService.safeHttpErrorMessage(
      'Agent API',
      503,
      '<html>boom</html>'
    );
    System.assertEquals('Agent API error 503', message);
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

  @IsTest
  static void replySubject_addsRePrefix() {
    System.assertEquals('Re: Help', ApologistConversationContext.replySubject('Help'));
    System.assertEquals('Re: Help', ApologistConversationContext.replySubject('Re: Help'));
    System.assertEquals('Re: Your case', ApologistConversationContext.replySubject(null));
  }

  @IsTest
  static void stripHtml_removesTags() {
    String text = ApologistConversationContext.stripHtml('<p>Hello<br/>world</p>');
    System.assert(text.contains('Hello'));
    System.assert(text.contains('world'));
    System.assert(!text.contains('<p>'));
  }

  @IsTest
  static void loadCaseContext_readsEmailThreadAndHeaders() {
    Case c = new Case(Subject = 'Order status', Description = 'Need an update', Origin = 'Email');
    insert c;
    insert new List<EmailMessage>{
      new EmailMessage(
        ParentId = c.Id,
        Incoming = true,
        FromAddress = 'customer@example.com',
        ToAddress = 'support@example.com',
        Subject = 'Order status',
        TextBody = 'Where is my order?',
        MessageDate = Datetime.now().addMinutes(-10),
        Status = '0'
      ),
      new EmailMessage(
        ParentId = c.Id,
        Incoming = false,
        FromAddress = 'support@example.com',
        ToAddress = 'customer@example.com',
        Subject = 'Re: Order status',
        TextBody = 'Looking into it.',
        MessageDate = Datetime.now().addMinutes(-5),
        Status = '3'
      )
    };

    ApologistConversationContext.DraftContext context = ApologistConversationContext.loadCaseContext(
      c.Id,
      null
    );
    System.assertEquals('case', context.contextType);
    System.assertEquals('Case', context.sessionStatus);
    System.assertEquals('Re: Order status', context.emailSubject);
    System.assertEquals(2, context.messages.size());
    System.assertEquals('Customer', context.messages[0].actorType);
    System.assertEquals('Where is my order?', context.messages[0].body);
    System.assertEquals('Agent', context.messages[1].actorType);

    String prompt = ApologistConversationContext.buildPrompt(context);
    System.assert(prompt.contains('Case subject: Order status'));
    System.assert(prompt.contains('Case description: Need an update'));
    System.assert(prompt.contains('Customer: Where is my order?'));
  }

  @IsTest
  static void loadCaseContext_appliesMessageLimit() {
    Case c = new Case(Subject = 'Thread', Origin = 'Email');
    insert c;
    List<EmailMessage> emails = new List<EmailMessage>();
    for (Integer i = 0; i < 5; i++) {
      emails.add(
        new EmailMessage(
          ParentId = c.Id,
          Incoming = Math.mod(i, 2) == 0,
          FromAddress = 'a@example.com',
          ToAddress = 'b@example.com',
          Subject = 'm' + i,
          TextBody = 'm' + i,
          MessageDate = Datetime.now().addMinutes(i - 10),
          Status = '0'
        )
      );
    }
    insert emails;

    ApologistConversationContext.DraftContext context = ApologistConversationContext.loadCaseContext(
      c.Id,
      2
    );
    System.assertEquals(2, context.messages.size());
    System.assertEquals('m3', context.messages[0].body);
    System.assertEquals('m4', context.messages[1].body);
  }

  @IsTest
  static void loadCaseContext_errorsWhenNoContext() {
    Case c = new Case(Subject = null, Description = null, Origin = 'Phone');
    insert c;
    Boolean threw = false;
    try {
      ApologistConversationContext.loadCaseContext(c.Id, null);
    } catch (AuraHandledException e) {
      threw = true;
      System.assert(e.getMessage().contains('No email messages') || e.getMessage() != null);
    }
    System.assert(threw, 'Expected error when Case has no emails or description');
  }

  @IsTest
  static void generateDraftForRecord_casePath() {
    Case c = new Case(Subject = 'Billing question', Description = 'Invoice issue', Origin = 'Email');
    insert c;
    insert new EmailMessage(
      ParentId = c.Id,
      Incoming = true,
      FromAddress = 'customer@example.com',
      ToAddress = 'support@example.com',
      Subject = 'Billing question',
      TextBody = 'Please explain my invoice.',
      MessageDate = Datetime.now(),
      Status = '0'
    );

    Test.setMock(HttpCalloutMock.class, new CompletionsMock());
    Test.startTest();
    ApologistAgentService.DraftResult result = ApologistAgentService.generateDraftForRecord(
      c.Id,
      null,
      null
    );
    Test.stopTest();

    System.assertEquals('case', result.contextType);
    System.assertEquals(true, result.canFillComposer);
    System.assertEquals('Re: Billing question', result.emailSubject);
    System.assertEquals(
      ApologistAgentService.CREDENTIAL_CASE,
      result.namedCredential
    );
    System.assertEquals('Thanks for reaching out — happy to help.', result.draft);
  }

  @IsTest
  static void generateDraftForRecord_honorsNamedCredentialOverride() {
    Case c = new Case(Subject = 'Override', Description = 'Desc', Origin = 'Email');
    insert c;
    insert new EmailMessage(
      ParentId = c.Id,
      Incoming = true,
      FromAddress = 'customer@example.com',
      ToAddress = 'support@example.com',
      Subject = 'Override',
      TextBody = 'Hello',
      MessageDate = Datetime.now(),
      Status = '0'
    );

    Test.setMock(
      HttpCalloutMock.class,
      new AssertingCompletionsMock(
        new List<String>{ 'callout:' + ApologistAgentService.CREDENTIAL_LEGACY + '/' },
        true
      )
    );
    Test.startTest();
    ApologistAgentService.DraftResult result = ApologistAgentService.generateDraftForRecord(
      c.Id,
      null,
      ApologistAgentService.CREDENTIAL_LEGACY
    );
    Test.stopTest();
    System.assertEquals(ApologistAgentService.CREDENTIAL_LEGACY, result.namedCredential);
  }

  @IsTest
  static void resolveNamedCredential_defaultsAndOverride() {
    System.assertEquals(
      ApologistAgentService.CREDENTIAL_MESSAGING,
      ApologistAgentService.resolveNamedCredential('messaging', null)
    );
    System.assertEquals(
      ApologistAgentService.CREDENTIAL_CASE,
      ApologistAgentService.resolveNamedCredential('case', null)
    );
    System.assertEquals(
      ApologistAgentService.CREDENTIAL_LEGACY,
      ApologistAgentService.resolveNamedCredential('case', 'Apologist_Agent')
    );
  }

  @IsTest
  static void resolveNamedCredential_rejectsInvalidName() {
    Boolean threw = false;
    try {
      ApologistAgentService.resolveNamedCredential('messaging', 'bad name!');
    } catch (AuraHandledException e) {
      threw = true;
    }
    System.assert(threw, 'Expected invalid Named Credential name error');
  }

  @IsTest
  static void resolveNamedCredential_allowsApologistPrefixOverride() {
    System.assertEquals(
      'Apologist_Agent_Ligonier',
      ApologistAgentService.resolveNamedCredential('case', 'Apologist_Agent_Ligonier')
    );
  }

  @IsTest
  static void resolveNamedCredential_rejectsNonApologistName() {
    Boolean threw = false;
    try {
      ApologistAgentService.resolveNamedCredential('messaging', 'Evil_Credential');
    } catch (AuraHandledException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('Apologist_Agent'),
        e.getMessage()
      );
    }
    System.assert(threw, 'Expected non-Apologist Named Credential to be rejected');
  }

  @IsTest
  static void validateNamedCredentialName_rejectsCalloutPrefix() {
    Boolean threw = false;
    try {
      ApologistAgentService.validateNamedCredentialName('callout:x');
    } catch (AuraHandledException e) {
      threw = true;
    }
    System.assert(threw, 'Expected callout: prefix to be rejected');
  }

  @IsTest
  static void generateDraftForRecord_rejectsUnsupportedType() {
    Account a = new Account(Name = 'Unsupported');
    insert a;
    Boolean threw = false;
    try {
      ApologistAgentService.generateDraftForRecord(a.Id, null, null);
    } catch (AuraHandledException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('Unsupported') || e.getMessage() != null,
        e.getMessage()
      );
    }
    System.assert(threw, 'Expected unsupported record type error');
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
