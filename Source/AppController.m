/*	Copyright (c) 2007-2012 Dorian Johnson <2011@dorianj.net>
	
	This file is part of CoRD.
	CoRD is free software; you can redistribute it and/or modify it under the
	terms of the GNU General Public License as published by the Free Software
	Foundation; either version 2 of the License, or (at your option) any later
	version.

	CoRD is distributed in the hope that it will be useful, but WITHOUT ANY
	WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
	FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

	You should have received a copy of the GNU General Public License along with
	CoRD; if not, write to the Free Software Foundation, Inc., 51 Franklin St,
	Fifth Floor, Boston, MA 02110-1301 USA
*/

#import <Carbon/Carbon.h>

#import "AppController.h"
#import "PFMoveApplication.h"
#import "CRDSession.h"
#import "CRDSessionView.h"
#import "CRDAppDelegate.h"
#import "CRDServerList.h"
#import "CRDTabView.h"
#import "CRDShared.h"
#import "CRDLabelCell.h"
#import "keychain.h"

#define TOOLBAR_DISCONNECT	@"Disconnect"
#define TOOLBAR_DRAWER @"Servers"
#define TOOLBAR_FULLSCREEN @"Fullscreen"
#define TOOLBAR_UNIFIED @"Windowed"
#define TOOLBAR_QUICKCONNECT @"Quick Connect"

#pragma mark -

@interface AppController (Private)
	- (void)saveInspectedServer;
	- (void)updateInstToMatchInspector:(CRDSession *)inst;
	- (void)setInspectorSettings:(CRDSession *)newSettings;
	- (void)completeConnection:(CRDSession *)inst;
	- (void)connectAsync:(CRDSession *)inst;
	- (void)autosizeUnifiedWindow;
	- (void)autosizeUnifiedWindowWithAnimation:(BOOL)animate;
	- (void)setInspectorEnabled:(BOOL)enabled;
	- (void)toggleControlsEnabledInView:(NSView *)view enabled:(BOOL)enabled;
	- (void)createWindowForInstance:(CRDSession *)inst;
	- (void)createWindowForInstance:(CRDSession *)inst asFullscreen:(BOOL)fullscreen;
	- (void)toggleDrawer:(id)sender visible:(BOOL)VisibleLength;
	- (void)addSavedServer:(CRDSession *)inst;
	- (void)addSavedServer:(CRDSession *)inst atIndex:(int)index;
	- (void)addSavedServer:(CRDSession *)inst atIndex:(int)index select:(BOOL)select;
	- (void)removeSavedServer:(CRDSession *)inst deleteFile:(BOOL)deleteFile;
	- (void)sortSavedServersByStoredListPosition;
	- (void)sortSavedServersAlphabetically;
	- (void)loadSavedServers;
	- (void)parseUrlQueryString:(NSString *)queryString forSession:(CRDSession *)session;
@end


#pragma mark -
@implementation AppController

