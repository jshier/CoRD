//
//  CRDAppDelegate.m
//  Cord
//
//  Created by Jon Shier on 1/19/13.
//
//

#import "CRDAppDelegate.h"
#import "CRDSession.h"
#import "AppController.h"
#import "CRDSessionView.h"

@implementation CRDAppDelegate

- (id)init
{
    if (!(self = [super init]))
        return nil;
    _appIsTerminating = NO;
    
    return self;
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename
{
	[self application:sender openFiles:@[filename]];
	return YES;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray *)filenames
{
	for (id file in filenames)
	{
		if ([[[file pathExtension] lowercaseString] isEqualTo:@"rdp"]) {
			CRDSession *inst = [[CRDSession alloc] initWithPath:file];

			if (inst != nil)
			{
				[inst setIsTemporary:YES];
				[self.appController.connectedServers addObject:inst];
				[self.appController.gui_serverList deselectAll:self];
				[self.appController listUpdated];
				[self.appController connectInstance:inst];
			}
		}
		else if ([[[file pathExtension] lowercaseString] isEqualTo:@"msrcincident"]) {
			CRDLog(CRDLogLevelInfo, @"Loading MSRCIncident File: %@", [[NSURL fileURLWithPath:file] absoluteString]);
			NSXMLDocument *incidentFile = [[NSXMLDocument alloc] initWithContentsOfURL:[NSURL fileURLWithPath:file] options:NSXMLDocumentTidyXML error:nil];
			CRDLog(CRDLogLevelInfo, @"File: %@, Version: %i", [incidentFile URI], [incidentFile version]);
			NSXMLElement *rootElement = [incidentFile rootElement];
			for (id child in [rootElement children])
				CRDLog(CRDLogLevelInfo,@"Child Name: %@",[child name]);
			[[NSAlert alertWithMessageText:@"Coming Soon!" defaultButton:@"OK" alternateButton:nil otherButton:nil informativeTextWithFormat:@"Support for MS Incident files coming soon!"] runModal];
		}
	}
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)theApplication
{
    return NO;
}


- (void)applicationWillTerminate:(NSNotification *)aNotification
{
    CRDLog(CRDLogLevelInfo,@"CoRD is Terminating, Cleaning Up");

	self.appIsTerminating = YES;

	CRDLog(CRDLogLevelDebug, @"Firing tableViewSelectionDidChange to force inspector to update");
	[self.appController tableViewSelectionDidChange:nil];

	// Save current state to user defaults
	CRDLog(CRDLogLevelDebug, @"Saving current state to user defaults");
	[[NSUserDefaults standardUserDefaults] setInteger:[[self.appController gui_serversDrawer] edge] forKey:CRDDefaultsUnifiedDrawerSide];
	[[NSUserDefaults standardUserDefaults] setBool:CRDDrawerIsVisible([self.appController gui_serversDrawer]) forKey:CRDDefaultsUnifiedDrawerShown];
	[[NSUserDefaults standardUserDefaults] setFloat:[[self.appController gui_serversDrawer] contentSize].width forKey:CRDDefaultsUnifiedDrawerWidth];

	NSDisableScreenUpdates();

	// Clean up the fullscreen window
	if ([self.appController displayMode] == CRDDisplayFullscreen)
	{
		CRDLog(CRDLogLevelDebug, @"Cleaning up Fullscreen Window");
		[[self.appController gui_tabView] exitFullScreenModeWithOptions:nil];
		[self.appController setDisplayMode:[self.appController displayModeBeforeFullscreen]];
	}
	[[NSUserDefaults standardUserDefaults] setInteger:[self.appController displayMode] forKey:CRDDefaultsDisplayMode];

	// Disconnect all connected servers
	CRDLog(CRDLogLevelInfo, @"Disconnecting any connected severs");
	for (CRDSession *inst in self.appController.connectedServers)
		[self.appController disconnectInstance:inst];

	[[self.appController gui_unifiedWindow] orderOut:nil];

	NSEnableScreenUpdates();

	// Flush each saved server to file (so that the perferred row will be saved)
	CRDLog(CRDLogLevelDebug, @"Flush and store servers");
	[self.appController storeSavedServerPositions];
	for (CRDSession *inst in self.appController.savedServers)
		[inst flushChangesToFile];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    // Make sure the drawer is in the user-saved position. Do it here (not awakeFromNib) so that it displays nicely
	[[self.appController gui_serversDrawer] setPreferredEdge:[[NSUserDefaults standardUserDefaults] integerForKey:CRDDefaultsUnifiedDrawerSide]];

	float width = [[NSUserDefaults standardUserDefaults] floatForKey:CRDDefaultsUnifiedDrawerWidth];
	float height = [[self.appController gui_serversDrawer] contentSize].height;
	if (width > 0)
		[[self.appController gui_serversDrawer] setContentSize:NSMakeSize(width, height)];

	if ([[NSUserDefaults standardUserDefaults] boolForKey:CRDDefaultsUnifiedDrawerShown])
		[[self.appController gui_serversDrawer] openOnEdge:[[NSUserDefaults standardUserDefaults] integerForKey:CRDDefaultsUnifiedDrawerSide]];

	[self.appController validateControls];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)hasVisibleWindows
{
	if (!hasVisibleWindows)
		[self.appController.gui_unifiedWindow makeKeyAndOrderFront:nil];

	return YES;
}

- (NSResponder *)application:(NSApplication *)application shouldForwardEvent:(NSEvent *)ev
{
	CRDSessionView *viewedSessionView = [[self.appController viewedServer] view];
	NSWindow *viewedSessionWindow = [viewedSessionView window];

	BOOL shouldForward = YES;

	shouldForward &= ([ev type] == NSKeyDown) || ([ev type] == NSKeyUp) || ([ev type] == NSFlagsChanged);
	shouldForward &= ([viewedSessionWindow firstResponder] == viewedSessionView) && [viewedSessionWindow isKeyWindow] && ([viewedSessionWindow isMainWindow] || ([self.appController displayMode] == CRDDisplayFullscreen));

	return shouldForward ? viewedSessionView : nil;
}

@end
