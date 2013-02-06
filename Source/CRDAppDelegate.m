//
//  CRDAppDelegate.m
//  Cord
//
//  Created by Jon Shier on 1/19/13.
//
//

#import "CRDAppDelegate.h"

@implementation CRDAppDelegate

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename
{
	[self application:sender openFiles:@[filename]];
	return YES;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray *)filenames
{
	for ( id file in filenames )
	{
		if ([[[file pathExtension] lowercaseString] isEqualTo:@"rdp"]) {
			CRDSession *inst = [[CRDSession alloc] initWithPath:file];

			if (inst != nil)
			{
				[inst setIsTemporary:YES];
				[connectedServers addObject:inst];
				[gui_serverList deselectAll:self];
				[self listUpdated];
				[self connectInstance:inst];
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

	_appIsTerminating = YES;

	CRDLog(CRDLogLevelDebug, @"Firing tableViewSelectionDidChange to force inspector to update");
	[self.appController tableViewSelectionDidChange:nil];

	// Save current state to user defaults
	CRDLog(CRDLogLevelDebug, @"Saving current state to user defaults");
	[userDefaults setInteger:[gui_serversDrawer edge] forKey:CRDDefaultsUnifiedDrawerSide];
	[userDefaults setBool:CRDDrawerIsVisible(gui_serversDrawer) forKey:CRDDefaultsUnifiedDrawerShown];
	[userDefaults setFloat:[gui_serversDrawer contentSize].width forKey:CRDDefaultsUnifiedDrawerWidth];

	NSDisableScreenUpdates();

	// Clean up the fullscreen window
	if (displayMode == CRDDisplayFullscreen)
	{
		CRDLog(CRDLogLevelDebug, @"Cleaning up Fullscreen Window");
		[gui_tabView exitFullScreenModeWithOptions:nil];
		[self setDisplayMode:displayModeBeforeFullscreen];
	}
	[userDefaults setInteger:displayMode forKey:CRDDefaultsDisplayMode];

	// Disconnect all connected servers
	CRDLog(CRDLogLevelInfo, @"Disconnecting any connected severs");
	for ( CRDSession *inst in connectedServers )
		[self disconnectInstance:inst];

	[gui_unifiedWindow orderOut:nil];

	NSEnableScreenUpdates();

	// Flush each saved server to file (so that the perferred row will be saved)
	CRDLog(CRDLogLevelDebug, @"Flush and store servers");
	[self storeSavedServerPositions];
	for (CRDSession *inst in savedServers)
		[inst flushChangesToFile];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	// Make sure the drawer is in the user-saved position. Do it here (not awakeFromNib) so that it displays nicely
	[gui_serversDrawer setPreferredEdge:[userDefaults integerForKey:CRDDefaultsUnifiedDrawerSide]];

	float width = [userDefaults floatForKey:CRDDefaultsUnifiedDrawerWidth];
	float height = [gui_serversDrawer contentSize].height;
	if (width > 0)
		[gui_serversDrawer setContentSize:NSMakeSize(width, height)];

	if ([userDefaults boolForKey:CRDDefaultsUnifiedDrawerShown])
		[gui_serversDrawer openOnEdge:[userDefaults integerForKey:CRDDefaultsUnifiedDrawerSide]];

	[self validateControls];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)hasVisibleWindows
{
	if (!hasVisibleWindows)
		[gui_unifiedWindow makeKeyAndOrderFront:nil];

	return YES;
}

- (NSResponder *)application:(NSApplication *)application shouldForwardEvent:(NSEvent *)ev
{
	CRDSessionView *viewedSessionView = [[self viewedServer] view];
	NSWindow *viewedSessionWindow = [viewedSessionView window];

	BOOL shouldForward = YES;

	shouldForward &= ([ev type] == NSKeyDown) || ([ev type] == NSKeyUp) || ([ev type] == NSFlagsChanged);
	shouldForward &= ([viewedSessionWindow firstResponder] == viewedSessionView) && [viewedSessionWindow isKeyWindow] && ([viewedSessionWindow isMainWindow] || ([self displayMode] == CRDDisplayFullscreen));

	return shouldForward ? viewedSessionView : nil;
}

@end