+ (void)initialize
{
	[[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Defaults" ofType:@"plist"]]];
}

- (id)init
{
	if (!(self = [super init]))
		return nil;

	userDefaults = [NSUserDefaults standardUserDefaults];
	
	_connectedServers = [[NSMutableArray alloc] init];
	_savedServers = [[NSMutableArray alloc] init];
	filteredServers = [[NSMutableArray alloc] init];
	
	filteredServersLabel = [[CRDLabelCell alloc] initTextCell:NSLocalizedString(@"Search Results", @"Servers list label 3")];
	connectedServersLabel = [[CRDLabelCell alloc] initTextCell:NSLocalizedString(@"Active Sessions", @"Servers list label 1")];
	savedServersLabel = [[CRDLabelCell alloc] initTextCell:NSLocalizedString(@"Saved Servers", @"Servers list label 2")];

    
	
	return self;
}
- (void) dealloc
{
	[_connectedServers release];
	[_savedServers release];
	[filteredServers release];
	
	[connectedServersLabel release];
	[savedServersLabel release];
	[filteredServersLabel release];
	
	[userDefaults release];
	g_appController = nil;
	[super dealloc];
}

- (void)awakeFromNib
{
    ((CRDAppDelegate *)[NSApp delegate]).appController = self;
	g_appController = self;
#ifndef CORD_DEBUG_BUILD
	PFMoveToApplicationsFolderIfNecessary();
#endif
	
	[self.self.gui_unifiedWindow makeKeyAndOrderFront:self];
	
	[[[NSApp windowsMenu] itemWithTitle:@"CoRD"] setKeyEquivalentModifierMask:(NSCommandKeyMask|NSAlternateKeyMask)];
	[[[NSApp windowsMenu] itemWithTitle:@"CoRD"] setKeyEquivalent:@"1"];
	
	[self setDisplayMode:CRDDisplayUnified];
	
	[self.self.gui_unifiedWindow setAcceptsMouseMovedEvents:YES];
	windowCascadePoint = CRDWindowCascadeStart;
	
	// Assure that the app support directory exists
	NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)[0];
	
	CRDCreateDirectory([appSupport stringByAppendingPathComponent:@"CoRD"]);
	CRDCreateDirectory([AppController savedServersPath]);
	
	// Load servers from the saved servers directory
	[self loadSavedServers];
	
	[self.gui_serverList deselectAll:nil];
	[self sortSavedServersByStoredListPosition];
	[self storeSavedServerPositions];
	

	// Set up server filter field
	NSMenu* searchMenu = [[[NSMenu alloc] initWithTitle:@"CoRD Servers Search Menu"] autorelease];
	[searchMenu setAutoenablesItems:YES];
	[searchMenu addItem:CRDMakeSearchFieldMenuItem(@"Recent Searches", NSSearchFieldRecentsTitleMenuItemTag)];
	[searchMenu addItem:CRDMakeSearchFieldMenuItem(@"No recent searches", NSSearchFieldNoRecentsMenuItemTag)];
	[searchMenu addItem:CRDMakeSearchFieldMenuItem(@"Recents", NSSearchFieldRecentsMenuItemTag)];
	[searchMenu addItem:CRDMakeSearchFieldMenuItem(@"-", NSSearchFieldRecentsTitleMenuItemTag)];
	[searchMenu addItem:CRDMakeSearchFieldMenuItem(@"Clear", NSSearchFieldClearRecentsMenuItemTag)];

	[[gui_searchField cell] setMaximumRecents:15];
	[[gui_searchField cell] setSearchMenuTemplate:searchMenu];

	
	// Register for drag operations
	NSArray *types = @[CRDRowIndexPboardType, NSFilenamesPboardType, NSFilesPromisePboardType];
	[self.gui_serverList registerForDraggedTypes:types];

	// Custom interface settings not accessable from IB
	[self.self.gui_unifiedWindow setExcludedFromWindowsMenu:YES];

	// Load a few user defaults that need to be loaded before anything is displayed
	[self setDisplayMode:[[userDefaults objectForKey:CRDDefaultsDisplayMode] intValue]];

	// Register for preferences KVO notification
	[[NSUserDefaults standardUserDefaults] addObserver:self forKeyPath:@"MinimalServerList" options:NSKeyValueObservingOptionNew context:NULL];
	
	[[NSAppleEventManager sharedAppleEventManager] setEventHandler:self andSelector:@selector(openUrl:withReplyEvent:) forEventClass:kInternetEventClass andEventID:kAEGetURL];
	
	[gui_toolbar validateVisibleItems];
	[self validateControls];
	[self listUpdated];

	if ([[NSUserDefaults standardUserDefaults] volatileDomainForName:NSArgumentDomain] != nil)
		[self parseCommandLine];
}		

- (void)parseCommandLine
{
    NSDictionary *arguments = [[NSUserDefaults standardUserDefaults] volatileDomainForName:NSArgumentDomain];
	
	// Try to emulate rdesktop's CLI args somewhat
	NSDictionary *argumentToKeyPath = @{@[@"host", @"h"]: @"hostName",
		@[@"username", @"u"]: @"username",
		@[@"port"]: @"port",
		@[@"domain", @"d"]: @"domain",
		@[@"password", @"p"]: @"password",
		@[@"bpp", @"a"]: @"screenDepth",
		//@"fullscreen",   [NSArray arrayWithObjects:@"fullscreen", @"f", nil], //haven't gotten booleans to work yet
		@[@"width"]: @"screenWidth",
		@[@"height"]: @"screenHeight"};
	
	CRDSession *newInst = nil;
	
	if ([arguments[@"l"] length])
	{
		NSString *labelMatch = [arguments[@"l"] lowercaseString];
		
		for (CRDSession *savedServer in self.savedServers)
			if ([[savedServer.label lowercaseString] isLike:labelMatch])
			{
				newInst = savedServer;
				break;
			}

		if (!newInst)
		{
			NSRunAlertPanel(
				NSLocalizedString(@"Server not found", nil),
				NSLocalizedString(@"No server was found with a label matching '%@'.", nil),
				nil, nil, nil, labelMatch);
			return;
		}
	}
	else
	{
		newInst = [[[CRDSession alloc] initWithBaseConnection] autorelease];
	
		if (arguments[@"g"])
		{
			NSInteger w, h;
			CRDSplitResolutionString(arguments[@"g"], &w, &h);
			[newInst setValue:@(w) forKey:@"screenWidth"];
			[newInst setValue:@(h) forKey:@"screenHeight"];
		}
		
		for (NSArray *argumentKeys in argumentToKeyPath)
		{
			NSString *instanceKeyPath = argumentToKeyPath[argumentKeys];
			
			for (NSString *argumentKey in argumentKeys)
				if (arguments[argumentKey])
					[newInst setValue:arguments[argumentKey] forKey:instanceKeyPath];
		}
		
		if ([[newInst hostName] length] == 0)
			return;
		
		[self.connectedServers addObject:newInst];
	}
	
	[self.gui_serverList deselectAll:self];
	[self listUpdated];
	[self connectInstance:newInst];
}

- (void)printUsage
{
    printf("usage: CoRD -hostname example.com -port port_number\n");
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	CRDSession *inst = [self selectedServer];
	CRDSession *viewedInst = [self viewedServer];
	SEL action = [item action];
	
    if (action == @selector(removeSelectedSavedServer:))
		return (inst != nil) && ![inst isTemporary] && ([inst status] == CRDConnectionClosed);
    else if (action == @selector(connect:))
        return (inst != nil) && [inst status] == CRDConnectionClosed;
    else if (action == @selector(disconnect:))
		return (inst != nil) && [inst status] != CRDConnectionClosed;
	else if (action == @selector(showServerInFinder:))
		return (inst != nil);
	else if (action == @selector(selectNext:))
		return [self.gui_tabView numberOfItems] > 1;
	else if (action == @selector(selectPrevious:))
		return [self.gui_tabView numberOfItems] > 1;
	else if (action == @selector(selectAdjacentSession:))
		return [self.gui_tabView numberOfItems] > 1;
	else if (action == @selector(takeScreenCapture:))
		return viewedInst != nil;
	else if (action == @selector(closeSessionOrWindow:))
		return [NSApp keyWindow] != nil;
	else if (action == @selector(duplicateSelectedServer:))
		return [self selectedServer] != nil;
	else if (action == @selector(addNewSavedServer:))
		return !_isFilteringSavedServers;
	else if (action == @selector(toggleInspector:))
	{
		NSString *hideOrShow = [gui_inspector isVisible]
				? NSLocalizedString(@"Hide Inspector", @"View menu -> Show Inspector")
				: NSLocalizedString(@"Show Inspector", @"View menu -> Hide Inspector");
		[item setTitle:hideOrShow];
		return inst != nil;
	}
	else if (action == @selector(toggleDrawer:))
	{
		NSString *hideOrShow = CRDDrawerIsVisible(self.gui_serversDrawer)
				? NSLocalizedString(@"Hide Servers Drawer", @"View menu -> Show Servers Drawer")
				: NSLocalizedString(@"Show Servers Drawer", @"View menu -> Hide Servers Drawer");
		[item setTitle:hideOrShow];
	}
	else if (action == @selector(keepSelectedServer:))
	{
		[item setState:CRDButtonState(![inst isTemporary])];
		return [inst status] == CRDConnectionConnected;
	}
	else if (action == @selector(performFullScreen:)) 
	{
		if ([self displayMode] == CRDDisplayFullscreen) {
			[item setTitle:NSLocalizedString(@"Exit Full Screen", @"View menu -> Exit Full Screen")];
			return YES;
		} else {
			[item setTitle:NSLocalizedString(@"Start Full Screen", @"View menu -> Start Full Screen")];
			return [self.connectedServers count] > 0;			
		}
	}
	else if (action == @selector(performServerMenuItem:))
	{
		CRDSession *representedInst = [item representedObject];
		[item setState:([self.connectedServers indexOfObject:representedInst] != NSNotFound ? NSOnState : NSOffState)];	
	}
	else if (action == @selector(performConnectOrDisconnect:))
	{
		NSString *localizedDisconnect = NSLocalizedString(@"Disconnect", @"Servers menu -> Disconnect/connect item");
		NSString *localizedConnect = NSLocalizedString(@"Connect", @"Servers menu -> Disconnect/connect item");
	
		if (inst == nil)
			return NO;
		else
			[item setTitle:([inst status] == CRDConnectionClosed) ? localizedConnect : localizedDisconnect];
	}
	else if (action == @selector(performUnified:))
	{
		NSString *localizedWindowed = NSLocalizedString(@"Toggle Windowed", @"View menu -> Toggle Windowed");
		NSString *localizedUnified = NSLocalizedString(@"Toggle Unified", @"View menu -> Toggle Unified");
		
		if (self.displayMode == CRDDisplayUnified)
			[item setTitle:localizedWindowed];
		else if (self.displayMode == CRDDisplayWindowed)
			[item setTitle:localizedUnified];
	}
	
	return YES;
}

#pragma mark -
#pragma mark Actions

- (IBAction)addNewSavedServer:(id)sender
{
	if (![self.self.gui_unifiedWindow isVisible])
		[self.self.gui_unifiedWindow makeKeyAndOrderFront:nil];

	if (!CRDDrawerIsVisible(self.gui_serversDrawer))
		[self toggleDrawer:nil visible:YES];
		
	CRDSession *inst = [[[CRDSession alloc] initWithBaseConnection] autorelease];
	
	NSString *path = CRDFindAvailableFileName([AppController savedServersPath], NSLocalizedString(@"New Server", @"Name of newly added servers"), @".rdp");
		
	[inst setIsTemporary:NO];
	[inst setFilename:path];
	[inst setValue:[[path lastPathComponent] stringByDeletingPathExtension] forKey:@"label"];
	[inst flushChangesToFile];
	
	[self addSavedServer:inst];
	
	[inst setValue:@([self.savedServers indexOfObjectIdenticalTo:inst]) forKey:@"preferredRowIndex"];
	
	if (![gui_inspector isVisible])
		[self toggleInspector:nil];
}


// Removes the currently selected server, and deletes the file.
- (IBAction)removeSelectedSavedServer:(id)sender
{
	CRDSession *inst = [self selectedServer];
	
	if (inst == nil || [inst isTemporary] || ([inst status] != CRDConnectionClosed) )
		return;
	
	NSAlert *alert = [NSAlert alertWithMessageText:
				NSLocalizedString(@"Delete saved server", @"Delete server confirm alert -> Title")
			defaultButton:NSLocalizedString(@"Delete", @"Delete server confirm alert -> Yes button") 
			alternateButton:NSLocalizedString(@"Cancel", @"Delete server confirm alert -> Cancel button")
			otherButton:nil
			informativeTextWithFormat:NSLocalizedString(@"Really delete", @"Delete server confirm alert -> Detail text"),
			[inst label]];
	[alert setAlertStyle:NSCriticalAlertStyle];
	
	if ([alert runModal] == NSAlertAlternateReturn)
		return;
	
	if ([inst status] != CRDConnectionClosed)
	{	
		[self performStop:nil];
		[self autosizeUnifiedWindowWithAnimation:NO];
	}
		
	[self.gui_serverList deselectAll:self];
	
	[self removeSavedServer:inst deleteFile:YES];
	
	[self listUpdated];
}

// Connects to the currently selected saved server
- (IBAction)connect:(id)sender
{
	CRDSession *inst = [self selectedServer];
	
	if (inst == nil)
		return;
		
	if ( ([inst status] == CRDConnectionConnected) && (self.displayMode == CRDDisplayWindowed) )
	{
		[[inst window] makeKeyAndOrderFront:self];
		[[inst window] makeFirstResponder:[inst view]];
	}
	else if ([inst status] == CRDConnectionClosed)
	{
		[self connectInstance:inst];
	}	
}

// Disconnects the currently selected active server
- (IBAction)disconnect:(id)sender
{
	CRDSession *inst = [self viewedServer];
	[self disconnectInstance:inst];
}

// Either connects or disconnects the selected server, depending on whether it's connected
- (IBAction)performConnectOrDisconnect:(id)sender
{
	CRDSession *inst = [self selectedServer];
	
	if ([inst status] == CRDConnectionClosed)
		[self connectInstance:inst];
	else
		[self performStop:nil];
}


// Toggles whether or not the selected server is kept after disconnect
- (IBAction)keepSelectedServer:(id)sender
{
	CRDSession *inst = [self selectedServer];
	if (inst == nil)
		return;
	
	[inst setIsTemporary:![inst isTemporary]];
	
	if (![inst isTemporary])
	{
		[inst setFilename:CRDFindAvailableFileName([AppController savedServersPath], [inst hostName], @".rdp")];
		[inst flushChangesToFile];
	}
	[self validateControls];
	[self listUpdated];
}

// Either disconnects the viewed session, or cancels a pending connection
- (IBAction)performStop:(id)sender
{	
	if ([[self selectedServer] status] == CRDConnectionConnecting)
		[self stopConnection:nil];
	else if ([[self viewedServer] status]  == CRDConnectionConnected)
		[self disconnect:nil];
}

- (IBAction)stopConnection:(id)sender
{
	[self cancelConnectingInstance:[self selectedServer]];
}


// Hides or shows the inspector.
- (IBAction)toggleInspector:(id)sender
{
	BOOL nowVisible = ![gui_inspector isVisible];
	if (nowVisible)
		[gui_inspector makeKeyAndOrderFront:sender];
	else
		[gui_inspector close];	
		
	[self validateControls];
}


// Hides/shows the performance options in inspector.
- (IBAction)togglePerformanceDisclosure:(id)sender
{
	BOOL nowVisible = ([sender state] != NSOffState);
	
	NSRect boxFrame = [gui_performanceOptions frame], windowFrame = [gui_inspector frame];
	
	if (nowVisible) {
		windowFrame.size.height += boxFrame.size.height;	
		windowFrame.origin.y	-= boxFrame.size.height;
	} else {
		windowFrame.size.height -= boxFrame.size.height;
		windowFrame.origin.y	+= boxFrame.size.height;
	}
	
	[gui_performanceOptions setHidden:!nowVisible];
	
	NSSize minSize = [gui_inspector minSize];
	[gui_inspector setMinSize:NSMakeSize(minSize.width, windowFrame.size.height)];
	[gui_inspector setMaxSize:NSMakeSize(CRDInspectorMaxWidth, windowFrame.size.height)];
	[[gui_inspector animator] setFrame:windowFrame display:YES];
}

// Called whenever anything in the inspector is edited
- (IBAction)fieldEdited:(id)sender
{
	if (sender == nil)
		return;
	
	if (inspectedServer != nil)
	{
		[self updateInstToMatchInspector:inspectedServer];
		[self listUpdated];
	}
}

- (IBAction)selectAdjacentSession:(id)sender
{
	if ([sender tag] == 0) {
		[self selectPrevious:sender];
	} else {
		[self selectNext:sender];
	}
}

- (IBAction)selectNext:(id)sender
{
	if (_isFilteringSavedServers)
		return;
	
	if ([self.connectedServers count] == 0)
		return;

	CRDSession *inst = [self viewedServer];
	if (inst == nil)
	{
		[self.gui_serverList selectRow:1];
		[self autosizeUnifiedWindow];
		return;
	}

	if ([self.gui_tabView indexOfSelectedItem] == ([self.connectedServers count] - 1))
	{
		if (!CRDDrawerIsVisible(self.gui_serversDrawer))
			[self.gui_tabView selectItemAtIndex:0];

		[self.gui_serverList selectRow:1];
		[self autosizeUnifiedWindow];
		return;
	}

	// There is a Selected Server and we don't need to loop, select the next.
	if (!CRDDrawerIsVisible(self.gui_serversDrawer))
		[self.gui_tabView selectItemAtIndex:([self.gui_tabView indexOfSelectedItem]+1)];

	[self.gui_serverList selectRow:(2 + [self.connectedServers indexOfObjectIdenticalTo:inst])];
	[self autosizeUnifiedWindow];
	
}

- (IBAction)selectPrevious:(id)sender
{
	if (_isFilteringSavedServers)
		return;
	
	if ([self.connectedServers count] == 0)
		return;
	
	CRDSession *inst = [self viewedServer];
	if (inst == nil)
	{
		[self.gui_serverList selectRow:[self.connectedServers count]];
		[self autosizeUnifiedWindow];
		return;
	}
	
	if ( [self.gui_tabView indexOfSelectedItem] == 0 )
	{
		if (!CRDDrawerIsVisible(self.gui_serversDrawer))
			[self.gui_tabView selectItemAtIndex:([self.connectedServers count] - 1)];

		[self.gui_serverList selectRow:([self.connectedServers count])];
		[self autosizeUnifiedWindow];
		return;
	}
	// There is a Selected Server and we don't need to loop, select the prev.
	if (!CRDDrawerIsVisible(self.gui_serversDrawer))
		[self.gui_tabView selectItemAtIndex:([self.gui_tabView indexOfSelectedItem]-1)];

	[self.gui_serverList selectRow:( [self.connectedServers indexOfObjectIdenticalTo:inst] ) ];
	[self autosizeUnifiedWindow];
}

- (IBAction)showOpen:(id)sender
{
	NSOpenPanel *panel = [NSOpenPanel openPanel];
	[panel setAllowsMultipleSelection:YES];
	[panel setAllowedFileTypes:@[@"rdp", @"msrcincident"]];
	[panel runModal];
	
	NSMutableArray *filenames = [NSMutableArray array];
	
	for (NSURL* url in [panel URLs])
		[filenames addObject:[url path]];
	
	if ([filenames count] <= 0)
		return;
	
	[self.appDelegate application:[NSApplication sharedApplication] openFiles:filenames];
}

- (IBAction)toggleDrawer:(id)sender
{	
	[self toggleDrawer:sender visible:!CRDDrawerIsVisible(self.gui_serversDrawer)];
	[gui_toolbar validateVisibleItems];
}

- (IBAction)startFullscreen:(id)sender
{
	CRDLog(CRDLogLevelInfo, @"Starting Full Screen");
	
	if (self.displayMode == CRDDisplayFullscreen || ![self.connectedServers count] || ![self viewedServer])
		return;
	
	self.displayModeBeforeFullscreen = self.displayMode;
	
	// Create the fullscreen window then move the tabview into it	
	CRDSession *inst = [self viewedServer];
	CRDSessionView *serverView = [inst view];
	NSSize serverSize = [serverView bounds].size;	
	NSRect winRect = [[NSScreen mainScreen] frame];

	// If needed, reconnect the instance so that it can fill the screen
	if (CRDPreferenceIsEnabled(CRDPrefsReconnectIntoFullScreen) && ( fabs(serverSize.width - winRect.size.width) > 0.001 || fabs(serverSize.height - winRect.size.height) > 0.001) )
	{
		[self performSelectorInBackground:@selector(reconnectInstanceForEnteringFullscreen:) withObject:inst];
		return;
	}
	
	if ([self displayMode] != CRDDisplayUnified)
		[self startUnified:self];
	
    NSDisableScreenUpdates();
    [[self.gui_tabView retain] autorelease];
    [self.gui_tabView removeFromSuperviewWithoutNeedingDisplay];
    [self.gui_unifiedWindow display];
    NSEnableScreenUpdates();
	
	
	if (NSFullScreenModeApplicationPresentationOptions == nil)
	{
		NSRunAlertPanel(
			NSLocalizedString(@"Full screen is not supported on Mac OS X 10.5.", nil),
			NSLocalizedString(@"Please upgrade your OS.", nil),
			@"OK", @"", @"");
		return;
	}
	[self.gui_tabView enterFullScreenMode:[self.gui_unifiedWindow screen] withOptions:
            @{NSFullScreenModeAllScreens: @NO,
            NSFullScreenModeApplicationPresentationOptions: @(NSApplicationPresentationAutoHideDock | NSApplicationPresentationAutoHideMenuBar)}];
            @{NSFullScreenModeAllScreens: @NO,
            NSFullScreenModeApplicationPresentationOptions: @((NSApplicationPresentationAutoHideDock | NSApplicationPresentationAutoHideMenuBar))};

	self.gui_tabView.window.delegate = self;
	[[self.gui_tabView window] setAcceptsMouseMovedEvents:YES];
	
	NSEnableScreenUpdates(); // Disable may have been used for slightly deferred fullscreen (see completeConnection:)
    [self setDisplayMode:CRDDisplayFullscreen];
}

- (IBAction)endFullscreen:(id)sender
{
	CRDLog(CRDLogLevelInfo, @"Ending Full Screen");

	if ([self displayMode] != CRDDisplayFullscreen)
		return;
	    
	// Misc preparation
	[self setDisplayMode:CRDDisplayUnified];
	[self autosizeUnifiedWindowWithAnimation:NO];
	[[self.gui_tabView window] setAcceptsMouseMovedEvents:NO];
	
    [self.gui_tabView exitFullScreenModeWithOptions:nil];
	
	[self.gui_tabView setFrame:CRDRectFromSize([[self.gui_unifiedWindow contentView] frame].size)];
	
	[[self.gui_unifiedWindow contentView] addSubview:self.gui_tabView];	
	[self.gui_unifiedWindow display];
	self.gui_unifiedWindow.delegate = self;
	
	if (self.displayModeBeforeFullscreen == CRDDisplayWindowed)
		[self startWindowed:self];
		
	[self setDisplayMode:self.displayModeBeforeFullscreen];
	
	if (self.displayMode == CRDDisplayUnified)
		[self.gui_unifiedWindow makeKeyAndOrderFront:nil];
	else
		[[[self selectedServer] window] makeKeyAndOrderFront:nil];
}

// Toggles between full screen and previous state
- (IBAction)performFullScreen:(id)sender
{
	if ([self displayMode] == CRDDisplayFullscreen)
		[self endFullscreen:sender];
	else
		[self startFullscreen:sender];
}

// Toggles between Windowed and Unified modes
- (IBAction)performUnified:(id)sender
{
	if (self.displayMode == CRDDisplayUnified)
		[self startWindowed:sender];
	else if (self.displayMode == CRDDisplayWindowed)
		[self startUnified:sender];
	
	[gui_toolbar validateVisibleItems];
}

- (IBAction)startWindowed:(id)sender
{
	if (self.displayMode == CRDDisplayWindowed)
		return;
	
	[self setDisplayMode:CRDDisplayWindowed];
	windowCascadePoint = CRDWindowCascadeStart;
	
	if ([self.connectedServers count] == 0)
		return;
	
	[self.gui_tabView removeAllItems];
	
	for (CRDSession *inst in self.connectedServers)
		[self createWindowForInstance:inst];
		
	[self autosizeUnifiedWindow];
}

- (IBAction)startUnified:(id)sender
{
	if (self.displayMode == CRDDisplayUnified || self.displayMode == CRDDisplayFullscreen)
		return;
		
	[self setDisplayMode:CRDDisplayUnified];
	
	if (![self.connectedServers count])
		return;
	
	
	for (CRDSession *inst in self.connectedServers)
	{
		[inst destroyWindow];
		[inst createUnified:!CRDPreferenceIsEnabled(CRDPrefsScaleSessions) enclosure:[self.gui_tabView frame]];
		[self.gui_tabView addItem:inst];
	}	
	
	[self.gui_tabView selectLastItem:self];
	
	[self autosizeUnifiedWindowWithAnimation:(sender != self)];
}

- (IBAction)takeScreenCapture:(id)sender
{
	CRDSession *inst = [self viewedServer];
	
	if (inst == nil)
		return;
	
	NSString *desktopFolder = NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES)[0];
	
	NSString *path = CRDFindAvailableFileName(desktopFolder, [[inst label] stringByAppendingString:NSLocalizedString(@" Screen Capture", @"File name for screen captures")], @".png");
	
	[[inst view] writeScreenCaptureToFile:path];
}

