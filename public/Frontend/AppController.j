@import <AppKit/AppKit.j>
@import <Foundation/CPObject.j>

// Custom background color attributes for layout highlights
var CorrectionHighlightColorAttributeName = @"CorrectionHighlightColorAttributeName";
var CorrectionAlertIdentifierAttributeName = @"CorrectionAlertIdentifierAttributeName";

// Fallback constants for system function keys if missing in active runtime scope
var CPF2FunctionKey = CPF2FunctionKey || @"\uf705",
    CPF7FunctionKey = CPF7FunctionKey || @"\uf70a",
    CPF8FunctionKey = CPF8FunctionKey || @"\uf70b";

// Subclass of CPBox that handles keyboard focus and keystroke events directly
@implementation AlertCardView : CPBox
{
    id _representedObject @accessors(property=representedObject);
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (BOOL)becomeFirstResponder
{
    var context = [self representedObject];
    if (context)
    {
        var alert = context.alert;
        var strongBorderColor = [CPColor colorWithRed:1.0 green:0.40 blue:0.40 alpha:1.0];
        if (alert.category === @"grammar") {
            strongBorderColor = [CPColor colorWithRed:0.20 green:0.60 blue:1.0 alpha:1.0];
        } else if (alert.category === @"clarity") {
            strongBorderColor = [CPColor colorWithRed:0.20 green:0.80 blue:0.20 alpha:1.0];
        } else if (alert.category === @"style") {
            strongBorderColor = [CPColor colorWithRed:0.70 green:0.30 blue:0.90 alpha:1.0];
        }

        [self setBorderWidth:2.5];
        [self setBorderColor:strongBorderColor];

        var appController = [CPApp delegate];
        if (appController && [appController respondsToSelector:@selector(selectAlertTextActionWithCard:)])
        {
            [appController selectAlertTextActionWithCard:self];
        }
    }
    return YES;
}

- (BOOL)resignFirstResponder
{
    [self setBorderWidth:1.0];
    [self setBorderColor:[CPColor colorWithWhite:0.85 alpha:1.0]];
    return YES;
}

// Request first responder keyboard focus when the card background is clicked
- (void)mouseDown:(CPEvent)anEvent
{
    [[self window] makeFirstResponder:self];
}

- (void)keyDown:(CPEvent)anEvent
{
    var keyCode = [anEvent keyCode];
    
    // Sort cards by physical vertical position to avoid reliance on fluctuating z-order array indexes
    var cards = [];
    var rawSubviews = [[self superview] subviews];
    for (var i = 0; i < [rawSubviews count]; i++) {
        var sv = [rawSubviews objectAtIndex:i];
        if ([sv isKindOfClass:[AlertCardView class]]) {
            cards.push(sv);
        }
    }
    cards.sort(function(a, b) {
        return CGRectGetMinY([a frame]) - CGRectGetMinY([b frame]);
    });

    var index = cards.indexOf(self);

    if (keyCode === CPDownArrowKeyCode)
    {
        if (index !== -1 && index < cards.length - 1)
        {
            var nextCard = cards[index + 1];
            [[self window] makeFirstResponder:nextCard];
        }
    }
    else if (keyCode === CPUpArrowKeyCode)
    {
        if (index !== -1 && index > 0)
        {
            var prevCard = cards[index - 1];
            [[self window] makeFirstResponder:prevCard];
        }
    }
    else if (keyCode === CPReturnKeyCode || keyCode === CPSpaceKeyCode)
    {
        var appController = [CPApp delegate];
        if (appController && [appController respondsToSelector:@selector(applyCorrectionForCard:)])
        {
            [appController applyCorrectionForCard:self];
        }
    }
    else if (keyCode === CPLeftArrowKeyCode || keyCode === CPEscapeKeyCode)
    {
        var appController = [CPApp delegate];
        if (appController && [appController respondsToSelector:@selector(returnFocusToEditor)])
        {
            [appController returnFocusToEditor];
        }
    }
    else
    {
        [super keyDown:anEvent];
    }
}

@end

@implementation AppController : CPObject
{
    CPTextView          _editorTextView;
    CPScrollView        _sidebarScrollView;
    CPView              _sidebarDocumentView;
    CPButton            _analyzeButton;
    CPPopUpButton       _languagePopUp;
    CPTextField         _statusLabel;
    
    // Progress & Sheet Controls
    CPProgressIndicator _progressBar;
    CPButton            _transferButton;
    CPWindow            _sheetWindow;
    CPTextView          _sheetTextView;

    // Service Settings Controls
    CPWindow            _settingsWindow;
    CPPopUpButton       _servicePopUp;
    CPTextField         _endpointField;
    CPTextField         _modelField;
    CPTextField         _apiKeyField;

    // Temporary Settings Variables to preserve changes before saving
    CPString            _lastSelectedService;
    CPString            _tempOllamaEndpoint;
    CPString            _tempOllamaModel;
    CPString            _tempGroqAPIKey;
    CPString            _tempGroqModel;
    CPString            _tempGeminiAPIKey;
    CPString            _tempGeminiModel;
    CPString            _tempOpenRouterAPIKey;
    CPString            _tempOpenRouterModel;

    CPArray             _paragraphsData;  // Cached structured backend responses
    CPDictionary        _alertCardsMap;   // Maps alert IDs to their sidebar visual card boxes
    CPBox               _currentHighlightedCard; // Currently active/selected card in sidebar
    
    int                 _totalParagraphs;
    int                 _completedParagraphs;

    BOOL                _isProgrammaticSelection;
    id                  _focusTimeoutId;  // Token pointer for debouncing async layout selection shifts
}

- (void)orderFrontFontPanel:(id)sender
{
   [[CPFontManager sharedFontManager] orderFrontFontPanel:self];
}

- (void)applicationDidFinishLaunching:(CPNotification)aNotification
{
    // --- PERSISTENT USER DEFAULTS INITIALIZATION ---
    var defaults = [CPUserDefaults standardUserDefaults];
    var defaultSettings = [CPDictionary dictionaryWithObjects:[
        @"http://localhost:11434/api/generate",
        @"gemma4:e4b",
        @"ollama",
        @"",
        @"llama3-8b-8192",
        @"",
        @"gemini-2.0-flash",
        @"",
        @"openai/gpt-4o"
    ] forKeys:[
        @"OllamaEndpoint",
        @"OllamaModel",
        @"ServiceType",
        @"GroqAPIKey",
        @"GroqModel",
        @"GeminiAPIKey",
        @"GeminiModel",
        @"OpenRouterAPIKey",
        @"OpenRouterModel"
    ]];
    [defaults registerDefaults:defaultSettings];

    // --- SYSTEM MENU BAR SETUP ---
    var mainMenu = [CPApp mainMenu];
    while ([mainMenu numberOfItems] > 0)
       [mainMenu removeItemAtIndex:0];

    // AI Assistant Menu
    var appItem = [mainMenu insertItemWithTitle:@"AI Assistant" action:nil keyEquivalent:nil atIndex:0];
    var appMenu = [[CPMenu alloc] initWithTitle:@"AI Assistant"];
    [appMenu addItemWithTitle:@"Settings..." action:@selector(openSettingsSheet:) keyEquivalent:@","];
    
    // VS Code Style Error Keys (F2 / Shift + F2)
    var nextF2 = [appMenu addItemWithTitle:@"Next Error (F2)" action:@selector(focusNextAlert:) keyEquivalent:CPF2FunctionKey];
    var prevF2 = [appMenu addItemWithTitle:@"Previous Error (Shift+F2)" action:@selector(focusPreviousAlert:) keyEquivalent:CPF2FunctionKey];
    [prevF2 setKeyEquivalentModifierMask:CPShiftKeyMask];
    
    // IntelliJ Style Error Keys (F8 / Shift + F8)
    var nextF8 = [appMenu addItemWithTitle:@"Next Error (F8)" action:@selector(focusNextAlert:) keyEquivalent:CPF8FunctionKey];
    var prevF8 = [appMenu addItemWithTitle:@"Previous Error (Shift+F8)" action:@selector(focusPreviousAlert:) keyEquivalent:CPF8FunctionKey];
    [prevF8 setKeyEquivalentModifierMask:CPShiftKeyMask];

    // MS Word Style Error Keys (Alt + F7)
    var wordStyleItem = [appMenu addItemWithTitle:@"Next Error (Word)" action:@selector(focusNextAlert:) keyEquivalent:CPF7FunctionKey];
    [wordStyleItem setKeyEquivalentModifierMask:CPAlternateKeyMask];

    // IntelliJ Style "Quick Fix" (Alt + Enter / Alt + Return)
    var quickFixItem = [appMenu addItemWithTitle:@"Quick Fix" action:@selector(applyActiveCorrectionFromMenu:) keyEquivalent:CPCarriageReturnCharacter];
    [quickFixItem setKeyEquivalentModifierMask:CPAlternateKeyMask];

    [mainMenu setSubmenu:appMenu forItem:appItem];

    // Format Menu with Font Panel
    var formatItem = [mainMenu insertItemWithTitle:@"Format" action:nil keyEquivalent:nil atIndex:1];
    var formatMenu = [[CPMenu alloc] initWithTitle:@"Format"];
    [formatMenu addItemWithTitle:@"Font Panel" action:@selector(orderFrontFontPanel:) keyEquivalent:@"t"];
    [mainMenu setSubmenu:formatMenu forItem:formatItem];
    [CPMenu setMenuBarVisible:YES];

    _alertCardsMap = [CPDictionary dictionary];

    var theWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 1100, 750) styleMask:CPBorderlessBridgeWindowMask];
    [theWindow setTitle:@"AI Writing Assistant"];
    [theWindow center];

    var contentView = [theWindow contentView];
    var bounds = [contentView bounds];

    // --- TOP ACTION BAR ---
    var topBar = [[CPView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(bounds), 50)];
    [topBar setAutoresizingMask:CPViewWidthSizable | CPViewMaxYMargin];
    [topBar setBackgroundColor:[CPColor colorWithWhite:0.97 alpha:1.0]];
    [contentView addSubview:topBar];

    // Check Button
    _analyzeButton = [[CPButton alloc] initWithFrame:CGRectMake(20, 12, 130, 26)];
    [_analyzeButton setTitle:@"Check Document"];
    [_analyzeButton setTarget:self];
    [_analyzeButton setAction:@selector(analyzeDocument:)];
    [topBar addSubview:_analyzeButton];

    // Language Selector Popup
    _languagePopUp = [[CPPopUpButton alloc] initWithFrame:CGRectMake(160, 12, 95, 26) pullsDown:NO];
    [_languagePopUp addItemWithTitle:@"English"];
    [[_languagePopUp lastItem] setRepresentedObject:@"en"];
    [_languagePopUp addItemWithTitle:@"Deutsch"];
    [[_languagePopUp lastItem] setRepresentedObject:@"de"];
    [_languagePopUp addItemWithTitle:@"Français"];
    [[_languagePopUp lastItem] setRepresentedObject:@"fr"];
    [topBar addSubview:_languagePopUp];

    // Unified Session Import/Export Button
    _transferButton = [[CPButton alloc] initWithFrame:CGRectMake(265, 12, 140, 26)];
    [_transferButton setTitle:@"Import / Export JSON"];
    [_transferButton setTarget:self];
    [_transferButton setAction:@selector(openTransferSheet:)];
    [topBar addSubview:_transferButton];

    // Progress Bar
    _progressBar = [[CPProgressIndicator alloc] initWithFrame:CGRectMake(420, 18, 120, 14)];
    [_progressBar setStyle:CPProgressIndicatorBarStyle];
    [_progressBar setIndeterminate:NO];
    [_progressBar setHidden:YES];
    [topBar addSubview:_progressBar];

    // Status Label
    _statusLabel = [[CPTextField alloc] initWithFrame:CGRectMake(550, 15, 525, 20)];
    [_statusLabel setStringValue:@"Enter narrative text below and run validation."];
    [_statusLabel setFont:[CPFont systemFontOfSize:12]];
    [_statusLabel setAutoresizingMask:CPViewWidthSizable];
    [topBar addSubview:_statusLabel];

    // --- MAIN WORKING LAYOUT (SPLIT VIEW) ---
    var splitHeight = CGRectGetHeight(bounds) - 50;
    var splitView = [[CPSplitView alloc] initWithFrame:CGRectMake(0, 50, CGRectGetWidth(bounds), splitHeight)];
    [splitView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [splitView setVertical:YES];
    [splitView setDelegate:self];

    var dividerWidth = [splitView dividerThickness];
    var leftWidth = (CGRectGetWidth([splitView bounds]) - dividerWidth) * 0.65;
    var rightWidth = (CGRectGetWidth([splitView bounds]) - dividerWidth) - leftWidth;

    // LEFT: Document Editor Scroll View
    var editorScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, leftWidth, splitHeight)];
    [editorScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [editorScroll setAutohidesScrollers:YES];
    [editorScroll setHasHorizontalScroller:NO];

    _editorTextView = [[CPTextView alloc] initWithFrame:[editorScroll bounds]];
    [_editorTextView setAutoresizingMask:CPViewWidthSizable];
    [_editorTextView setMinSize:CGSizeMake(0, 0)];
    [_editorTextView setMaxSize:CGSizeMake(100000, 100000)];
    [_editorTextView setHorizontallyResizable:NO];
    [_editorTextView setVerticallyResizable:YES];
    [_editorTextView setRichText:YES];
    [_editorTextView setFont:[CPFont fontWithName:@"Arial" size:14.0]];
    [_editorTextView setDelegate:self];
    [_editorTextView setAutoresizingMask:CPViewWidthSizable];
    [[_editorTextView textContainer] setWidthTracksTextView:YES];

    [editorScroll setDocumentView:_editorTextView];
    [splitView addSubview:editorScroll];

    // RIGHT: Alert Sidebar Panel
    _sidebarScrollView = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, splitHeight)];
    [_sidebarScrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [_sidebarScrollView setAutohidesScrollers:YES];
    [_sidebarScrollView setHasHorizontalScroller:NO];
    [_sidebarScrollView setBackgroundColor:[CPColor colorWithWhite:0.96 alpha:1.0]];

    _sidebarDocumentView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, 10)];
    [_sidebarDocumentView setAutoresizingMask:CPViewWidthSizable];
    [_sidebarScrollView setDocumentView:_sidebarDocumentView];
    [splitView addSubview:_sidebarScrollView];

    [contentView addSubview:splitView];
    [theWindow orderFront:self];

    // Sample initial text block
    [_editorTextView setString:@"Welcome to the GrammarMom Editor, the best place to write what's important.\n\nRed underlines mean that Grammarly has spotted a mistake in your writing. You'll see one if you mispell something. If you're worry about typos or grammatical errors that could effect your credibility, suggestions will helps you fix those to."];
}

