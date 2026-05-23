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
    CPDictionary     _alertCardsMap;   // Tracks DOM elements for clean redraws
}

- (void)applicationDidFinishLaunching:(CPNotification)aNotification
{
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

    // Status Label (shifted right to accommodate the popup)
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

    // LEFT: Document Editor (Rich-Text representation enabled)
    var editorScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, leftWidth, splitHeight)];
    [editorScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [editorScroll setAutohidesScrollers:YES];

    _editorTextView = [[CPTextView alloc] initWithFrame:[editorScroll bounds]];
    [_editorTextView setAutoresizingMask:CPViewWidthSizable];
    [_editorTextView setRichText:YES];
    [_editorTextView setFont:[CPFont fontWithName:@"Arial" size:14.0]];
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
    [_editorTextView setString:@"Welcome to the Grammarly Editor, the best place to write what's important.\n\nRed underlines mean that Grammarly has spotted a mistake in your writing. You'll see one if you mispell something. If you're worry about typos or grammatical errors that could effect your credibility, suggestions will helps you fix those to."];
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

    // Get selected language run ID (48 for English, 49 for German)
    var runId = [[_languagePopUp selectedItem] tag] || 48;

    var payload = { "text": documentText, "run_id": runId };
    var postData = [CPString stringWithString:JSON.stringify(payload)];
    [request setHTTPBody:postData];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
    {
        [_analyzeButton setEnabled:YES];
debugger

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

// Computes absolute structural range of paragraph elements to apply formatting safely
- (void)renderHighlightsAndSidebar
{
    // Clean existing style markers and custom sidebar frames
    var textStorage = [_editorTextView textStorage];
    var completeDocRange = CPMakeRange(0, [textStorage length]);
    [textStorage removeAttribute:CPBackgroundColorAttributeName range:completeDocRange];
    [textStorage removeAttribute:CorrectionAlertIdentifierAttributeName range:completeDocRange];

    [[_sidebarDocumentView subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];

    var sidebarWidth = CGRectGetWidth([_sidebarScrollView bounds]) - 20;
    var currentY = 15;
    var docString = [_editorTextView string];

    var totalAlerts = 0;

    for (var i = 0; i < _paragraphsData.length; i++) {
        var pData = _paragraphsData[i];
        var pText = pData.text;

        // Locating the exact start boundary of this paragraph inside the editor's text storage
        var absoluteParaOffset = [docString rangeOfString:pText].location;
        if (absoluteParaOffset === CPNotFound) {
            continue;
        }

        var alerts = pData.alerts;
        for (var j = 0; j < alerts.length; j++) {
            var alert = alerts[j];
            totalAlerts++;

            // Local ranges mapped to complete document context offsets
            var absRange = CPMakeRange(absoluteParaOffset + alert.offset, alert.length);

            // Determine Highlight Color based on category
            var highlightColor = [CPColor colorWithRed:1.0 green:0.90 blue:0.90 alpha:1.0]; // Default spelling (Light Red)
            if (alert.category === @"grammar") {
                highlightColor = [CPColor colorWithRed:0.90 green:0.95 blue:1.0 alpha:1.0]; // Light Blue
            } else if (alert.category === @"clarity") {
                highlightColor = [CPColor colorWithRed:0.92 green:1.0 blue:0.92 alpha:1.0]; // Light Green
            } else if (alert.category === @"style") {
                highlightColor = [CPColor colorWithRed:0.97 green:0.92 blue:1.0 alpha:1.0]; // Light Purple
            }

            // Apply attributes to the text storage rendering
            [textStorage addAttribute:CPBackgroundColorAttributeName value:highlightColor range:absRange];
            [textStorage addAttribute:CorrectionAlertIdentifierAttributeName value:alert.id range:absRange];

            // Render Alert Card into the Sidebar Column
            var card = [self createAlertCardFrame:CGRectMake(10, currentY, sidebarWidth, 140) forAlert:alert paragraphIndex:i];
            [_sidebarDocumentView addSubview:card];
            currentY += 155;
        }
    }

    [_sidebarDocumentView setFrameSize:CGSizeMake(sidebarWidth + 20, currentY + 30)];
}

// Generate the visual alert representation matching standard layout specs
- (CPView)createAlertCardFrame:(CGRect)frame forAlert:(id)alert paragraphIndex:(int)pIndex
{
    var cardBox = [[CPBox alloc] initWithFrame:frame];
    [cardBox setTitle:alert.title];
    [cardBox setAutoresizingMask:CPViewWidthSizable];

    var container = [cardBox contentView];
    var contentWidth = CGRectGetWidth([container bounds]);

    // Issue Description Text Area
    var description = [[CPTextField alloc] initWithFrame:CGRectMake(10, 5, contentWidth - 20, 55)];
    [description setStringValue:alert.explanation];
    [description setLineBreakMode:CPLineBreakByWordWrapping];
    [description setFont:[CPFont systemFontOfSize:11.0]];
    [description setTextColor:[CPColor colorWithWhite:0.3 alpha:1.0]];
    [container addSubview:description];

    // Correction Suggestion Action Button
    var actionBtn = [[CPButton alloc] initWithFrame:CGRectMake(10, 65, contentWidth - 20, 26)];
    [actionBtn setTitle:[CPString stringWithFormat:@"Correct to: '%@'", alert.suggested_text]];
    [actionBtn setFont:[CPFont boldSystemFontOfSize:11.0]];
    [actionBtn setTarget:self];

    // Wrap references dynamically to process modifications inside action handles
    [actionBtn setAction:@selector(applyCorrectionAction:)];
    actionBtn._representedObject = { "alert": alert, "paragraphIndex": pIndex };
    [container addSubview:actionBtn];

    return cardBox;
}

- (void)applyCorrectionAction:(id)sender
{
    var context = sender._representedObject;
    var alert = context.alert;
    var pIndex = context.paragraphIndex;

    var textStorage = [_editorTextView textStorage];
    var docString = [_editorTextView string];
    var pData = _paragraphsData[pIndex];
    var pText = pData.text;

    var absoluteParaOffset = [docString rangeOfString:pText].location;
    if (absoluteParaOffset === CPNotFound) {
        [_statusLabel setStringValue:@"Context mismatch. Please re-run check."];
        return;
    }

    var absRange = CPMakeRange(absoluteParaOffset + alert.offset, alert.length);

    // Swap original string matching current target range with chosen suggestion
    [_editorTextView setSelectedRange:absRange];
    [_editorTextView insertText:alert.suggested_text];

    // Shift offsets for any subsequent corrections in the same paragraph
    var lengthDelta = [alert.suggested_text length] - alert.length;
    var alerts = pData.alerts;

    for (var i = 0; i < alerts.length; i++) {
        if (alerts[i].offset > alert.offset) {
            alerts[i].offset += lengthDelta;
        }
    }

    // Reflect new content matching values to cache structures
    var originalLength = [pText length];
    var preStr = [pText substringToIndex:alert.offset];
    var postStr = [pText substringFromIndex:alert.offset + alert.length];
    pData.text = preStr + alert.suggested_text + postStr;

    // Remove solved item entry
    [pData.alerts removeObject:alert];

    // Refresh display
    [self renderHighlightsAndSidebar];
    [_statusLabel setStringValue:@"Correction successfully applied."];
}

@end