- (IBAction)performQuickConnect:(id)sender
{
	NSString *address = [gui_quickConnect stringValue], *hostname;
	BOOL isConsoleSession = [[NSApp currentEvent] modifierFlags] | NSShiftKeyMask;
	NSInteger port;
		
	CRDSplitHostNameAndPort(address, &hostname, &port);
	
	
	// Check if hostname is already in saved servers...
	for (id server in self.savedServers)
		if ([[[server label] lowercaseString] isEqualToString:[hostname lowercaseString]]) {
			[self connectInstance:server];
			return;
		}
	
	
	CRDSession *newInst = [[[CRDSession alloc] initWithBaseConnection] autorelease];
	
//    newInst.label = hostname;
//    newInst.hostName = hostname;
//    newInst.port = port;
	[newInst setValue:hostname forKey:@"label"];
	[newInst setValue:hostname forKey:@"hostName"];
	[newInst setValue:@(port) forKey:@"port"];
    newInst.username = [[NSUserDefaults standardUserDefaults] valueForKey:@"CRDDefaultUserName"];
    newInst.password = [NSString stringWithUTF8String:keychain_get_password("Default Password", "Default Username")];
    newInst.domain = [[NSUserDefaults standardUserDefaults] valueForKey:@"CRDDefaultDomain"];

	if (isConsoleSession)
		[newInst setValue:@(isConsoleSession) forKey:@"consoleSession"];
	
	[self.connectedServers addObject:newInst];
	[self.gui_serverList deselectAll:self];
	[self listUpdated];
	[self connectInstance:newInst];

	if (!_isFilteringSavedServers)
		[self.gui_serverList selectRow:(1+[self.connectedServers indexOfObject:newInst])];
	
	
	NSMutableArray *recent = [NSMutableArray arrayWithArray:[userDefaults arrayForKey:CRDDefaultsQuickConnectServers]];
	
	if ([recent containsObject:address])
		[recent removeObject:address];
	
	if ([recent count] > 15)
		[recent removeLastObject];
	
	[recent insertObject:address atIndex:0];
	[userDefaults setObject:recent forKey:CRDDefaultsQuickConnectServers];
	[userDefaults synchronize];
	
	[gui_quickConnect setStringValue:@""];
}


- (IBAction)jumpToQuickConnect:(id)sender
{
	if (![[gui_quickConnect window] isKeyWindow])
		[[gui_quickConnect window] makeKeyAndOrderFront:[gui_quickConnect window]];

	if (![gui_quickConnect currentEditor] && [gui_quickConnect window])
		[[gui_quickConnect window] makeFirstResponder:gui_quickConnect];
}

- (IBAction)clearQuickConnectHistory:(id)sender
{
	[userDefaults setObject:@[] forKey:CRDDefaultsQuickConnectServers];
}