// Helper method to safely access cards in vertical visual layout order
- (CPArray)sortedAlertCards
{
    var cards = [];
    var rawSubviews = [_sidebarDocumentView subviews];
    for (var i = 0; i < [rawSubviews count]; i++) {
        var sv = [rawSubviews objectAtIndex:i];
        if ([sv isKindOfClass:[AlertCardView class]]) {
            cards.push(sv);
        }
    }
    cards.sort(function(a, b) {
        return CGRectGetMinY([a frame]) - CGRectGetMinY([b frame]);
    });
    return cards;
}

// --- DYNAMIC LAYOUT RESIZING HANDLER (CPSPLITVIEW DELEGATE) ---

- (void)splitViewDidResizeSubviews:(CPNotification)aNotification
{
    if (_editorTextView)
    {
        var editorClipWidth = CGRectGetWidth([[_editorTextView superview] bounds]);
        if (editorClipWidth > 0)
        {
            [_editorTextView setFrameSize:CGSizeMake(editorClipWidth, CGRectGetHeight([_editorTextView frame]))];
        }
    }

    if (_sidebarDocumentView)
    {
        var sidebarClipWidth = CGRectGetWidth([[_sidebarScrollView contentView] bounds]);
        if (sidebarClipWidth > 0)
        {
            [_sidebarDocumentView setFrameSize:CGSizeMake(sidebarClipWidth, CGRectGetHeight([_sidebarDocumentView frame]))];
        }
    }
}

