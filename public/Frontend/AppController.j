@import <AppKit/AppKit.j>
@import <Foundation/CPObject.j>

// Custom background color attributes for layout highlights
var CorrectionHighlightColorAttributeName = @"CorrectionHighlightColorAttributeName";
var CorrectionAlertIdentifierAttributeName = @"CorrectionAlertIdentifierAttributeName";

@implementation AppController : CPObject
{
    CPTextView       _editorTextView;
    CPScrollView     _sidebarScrollView;
    CPView           _sidebarDocumentView;
    CPButton         _analyzeButton;
    CPPopUpButton    _languagePopUp;
    CPTextField      _statusLabel;

    CPArray          _paragraphsData;  // Cached structured backend responses
    CPDictionary     _alertCardsMap;   // Maps alert IDs to their sidebar visual card boxes
    CPBox            _currentHighlightedCard; // Currently active/selected card in sidebar
}

- (void)orderFrontFontPanel:(id)sender
{
   [[CPFontManager sharedFontManager] orderFrontFontPanel:self];
}

- (void)applicationDidFinishLaunching:(CPNotification)aNotification
{
    // --- SYSTEM MENU BAR SETUP ---
    var mainMenu = [CPApp mainMenu];
    while ([mainMenu numberOfItems] > 0)
       [mainMenu removeItemAtIndex:0];

    // Format Menu with Font Panel
    var formatItem = [mainMenu insertItemWithTitle:@"Format" action:nil keyEquivalent:nil atIndex:0];
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
    _languagePopUp = [[CPPopUpButton alloc] initWithFrame:CGRectMake(165, 12, 110, 26) pullsDown:NO];
    [_languagePopUp addItemWithTitle:@"English"];
    [[_languagePopUp lastItem] setTag:48];
    [_languagePopUp addItemWithTitle:@"Deutsch"];
    [[_languagePopUp lastItem] setTag:49];
    [topBar addSubview:_languagePopUp];

    // Status Label
    _statusLabel = [[CPTextField alloc] initWithFrame:CGRectMake(290, 15, 350, 20)];
    [_statusLabel setStringValue:@"Enter narrative text below and run validation."];
    [_statusLabel setFont:[CPFont systemFontOfSize:12]];
    [topBar addSubview:_statusLabel];

    // --- MAIN WORKING LAYOUT (SPLIT VIEW) ---
    var splitHeight = CGRectGetHeight(bounds) - 50;
    var splitView = [[CPSplitView alloc] initWithFrame:CGRectMake(0, 50, CGRectGetWidth(bounds), splitHeight)];
    [splitView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [splitView setVertical:YES];

    var dividerWidth = [splitView dividerThickness];
    var leftWidth = (CGRectGetWidth([splitView bounds]) - dividerWidth) * 0.65;
    var rightWidth = (CGRectGetWidth([splitView bounds]) - dividerWidth) - leftWidth;

    // LEFT: Document Editor Scroll View
    var editorScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, leftWidth, splitHeight)];
    [editorScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [editorScroll setAutohidesScrollers:YES];
    [editorScroll setHasHorizontalScroller:NO]; // Disable horizontal scrolling to enforce wrapping

    // Text Editor Configuration (Responsive text wrapping)
    _editorTextView = [[CPTextView alloc] initWithFrame:[editorScroll bounds]];
    [_editorTextView setAutoresizingMask:CPViewWidthSizable];
    [_editorTextView setMinSize:CGSizeMake(0, 0)];
    [_editorTextView setMaxSize:CGSizeMake(100000, 100000)];
    [_editorTextView setHorizontallyResizable:NO];
    [_editorTextView setVerticallyResizable:YES];
    [_editorTextView setRichText:YES];
    [_editorTextView setFont:[CPFont fontWithName:@"Arial" size:14.0]];
    [_editorTextView setDelegate:self]; // Listen to cursor selection events
    
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

- (void)analyzeDocument:(id)sender
{
    var documentText = [_editorTextView string];
    if (!documentText || [documentText length] === 0) {
        [_statusLabel setStringValue:@"Please enter text before analyzing."];
        return;
    }

    [_analyzeButton setEnabled:NO];
    [_statusLabel setStringValue:@"Analyzing document clarity and correctness..."];

    var request = [CPURLRequest requestWithURL:@"/DBB/analyze_text"];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var runId = [[_languagePopUp selectedItem] tag] || 48;

    var payload = { "text": documentText, "run_id": runId };
    var postData = [CPString stringWithString:JSON.stringify(payload)];
    [request setHTTPBody:postData];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
    {
        [_analyzeButton setEnabled:YES];

        if (error || !data) {
            [_statusLabel setStringValue:@"Error connecting to processing engine."];
            return;
        }

        try {
            var result = JSON.parse(data);
        } catch (e) {
            [_statusLabel setStringValue:@"Error decoding syntax engine responses."];
            CPLog.error(@"JSON Parsing Exception: " + e.message);
        }

        _paragraphsData = result.paragraphs;
        [self renderHighlightsAndSidebar];
        [_statusLabel setStringValue:@"Analysis finalized. Correct highlighted segments."];
    }];
}