- (IBAction)helpForConnectionOptions:(id)sender
{
    [[NSHelpManager sharedHelpManager] openHelpAnchor:@"ConnectionOptions" inBook: [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleHelpBookName"]];
}

// Sent when a server in the Server menu is clicked on; either connects to the server or makes it visible
- (IBAction)performServerMenuItem:(id)sender
{
	CRDSession *inst = [sender representedObject];
	
	if (inst == nil)
		return;
	
	// Select the Activated Server in the Server List...
	[self.gui_serverList selectRow:([self.savedServers indexOfObject:inst] + 2 + [self.connectedServers count])];
		
	if ([self.connectedServers indexOfObject:inst] != NSNotFound)
	{
		// connected server, switch to it
		if (self.displayMode == CRDDisplayUnified)
		{
			[self.gui_tabView selectItem:inst];
			[self.gui_unifiedWindow makeFirstResponder:[inst view]];
			[self autosizeUnifiedWindow];
		}
		else if (self.displayMode == CRDDisplayWindowed)
		{
			[[inst window] makeKeyAndOrderFront:nil];
			[[inst window] makeFirstResponder:[inst view]];
		}
	}
	else
	{
		[self connectInstance:inst];
	}
}



- (IBAction)saveSelectedServer:(id)sender
{
	CRDSession *inst = [self selectedServer];
	
	if (inst == nil)
		return;
		
	NSSavePanel *savePanel = [NSSavePanel savePanel];
	[savePanel setTitle:NSLocalizedString(@"Save Server As", @"Save server dialog -> Title")];
	
	[savePanel setAllowedFileTypes:@[@"rdp"]];
	[savePanel setCanSelectHiddenExtension:YES];
	[savePanel setExtensionHidden:NO];
	
	if ([inst label] != nil)
		[savePanel setNameFieldStringValue:[[inst label] stringByAppendingPathExtension:@"rdp"]];
	
	[savePanel beginSheetModalForWindow:self.gui_unifiedWindow completionHandler:^(NSInteger result) {		
		if (result != NSOKButton)
			return;
			
		[inst writeToFile:[[savePanel URL] path] atomically:YES updateFilenames:NO];

	}];
}

- (IBAction)sortSavedServersAlphabetically:(id)sender
{
	[self sortSavedServersAlphabetically];
	[self storeSavedServerPositions];
	[self listUpdated];
}

- (IBAction)doNothing:(id)sender
{

}

- (IBAction)duplicateSelectedServer:(id)sender
{
	CRDSession *selectedServer = [self selectedServer];
	
	if (!selectedServer)
		return;
	
	NSUInteger serverIndex;
	
	if ( (serverIndex = [self.savedServers indexOfObject:selectedServer]) == NSNotFound)
		serverIndex = [self.savedServers count]-1;
	
	CRDSession *duplicate = [[selectedServer copy] autorelease];
	[duplicate setFilename:CRDFindAvailableFileName([AppController savedServersPath], [[duplicate label] stringByDeletingFileSystemCharacters], @".rdp")];
	[duplicate flushChangesToFile];
	[self addSavedServer:duplicate atIndex:serverIndex+1 select:YES];
}

- (IBAction)filterServers:(id)sender
{
	NSString *searchString = [gui_searchField stringValue];

	if (![searchString length])
	{
		[self setValue:@NO  forKey:@"isFilteringSavedServers"];
		[filteredServers removeAllObjects];
	}
	else
	{
		[self setValue:@YES forKey:@"isFilteringSavedServers"];
		[filteredServers removeAllObjects];
		
		NSString *searchCompareString = [NSString stringWithFormat:@"*%@*", [[searchString strip] lowercaseString]];

		[filteredServers addObjectsFromArray:self.connectedServers];
		[filteredServers addObjectsFromArray:self.savedServers];
		[filteredServers filterUsingPredicate:[NSPredicate predicateWithFormat:@"(label like[c] %@) OR (hostName like[c] %@) OR (username like[c] %@) OR (domain like[c] %@)",searchCompareString,searchCompareString,searchCompareString,searchCompareString]];
	}
	
	if (sender == gui_searchField)
	{	
		[self listUpdated];
				
		if ([filteredServers count])
			[self.gui_serverList selectRow:1];
	}
}

- (IBAction)jumpToFilter:(id)sender
{
	if (![[gui_searchField window] isKeyWindow])
		[[gui_searchField window] makeKeyAndOrderFront:[gui_searchField window]];
	
	if (![gui_searchField currentEditor] && [gui_searchField window])
		[[gui_searchField window] makeFirstResponder:gui_searchField];
}

- (IBAction)showServerInFinder:(id)sender
{
	CRDSession *selectedServer = [self selectedServer];
	
	if (selectedServer == nil)
		return;
		
	[[NSWorkspace sharedWorkspace] selectFile:[selectedServer filename] inFileViewerRootedAtPath:nil];
}

- (IBAction)visitDevelopment:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:CRDTracURL]];
}
- (IBAction)reportABug:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:CRDBugReportURL()]];
}
- (IBAction)visitHomepage:(id)sender
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:CRDHomePageURL]];
}
- (IBAction)visitSupportForums:(id)sender
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:CRDSupportForumsURL]];
}

// If in unified and with sessions, disconnects active. Otherwise, close the window. Similar to Safari 'Close Tab'
- (IBAction)closeSessionOrWindow:(id)sender
{
	NSWindow *visibleWindow = [NSApp mainWindow];
	
	if ([self.gui_tabView isInFullScreenMode])
		[self endFullscreen:sender];
	else if ( (visibleWindow == gui_preferencesWindow) || (visibleWindow == gui_inspector) )
		[visibleWindow orderOut:nil];
	else if (visibleWindow == self.gui_unifiedWindow)
	{
		if ((self.displayMode == CRDDisplayUnified) && [self.connectedServers count])
			[self performStop:nil];
		else 
			[self.gui_unifiedWindow orderOut:nil];
	}
	else if (self.displayMode == CRDDisplayWindowed)
		[visibleWindow performClose:nil];
	else
		[visibleWindow orderOut:nil];
}

#pragma mark -
#pragma mark NSToolbar Delegate methods

-(BOOL)validateToolbarItem:(NSToolbarItem *)toolbarItem
{
	NSInteger itemTag = [toolbarItem tag];
	CRDSession *inst = [self selectedServer];
	CRDSession *viewedInst = [self viewedServer];
	
	if (itemTag == 1 && (![self.gui_unifiedWindow isKeyWindow]))
		return NO;
	else if (itemTag == 3)
		return ([self.connectedServers count] > 0);
	else if ((itemTag  == 4) && (self.displayMode != CRDDisplayFullscreen))
	{
		NSString *label = (self.displayMode == CRDDisplayUnified) ? @"Windowed" : @"Unified";
		NSString *localizedLabel = (self.displayMode == CRDDisplayUnified) 
				? NSLocalizedString(@"Windowed", @"Display Mode toolbar item -> Windowed label")
				: NSLocalizedString(@"Unified", @"Display Mode toolbar item -> Unified label");
				
		[toolbarItem setImage:[NSImage imageNamed:label]];
		[toolbarItem setValue:localizedLabel forKey:@"label"];	
	}
	else if (itemTag == 5)
	{
		if (![self.gui_unifiedWindow isKeyWindow])
			return NO;
		
		NSString *label = ([inst status] == CRDConnectionConnecting) ? @"Stop" : @"Disconnect";
		NSString *localizedLabel = ([inst status] == CRDConnectionConnecting)
				? NSLocalizedString(@"Stop", @"Disconnect toolbar item -> Stop label")
				: NSLocalizedString(@"Disconnect", @"Disconnect toolbar item -> Disconnect label");
		
		[toolbarItem setImage:[NSImage imageNamed:label]];
		[toolbarItem setValue:localizedLabel forKey:@"label"];
		return ([inst status] == CRDConnectionConnecting) || ( (viewedInst != nil) && (self.displayMode == CRDDisplayUnified) );
	}
	else if (itemTag == 6 || itemTag == 7)
	{
		return ([self.connectedServers count] > 1);
	}
	return YES;
}
//Application delegates were here.
#pragma mark -
#pragma mark NSTableDataSource methods

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView
{
	if (_isFilteringSavedServers)
		return 1 + [filteredServers count];
	else
		return 2 + [self.connectedServers count] + [self.savedServers count];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
	if (_isFilteringSavedServers)
	{
		if (rowIndex == 0)
			return [filteredServersLabel attributedStringValue];
		
		return [self serverInstanceForRow:rowIndex]; 
	}

	if (rowIndex == 0)
		return [connectedServersLabel attributedStringValue];
	else if (rowIndex == [self.connectedServers count] + 1)
		return [savedServersLabel attributedStringValue];
	
	return [self serverInstanceForRow:rowIndex];
}

- (NSDragOperation)tableView:(NSTableView*)tv validateDrop:(id <NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)op
{	
	NSPasteboard *pb = [info draggingPasteboard];
	NSString *pbDataType = [self.gui_serverList pasteboardDataType:pb];
	
	if (_isFilteringSavedServers)
		return NO;

	if ([pbDataType isEqualToString:CRDRowIndexPboardType])
		return NSDragOperationMove;
	
	if ([pbDataType isEqualToString:NSFilenamesPboardType])
	{
		NSArray *files = [[info draggingPasteboard] propertyListForType:NSFilenamesPboardType];
		NSArray *rdpFiles = CRDFilterFilesByType(files, @[@"rdp"]);
		return ([rdpFiles count] > 0) ? NSDragOperationCopy : NSDragOperationNone;
	}
	
	return NSDragOperationNone;
}

- (BOOL)tableView:(NSTableView *)aTableView acceptDrop:(id <NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)operation
{
	NSPasteboard *pb = [info draggingPasteboard];
	NSString *pbDataType = [self.gui_serverList pasteboardDataType:pb];
	int newRow = -1;
	
	if (_isFilteringSavedServers)
		return NO;
	
	if ([pbDataType isEqualToString:CRDRowIndexPboardType])
	{
		newRow = row;
	}
	else if ([pbDataType isEqualToString:NSFilenamesPboardType])
	{
		// External drag, load all rdp files passed
		NSArray *files = [[info draggingPasteboard] propertyListForType:NSFilenamesPboardType];
		NSArray *rdpFiles = CRDFilterFilesByType(files, @[@"rdp"]);
		
		CRDSession *inst;
		NSUInteger insertIndex = [self.savedServers indexOfObject:[self serverInstanceForRow:row]];
		
		if (insertIndex == NSNotFound)
			insertIndex = [self.savedServers count];
		
		for (NSString *file in rdpFiles)
		{
			inst = [[CRDSession alloc] initWithPath:file];
			
			if (inst != nil)
			{
				[inst setFilename:CRDFindAvailableFileName([AppController savedServersPath], [inst label], @".rdp")];
				[self addSavedServer:inst atIndex:insertIndex];
			}
			
			[inst release];
		}
		
		return YES;
	}
	
	if ([info draggingSource] == self.gui_serverList)
	{
		[self reinsertHeldSavedServer:newRow];
		return YES;
	}

	return NO;
}

- (BOOL)tableView:(NSTableView *)aTableView writeRowsWithIndexes:(NSIndexSet *)rowIndexes toPasteboard:(NSPasteboard*)pboard
{
	CRDSession *inst = [self serverInstanceForRow:[rowIndexes firstIndex]];
	
	if (inst == nil)
		return NO;
	
	int row = [rowIndexes firstIndex];
	
	[pboard declareTypes:@[CRDRowIndexPboardType, NSFilenamesPboardType] owner:nil];
	[pboard setPropertyList:@[[inst filename]] forType:NSFilenamesPboardType];
	[pboard setString:[NSString stringWithFormat:@"%d", row] forType:CRDRowIndexPboardType];

	return YES;
}