// --- CONFIGURATION PANEL ---

- (void)openSettingsSheet:(id)sender
{
    if (!_settingsWindow)
    {
        _settingsWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 480, 290)
                                                   styleMask:CPTitledWindowMask | CPClosableWindowMask];
        
        var sheetContentView = [_settingsWindow contentView];
        var sheetBounds = [sheetContentView bounds];

        // Description Info
        var infoLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 15, CGRectGetWidth(sheetBounds) - 30, 40)];
        [infoLabel setStringValue:@"Configure your LLM integration (Ollama, Groq, Gemini, or OpenRouter)."];
        [infoLabel setFont:[CPFont systemFontOfSize:11.0]];
        [infoLabel setTextColor:[CPColor colorWithWhite:0.3 alpha:1.0]];
        [infoLabel setLineBreakMode:CPLineBreakByWordWrapping];
        [sheetContentView addSubview:infoLabel];

        // Service Type
        var serviceLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 60, 110, 20)];
        [serviceLabel setStringValue:@"Service Type:"];
        [serviceLabel setFont:[CPFont systemFontOfSize:12.0]];
        [serviceLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:serviceLabel];

        _servicePopUp = [[CPPopUpButton alloc] initWithFrame:CGRectMake(135, 57, 150, 26) pullsDown:NO];
        [_servicePopUp addItemWithTitle:@"Ollama"];
        [[_servicePopUp lastItem] setRepresentedObject:@"ollama"];
        [_servicePopUp addItemWithTitle:@"Groq API"];
        [[_servicePopUp lastItem] setRepresentedObject:@"groq"];
        [_servicePopUp addItemWithTitle:@"Google Gemini"];
        [[_servicePopUp lastItem] setRepresentedObject:@"gemini"];
        [_servicePopUp addItemWithTitle:@"OpenRouter"];
        [[_servicePopUp lastItem] setRepresentedObject:@"openrouter"];
        [_servicePopUp setTarget:self];
        [_servicePopUp setAction:@selector(serviceTypeDidChange:)];
        [sheetContentView addSubview:_servicePopUp];

        // Endpoint Target URL
        var endpointLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 95, 110, 20)];
        [endpointLabel setStringValue:@"Ollama API URL:"];
        [endpointLabel setFont:[CPFont systemFontOfSize:12.0]];
        [endpointLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:endpointLabel];

        _endpointField = [[CPTextField alloc] initWithFrame:CGRectMake(135, 92, CGRectGetWidth(sheetBounds) - 155, 24)];
        [_endpointField setEditable:YES];
        [_endpointField setBezeled:YES];
        [_endpointField setFont:[CPFont systemFontOfSize:12.0]];
        [sheetContentView addSubview:_endpointField];

        // Model String Selector
        var modelLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 130, 110, 20)];
        [modelLabel setStringValue:@"Model Name:"];
        [modelLabel setFont:[CPFont systemFontOfSize:12.0]];
        [modelLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:modelLabel];

        _modelField = [[CPTextField alloc] initWithFrame:CGRectMake(135, 127, CGRectGetWidth(sheetBounds) - 155, 24)];
        [_modelField setEditable:YES];
        [_modelField setBezeled:YES];
        [_modelField setFont:[CPFont systemFontOfSize:12.0]];
        [sheetContentView addSubview:_modelField];

        // API Key Field
        var apiKeyLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 165, 110, 20)];
        [apiKeyLabel setStringValue:@"API Key:"];
        [apiKeyLabel setFont:[CPFont systemFontOfSize:12.0]];
        [apiKeyLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:apiKeyLabel];

        _apiKeyField = [[CPTextField alloc] initWithFrame:CGRectMake(135, 162, CGRectGetWidth(sheetBounds) - 155, 24)];
        [_apiKeyField setEditable:YES];
        [_apiKeyField setBezeled:YES];
        [_apiKeyField setFont:[CPFont systemFontOfSize:12.0]];
        [sheetContentView addSubview:_apiKeyField];

        // Action Buttons
        var btnY = CGRectGetHeight(sheetBounds) - 45;

        var cancelBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(sheetBounds) - 205, btnY, 90, 26)];
        [cancelBtn setTitle:@"Cancel"];
        [cancelBtn setTarget:self];
        [cancelBtn setAction:@selector(closeSettingsSheet:)];
        [sheetContentView addSubview:cancelBtn];

        var saveBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(sheetBounds) - 105, btnY, 90, 26)];
        [saveBtn setTitle:@"Save"];
        [saveBtn setTarget:self];
        [saveBtn setAction:@selector(saveSettings:)];
        [sheetContentView addSubview:saveBtn];
    }

    [_settingsWindow setTitle:@"AI Service Configuration"];
    
    var defaults = [CPUserDefaults standardUserDefaults];
    var activeService = [defaults objectForKey:@"ServiceType"] || @"ollama";
    _lastSelectedService = activeService;

    // Load saved settings into temporary working variables
    _tempOllamaEndpoint = [defaults objectForKey:@"OllamaEndpoint"] || @"http://localhost:11434/api/generate";
    _tempOllamaModel = [defaults objectForKey:@"OllamaModel"] || @"gemma4:e4b";
    _tempGroqAPIKey = [defaults objectForKey:@"GroqAPIKey"] || @"";
    _tempGroqModel = [defaults objectForKey:@"GroqModel"] || @"llama3-8b-8192";
    _tempGeminiAPIKey = [defaults objectForKey:@"GeminiAPIKey"] || @"";
    _tempGeminiModel = [defaults objectForKey:@"GeminiModel"] || @"gemini-2.0-flash";
    _tempOpenRouterAPIKey = [defaults objectForKey:@"OpenRouterAPIKey"] || @"";
    _tempOpenRouterModel = [defaults objectForKey:@"OpenRouterModel"] || @"openai/gpt-4o";

    if (activeService === @"ollama") [_servicePopUp selectItemAtIndex:0];
    else if (activeService === @"groq") [_servicePopUp selectItemAtIndex:1];
    else if (activeService === @"gemini") [_servicePopUp selectItemAtIndex:2];
    else if (activeService === @"openrouter") [_servicePopUp selectItemAtIndex:3];

    [self updateFieldsForService:activeService];

    [CPApp beginSheet:_settingsWindow
        modalForWindow:[_editorTextView window]
         modalDelegate:self
        didEndSelector:nil
           contextInfo:nil];
}