- (void)renderHighlightsAndSidebar
{
    // Reset selection cache
    [_alertCardsMap removeAllObjects];
    _currentHighlightedCard = nil;

    var textStorage = [_editorTextView textStorage];
    var completeDocRange = CPMakeRange(0, [textStorage length]);
    [textStorage removeAttribute:CPBackgroundColorAttributeName range:completeDocRange];
    [textStorage removeAttribute:CorrectionAlertIdentifierAttributeName range:completeDocRange];

    [[_sidebarDocumentView subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];

    var sidebarWidth = CGRectGetWidth([_sidebarScrollView bounds]) - 20;
    var currentY = 15;
    var docString = [_editorTextView string];

    for (var i = 0; i < _paragraphsData.length; i++) {
        var pData = _paragraphsData[i];
        var pText = pData.text;

        var absoluteParaOffset = [docString rangeOfString:pText].location;
        if (absoluteParaOffset === CPNotFound) {
            continue;
        }

        var alerts = pData.alerts;
        for (var j = 0; j < alerts.length; j++) {
            var alert = alerts[j];

            var absRange = CPMakeRange(absoluteParaOffset + alert.offset, alert.length);

            // Determine Highlight Colors
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

            // Render visual card
            var card = [self createAlertCardFrame:CGRectMake(10, currentY, sidebarWidth, 110) forAlert:alert paragraphIndex:i];
            [_sidebarDocumentView addSubview:card];
            
            // Map the alert ID to its respective visual CPBox for fast programmatic highlighting
            [_alertCardsMap setObject:card forKey:alert.id];
            
            currentY += 125;
        }
    }

    [_sidebarDocumentView setFrameSize:CGSizeMake(sidebarWidth + 20, currentY + 30)];
}

- (CPView)createAlertCardFrame:(CGRect)frame forAlert:(id)alert paragraphIndex:(int)pIndex
{
    var cardBox = [[CPBox alloc] initWithFrame:frame];
    [cardBox setTitle:alert.title];
    [cardBox setAutoresizingMask:CPViewWidthSizable];

    var container = [cardBox contentView];
    var contentWidth = CGRectGetWidth([container bounds]);

    // --- VISUAL ACCENT STRIP (Connects sidebar to text category colors) ---
    var accentColor = [CPColor colorWithRed:1.0 green:0.40 blue:0.40 alpha:1.0]; // Spelling (Red Accent)
    if (alert.category === @"grammar") {
        accentColor = [CPColor colorWithRed:0.20 green:0.60 blue:1.0 alpha:1.0]; // Grammar (Blue Accent)
    } else if (alert.category === @"clarity") {
        accentColor = [CPColor colorWithRed:0.20 green:0.80 blue:0.20 alpha:1.0]; // Clarity (Green Accent)
    } else if (alert.category === @"style") {
        accentColor = [CPColor colorWithRed:0.70 green:0.30 blue:0.90 alpha:1.0]; // Style (Purple Accent)
    }

    var accentStrip = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 5, CGRectGetHeight(frame))];
    [accentStrip setBackgroundColor:accentColor];
    [accentStrip setAutoresizingMask:CPViewMinXMargin | CPViewHeightSizable];
    [cardBox addSubview:accentStrip];

    // --- SELECT EVENT TRIGGER (Makes card body clickable to focus the text) ---
    var bgSelectBtn = [[CPButton alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(frame), CGRectGetHeight(frame))];
    [bgSelectBtn setBezelStyle:CPBorderlessBridgeWindowMask];
    [bgSelectBtn setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [bgSelectBtn setTarget:self];
    [bgSelectBtn setAction:@selector(selectAlertTextAction:)];
    bgSelectBtn._representedObject = { "alert": alert, "paragraphIndex": pIndex };
    [cardBox addSubview:bgSelectBtn]; // Put behind content elements

    // Issue Description Area (Non-blocking hit behavior so background button registers clicks)
    var description = [[CPTextField alloc] initWithFrame:CGRectMake(10, 5, contentWidth - 25, 45)];
    [description setStringValue:alert.explanation];
    [description setLineBreakMode:CPLineBreakByWordWrapping];
    [description setFont:[CPFont systemFontOfSize:11.0]];
    [description setTextColor:[CPColor colorWithWhite:0.3 alpha:1.0]];
    [container addSubview:description];

    // Correction Suggestion Action Button
    var actionBtn = [[CPButton alloc] initWithFrame:CGRectMake(10, 52, contentWidth - 25, 26)];
    [actionBtn setTitle:[CPString stringWithFormat:@"Correct to: '%@'", alert.suggested_text]];
    [actionBtn setFont:[CPFont boldSystemFontOfSize:11.0]];
    [actionBtn setTarget:self];
    [actionBtn setAction:@selector(applyCorrectionAction:)];
    actionBtn._representedObject = { "alert": alert, "paragraphIndex": pIndex };
    [container addSubview:actionBtn];

    return cardBox;
}