- (BOOL)tableView:(NSTableView *)aTableView canDragRow:(NSUInteger)rowIndex
{	
	if (_isFilteringSavedServers)
		return [filteredServers indexOfObject:[self serverInstanceForRow:rowIndex]] != NSNotFound;
	else
		return [self.savedServers indexOfObject:[self serverInstanceForRow:rowIndex]] != NSNotFound;
}

- (BOOL)tableView:(NSTableView *)aTableView canDropAboveRow:(NSUInteger)rowIndex
{
	if (_isFilteringSavedServers)
		return NO;
	else
		return rowIndex >= 2 + [self.connectedServers count];
}


#pragma mark NSTableView delegate

- (void)tableViewSelectionDidChange:(NSNotification *)aNotification
{
    TRACE_FUNC;
	NSInteger selectedRow = [self.gui_serverList selectedRow];
	CRDSession *inst = [self selectedServer];
	
	CRDLog(CRDLogLevelDebug,@"NSTableView Delegate - Selection Changed Server: %@ Row Index: %i", [inst label], selectedRow);
	
	[self validateControls];
	
	// If there's no selection, clear the inspector
	if (selectedRow < 1 || (selectedRow == [self.connectedServers count] + 1))
	{
		[self setInspectorSettings:nil];	
		inspectedServer = nil;
		[self setInspectorEnabled:NO];
		return;
	}
    else
    {
        [self updateInstToMatchInspector:inspectedServer];
        [self saveInspectedServer];
    }
	
	if (self.appDelegate.appIsTerminating)
	{
		[self setInspectorEnabled:NO];
		return;
	}

	inspectedServer = inst;
	[self setInspectorSettings:inst];
	[self setInspectorEnabled:YES];
	
    
    // If we're not filtering servers, and the new selection is an active session and this wasn't called from self, change the selected view
	
	if (_isFilteringSavedServers || !inst || !aNotification)
		return;
	
    if (([inst status] == CRDConnectionConnected) && ([self.gui_tabView indexOfItem:inst] != NSNotFound)) 
    {			
        [self.gui_tabView selectItem:inspectedServer];
        [self.gui_unifiedWindow makeFirstResponder:[[self viewedServer] view]];
        [self autosizeUnifiedWindow];
    }
    
    if ( ([inst status] == CRDConnectionDisconnecting || [inst status] == CRDConnectionClosed) && (self.displayMode == CRDDisplayFullscreen) )
        [self selectNext:self];
}

- (BOOL)tableView:(NSTableView *)aTableView shouldSelectRow:(NSInteger)rowIndex
{
	if (_isFilteringSavedServers)
		return rowIndex >= 1;
	else
		return (rowIndex >= 1) && (rowIndex != [self.connectedServers count] + 1);
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row
{	
	if (_isFilteringSavedServers)
	{
		if (!row || (row == [filteredServers count] + 1) )
			return [filteredServersLabel cellSize].height;
		
		return [[[self serverInstanceForRow:row] cellRepresentation] cellSize].height;			
	}

	if (!row || row == [self.connectedServers count] + 1)
		return [connectedServersLabel cellSize].height;
	
	return [[[self serverInstanceForRow:row] cellRepresentation] cellSize].height;	
}

- (id)tableColumn:(NSTableColumn *)column inTableView:(NSTableView *)tableView dataCellForRow:(int)row
{
	if (_isFilteringSavedServers)
	{
		if (row == 0)
			return filteredServersLabel;
		
		return [[self serverInstanceForRow:row] cellRepresentation];
	}
	
	if (row == 0)
		return connectedServersLabel;
	else if (row == [self.connectedServers count] + 1)
		return savedServersLabel;
	
	return [[self serverInstanceForRow:row] cellRepresentation];
}

- (NSString *)tableView:(NSTableView *)tableView typeSelectStringForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	return [[self serverInstanceForRow:row] label];
}

#pragma mark Other table view related
- (void)cellNeedsDisplay:(NSCell *)cell
{
	[self.gui_serverList setNeedsDisplay:YES];
}


#pragma mark -
#pragma mark NSWindow delegate

- (void)windowWillClose:(NSNotification *)sender
{
	if ([sender object] == gui_inspector)
	{
		[self fieldEdited:nil];
		[self saveInspectedServer];

		[self validateControls];
		
		if ( ([self viewedServer] == nil) && CRDDrawerIsVisible(self.gui_serversDrawer))
			[self.gui_unifiedWindow makeFirstResponder:self.gui_serverList];
	}
}

- (void)windowDidBecomeKey:(NSNotification *)sender
{
	if ( (([sender object] == self.gui_unifiedWindow) && (self.displayMode == CRDDisplayUnified)) ||  (self.displayMode == CRDDisplayFullscreen) )
	{
		[[self viewedServer] announceNewClipboardData];
	}
}

- (void)windowDidResignKey:(NSNotification *)sender
{
	if ( (([sender object] == self.gui_unifiedWindow) && (self.displayMode == CRDDisplayUnified)) || (self.displayMode == CRDDisplayFullscreen) )
	{
		[[self viewedServer] requestRemoteClipboardData];
	}
}

// Implement unified window 'snap' to real size
- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)proposedFrameSize
{
	if ( (sender == self.gui_unifiedWindow) && (self.displayMode == CRDDisplayUnified) && ([self viewedServer] != nil) )
	{
		NSSize realSize = [[[self viewedServer] view] bounds].size;
		realSize.height += [self.gui_unifiedWindow frame].size.height - [[self.gui_unifiedWindow contentView] frame].size.height;
		if ( (realSize.width-proposedFrameSize.width <= CRDWindowSnapSize) && (realSize.height-proposedFrameSize.height <= CRDWindowSnapSize) )
		{
			return realSize;	
		}
	}
	
	return proposedFrameSize;
}
- (void)windowDidMove:(NSNotification *)window
{
	CRDSession *inst = [self viewedServer];
	
	if (!inst)
	{
		[self.gui_unifiedWindow saveFrameUsingName:@"UnifiedWindowFrame"];	
	}
	CRDLog(CRDLogLevelDebug, @"Window Did Move; Origin-x: %f Origin-y: %f",[self.gui_unifiedWindow frame].origin.x, [self.gui_unifiedWindow frame].origin.y);
}

- (void)windowDidResize:(NSNotification *)notification
{
	CRDSession *inst = [self viewedServer];
	
	if (!inst)
	{
		[self.gui_unifiedWindow saveFrameUsingName:@"UnifiedWindowFrame"];	
	}

	CRDLog(CRDLogLevelDebug, @"Window Did Resize; Width: %f Height: %f",[self.gui_unifiedWindow frame].size.width, [self.gui_unifiedWindow frame].size.height);
}

#pragma mark -
#pragma mark NSSearchField Delegate

-(BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)commandSelector
{	
	if ( (control != gui_searchField) || ![filteredServers count])
		return NO;
	
	if (commandSelector == @selector(insertNewline:))
	{
		[self connect:nil];
		[gui_searchField setStringValue:@""];
		return NO;
	}
	
	if (commandSelector == @selector(moveUp:))
	{
		if ([self.gui_serverList selectedRow] > 1) 
			[self.gui_serverList selectRow:([self.gui_serverList selectedRow] - 1)];
		else
			[self.gui_serverList selectRow:([self.gui_serverList numberOfRows] - 1)];
		
		return YES;
	}
	
	if (commandSelector == @selector(moveDown:))
	{
		if ( [self.gui_serverList selectedRow] < ([self.gui_serverList numberOfRows] - 1) ) 
			[self.gui_serverList selectRow:([self.gui_serverList selectedRow] + 1)];
		else
			[self.gui_serverList selectRow:1];

		return YES;
	}

	return NO;
}


#pragma mark -
#pragma mark Managing connected servers

// Starting point to connect to a instance
- (void)connectInstance:(CRDSession *)inst
{
	if (!inst)
		return;
	
	if ([inst status] == CRDConnectionConnecting || [inst status] == CRDConnectionDisconnecting)
		return;
	
	if ([inst status] == CRDConnectionConnected)
		[self disconnectInstance:inst];
		
	[NSThread detachNewThreadSelector:@selector(connectAsync:) toTarget:self withObject:inst];
}

// Assures that the passed instance is disconnected and removed from view. Main thread only.
- (void)disconnectInstance:(CRDSession *)inst
{
	if (!inst || [self.connectedServers indexOfObjectIdenticalTo:inst] == NSNotFound)
		return;
		
	if (self.displayMode != CRDDisplayWindowed)
		[self.gui_tabView removeItem:inst];
	
	if ([inst status] == CRDConnectionConnected)
		[inst disconnect];
		
	if ([[inst valueForKey:@"temporarilyFullscreen"] boolValue])
	{
		[inst setValue:@NO forKey:@"fullscreen"];
		[inst setValue:@NO forKey:@"temporarilyFullscreen"];
	}
	

	[[inst retain] autorelease];
	[self.connectedServers removeObject:inst];
	
	if ([inst isTemporary])
	{
		// If temporary and in the CoRD servers directory, delete it
		if ([[[inst filename] stringByDeletingLastPathComponent] isEqualToString:[AppController savedServersPath]])
		{
			[inst clearKeychainData];
			[[NSFileManager defaultManager] removeItemAtPath:[inst filename] error:NULL];
		}
		
		if ([inst isEqualTo:[self selectedServer]])
			[self.gui_serverList deselectAll:self];
	}
	else
	{
		// Move to saved servers if not already there
		if (![inst filename])
		{
			NSString *path = CRDFindAvailableFileName([AppController savedServersPath], [[inst label] stringByDeletingFileSystemCharacters], @".rdp");

			[inst writeToFile:path atomically:YES updateFilenames:YES];
		}
		
		// Re-insert into saved server list
		int preferredRow = MIN([self.savedServers count], [[inst valueForKey:@"preferredRowIndex"] intValue]);
		[self addSavedServer:inst atIndex:preferredRow select:YES];
	}

	[self listUpdated];
		
	if ((self.displayMode == CRDDisplayFullscreen) && ![self.gui_tabView numberOfItems])
	{
		CRDLog(CRDLogLevelInfo, @"Disconnecting while in Full Screen");
		[self autosizeUnifiedWindowWithAnimation:YES];
		[self endFullscreen:self];
	}
	else if (self.displayMode == CRDDisplayUnified)
	{
		[self autosizeUnifiedWindowWithAnimation:YES];
		
		if (![self viewedServer] && CRDDrawerIsVisible(self.gui_serversDrawer))
			[self.gui_unifiedWindow makeFirstResponder:self.gui_serverList];
	}
	else if (self.displayMode == CRDDisplayWindowed)
	{
		if (![self.connectedServers count] && ![self.gui_unifiedWindow isVisible])
			[self.gui_unifiedWindow makeKeyAndOrderFront:nil];
	}
	
	if (![inst isEqualTo:[self selectedServer]] || ![self.gui_unifiedWindow isKeyWindow])
	{
		[NSApp requestUserAttention:NSInformationalRequest];
	}
	
}