- (void)updateFieldsForService:(CPString)serviceType
{
    if (serviceType === @"ollama") {
        [_endpointField setEnabled:YES];
        [_endpointField setStringValue:_tempOllamaEndpoint];
        [_modelField setStringValue:_tempOllamaModel];
        [_apiKeyField setEnabled:NO];
        [_apiKeyField setStringValue:@""];
        [_apiKeyField setPlaceholderString:@"Not required for Ollama"];
    } else {
        [_endpointField setEnabled:NO];
        [_endpointField setStringValue:@""];
        [_endpointField setPlaceholderString:@"Constant Endpoint"];
        [_apiKeyField setEnabled:YES];
        [_apiKeyField setPlaceholderString:@"Enter API Key"];
        
        if (serviceType === @"groq") {
            [_modelField setStringValue:_tempGroqModel];
            [_apiKeyField setStringValue:_tempGroqAPIKey];
        } else if (serviceType === @"gemini") {
            [_modelField setStringValue:_tempGeminiModel];
            [_apiKeyField setStringValue:_tempGeminiAPIKey];
        } else if (serviceType === @"openrouter") {
            [_modelField setStringValue:_tempOpenRouterModel];
            [_apiKeyField setStringValue:_tempOpenRouterAPIKey];
        }
    }
}

- (void)serviceTypeDidChange:(id)sender
{
    // 1. Commit active fields to temporary storage before switching service variables
    if (_lastSelectedService === @"ollama") {
        _tempOllamaEndpoint = [_endpointField stringValue];
        _tempOllamaModel = [_modelField stringValue];
    } else if (_lastSelectedService === @"groq") {
        _tempGroqModel = [_modelField stringValue];
        _tempGroqAPIKey = [_apiKeyField stringValue];
    } else if (_lastSelectedService === @"gemini") {
        _tempGeminiModel = [_modelField stringValue];
        _tempGeminiAPIKey = [_apiKeyField stringValue];
    } else if (_lastSelectedService === @"openrouter") {
        _tempOpenRouterModel = [_modelField stringValue];
        _tempOpenRouterAPIKey = [_apiKeyField stringValue];
    }

    // 2. Load fields for newly selected service
    var newService = [[_servicePopUp selectedItem] representedObject];
    _lastSelectedService = newService;
    [self updateFieldsForService:newService];
}

- (void)closeSettingsSheet:(id)sender
{
    [CPApp endSheet:_settingsWindow];
    [_settingsWindow orderOut:self];
}