// Action: Selecting a card highlights and focuses the text segment
- (void)selectAlertTextAction:(id)sender
{
    var context = sender._representedObject;
    var alert = context.alert;
    var pIndex = context.paragraphIndex;

    var docString = [_editorTextView string];
    var pData = _paragraphsData[pIndex];
    var pText = pData.text;

    var absoluteParaOffset = [docString rangeOfString:pText].location;
    if (absoluteParaOffset === CPNotFound) {
        return;
    }

    var absRange = CPMakeRange(absoluteParaOffset + alert.offset, alert.length);
    
    // Perform selection
    [_editorTextView setSelectedRange:absRange];
    [[_editorTextView window] makeFirstResponder:_editorTextView];
}

// Delegate: Clicked / Cursor placement in Highlighted text updates Sidebar selection
- (void)textViewDidChangeSelection:(CPNotification)aNotification
{
    var selectedRange = [_editorTextView selectedRange];
    if (selectedRange.length < 0 || !_paragraphsData) {
        return;
    }

    var textStorage = [_editorTextView textStorage];
    var docString = [_editorTextView string];
    var cursorLoc = selectedRange.location;

    // Reset currently highlighted card visual background
    if (_currentHighlightedCard) {
        [_currentHighlightedCard setBackgroundColor:[CPColor clearColor]];
        _currentHighlightedCard = nil;
    }

    // Identify which alert key corresponds to the selection range
    for (var i = 0; i < _paragraphsData.length; i++) {
        var pData = _paragraphsData[i];
        var pText = pData.text;

        var absoluteParaOffset = [docString rangeOfString:pText].location;
        if (absoluteParaOffset === CPNotFound) {
            continue;
        }

        var alerts = pData.alerts;
        for (var j = 0; j < alerts.length; j++) {
            var alert = alerts[j];
            var alertStart = absoluteParaOffset + alert.offset;
            var alertEnd = alertStart + alert.length;

            // If the cursor falls inside the highlighted boundaries
            if (cursorLoc >= alertStart && cursorLoc <= alertEnd) {
                var activeCard = [_alertCardsMap objectForKey:alert.id];
                if (activeCard) {
                    // Soft gray background to indicate selection focus
                    [activeCard setBackgroundColor:[CPColor colorWithRed:0.93 green:0.93 blue:0.93 alpha:1.0]];
                    _currentHighlightedCard = activeCard;

                    // Automatically scroll the sidebar viewport smoothly
                    var cardFrame = [activeCard frame];
                    [[_sidebarScrollView contentView] scrollToPoint:CGPointMake(0, MAX(0, cardFrame.origin.y - 15))];
                }
                return;
            }
        }
    }
}

- (void)applyCorrectionAction:(id)sender
{
    var context = sender._representedObject;
    var alert = context.alert;
    var pIndex = context.paragraphIndex;

    var docString = [_editorTextView string];
    var pData = _paragraphsData[pIndex];
    var pText = pData.text;

    var absoluteParaOffset = [docString rangeOfString:pText].location;
    if (absoluteParaOffset === CPNotFound) {
        [_statusLabel setStringValue:@"Context mismatch. Please re-run check."];
        return;
    }

    var absRange = CPMakeRange(absoluteParaOffset + alert.offset, alert.length);

    [_editorTextView setSelectedRange:absRange];
    [_editorTextView insertText:alert.suggested_text];

    var lengthDelta = [alert.suggested_text length] - alert.length;
    var alerts = pData.alerts;

    for (var i = 0; i < alerts.length; i++) {
        if (alerts[i].offset > alert.offset) {
            alerts[i].offset += lengthDelta;
        }
    }

    var originalLength = [pText length];
    var preStr = [pText substringToIndex:alert.offset];
    var postStr = [pText substringFromIndex:alert.offset + alert.length];
    pData.text = preStr + alert.suggested_text + postStr;

    [pData.alerts removeObject:alert];

    [self renderHighlightsAndSidebar];
    [_statusLabel setStringValue:@"Correction successfully applied."];
}

@end