- (void)cancelConnectingInstance:(CRDSession *)inst
{
	if ([inst status] != CRDConnectionConnecting)
		return;
	
	[inst cancelConnection];
	
	[self.gui_serverList deselectAll:nil];
	[self.connectedServers removeObject:inst];
	inspectedServer = nil;
	[self listUpdated];
}

- (void)reconnectInstanceForEnteringFullscreen:(CRDSession*)inst
{
    @autoreleasepool {
        CRDLog(CRDLogLevelInfo, @"Reconnecting for Full Screen...");
	
        [self performSelectorOnMainThread:@selector(disconnectInstance:) withObject:inst waitUntilDone:YES];

        while ([inst status] != CRDConnectionClosed)
            usleep(1000);

        [inst setValue:@YES forKey:@"fullscreen"];
        [inst setValue:@YES forKey:@"temporarilyFullscreen"];
	
        [self performSelectorOnMainThread:@selector(connectInstance:) withObject:inst waitUntilDone:YES];
    }
}

#pragma mark -
#pragma mark Support for dragging of saved servers

- (void)holdSavedServer:(NSInteger)row
{
	CRDSession *inst = [self serverInstanceForRow:row];
	NSUInteger index = [self.savedServers indexOfObjectIdenticalTo:inst];
	
	if (!inst || (index == NSNotFound))
		return;
	
	dumpedInstanceWasSelected = [self selectedServer] == inst;
	dumpedInstance = [inst retain];
	[inst setValue:@(index) forKey:@"preferredRowIndex"];
	
	[self.savedServers removeObject:inst];
}

- (void)reinsertHeldSavedServer:(NSInteger)intoRow
{
	NSUInteger index = (intoRow == -1) ? [[dumpedInstance valueForKey:@"preferredRowIndex"] intValue] : (intoRow - 2 - [self.connectedServers count]);
	[self addSavedServer:dumpedInstance atIndex:index select:dumpedInstanceWasSelected];
	[dumpedInstance setValue:@(index) forKey:@"preferredRowIndex"];
}

#pragma mark -
#pragma mark Other

- (BOOL)mainWindowIsFocused
{
	return [self.gui_unifiedWindow isMainWindow] && [self.gui_unifiedWindow isKeyWindow];
}

// xxx probably should be private
- (CRDSession *)serverInstanceForRow:(int)row
{
	NSUInteger connectedCount = [self.connectedServers count], savedCount = [self.savedServers count], filteredCount = [filteredServers count];
	
	if (_isFilteringSavedServers)
	{
		if ( (row <= 0) || (row > 1 + filteredCount) )
			return nil;
		if (row <= filteredCount)
			return filteredServers[(row-1)];
		
		return nil;
	}

	if ( (row <= 0) || (row == 1+connectedCount) || (row > 1 + connectedCount + savedCount) )
		return nil;
	if (row <= connectedCount)
		return self.connectedServers[row-1];
	
	return self.savedServers[row - connectedCount - 2];
}

- (void)openUrl:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent
{	
	// rdp://user:password@host:port/Domain

	NSURL *url = [NSURL URLWithString:[[event paramDescriptorForKeyword:keyDirectObject] stringValue]];
	
	if (![url host])
		return;

	// Check if hostname is already in saved servers...
	for (id server in self.savedServers)
		if ([[[server label] lowercaseString] isEqualToString:[[url host] lowercaseString]]) {
			[self connectInstance:server];
			return;
		}
	
	CRDSession *session = [[[CRDSession alloc] initWithBaseConnection] autorelease];

	[session setValue:[url host] forKey:@"hostName"];
	[session setValue:[url host] forKey:@"label"];

	if ([url port] != nil)
		[session setValue:[url port] forKey:@"port"];
	if ([url user] != nil)
		[session setValue:[[url user] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] forKey:@"username"];
	if ([url password] != nil)
		[session setValue:[[url password] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] forKey:@"password"];
	if ([url path] != nil)
		[session setValue:[[url path] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]] forKey:@"domain"];
	if ([url query] != nil)
		[self parseUrlQueryString:[url query] forSession:session];
	
	[self.connectedServers addObject:session];
	[self.gui_serverList deselectAll:self];
	[self listUpdated];
	[self connectInstance:session];
}


- (void)updateInspectorToMatchSelectedServer
{
	[self setInspectorSettings:[self selectedServer]];
}


#pragma mark -
#pragma mark Accessors

- (NSWindow *)unifiedWindow
{
	return self.gui_unifiedWindow;
}

// Returns the connected server that the tab view is displaying
- (CRDSession *)viewedServer
{
	if (self.displayMode == CRDDisplayUnified || self.displayMode == CRDDisplayFullscreen)
	{
		CRDSession *selectedItem = [self.gui_tabView selectedItem];

		if (selectedItem == nil)
			return nil;
	
		for (CRDSession *inst in self.connectedServers)
			if (inst == selectedItem)
				return inst;
	}
	else // windowed mode
	{
		for (CRDSession *inst in self.connectedServers)
			if ([[inst window] isMainWindow])
				return inst;
	}
	
	return nil;
}

- (CRDSession *)selectedServer
{
	if (!CRDDrawerIsVisible(self.gui_serversDrawer))
		return nil;
	else
		return [self serverInstanceForRow:[self.gui_serverList selectedRow]];
}

#pragma mark -
#pragma mark KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if ([keyPath isEqualToString:@"label"])
	{
		NSString *newLabel = change[NSKeyValueChangeNewKey];
		if ( ([newLabel length] > 0) && ![newLabel isEqual:change[NSKeyValueChangeOldKey]] && ![object isTemporary])
		{
			NSString *newPath = CRDFindAvailableFileName([AppController savedServersPath], [newLabel stringByDeletingFileSystemCharacters], @".rdp");
			
			[[NSFileManager defaultManager] moveItemAtPath:[object filename] toPath:newPath error:NULL];
			[object setFilename:newPath];
		}
	}
	else if ([keyPath isEqualToString:CRDPrefsScaleSessions])
	{
	
	
	}
	else if ([keyPath isEqualToString:CRDPrefsMinimalisticServerList])
	{
		[[NSNotificationCenter defaultCenter] postNotificationName:CRDMinimalViewDidChangeNotification object:nil];
	
		[self.gui_serverList noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [self.gui_serverList numberOfRows])]];
	}
}

- (void)listUpdated
{
	if ([userDefaults boolForKey:@"keepServersSortedAlphabetically"])
		[self sortSavedServersAlphabetically];

	// Remove all subvies of self.gui_serverList, to make sure that no progess indicators are out-of-place
	for (NSView *subview in [[[self.gui_serverList subviews] copy] autorelease])
		[subview removeFromSuperviewWithoutNeedingDisplay];

	[self.gui_serverList noteNumberOfRowsChanged];

	if ([self serverInstanceForRow:[self.gui_serverList selectedRow]] == nil)
		[self.gui_serverList selectRow:-1];

	for (NSMenuItem *hotkeyMenuItem in [[gui_hotkey menu] itemArray])
		[hotkeyMenuItem setEnabled:YES];



	// Update servers menu items
	int separatorIndex = [gui_serversMenu indexOfItemWithTag:SERVERS_SEPARATOR_TAG], i;

	while ( (i = [gui_serversMenu numberOfItems]-1) > separatorIndex)
		[gui_serversMenu removeItemAtIndex:i];

	NSMenuItem *menuItem;
	CRDSession *inst;

	for (inst in self.connectedServers)
	{
		menuItem = [[NSMenuItem alloc] initWithTitle:[inst label] action:@selector(performServerMenuItem:) keyEquivalent:[NSString stringWithFormat:@"%ld", [inst hotkey]]];
		[menuItem setKeyEquivalentModifierMask:NSCommandKeyMask];
		[menuItem setRepresentedObject:inst];
		[gui_serversMenu addItem:menuItem];
		[menuItem release];

		if ([inst hotkey] != -1)
			[[[gui_hotkey menu] itemAtIndex:[inst hotkey]] setEnabled:NO];
	}

	for (inst in self.savedServers)
	{
		menuItem = [[NSMenuItem alloc] initWithTitle:[inst label] action:@selector(performServerMenuItem:) keyEquivalent:[NSString stringWithFormat:@"%ld", [inst hotkey]]];
		[menuItem setKeyEquivalentModifierMask:NSCommandKeyMask];
		[menuItem setRepresentedObject:inst];
		[gui_serversMenu addItem:menuItem];
		[menuItem release];

		if ([inst hotkey] != -1)
			[[[gui_hotkey menu] itemAtIndex:[inst hotkey]] setEnabled:NO];
	}
}

- (void)storeSavedServerPositions
{
	for (CRDSession *inst in self.savedServers)
		[inst setValue:@([self.savedServers indexOfObject:inst]) forKey:@"preferredRowIndex"];
}

// Validates non-menu and toolbar interface items
- (void)validateControls
{
	CRDSession *inst = [self selectedServer];

	[gui_connectButton setEnabled:(inst != nil && [inst status] == CRDConnectionClosed)];
	[gui_inspectorButton setEnabled:(inst != nil)];
}

@end

#pragma mark -

@implementation AppController (Private)

#pragma mark -
#pragma mark General

- (void)setInspectorEnabled:(BOOL)enabled
{
	[self toggleControlsEnabledInView:[gui_inspector contentView] enabled:enabled];
	[gui_inspector display];
}

- (void)createWindowForInstance:(CRDSession *)inst
{
	[self createWindowForInstance:inst asFullscreen:NO];
}

- (void)createWindowForInstance:(CRDSession *)inst asFullscreen:(BOOL)fullscreen
{
	[inst createWindow:!CRDPreferenceIsEnabled(CRDPrefsScaleSessions)];
	
	NSWindow *window = [inst window];
	windowCascadePoint = [window cascadeTopLeftFromPoint:windowCascadePoint];
	[window makeFirstResponder:[inst view]];
	[window makeKeyAndOrderFront:self];
}

- (void)saveInspectedServer
{
	if ([inspectedServer modified] && ![inspectedServer isTemporary])
		[inspectedServer flushChangesToFile];
}

// Enables/disables GUI controls recursively
- (void)toggleControlsEnabledInView:(NSView *)view enabled:(BOOL)enabled
{
	if ([view isKindOfClass:[NSControl class]])
	{
		if ([view isKindOfClass:[NSTextField class]] && ![(NSTextField *)view drawsBackground])
			[(NSTextField *)view setTextColor:(enabled ? [NSColor blackColor] : [NSColor disabledControlTextColor])];
		
		[(NSControl *)view setEnabled:enabled];
	}
	else
	{
		for (id subview in [view subviews])
			[self toggleControlsEnabledInView:subview enabled:enabled];
	}
}