- (void)saveSettings:(id)sender
{
    // First, commit active fields to temporary variables
    var activeService = [[_servicePopUp selectedItem] representedObject] || @"ollama";
    if (activeService === @"ollama") {
        _tempOllamaEndpoint = [_endpointField stringValue];
        _tempOllamaModel = [_modelField stringValue];
    } else if (activeService === @"groq") {
        _tempGroqModel = [_modelField stringValue];
        _tempGroqAPIKey = [_apiKeyField stringValue];
    } else if (activeService === @"gemini") {
        _tempGeminiModel = [_modelField stringValue];
        _tempGeminiAPIKey = [_apiKeyField stringValue];
    } else if (activeService === @"openrouter") {
        _tempOpenRouterModel = [_modelField stringValue];
        _tempOpenRouterAPIKey = [_apiKeyField stringValue];
    }

    // Persist all configured settings to standard user defaults
    var defaults = [CPUserDefaults standardUserDefaults];
    [defaults setObject:activeService forKey:@"ServiceType"];
    [defaults setObject:_tempOllamaEndpoint forKey:@"OllamaEndpoint"];
    [defaults setObject:_tempOllamaModel forKey:@"OllamaModel"];
    [defaults setObject:_tempGroqModel forKey:@"GroqModel"];
    [defaults setObject:_tempGroqAPIKey forKey:@"GroqAPIKey"];
    [defaults setObject:_tempGeminiModel forKey:@"GeminiModel"];
    [defaults setObject:_tempGeminiAPIKey forKey:@"GeminiAPIKey"];
    [defaults setObject:_tempOpenRouterModel forKey:@"OpenRouterModel"];
    [defaults setObject:_tempOpenRouterAPIKey forKey:@"OpenRouterAPIKey"];
    
    [self closeSettingsSheet:sender];
    [_statusLabel setStringValue:@"AI configuration updated and saved."];
}

// --- UNIFIED IMPORT & EXPORT SESSION DATA ---

- (void)openTransferSheet:(id)sender
{
    if (!_sheetWindow)
    {
        _sheetWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 580, 460)
                                                   styleMask:CPTitledWindowMask | CPClosableWindowMask | CPResizableWindowMask];
        
        var sheetContentView = [_sheetWindow contentView];
        var sheetBounds = [sheetContentView bounds];

        // Description Label
        var infoLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 10, CGRectGetWidth(sheetBounds) - 30, 45)];
        [infoLabel setStringValue:@"To export, copy the JSON block below. To import a past run, replace the JSON content below and click \"Import JSON\"."];
        [infoLabel setFont:[CPFont systemFontOfSize:11.0]];
        [infoLabel setTextColor:[CPColor colorWithWhite:0.3 alpha:1.0]];
        [infoLabel setLineBreakMode:CPLineBreakByWordWrapping];
        [infoLabel setAutoresizingMask:CPViewWidthSizable | CPViewMaxYMargin];
        [sheetContentView addSubview:infoLabel];

        // Scroll View for JSON text area
        var scroll = [[CPScrollView alloc] initWithFrame:CGRectMake(15, 60, CGRectGetWidth(sheetBounds) - 30, CGRectGetHeight(sheetBounds) - 130)];
        [scroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [scroll setAutohidesScrollers:YES];

        _sheetTextView = [[CPTextView alloc] initWithFrame:[scroll bounds]];
        [_sheetTextView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [_sheetTextView setFont:[CPFont fontWithName:@"Courier" size:11.0]];
        [_sheetTextView setRichText:NO];
        [scroll setDocumentView:_sheetTextView];
        [sheetContentView addSubview:scroll];

        // Bottom Buttons
        var btnY = CGRectGetHeight(sheetBounds) - 50;

        var cancelBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(sheetBounds) - 235, btnY, 110, 26)];
        [cancelBtn setTitle:@"Cancel / Close"];
        [cancelBtn setAutoresizingMask:CPViewMinXMargin | CPViewMinYMargin];
        [cancelBtn setTarget:self];
        [cancelBtn setAction:@selector(closeSheet:)];
        [sheetContentView addSubview:cancelBtn];

        var actionBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(sheetBounds) - 115, btnY, 100, 26)];
        [actionBtn setTitle:@"Import JSON"];
        [actionBtn setAutoresizingMask:CPViewMinXMargin | CPViewMinYMargin];
        [actionBtn setTarget:self];
        [actionBtn setAction:@selector(executeImportAction:)];
        [sheetContentView addSubview:actionBtn];
    }

    [_sheetWindow setTitle:@"Transfer Session Data (JSON)"];
    [_sheetTextView setEditable:YES];

    // Assemble document structure and validation response mapping into transfer JSON
    var sessionState = {
        "editorText": [_editorTextView string],
        "paragraphsData": _paragraphsData || []
    };
    
    var jsonString = JSON.stringify(sessionState, null, 2);
    [_sheetTextView setString:jsonString];

    [CPApp beginSheet:_sheetWindow
        modalForWindow:[_editorTextView window]
         modalDelegate:self
        didEndSelector:nil
           contextInfo:nil];
           
    window.setTimeout(function() { [_sheetTextView selectAll:self]; }, 100);
}

- (void)closeSheet:(id)sender
{
    [CPApp endSheet:_sheetWindow];
    [_sheetWindow orderOut:self];
}

- (void)executeImportAction:(id)sender
{
    var text = [_sheetTextView string];
    if (text && [text length] > 0)
    {
        try {
            var sessionData = JSON.parse(text);
            if (sessionData && typeof sessionData === "object") {
                if (sessionData.editorText !== undefined) {
                    [_editorTextView setString:sessionData.editorText];
                }
                
                if (sessionData.paragraphsData && Array.isArray(sessionData.paragraphsData)) {
                    _paragraphsData = sessionData.paragraphsData;
                } else {
                    _paragraphsData = [];
                }

                // Render highlighting and populate sidebar container directly
                [self renderHighlightsAndSidebar];
                [_statusLabel setStringValue:@"Session state loaded successfully."];
            } else {
                [_statusLabel setStringValue:@"Failed to load state: invalid structure format."];
            }
        } catch (e) {
            [_statusLabel setStringValue:@"JSON structural format analysis failed."];
            CPLog.error(@"JSON Parsing Exception: " + e.message);
        }
    }
    [self closeSheet:sender];
}

// --- PROGRESSIVE DOCUMENT ANALYSIS ---