- (void)parseUrlQueryString:(NSString *)queryString forSession:(CRDSession *)session
{	
	NSArray *booleanParamters = @[@"consoleSession",@"fullscreen",@"windowDrags",@"drawDesktop",@"windowAnimation",@"themes",@"fontSmoothing",@"savePassword",@"forwardDisks",@"forwardPrinters"];
	NSArray *stringParameters = @[@"screenDepth",@"screenWidth",@"screenHeight",@"fowardAudio",@"label"];
	
	for (id setting in [queryString componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"&:"]])
	{
		NSString *key = [setting componentsSeparatedByString:@"="][0];
		
		if ([stringParameters containsObject:key])
			[session setValue:[setting componentsSeparatedByString:@"="][1] forKey:key];
		else if ([booleanParamters containsObject:key])
			[session setValue:@([[setting componentsSeparatedByString:@"="][1] boolValue]) forKey:key];
		else
			CRDLog(CRDLogLevelError, @"Invalid Parameter: %@", setting);
	}
}

#pragma mark -
#pragma mark Managing inspector settings

// Sets all of the values in the passed CRDSession to match the inspector
- (void)updateInstToMatchInspector:(CRDSession *)inst
{
	if (![[inst retain] autorelease])
		return;
	
	// Checkboxes
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_displayDragging)		forKey:@"windowDrags"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_drawDesktop)			forKey:@"drawDesktop"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_enableAnimations)		forKey:@"windowAnimation"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_enableThemes)			forKey:@"themes"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_enableFontSmoothing)	forKey:@"fontSmoothing"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_savePassword)			forKey:@"savePassword"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_forwardDisks)			forKey:@"forwardDisks"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_forwardPrinters)		forKey:@"forwardPrinters"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_consoleSession)		forKey:@"consoleSession"];
	
	// Text fields
	[inst setValue:[gui_label stringValue]		forKey:@"label"];
	[inst setValue:[gui_username stringValue]	forKey:@"username"];
	[inst setValue:[gui_domain stringValue]		forKey:@"domain"];	
	[inst setValue:[gui_password stringValue]	forKey:@"password"];
	
	// Host
	NSInteger port;
	NSString *s;
	CRDSplitHostNameAndPort([gui_host stringValue], &s, &port);
	[inst setValue:@(port) forKey:@"port"];
	[inst setValue:s forKey:@"hostName"];
	
	// Hotkey
	NSInteger hotkey;
	if ( ([gui_hotkey indexOfSelectedItem] > 9) || ([gui_hotkey indexOfSelectedItem] == 0) )
		hotkey = -1;
	else
	{
		hotkey = [gui_hotkey indexOfSelectedItem];
		[[gui_hotkey itemAtIndex:hotkey] setEnabled:NO];
	}
	[inst setValue:@(hotkey) forKey:@"hotkey"];

	// Audio Forwarding
	if ([[gui_forwardAudio selectedCell] tag] >= 0  && [[gui_forwardAudio selectedCell] tag] < 3)
		[inst setValue:@([[gui_forwardAudio selectedCell] tag]) forKey:@"forwardAudio"];
	else
		[inst setValue:@0 forKey:@"forwardAudio"];

	// Screen depth
	[inst setValue:@(([gui_colorCount indexOfSelectedItem] +1 ) * 8) forKey:@"screenDepth"];
			
	// Screen resolution
	NSInteger width = 0, height = 0;
	NSString *resolutionString = [[gui_screenResolution selectedItem] title];
	BOOL isFullscreen = CRDResolutionStringIsFullscreen(resolutionString);
	
	[inst setValue:@(isFullscreen) forKey:@"fullscreen"];

	if (!isFullscreen)
		CRDSplitResolutionString(resolutionString, &width, &height);
	
	[inst setValue:@(width) forKey:@"screenWidth"];
	[inst setValue:@(height) forKey:@"screenHeight"];
	
	[self saveInspectedServer];
	
	[gui_inspector setTitle:[NSLocalizedString(@"Inspector: ", @"Inspector -> Enabled title") stringByAppendingString:[inst label]]];
}

// Sets the inspector options to match an CRDSession
- (void)setInspectorSettings:(CRDSession *)newSettings
{
	#define BUTTON_STATE_FOR_KEY(k) CRDButtonState([[newSettings valueForKey:(k)] boolValue])
	
	if (newSettings == nil)
	{
		[gui_inspector setTitle:NSLocalizedString(@"Inspector: No Server Selected", @"Inspector -> Disabled title")];
		newSettings = [[[CRDSession alloc] init] autorelease];
	}
	else
	{
		[gui_inspector setTitle:[NSLocalizedString(@"Inspector: ", @"Inspector -> Enabled title") stringByAppendingString:[newSettings label]]];
	}
		
	// All checkboxes 
	[gui_displayDragging     setState:BUTTON_STATE_FOR_KEY(@"windowDrags")];
	[gui_drawDesktop         setState:BUTTON_STATE_FOR_KEY(@"drawDesktop")];
	[gui_enableAnimations    setState:BUTTON_STATE_FOR_KEY(@"windowAnimation")];
	[gui_enableThemes        setState:BUTTON_STATE_FOR_KEY(@"themes")];
	[gui_enableFontSmoothing setState:BUTTON_STATE_FOR_KEY(@"fontSmoothing")];
	[gui_savePassword        setState:BUTTON_STATE_FOR_KEY(@"savePassword")];
	[gui_forwardDisks        setState:BUTTON_STATE_FOR_KEY(@"forwardDisks")];
	[gui_forwardPrinters     setState:BUTTON_STATE_FOR_KEY(@"forwardPrinters")];
	[gui_consoleSession      setState:BUTTON_STATE_FOR_KEY(@"consoleSession")];
	
	// Most of the text fields
	[gui_label    setStringValue:[newSettings valueForKey:@"label"]];
	[gui_username setStringValue:[newSettings valueForKey:@"username"]];
	[gui_domain   setStringValue:[newSettings valueForKey:@"domain"]];
	[gui_password setStringValue:[newSettings valueForKey:@"password"]];
	
	// Host
	int port = [[newSettings valueForKey:@"port"] intValue];
	NSString *host = [newSettings valueForKey:@"hostName"];
	[gui_host setStringValue:CRDJoinHostNameAndPort(host, port)];
	
	// Hotkey
	int hotkey = [[newSettings valueForKey:@"hotkey"] intValue];
	if (hotkey > 0 && hotkey <= 9)
		[gui_hotkey selectItemAtIndex:hotkey];
	else
		[gui_hotkey selectItemAtIndex:0];
	
	// Audio Forwarding Matrix
	[gui_forwardAudio selectCellWithTag:[[newSettings valueForKey:@"forwardAudio"] intValue]];
	
	// Color depth
	int colorDepth = [[newSettings valueForKey:@"screenDepth"] intValue];
	[gui_colorCount selectItemAtIndex:(colorDepth/8-1)];
	
	// Screen resolution
	[gui_screenResolution selectItemAtIndex:-1];
	if ([[newSettings valueForKey:@"fullscreen"] boolValue])
	{
		for (NSMenuItem *menuItem in [gui_screenResolution itemArray])
			if (CRDResolutionStringIsFullscreen([menuItem title]))
			{
				[gui_screenResolution selectItem:menuItem];
				break;
			}
	}
	else 
	{
		NSInteger screenWidth = [[newSettings valueForKey:@"screenWidth"] integerValue];
		NSInteger screenHeight = [[newSettings valueForKey:@"screenHeight"] integerValue]; 
		if (!screenWidth || !screenHeight) {
			screenWidth = CRDDefaultScreenWidth;
			screenHeight = CRDDefaultScreenHeight;
		}
		// If the user opens an .rdc file with a resolution that the user doesn't have, nothing will be selected. We're not adding it to the array controller, because we don't want resolutions from .rdc files to be persistent in CoRD prefs
		NSString *resolutionLabel = [NSString stringWithFormat:@"%ldx%ld", screenWidth, screenHeight];
		[gui_screenResolution selectItemWithTitle:resolutionLabel];
	}
	
	#undef BUTTON_STATE_FOR_KEY
}

- (void)toggleDrawer:(id)sender visible:(BOOL)visible
{
	if (visible)
		[self.gui_serversDrawer open];
	else
		[self.gui_serversDrawer close];
	
	[gui_toolbar validateVisibleItems];
}


#pragma mark -
#pragma mark Connecting to servers asynchronously

// Should only be called by connectInstance in the connection thread
- (void)connectAsync:(CRDSession *)inst
{
	@autoreleasepool {
        if ([[inst valueForKey:@"fullscreen"] boolValue])
        {
            NSSize screenSize = [[self.gui_unifiedWindow screen] frame].size;
            [inst setValue:@((NSInteger)screenSize.width) forKey:@"screenWidth"];
            [inst setValue:@((NSInteger)screenSize.height) forKey:@"screenHeight"];
        }
	
        BOOL connected = [inst connect];
	
        [self performSelectorOnMainThread:@selector(completeConnection:) withObject:inst waitUntilDone:NO];
					
        if (connected)
            [inst runConnectionRunLoop]; // this will block until the session is finished
		
        if ([inst status] == CRDConnectionConnected)
            [self performSelectorOnMainThread:@selector(disconnectInstance:) withObject:inst waitUntilDone:YES];
	}
}

// Called in main thread by connectAsync
- (void)completeConnection:(CRDSession *)inst
{	
	if ([inst status] == CRDConnectionConnected)
	{
		// Move it into the proper list
		if (![inst isTemporary])
		{
			[[inst retain] autorelease];
			[self.savedServers removeObject:inst];
			[self.connectedServers addObject:inst];
		}
		
		if (!_isFilteringSavedServers && ([self.connectedServers indexOfObject:inst] != NSNotFound) )
			[self.gui_serverList selectRow:(1 + [self.connectedServers indexOfObject:inst])];
		
		[self listUpdated];
		
		// Create gui
		if ( (self.displayMode == CRDDisplayUnified) || (self.displayMode == CRDDisplayFullscreen) )
		{
			[inst createUnified:!CRDPreferenceIsEnabled(CRDPrefsScaleSessions) enclosure:[self.gui_tabView frame]];
			[self.gui_tabView addItem:inst];
			[self.gui_tabView selectLastItem:self];
			[self.gui_unifiedWindow makeFirstResponder:[inst view]];
		}
		else
		{
			[self createWindowForInstance:inst];
		}
		
		
		if ([[inst valueForKey:@"fullscreen"] boolValue] || [[inst valueForKey:@"temporarilyFullscreen"] boolValue])
		{
			[self startFullscreen:nil];
			return;
		}
		
		if (self.displayMode == CRDDisplayUnified)
			[self autosizeUnifiedWindow];
	}
	else
	{
		[self cellNeedsDisplay:(NSCell *)[inst cellRepresentation]];
		RDConnectionError errorCode = [inst conn]->errorCode;
		
		if (errorCode != ConnectionErrorNone && errorCode != ConnectionErrorCanceled)
		{			
			NSString *localizedErrorDescriptions[] = {
					@"No error", /* shouldn't ever occur */
					NSLocalizedString(@"The connection timed out.", @"Connection errors -> Timeout"),
					NSLocalizedString(@"The host name could not be resolved.", @"Connection errors -> Host not found"), 
					NSLocalizedString(@"There was an error connecting.", @"Connection errors -> Couldn't connect"),
					NSLocalizedString(@"You canceled the connection.", @"Connection errors -> User canceled")
					};
			NSString *title = [NSString stringWithFormat:NSLocalizedString(@"Couldn't connect to %@",
					@"Connection error alert -> Title"), [inst label]];
			
			NSAlert *alert = [NSAlert alertWithMessageText:title 
											 defaultButton:NSLocalizedString(@"Retry", @"Connection errors -> Retry button") 
										   alternateButton:NSLocalizedString(@"Cancel",@"Connection errors -> Cancel button") 
											   otherButton:nil 
								 informativeTextWithFormat:@"%@", localizedErrorDescriptions[errorCode]];
			[alert setAlertStyle:NSCriticalAlertStyle];
			
			// Retry if requested
			if ([alert runModal] == NSAlertDefaultReturn)
			{
				[self connectInstance:inst];
			}
			else if ([inst isTemporary]) // Temporary items may be in self.connectedServers even though connection failed
			{
				[self.connectedServers removeObject:inst];
				[self listUpdated];
			}
		}
	}	
}


#pragma mark -
#pragma mark Autmatic window sizing

- (void)autosizeUnifiedWindow
{
	[self autosizeUnifiedWindowWithAnimation:YES];
}

- (void)autosizeUnifiedWindowWithAnimation:(BOOL)animate
{
	CRDSession *inst = [self viewedServer];
	NSRect currentScreenFrame = [[self.gui_unifiedWindow screen] visibleFrame], oldWindowFrame = [self.gui_unifiedWindow frame], newWindowFrame;
	NSSize newContentSize;
	float scrollerWidth = [NSScroller scrollerWidth];
	float toolbarHeight = oldWindowFrame.size.height - [[self.gui_unifiedWindow contentView] frame].size.height;

	
	if ([self displayMode] == CRDDisplayUnified && inst)
	{
		// Not pretty but better than before...
		newContentSize = ([[inst view] bounds].size.width > 100) ? [[inst view] bounds].size : NSMakeSize(CRDDefaultFrameWidth, CRDDefaultFrameHeight);
		[self.gui_unifiedWindow setContentMaxSize:newContentSize];
	}
	else
	{
		newContentSize = [[NSScreen mainScreen] visibleFrame].size;
		[self.gui_unifiedWindow setContentMaxSize:newContentSize];
	}

	
	if (CRDPreferenceIsEnabled(CRDPrefsScaleSessions) && inst)
		[self.gui_unifiedWindow setContentAspectRatio:newContentSize];
	else
		[self.gui_unifiedWindow setContentResizeIncrements:NSMakeSize(1.0,1.0)];
	
	newWindowFrame = NSMakeRect(oldWindowFrame.origin.x, 
								oldWindowFrame.origin.y + oldWindowFrame.size.height - newContentSize.height - toolbarHeight,
								newContentSize.width,
								newContentSize.height + toolbarHeight
								);
	
	float drawerWidth = [self.gui_serversDrawer contentSize].width + 
			([[[self.gui_serversDrawer contentView] window] frame].size.width-[self.gui_serversDrawer contentSize].width) / 2.0 + 1.0;
	
	// For our adjustments, add the drawer width
	if ([self.gui_serversDrawer state] == NSDrawerOpenState)
	{
		if ([self.gui_serversDrawer edge] == NSMinXEdge) // left side
			newWindowFrame.origin.x -= drawerWidth;
		
		newWindowFrame.size.width += drawerWidth;
	}
	
	newWindowFrame.size.width = MIN(currentScreenFrame.size.width, newWindowFrame.size.width);
	newWindowFrame.size.height = MIN(currentScreenFrame.size.height, newWindowFrame.size.height);
	
	
	// Assure that no unneccesary scrollers are created
	if (!CRDPreferenceIsEnabled(CRDPrefsScaleSessions))
	{
		
		if (newWindowFrame.size.height > currentScreenFrame.size.height && newWindowFrame.size.width + scrollerWidth <= currentScreenFrame.size.width)
		{
			newWindowFrame.origin.y = currentScreenFrame.origin.y;
			newWindowFrame.size.height = currentScreenFrame.size.height;
			newWindowFrame.size.width += scrollerWidth;

		}
		if (newWindowFrame.size.width > currentScreenFrame.size.width && newWindowFrame.size.height+scrollerWidth <= currentScreenFrame.size.height)
		{
			newWindowFrame.origin.x = currentScreenFrame.origin.x;
			newWindowFrame.size.width = currentScreenFrame.size.width;
			newWindowFrame.size.height += scrollerWidth;
		}
	}
	
	// Try to make it contained within the screen
	if (newWindowFrame.origin.y < currentScreenFrame.origin.y && newWindowFrame.size.height <= currentScreenFrame.size.height)
		newWindowFrame.origin.y = currentScreenFrame.origin.y;
	
	if (newWindowFrame.origin.x + newWindowFrame.size.width > currentScreenFrame.size.width)
	{
		newWindowFrame.origin.x -= (newWindowFrame.origin.x + newWindowFrame.size.width) - (currentScreenFrame.origin.x + currentScreenFrame.size.width);
		newWindowFrame.origin.x = MAX(newWindowFrame.origin.x, currentScreenFrame.origin.x);
	}
	
		
	// Reset window rect to exclude drawer
	if ([self.gui_serversDrawer state] == NSDrawerOpenState)
	{
		float drawerWidth = [self.gui_serversDrawer contentSize].width;
		drawerWidth += ([[[self.gui_serversDrawer contentView] window] frame].size.width - drawerWidth) / 2.0 + 1;
		if ([self.gui_serversDrawer edge] == NSMinXEdge) // left side
			newWindowFrame.origin.x += drawerWidth;

		newWindowFrame.size.width -= drawerWidth;
	}
	
	
	// Assure that the aspect ratio is correct
	if (CRDPreferenceIsEnabled(CRDPrefsScaleSessions))
	{
		float bareWindowHeight = (newWindowFrame.size.height - toolbarHeight);
		float realAspect = newContentSize.width / newContentSize.height;
		float proposedAspect = newWindowFrame.size.width / bareWindowHeight;
		
		if (fabs(realAspect - proposedAspect) > 0.001)
		{
			if (realAspect > proposedAspect)
			{
				float oldHeight = newWindowFrame.size.height;
				newWindowFrame.size.height = toolbarHeight + newWindowFrame.size.width * (1.0 / realAspect);
				newWindowFrame.origin.y += oldHeight - newWindowFrame.size.height;
			}
			else
			{
				newWindowFrame.size.width = bareWindowHeight * realAspect;
			}
		}
	}
	
    id resizeTarget = animate ? [self.gui_unifiedWindow animator] : self.gui_unifiedWindow;
    
	[NSAnimationContext beginGrouping];
	if ( ([self displayMode] != CRDDisplayUnified) || ([self viewedServer] == nil))
	{
		[self.gui_unifiedWindow setTitle:@"CoRD"];
		[resizeTarget setFrameUsingName:@"UnifiedWindowFrame"];
	}
	else {
		[self.gui_unifiedWindow setTitle:[[self viewedServer] label]];
		[resizeTarget setFrame:newWindowFrame display:YES];
	}
	[NSAnimationContext endGrouping];
}


#pragma mark -
#pragma mark Managing saved servers

- (void)loadSavedServers
{
	CRDSession *savedSession;
	NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[AppController savedServersPath] error:NULL];
	for (NSString *filename in files)
	{
		if ([[filename pathExtension] isEqualToString:@"rdp"])
		{
			CRDLog(CRDLogLevelInfo, [NSString stringWithFormat:@"Loading Server: %@",filename]);

			savedSession = [[CRDSession alloc] initWithPath:[[AppController savedServersPath] stringByAppendingPathComponent:filename]];
			if (savedSession != nil)
				[self addSavedServer:savedSession];
			else
				CRDLog(CRDLogLevelError, @"RDP file '%@' failed to load!", filename);
			
			[savedSession release];
		}
	}
}

- (void)addSavedServer:(CRDSession *)inst
{
	[self addSavedServer:inst atIndex:[self.savedServers count] select:YES];
}

- (void)addSavedServer:(CRDSession *)inst atIndex:(int)index
{
	[self addSavedServer:inst atIndex:index select:NO];
}

- (void)addSavedServer:(CRDSession *)inst atIndex:(int)index select:(BOOL)select
{
	if ( !inst || (index < 0) || (index > [self.savedServers count]) )
		return;
	
	[inst setIsTemporary:NO];
	
	index = MIN(MAX(index, 0), [self.savedServers count]);
		
	[self.savedServers insertObject:inst atIndex:index];
	
	if (_isFilteringSavedServers)
		[self filterServers:nil];
		
	[self listUpdated];
	
	if (select)
		[self.gui_serverList selectRow:(2 + [self.connectedServers count] + [self.savedServers indexOfObjectIdenticalTo:inst])];
		
	[inst addObserver:self forKeyPath:@"label" options:(NSKeyValueObservingOptionNew|NSKeyValueObservingOptionOld) context:NULL];
}

- (void)removeSavedServer:(CRDSession *)inst deleteFile:(BOOL)deleteFile
{
	if (deleteFile)
	{
		[inst clearKeychainData];
		[[NSFileManager defaultManager] removeItemAtPath:[inst filename] error:NULL];
	}
	
	[inst removeObserver:self forKeyPath:@"label"];
	
	[self.savedServers removeObject:inst];
	
	if (inspectedServer == inst)
		inspectedServer = nil;
		
	if (_isFilteringSavedServers)
		[self filterServers:nil];

	[self listUpdated];
}

- (void)sortSavedServersByStoredListPosition
{
	[self.savedServers sortUsingSelector:@selector(compareUsingPreferredOrder:)];
}

- (void)sortSavedServersAlphabetically
{
	NSArray *sortDescriptors = @[[[[NSSortDescriptor alloc] initWithKey:@"label" ascending:YES] autorelease],
			[[[NSSortDescriptor alloc] initWithKey:@"hostName" ascending:YES] autorelease],
			[[[NSSortDescriptor alloc] initWithKey:@"username" ascending:YES] autorelease]];
	[self.savedServers sortUsingDescriptors:sortDescriptors];
}


@end

#pragma mark -

@implementation AppController (SharedResources)

+ (NSString *)savedServersPath
{
	static NSString *s_savedServersPath = nil;
	
	s_savedServersPath = [[[NSUserDefaults standardUserDefaults] objectForKey:CRDSavedServersPath] stringByExpandingTildeInPath];

	if (s_savedServersPath == nil)
		s_savedServersPath = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"CoRD/Servers"] retain];
	
	return s_savedServersPath;
}

@end