- (void)analyzeDocument:(id)sender
{
    var documentText = [_editorTextView string];
    if (!documentText || [documentText length] === 0) {
        [_statusLabel setStringValue:@"Please enter text before analyzing."];
        return;
    }

    // Splittet bei doppelten Zeilenumbrüchen ODER bei einem Punkt, gefolgt von einem Zeilenumbruch und einem Großbuchstaben
    var paragraphs = documentText.split(/(?:\r?\n\r?\n+)|(?<=\.)\r?\n(?=\p{Lu})/u);
    _totalParagraphs = paragraphs.length;
    _completedParagraphs = 0;

    _paragraphsData = [];
    for (var i = 0; i < _totalParagraphs; i++) {
        _paragraphsData.push({ "text": paragraphs[i], "alerts": [], "completed": false });
    }

    [_alertCardsMap removeAllObjects];
    _currentHighlightedCard = nil;
    
    var textStorage = [_editorTextView textStorage];
    var completeDocRange = CPMakeRange(0, [textStorage length]);
    [textStorage removeAttribute:CPBackgroundColorAttributeName range:completeDocRange];
    [textStorage removeAttribute:CorrectionAlertIdentifierAttributeName range:completeDocRange];
    [[_sidebarDocumentView subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];

    [_progressBar setHidden:NO];
    [_progressBar setMaxValue:_totalParagraphs];
    [_progressBar setDoubleValue:0];

    [_analyzeButton setEnabled:NO];
    [_languagePopUp setEnabled:NO];
    [_transferButton setEnabled:NO];
    [_statusLabel setStringValue:@"Analyzing document... Progress: 0%"];

    var langCode = [[_languagePopUp selectedItem] representedObject] || @"en";

    for (var i = 0; i < _totalParagraphs; i++) {
        [self analyzeParagraph:paragraphs[i] index:i langCode:langCode];
    }
}

- (void)analyzeParagraph:(CPString)pText index:(int)pIndex langCode:(CPString)langCode
{
    // Use the initializer that allows setting the cache policy and timeout interval (e.g., 3600.0 seconds)
    var request = [CPURLRequest requestWithURL:@"/DBB/analyze_paragraph" 
                                   cachePolicy:CPURLRequestUseProtocolCachePolicy 
                               timeoutInterval:3600.0];
                               
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var defaults = [CPUserDefaults standardUserDefaults];
    var serviceType = [defaults objectForKey:@"ServiceType"] || @"ollama";

    var endpoint = [defaults objectForKey:@"OllamaEndpoint"] || @"";
    var model = @"";
    var apiKey = @"";

    if (serviceType === @"ollama") {
        model = [defaults objectForKey:@"OllamaModel"];
    } else if (serviceType === @"groq") {
        model = [defaults objectForKey:@"GroqModel"];
        apiKey = [defaults objectForKey:@"GroqAPIKey"];
    } else if (serviceType === @"gemini") {
        model = [defaults objectForKey:@"GeminiModel"];
        apiKey = [defaults objectForKey:@"GeminiAPIKey"];
    } else if (serviceType === @"openrouter") {
        model = [defaults objectForKey:@"OpenRouterModel"];
        apiKey = [defaults objectForKey:@"OpenRouterAPIKey"];
    }

    var payload = { 
        "text": pText, 
        "paragraph_index": pIndex, 
        "lang_code": langCode,
        "service_type": serviceType,
        "endpoint": endpoint,
        "model": model,
        "api_key": apiKey
    };
    
    var postData = [CPString stringWithString:JSON.stringify(payload)];
    [request setHTTPBody:postData];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
    {
        _completedParagraphs++;
        [_progressBar setDoubleValue:_completedParagraphs];

        var percent = Math.round((_completedParagraphs / _totalParagraphs) * 100);
        [_statusLabel setStringValue:@"Analyzing document... Progress: " + percent + "%"];

        if (!error && data) {
            try {
                var result = JSON.parse(data);
                _paragraphsData[pIndex] = {
                    "text": result.text,
                    "alerts": result.alerts,
                    "completed": true
                };
            } catch (e) {
                CPLog.error(@"JSON Parsing Exception: " + e.message);
            }
        } else {
            _paragraphsData[pIndex] = {
                "text": pText,
                "alerts": [],
                "completed": true
            };
        }

        [self renderHighlightsAndSidebar];

        if (_completedParagraphs === _totalParagraphs) {
            [_analyzeButton setEnabled:YES];
            [_languagePopUp setEnabled:YES];
            [_transferButton setEnabled:YES];
            [_progressBar setHidden:YES];
            [_statusLabel setStringValue:@"Analysis finalized. Correct highlighted segments."];
        }
    }];
}

- (void)renderHighlightsAndSidebar
{
    [_alertCardsMap removeAllObjects];
    _currentHighlightedCard = nil;

    var textStorage = [_editorTextView textStorage];
    var completeDocRange = CPMakeRange(0, [textStorage length]);
    [textStorage removeAttribute:CPBackgroundColorAttributeName range:completeDocRange];
    [textStorage removeAttribute:CorrectionAlertIdentifierAttributeName range:completeDocRange];

    [[_sidebarDocumentView subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];

    var sidebarWidth = CGRectGetWidth([[_sidebarScrollView contentView] bounds]) - 20;
    if (sidebarWidth <= 0) {
        sidebarWidth = CGRectGetWidth([_sidebarScrollView bounds]) - 20;
    }
    
    var currentY = 15;
    var docString = [_editorTextView string];

    for (var i = 0; i < _paragraphsData.length; i++) {
        var pData = _paragraphsData[i];
        if (!pData || !pData.completed) {
            continue;
        }
        var pText = pData.text;

        var absoluteParaOffset = [docString rangeOfString:pText].location;
        if (absoluteParaOffset === CPNotFound) {
            continue;
        }

        var alerts = pData.alerts;
        for (var j = 0; j < alerts.length; j++) {
            var alert = alerts[j];
            var absRange = CPMakeRange(absoluteParaOffset + alert.offset, alert.length);

            var highlightColor = [CPColor colorWithRed:1.0 green:0.90 blue:0.90 alpha:1.0]; // Spelling
            if (alert.category === @"grammar") {
                highlightColor = [CPColor colorWithRed:0.90 green:0.95 blue:1.0 alpha:1.0]; // Grammar
            } else if (alert.category === @"clarity") {
                highlightColor = [CPColor colorWithRed:0.92 green:1.0 blue:0.92 alpha:1.0]; // Clarity
            } else if (alert.category === @"style") {
                highlightColor = [CPColor colorWithRed:0.97 green:0.92 blue:1.0 alpha:1.0]; // Style
            }

            [textStorage addAttribute:CPBackgroundColorAttributeName value:highlightColor range:absRange];
            [textStorage addAttribute:CorrectionAlertIdentifierAttributeName value:alert.id range:absRange];

            var card = [self createAlertCardFrame:CGRectMake(10, currentY, sidebarWidth, 110) forAlert:alert paragraphIndex:i];
            [_sidebarDocumentView addSubview:card];
            
            [_alertCardsMap setObject:card forKey:alert.id];
            currentY += 125;
        }
    }

    [_sidebarDocumentView setFrameSize:CGSizeMake(sidebarWidth + 20, currentY + 30)];
}

- (CPView)createAlertCardFrame:(CGRect)frame forAlert:(id)alert paragraphIndex:(int)pIndex
{
    var cardBox = [[AlertCardView alloc] initWithFrame:frame];
    [cardBox setRepresentedObject:{ "alert": alert, "paragraphIndex": pIndex }];
    
    [cardBox setBoxType:CPBoxCustom];
    [cardBox setBorderType:CPLineBorder];
    [cardBox setBorderWidth:1.0];
    [cardBox setBorderColor:[CPColor colorWithWhite:0.85 alpha:1.0]];
    [cardBox setCornerRadius:5.0];
    [cardBox setTitle:alert.title];
    [cardBox setAutoresizingMask:CPViewWidthSizable];

    var container = [cardBox contentView];
    var contentWidth = CGRectGetWidth([container bounds]);

    var cardBgColor = [CPColor colorWithRed:1.0 green:0.90 blue:0.90 alpha:1.0]; // Spelling
    
    if (alert.category === @"grammar") {
        cardBgColor = [CPColor colorWithRed:0.90 green:0.95 blue:1.0 alpha:1.0];
    } else if (alert.category === @"clarity") {
        cardBgColor = [CPColor colorWithRed:0.92 green:1.0 blue:0.92 alpha:1.0];
    } else if (alert.category === @"style") {
        cardBgColor = [CPColor colorWithRed:0.97 green:0.92 blue:1.0 alpha:1.0];
    }

    [cardBox setFillColor:cardBgColor];

    // Beschreibungstext (Hit-Tests sind deaktiviert, um Klicks an cardBox weiterzuleiten)
    var description = [[CPTextField alloc] initWithFrame:CGRectMake(15, 5, contentWidth - 25, 45)];
    [description setStringValue:alert.explanation];
    [description setLineBreakMode:CPLineBreakByWordWrapping];
    [description setFont:[CPFont systemFontOfSize:11.0]];
    [description setTextColor:[CPColor colorWithWhite:0.25 alpha:1.0]];
    [description setHitTests:NO];
    [description setAutoresizingMask:CPViewWidthSizable];
    [container addSubview:description];

    // Aktions-Button
    var actionBtn = [[CPButton alloc] initWithFrame:CGRectMake(15, 52, contentWidth - 30, 26)];
    [actionBtn setTitle:[CPString stringWithFormat:@"Correct to: '%@'", alert.suggested_text]];
    [actionBtn setFont:[CPFont boldSystemFontOfSize:11.0]];
    [actionBtn setTarget:self];
    [actionBtn setAction:@selector(applyCorrectionAction:)];
    [actionBtn setAutoresizingMask:CPViewWidthSizable];
    [container addSubview:actionBtn];

    return cardBox;
}

- (void)selectAlertTextActionWithCard:(AlertCardView)card
{
    var context = [card representedObject];
    if (!context) return;
    
    var alert = context.alert;
    var pIndex = context.paragraphIndex;

    var docString = [_editorTextView string];
    var pData = _paragraphsData[pIndex];
    if (!pData) return;
    
    var pText = pData.text;
    var absoluteParaOffset = [docString rangeOfString:pText].location;

    if (absoluteParaOffset === CPNotFound)
        return;

    var absRange = CPMakeRange(absoluteParaOffset + alert.offset, alert.length);
    var currentRange = [_editorTextView selectedRange];

    // Programmatically sync selection only if range is different to prevent cycles
    if (currentRange.location !== absRange.location || currentRange.length !== absRange.length)
    {
        _isProgrammaticSelection = YES;
        [_editorTextView setSelectedRange:absRange];
        [_editorTextView scrollRangeToVisible:absRange];
        _isProgrammaticSelection = NO;
    }

    // Clear any previously queued focus actions to debouce rapid navigation inputs
    if (_focusTimeoutId)
    {
        clearTimeout(_focusTimeoutId);
        _focusTimeoutId = nil;
    }

    // Only restore responder state asynchronously if focus was stolen or isn't already active
    var theWindow = [card window];
    if ([theWindow firstResponder] !== card)
    {
        _focusTimeoutId = setTimeout(function() {
            [theWindow makeFirstResponder:card];
            _focusTimeoutId = nil;
        }, 30);
    }

    var cardFrame = [card frame];
    [[_sidebarScrollView contentView] scrollToPoint:CGPointMake(0, MAX(0, cardFrame.origin.y - 15))];
}

- (void)applyCorrectionForCard:(AlertCardView)card
{
    var context = [card representedObject];
    if (!context) return;
    
    var alert = context.alert;
    var pIndex = context.paragraphIndex;

    var docString = [_editorTextView string];
    var pData = _paragraphsData[pIndex];
    if (!pData) return;
    
    var pText = pData.text;
    var absoluteParaOffset = [docString rangeOfString:pText].location;
    if (absoluteParaOffset === CPNotFound) {
        [_statusLabel setStringValue:@"Context mismatch. Please re-run check."];
        return;
    }

    var absRange = CPMakeRange(absoluteParaOffset + alert.offset, alert.length);

    _isProgrammaticSelection = YES;
    [_editorTextView setSelectedRange:absRange];
    [_editorTextView insertText:alert.suggested_text];
    _isProgrammaticSelection = NO;

    var lengthDelta = [alert.suggested_text length] - alert.length;
    var alerts = pData.alerts;

    for (var i = 0; i < alerts.length; i++) {
        if (alerts[i].offset > alert.offset) {
            alerts[i].offset += lengthDelta;
        }
    }

    var preStr = [pText substringToIndex:alert.offset];
    var postStr = [pText substringFromIndex:alert.offset + alert.length];
    pData.text = preStr + alert.suggested_text + postStr;

    [pData.alerts removeObject:alert];

    // Determine current index utilizing the sorted list
    var cards = [self sortedAlertCards];
    var activeIndex = cards.indexOf(card);

    [self renderHighlightsAndSidebar];

    var updatedCards = [self sortedAlertCards];
    if (updatedCards.length > 0)
    {
        var nextFocusIndex = Math.min(activeIndex, updatedCards.length - 1);
        if (nextFocusIndex !== -1)
        {
            var nextCard = updatedCards[nextFocusIndex];
            [[_editorTextView window] makeFirstResponder:nextCard];
        }
    }
    else
    {
        [self returnFocusToEditor];
    }

    [_statusLabel setStringValue:@"Correction successfully applied."];
}

- (void)applyActiveCorrectionFromMenu:(id)sender
{
    var activeFirstResponder = [[_editorTextView window] firstResponder];
    
    if ([activeFirstResponder isKindOfClass:[AlertCardView class]])
    {
        [self applyCorrectionForCard:activeFirstResponder];
        return;
    }
    
    if (activeFirstResponder === _editorTextView && _paragraphsData)
    {
        var selectedRange = [_editorTextView selectedRange];
        var docString = [_editorTextView string];
        var cursorLoc = selectedRange.location;

        for (var i = 0; i < _paragraphsData.length; i++) {
            var pData = _paragraphsData[i];
            if (!pData || !pData.completed) continue;
            
            var pText = pData.text;
            var absoluteParaOffset = [docString rangeOfString:pText].location;
            if (absoluteParaOffset === CPNotFound) continue;

            var alerts = pData.alerts;
            for (var j = 0; j < alerts.length; j++) {
                var alert = alerts[j];
                var alertStart = absoluteParaOffset + alert.offset;
                var alertEnd = alertStart + alert.length;

                if (cursorLoc >= alertStart && cursorLoc <= alertEnd) {
                    var activeCard = [_alertCardsMap objectForKey:alert.id];
                    if (activeCard) {
                        [self applyCorrectionForCard:activeCard];
                    }
                    return;
                }
            }
        }
    }
}

- (void)applyCorrectionAction:(id)sender
{
    var card = [sender superview];
    while (card && ![card isKindOfClass:[AlertCardView class]])
    {
        card = [card superview];
    }
    if (card)
    {
        [self applyCorrectionForCard:card];
    }
}

- (void)returnFocusToEditor
{
    [[_editorTextView window] makeFirstResponder:_editorTextView];
}

- (void)focusNextAlert:(id)sender
{
    var cards = [self sortedAlertCards];
    if (cards.length === 0) return;

    var currentFirst = [[_editorTextView window] firstResponder];
    
    // If the editor is active and a card has already been visually marked, focus it directly
    if (currentFirst === _editorTextView && _currentHighlightedCard)
    {
        [[_editorTextView window] makeFirstResponder:_currentHighlightedCard];
        return;
    }

    var index = cards.indexOf(currentFirst);
    if (index === -1)
    {
        [[_editorTextView window] makeFirstResponder:cards[0]];
    }
    else if (index < cards.length - 1)
    {
        [[_editorTextView window] makeFirstResponder:cards[index + 1]];
    }
}

- (void)focusPreviousAlert:(id)sender
{
    var cards = [self sortedAlertCards];
    if (cards.length === 0) return;

    var currentFirst = [[_editorTextView window] firstResponder];
    
    // If the editor is active and a card has already been visually marked, focus it directly
    if (currentFirst === _editorTextView && _currentHighlightedCard)
    {
        [[_editorTextView window] makeFirstResponder:_currentHighlightedCard];
        return;
    }

    var index = cards.indexOf(currentFirst);
    if (index === -1)
    {
        [[_editorTextView window] makeFirstResponder:cards[cards.length - 1]];
    }
    else if (index > 0)
    {
        [[_editorTextView window] makeFirstResponder:cards[index - 1]];
    }
}

- (void)textViewDidChangeSelection:(CPNotification)aNotification
{
    if (_isProgrammaticSelection)
        return;

    // Decouple editor updates entirely when user actively navigates sidebar cards
    var activeFirstResponder = [[_editorTextView window] firstResponder];
    if ([activeFirstResponder isKindOfClass:[AlertCardView class]])
        return;

    var selectedRange = [_editorTextView selectedRange];

    if (selectedRange.length < 0 || !_paragraphsData) {
        return;
    }

    var docString = [_editorTextView string];
    var cursorLoc = selectedRange.location;

    if (_currentHighlightedCard) {
        [_currentHighlightedCard setBorderWidth:1.0];
        [_currentHighlightedCard setBorderColor:[CPColor colorWithWhite:0.85 alpha:1.0]];
        _currentHighlightedCard = nil;
    }

    for (var i = 0; i < _paragraphsData.length; i++) {
        var pData = _paragraphsData[i];
        if (!pData || !pData.completed) continue;
        
        var pText = pData.text;
        var absoluteParaOffset = [docString rangeOfString:pText].location;
        if (absoluteParaOffset === CPNotFound) {
            continue;
        }

        var MathAlerts = pData.alerts;
        for (var j = 0; j < MathAlerts.length; j++) {
            var alert = MathAlerts[j];
            var alertStart = absoluteParaOffset + alert.offset;
            var alertEnd = alertStart + alert.length;

            if (cursorLoc >= alertStart && cursorLoc <= alertEnd) {
                var activeCard = [_alertCardsMap objectForKey:alert.id];
                if (activeCard) {
                    var strongBorderColor = [CPColor colorWithRed:1.0 green:0.40 blue:0.40 alpha:1.0]; // Spelling default
                    if (alert.category === @"grammar") {
                        strongBorderColor = [CPColor colorWithRed:0.20 green:0.60 blue:1.0 alpha:1.0];
                    } else if (alert.category === @"clarity") {
                        strongBorderColor = [CPColor colorWithRed:0.20 green:0.80 blue:0.20 alpha:1.0];
                    } else if (alert.category === @"style") {
                        strongBorderColor = [CPColor colorWithRed:0.70 green:0.30 blue:0.90 alpha:1.0];
                    }

                    [activeCard setBorderWidth:2.5];
                    [activeCard setBorderColor:strongBorderColor];
                    _currentHighlightedCard = activeCard;

                    var cardFrame = [activeCard frame];
                    [[_sidebarScrollView contentView] scrollToPoint:CGPointMake(0, MAX(0, cardFrame.origin.y - 15))];

                    // Transfer keyboard focus only on direct mouse interaction to avoid disrupting keyboard-only text typing/arrowing
                    var currentEvent = [CPApp currentEvent];
                    var isMouseEvent = currentEvent && (
                        [currentEvent type] === CPLeftMouseDown ||
                        [currentEvent type] === CPLeftMouseUp ||
                        [currentEvent type] === CPLeftMouseDragged
                    );

                    if (isMouseEvent)
                    {
                        [[_editorTextView window] makeFirstResponder:activeCard];
                    }
                }
                return;
            }
        }
    }
}

@end
