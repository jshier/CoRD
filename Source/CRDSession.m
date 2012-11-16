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

#import <CoreServices/CoreServices.h>

#import "CRDSession.h"
#import "CRDSessionView.h"
#import "CRDKeyboard.h"
#import "CRDServerCell.h"
#import "AppController.h"
#import "keychain.h"

@interface CRDSession (Private)
- (BOOL)readFileAtPath:(NSString *)path;
- (void)updateKeychainData:(NSString *)newHost user:(NSString *)newUser password:(NSString *)newPassword force:(BOOL)force;
- (void)setStatus:(CRDConnectionStatus)status;
- (void)setStatusAsNumber:(NSNumber *)status;
- (void)createScrollEnclosure:(NSRect)frame;
- (void)createViewWithFrameValue:(NSValue *)frameRect;
- (void)setUpConnectionThread;
- (void)discardConnectionThread;
@end

#pragma mark -

@implementation CRDSession

- (id)init
{
	if (!(self = [super init]))
		return nil;
	
	rdpFilename = _label = _hostName = _clientHostname = _username = _password = _domain = @"";
	preferredRowIndex = -1;
	screenDepth = 16;
	_isTemporary = themes = YES;
	_hotkey = -1;
	_forwardAudio = CRDDisableAudio;
	fileEncoding = NSUTF8StringEncoding;
	
	// Other initialization
	otherAttributes = [[NSMutableDictionary alloc] init];
	
	_cellRepresentation = [[CRDServerCell alloc] init];
	inputEventStack = [[NSMutableArray alloc] init];
	
	[self setStatus:CRDConnectionClosed];
	
	[self setClientHostname:[[NSUserDefaults standardUserDefaults] valueForKey:@"CRDBaseConnectionClientHostname"]];
	
	return self;
}

- (id)initWithPath:(NSString *)path
{
	if (!(self = [self init]))
		return nil;
	
	if (![self readFileAtPath:path])
	{
		[self autorelease];
		return nil;
	}
	
	return self;
}

// Initializes using user's 'base connection' settings
- (id)initWithBaseConnection
{
	if (!(self = [self init]))
		return nil;
	
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	
	for (NSString *k in @[@"ConsoleSession", @"ForwardDisks", @"ForwardPrinters", @"DrawDesktop", @"WindowDrags", @"WindowAnimation", @"Themes", @"FontSmoothing"])
	{
		NSNumber *isChecked = @([[defaults valueForKey:[@"CRDBaseConnection" stringByAppendingString:k]] boolValue]);
		
		[self setValue:isChecked forKey:[k lowercaseFirst]];
	}
	
	[self setValue:CRDNumberForColorsText([defaults valueForKey:@"CRDBaseConnectionColors"]) forKey:@"screenDepth"];
	
	[self setValue:@([[defaults valueForKey:@"CRDBaseConnectionForwardAudio"] intValue]) forKey:@"forwardAudio"];
		
	NSString *resolutionString = [defaults valueForKey:@"CRDBaseConnectionScreenSize"];
	fullscreen = CRDResolutionStringIsFullscreen(resolutionString);

	if (!fullscreen)
		CRDSplitResolutionString(resolutionString, &screenWidth, &screenHeight);
			
	return self;
}

- (void)dealloc
{
	if (_connectionStatus == CRDConnectionConnected)
		[self disconnectAsync:@YES];
			
	while (_connectionStatus != CRDConnectionClosed)
		usleep(1000);
	
	[inputEventPort invalidate];
	[inputEventPort release];
	[inputEventStack release];
	
	[_label release];
	[_hostName release];
	[_clientHostname release];
	[_username release];
	[_password release];
	[_domain release];
	[otherAttributes release];
	[rdpFilename release];
	
		
	[_cellRepresentation release];
	[super dealloc];
}

- (id)valueForUndefinedKey:(NSString *)key
{
	return otherAttributes[key];
}

- (void)setValue:(id)value forKey:(NSString *)key
{
	if (![[self valueForKey:key] isEqualTo:value])
	{
		_modified |= ![key isEqualToString:@"view"];
		[super setValue:value forKey:key];
	}
}

- (id)copyWithZone:(NSZone *)zone
{
	CRDSession *newSession = [[CRDSession alloc] init];
	
	newSession->_label = [_label copy];
	newSession->_hostName = [_hostName copy];
	newSession->_clientHostname = [_clientHostname copy];
	newSession->_username = [_username copy];
	newSession->_password = [_password copy];
	newSession->_domain = [_domain copy];
	newSession->otherAttributes = [otherAttributes copy];
	newSession->forwardDisks = forwardDisks; 
	newSession->_forwardAudio = _forwardAudio;
	newSession->forwardPrinters = forwardPrinters;
	newSession->savePassword = savePassword;
	newSession->drawDesktop = drawDesktop;
	newSession->windowDrags = windowDrags;
	newSession->windowAnimation = windowAnimation;
	newSession->themes = themes;
	newSession->fontSmoothing = fontSmoothing;
	newSession->consoleSession = consoleSession;
	newSession->fullscreen = fullscreen;
	newSession->screenDepth = screenDepth;
	newSession->screenWidth = screenWidth;
	newSession->screenHeight = screenHeight;
	newSession->port = port;
	newSession->_modified = _modified;
	newSession->_hotkey = _hotkey;

	return newSession;
}


#pragma mark -
#pragma mark Working with rdesktop

// Invoked on incoming data arrival, starts the processing of incoming packets
- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)streamEvent
{
	if (streamEvent == NSStreamEventErrorOccurred)
	{
		[g_appController performSelectorOnMainThread:@selector(disconnectInstance:) withObject:self waitUntilDone:NO];
		return;
	}

	uint8 type;
	RDStreamRef s;
	uint32 ext_disc_reason;
	
	if (_connectionStatus != CRDConnectionConnected)
		return;
	
	do
	{
		s = rdp_recv(_conn, &type);
		if (s == NULL)
		{
			[g_appController performSelectorOnMainThread:@selector(disconnectInstance:) withObject:self waitUntilDone:NO];
			return;
		}
		
		switch (type)
		{
			case RDP_PDU_DEMAND_ACTIVE:
				process_demand_active(_conn, s);
				break;
			case RDP_PDU_DEACTIVATE:
				DEBUG(("RDP_PDU_DEACTIVATE\n"));
				break;
			case RDP_PDU_DATA:
				if (process_data_pdu(_conn, s, &ext_disc_reason))
				{
					[g_appController performSelectorOnMainThread:@selector(disconnectInstance:) withObject:self waitUntilDone:NO];
					return;
				}
				break;
			case RDP_PDU_REDIRECT:
				process_redirect_pdu(_conn, s);
				break;
			case 0:
				break;
			default:
				unimpl("PDU %d\n", type);
		}
		
	} while ( (_conn->nextPacket < s->end) && (_connectionStatus == CRDConnectionConnected) );
}

// Using the current properties, attempt to connect to a server. Blocks until timeout or failure.
- (BOOL)connect
{
	if (_connectionStatus == CRDConnectionDisconnecting)
	{
		time_t startTime = time(NULL);
		
		while (_connectionStatus == CRDConnectionDisconnecting)
			usleep(1000);
			
		if (time(NULL) - startTime > 10)
			CRDLog(CRDLogLevelError, @"Got hung up on old frozen connection while connecting to %@", _label);
	}
	
	if (_connectionStatus != CRDConnectionClosed)
		return NO;
	
	_connectionStatus = CRDConnectionConnecting;
	
	free(_conn);
	_conn = malloc(sizeof(RDConnection));
	memset(_conn, 0, sizeof(RDConnection));
	CRDFillDefaultConnection(_conn);
	_conn->controller = self;
	
	// Fail quickly if it's a totally bogus host
	if (![_hostName length])
	{
		_connectionStatus = CRDConnectionClosed;
		_conn->errorCode = ConnectionErrorHostResolution;
		return NO;
	}
	
	// Set status to connecting on main thread so that the cell's progress indicator timer is on the main thread
	[self performSelectorOnMainThread:@selector(setStatusAsNumber:) withObject:@(CRDConnectionConnecting) waitUntilDone:NO];
	
	[g_appController performSelectorOnMainThread:@selector(validateControls) withObject:nil waitUntilDone:NO];

	// RDP5 performance flags
	unsigned performanceFlags = RDP5_DISABLE_NOTHING;
	if (!windowDrags)
		performanceFlags |= RDP5_NO_FULLWINDOWDRAG;
	
	if (!themes)
		performanceFlags |= RDP5_NO_THEMING;
	
	if (!drawDesktop)
		performanceFlags |= RDP5_NO_WALLPAPER;
	
	if (!windowAnimation)
		performanceFlags |= RDP5_NO_MENUANIMATIONS;
	
	if (fontSmoothing)
		performanceFlags |= RDP5_FONT_SMOOTHING;  
	
	_conn->rdp5PerformanceFlags = performanceFlags;
	

	// Simple heuristic to guess if user wants to auto log-in
	unsigned logonFlags = RDP_LOGON_NORMAL;
	if ([_username length] > 0 && ([_password length] || savePassword))
		logonFlags |= RDP_LOGON_AUTO;
		
	if (consoleSession)
		logonFlags |= RDP_LOGON_LEAVE_AUDIO;
	
	logonFlags |= _conn->useRdp5 ? RDP_LOGON_COMPRESSION2 : RDP_LOGON_COMPRESSION;
	
	// Other various settings
	_conn->serverBpp = (screenDepth==8 || screenDepth==16 || screenDepth==24) ? screenDepth : 16;
	_conn->consoleSession = consoleSession;
	_conn->screenWidth = screenWidth ? screenWidth : CRDDefaultScreenWidth;
	_conn->screenHeight = screenHeight ? screenHeight : CRDDefaultScreenHeight;
	_conn->tcpPort = (!port || port>=65536) ? CRDDefaultPort : port;
	strncpy(_conn->username, CRDMakeWindowsString(_username), sizeof(_conn->username));

	// Set remote keymap to match local OS X input type
	if (CRDPreferenceIsEnabled(CRDSetServerKeyboardLayout))
		_conn->keyboardLayout = [CRDKeyboard windowsKeymapForMacKeymap:[CRDKeyboard currentKeymapIdentifier]];
	else
		_conn->keyboardLayout = 0;
	
	if (forwardDisks)
	{
		NSMutableArray *validDrives = [NSMutableArray array], *validNames = [NSMutableArray array];
		
		if (CRDPreferenceIsEnabled(CRDForwardOnlyDefinedPaths) && [[[NSUserDefaults standardUserDefaults] arrayForKey:@"CRDForwardedPaths"] count] > 0)
		{	
			for (NSDictionary *pair in [[NSUserDefaults standardUserDefaults] arrayForKey:@"CRDForwardedPaths"])
			{
				if (![[pair valueForKey:@"enabled"] boolValue])
					continue;
				
				if (![[NSFileManager defaultManager] fileExistsAtPath:[pair[@"path"] stringByExpandingTildeInPath]] || ![pair[@"label"] length])
				{
					CRDLog(CRDLogLevelInfo, @"Empty custom forward label or path, skipping: %@", pair);
					continue;
				}
				
				[validDrives addObject:[pair[@"path"] stringByExpandingTildeInPath]];
				[validNames addObject:pair[@"label"]];
			}
		} 
		else 
		{
			for (NSString *volumePath in [[NSWorkspace sharedWorkspace] mountedLocalVolumePaths])
				if ([volumePath characterAtIndex:0] != '.')
				{
					[validDrives addObject:volumePath];
					[validNames addObject:[[NSFileManager defaultManager] displayNameAtPath:volumePath]];
				}
		}
		
		if ([validDrives count] && [validNames count])
			disk_enum_devices(_conn, CRDMakeCStringArray(validDrives), CRDMakeCStringArray(validNames), [validDrives count]);
	}
	

	if (forwardPrinters)
		printer_enum_devices(_conn);
	
	if (_forwardAudio == CRDLeaveAudio)
	{
		logonFlags |= RDP_LOGON_LEAVE_AUDIO;
	}
	
	if ([_clientHostname length]) {
		memset(_conn->hostname,0,64);
		strncpy(_conn->hostname, CRDMakeWindowsString(_clientHostname), 64);
        _conn->hostname[MIN([_clientHostname length], 64)] = '\0';
	}
	
	rdpdr_init(_conn);
	cliprdr_init(_conn);

	// Make the connection
	BOOL connected = rdp_connect(_conn,
							[_hostName UTF8String], 
							logonFlags, 
							_domain,
							_username,
							_password,
							"",  /* xxx: command on logon */
							"", /* xxx: session directory */
							NO
							);
							
	// Upon success, set up the input socket
	if (connected)
	{
		[self setStatus:CRDConnectionConnected];
		[self setUpConnectionThread];

		NSStream *is = _conn->inputStream;
		[is setDelegate:self];
		[is scheduleInRunLoop:connectionRunLoop forMode:NSDefaultRunLoopMode];

		[self performSelectorOnMainThread:@selector(createViewWithFrameValue:) withObject:[NSValue valueWithRect:NSMakeRect(0.0, 0.0, _conn->screenWidth, _conn->screenHeight)] waitUntilDone:YES];
	}
	else if (_connectionStatus == CRDConnectionConnecting)
	{
		[self setStatus:CRDConnectionClosed];
		[self performSelectorOnMainThread:@selector(setStatusAsNumber:) withObject:@(CRDConnectionClosed) waitUntilDone:NO];
	}
	
	return connected;
}

- (void)disconnect
{
	[self disconnectAsync:@YES];
}

- (void)disconnectAsync:(NSNumber *)nonblocking
{
	@autoreleasepool {
        if (_connectionStatus == CRDConnectionConnecting)
            _conn->errorCode = ConnectionErrorCanceled;
        
        [self setStatus:CRDConnectionDisconnecting];
        if (connectionRunLoopFinished || ![nonblocking boolValue])
        {
            // Try to forcefully break the connection thread out of its run loop
            @synchronized(self)
            {
                [inputEventPort sendBeforeDate:[NSDate dateWithTimeIntervalSinceNow:TIMEOUT_LENGTH] components:nil from:nil reserved:0];
            }
            
            time_t start = time(NULL);
            while (!connectionRunLoopFinished && (time(NULL) - start < TIMEOUT_LENGTH))
                usleep(1000);
            
            // UI cleanup
            [self performSelectorOnMainThread:@selector(destroyUIElements) withObject:nil waitUntilDone:YES];
            
            
            // Clear out the bitmap cache
            int i, k;
            for (i = 0; i < BITMAP_CACHE_SIZE; i++)
            {
                for (k = 0; k < BITMAP_CACHE_ENTRIES; k++)
                {
                    ui_destroy_bitmap(_conn->bmpcache[i][k].bitmap);
                    _conn->bmpcache[i][k].bitmap = NULL;
                }
            }
            
            for (i = 0; i < CURSOR_CACHE_SIZE; i++)
                ui_destroy_cursor(_conn->cursorCache[i]);
            
            
            free(_conn->rdpdrClientname);
            
            
            memset(_conn, 0, sizeof(RDConnection));
            free(_conn);
            _conn = NULL;
            
            [self setStatus:CRDConnectionClosed];
        }
        else
        {
            [self performSelectorInBackground:@selector(disconnectAsync:) withObject:@NO];
        }
    }
}

#pragma mark -
#pragma mark Working with the input run loop

- (void)runConnectionRunLoop
{
	@autoreleasepool {
        connectionRunLoopFinished = NO;
        
        BOOL gotInput;
        do
        {
            @autoreleasepool {
                gotInput = [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
            }
        } while (_connectionStatus == CRDConnectionConnected && gotInput);
                
        rdp_disconnect(_conn);
        [self discardConnectionThread];
        connectionRunLoopFinished = YES;
    }

}


#pragma mark -
#pragma mark Clipboard synchronization

- (void)announceNewClipboardData
{
	int newChangeCount = [[NSPasteboard generalPasteboard] changeCount];

	if (newChangeCount != clipboardChangeCount)
		[self informServerOfPasteboardType];

	clipboardChangeCount = newChangeCount;
}

// Assures that the remote clipboard is the same as the passed pasteboard, sending new clipboard as needed
- (void)setRemoteClipboard:(int)suggestedFormat
{
	if (_connectionStatus != CRDConnectionConnected)
		return;
		
	NSPasteboard *pb = [NSPasteboard generalPasteboard];
	if (![pb availableTypeFromArray:@[NSStringPboardType]])
		return;
	
	NSString *pasteContent = CRDConvertLineEndings([pb stringForType:NSStringPboardType], YES);
	
	CFDataRef pasteContentAsData = CFStringCreateExternalRepresentation(NULL, (CFStringRef)pasteContent, kCFStringEncodingUTF16LE, 0x20 /* unicode space */);
	NSMutableData *unicodePasteContent = [NSMutableData dataWithData:(NSData *)pasteContentAsData];
	CFRelease(pasteContentAsData);
	
	if (![unicodePasteContent length])
		return;

	[unicodePasteContent increaseLengthBy:2];  // NULL terminate with 2 bytes (UTF16LE)
	
	cliprdr_send_data(_conn, (unsigned char *)[unicodePasteContent bytes], [unicodePasteContent length]);
}

- (void)requestRemoteClipboardData
{
	if (_connectionStatus != CRDConnectionConnected)
		return;
		
	_conn->clipboardRequestType = CF_UNICODETEXT;
	cliprdr_send_data_request(_conn, CF_UNICODETEXT);
}

// Sets the local clipboard to match the server provided data. Only called by server (via CRDMixedGlue) when new data has actually arrived
- (void)setLocalClipboard:(NSData *)data format:(int)format
{
	if ( ((format != CF_UNICODETEXT) && (format != CF_AUTODETECT)) || ![data length] )
		return;
	
	unsigned char endiannessMarker[] = {0xFF, 0xFE};
	
	NSMutableData *rawClipboardData = [[NSMutableData alloc] initWithCapacity:[data length]];
	[rawClipboardData appendBytes:endiannessMarker length:2];
	[rawClipboardData appendBytes:[data bytes] length:[data length]-2];
	NSString *temp = [[NSString alloc] initWithData:rawClipboardData encoding:NSUnicodeStringEncoding];
	[rawClipboardData release];
	
	[remoteClipboard release];
	remoteClipboard = [CRDConvertLineEndings(temp, NO) retain];
	[[NSPasteboard generalPasteboard] setString:remoteClipboard forType:NSStringPboardType];
    
    [temp release];
}

// Informs the receiver that the server has new clipboard data and is about to send it
- (void)gotNewRemoteClipboardData
{
	isClipboardOwner = YES;
	[[NSPasteboard generalPasteboard] declareTypes:@[NSStringPboardType] owner:self];
}

- (void)informServerOfPasteboardType
{
	if ([[NSPasteboard generalPasteboard] availableTypeFromArray:@[NSStringPboardType]] == nil)
		return;
	
	if (_connectionStatus == CRDConnectionConnected)
		cliprdr_send_simple_native_format_announce(_conn, CF_UNICODETEXT);
}

- (void)pasteboardChangedOwner:(NSPasteboard *)sender
{
	isClipboardOwner = NO;
}


#pragma mark -
#pragma mark Working with the represented file

// Saves all of the current settings to a Microsoft RDC client compatible file

- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)atomicFlag updateFilenames:(BOOL)updateNamesFlag
{
	#define write_int(n, v)	 [outputBuffer appendString:[NSString stringWithFormat:@"%@:i:%ld\r\n", (n), (v)]]
	#define write_string(n, v) [outputBuffer appendString:[NSString stringWithFormat:@"%@:s:%@\r\n", (n), (v) ? (v) : @""]]
	
	NSString *expandedPath = [path stringByExpandingTildeInPath];
	
	if (![expandedPath length])
		return NO;

	NSMutableString *outputBuffer = [[NSMutableString alloc] init];
	
	write_int(@"connect to console", (long)consoleSession);
	write_int(@"redirectdrives", (long)forwardDisks);
	write_int(@"redirectprinters", (long)forwardPrinters);
	write_int(@"disable wallpaper", (long)!drawDesktop);
	write_int(@"disable full window drag", (long)!windowDrags);
	write_int(@"disable menu anims", (long)!windowAnimation);
	write_int(@"disable themes", (long)!themes);
	write_int(@"disable font smoothing", (long)!fontSmoothing);
	write_int(@"audiomode", _forwardAudio);
	write_int(@"desktopwidth", screenWidth);
	write_int(@"desktopheight", screenHeight);
	write_int(@"session bpp", screenDepth);
	write_int(@"cord save password", (long)savePassword);
	write_int(@"cord fullscreen", (long)fullscreen);
	write_int(@"cord row index", preferredRowIndex);
	write_int(@"cord hotkey", _hotkey);
	write_int(@"cord displayMode", _displayMode);
	
	write_string(@"full address", CRDJoinHostNameAndPort(_hostName, port));
	write_string(@"username", _username);
	write_string(@"domain", _domain);
	write_string(@"cord label", _label);
	
	// Write all entries in otherAttributes	
	for (NSString *key in otherAttributes)
	{
		id value = otherAttributes[key];
		if ([value isKindOfClass:[NSNumber class]])
			write_int(key, [value integerValue]);
		else
			write_string(key, value);
	}
	
	BOOL writeToFileSucceeded = [outputBuffer writeToFile:expandedPath atomically:atomicFlag encoding:fileEncoding error:NULL] | [outputBuffer writeToFile:expandedPath atomically:atomicFlag encoding:(fileEncoding = NSUTF8StringEncoding) error:NULL];

	[outputBuffer release];
	
	if (writeToFileSucceeded)
	{
		NSDictionary *newAttrs = @{NSFileHFSTypeCode:@('RDP ')};
        [[NSFileManager defaultManager] setAttributes:newAttrs ofItemAtPath:expandedPath error:NULL];
	}
	else
	{
		CRDLog(CRDLogLevelError, @"Error writing RDP file to '%@'", expandedPath);
	}

	if (writeToFileSucceeded && updateNamesFlag)
	{
		_modified = NO;
		[self setFilename:expandedPath];
	}
	
	return writeToFileSucceeded;
	
	#undef write_int
	#undef write_string
}

- (void)flushChangesToFile
{
	[self writeToFile:[self filename] atomically:YES updateFilenames:NO];
}


#pragma mark -
#pragma mark Working with GUI

// Updates the CRDServerCell this instance manages to match the current details.
- (void)updateCellData
{
	if (![[NSThread currentThread] isEqual:[NSThread mainThread]])
		return [self performSelectorOnMainThread:@selector(updateCellData) withObject:nil waitUntilDone:NO];
	
	// Update the text
	NSString *fullHost = (port && port != CRDDefaultPort) ? [NSString stringWithFormat:@"%@:%ld", _hostName, port] : _hostName;
	[_cellRepresentation setDisplayedText:_label username:_username address:fullHost];
	
	// Update the image
	if (_connectionStatus != CRDConnectionConnecting)
	{
		NSString *iconBaseName = @"RDP Document File";
		
		if (_connectionStatus == CRDConnectionClosed)
			iconBaseName = @"RDP Document Gray";
			
		NSImage *base = [NSImage imageNamed:iconBaseName];
		[base setFlipped:YES];
		
		NSImage *cellImage = [[[NSImage alloc] initWithSize:NSMakeSize(SERVER_CELL_FULL_IMAGE_SIZE, SERVER_CELL_FULL_IMAGE_SIZE)] autorelease];
		
		[cellImage lockFocus]; {
			[[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
			[base drawInRect:CRDRectFromSize([cellImage size]) fromRect:CRDRectFromSize([base size]) operation:NSCompositeSourceOver fraction:1.0];
		} [cellImage unlockFocus];

		if ([self isTemporary])
		{
			// Copy the document image into a new image and badge it with the clock
			[cellImage lockFocus]; {
				[[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];

				[base drawInRect:CRDRectFromSize([cellImage size]) fromRect:CRDRectFromSize([base size]) operation:NSCompositeSourceOver fraction:1.0];
			
				NSImage *clockIcon = [NSImage imageNamed:@"Clock icon"];
				NSSize clockSize = [clockIcon size], iconSize = [cellImage size];
				NSRect dest = NSMakeRect(iconSize.width - clockSize.width - 1.0, iconSize.height - clockSize.height, clockSize.width, clockSize.height);
				[clockIcon drawInRect:dest fromRect:CRDRectFromSize(clockSize) operation:NSCompositeSourceOver fraction:0.9];
			} [cellImage unlockFocus];
		}

		[_cellRepresentation setImage:cellImage];
	}
	
	[g_appController cellNeedsDisplay:_cellRepresentation];
}

- (void)createWindow:(BOOL)useScrollView
{	
	[NSAnimationContext beginGrouping];
	_usesScrollers = useScrollView;
	[_window release];
	NSRect sessionScreenSize = [_view bounds];
	_window = [[NSWindow alloc] initWithContentRect:sessionScreenSize styleMask:(NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask) backing:NSBackingStoreBuffered defer:NO];
	
	[_window setContentMaxSize:sessionScreenSize.size];
	[_window setTitle:_label];
	[_window setAcceptsMouseMovedEvents:YES];
	[_window setDelegate:self];
	[_window setReleasedWhenClosed:NO];
	[[_window contentView] setAutoresizesSubviews:YES];
	[_window setContentMinSize:NSMakeSize(100.0, 75.0)];
	
	[_window setAlphaValue:0.0];
	[_view setFrameOrigin:NSZeroPoint];
	[_view removeFromSuperview];
	
	if (useScrollView)
	{
		[self createScrollEnclosure:[[_window contentView] bounds]];
		[[_window contentView] addSubview:scrollEnclosure];
	}
	else
	{
		[_view setFrameSize:[[_window contentView] frame].size];
		[_view setAutoresizingMask:(NSViewWidthSizable|NSViewHeightSizable)];
		[_window setContentAspectRatio:sessionScreenSize.size];
		[[_window contentView] addSubview:_view];
		[_view setNeedsDisplay:YES];
	}
	
	[[_window animator] setAlphaValue:1.0];
	[_window makeFirstResponder:_view];
	[_window display];
	[NSAnimationContext endGrouping];
}


- (void)createUnified:(BOOL)useScrollView enclosure:(NSRect)enclosure
{	
	_usesScrollers = useScrollView;
	if (useScrollView)
		[self createScrollEnclosure:enclosure];
	else
		[_view setAutoresizingMask:(NSViewWidthSizable|NSViewHeightSizable)];
}

- (void)destroyUnified
{
}

- (void)destroyWindow
{
	[_window setDelegate:nil]; // avoid the last windowWillClose delegate message
	[_window close];
	[_window release];
	_window = nil;
}

- (void)destroyUIElements
{
	[_view setController:nil]; // inform view it's no longer being controller and is probably being deallocated
	[self destroyWindow];
	[scrollEnclosure release];
	scrollEnclosure = nil;
	[_view release];
	_view = nil;
}

#pragma mark -
#pragma mark NSWindow delegate

- (void)windowWillClose:(NSNotification *)aNotification
{
	if (_connectionStatus == CRDConnectionConnected)
		[g_appController disconnectInstance:self];
}

- (void)windowDidBecomeKey:(NSNotification *)sender
{
	if ([sender object] == _window)
		[self announceNewClipboardData];
}

- (void)windowDidResignKey:(NSNotification *)sender
{
	if ([sender object] == _window)
		[self requestRemoteClipboardData];
}

- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)proposedFrameSize
{
	NSSize realSize = [_view bounds].size;
	realSize.height += [sender frame].size.height - [[sender contentView] frame].size.height;
	
	if ( (realSize.width-proposedFrameSize.width <= CRDWindowSnapSize) && (realSize.height-proposedFrameSize.height <= CRDWindowSnapSize) )
		return realSize;
		
	return proposedFrameSize;
}


#pragma mark -
#pragma mark Sending input from other threads

- (void)sendInputOnConnectionThread:(uint32)time type:(uint16)type flags:(uint16)flags param1:(uint16)param1 param2:(uint16)param2
{
	if (_connectionStatus != CRDConnectionConnected)
		return;
	
	if ([NSThread currentThread] == connectionThread)
	{
		rdp_send_input(_conn, time, type, flags, param1, param2);
	}
	else
	{	
		// Push this event onto the event stack and handle it in the connection thread
		CRDInputEvent queuedEvent = CRDMakeInputEvent(time, type, flags, param1, param2), *ie;
		
		ie = malloc(sizeof(CRDInputEvent));
		memcpy(ie, &queuedEvent, sizeof(CRDInputEvent));
		
		@synchronized(inputEventStack)
		{
			[inputEventStack addObject:[NSValue valueWithPointer:ie]];
		}
		
		// Inform the connection thread it has unprocessed events
		[inputEventPort sendBeforeDate:[NSDate date] components:nil from:nil reserved:0];
	}
}

// Called by the connection thread in the run loop when new user input needs to be sent
- (void)handleMachMessage:(void *)msg
{
    @synchronized(inputEventStack)
	{
		while ([inputEventStack count] != 0)
		{
			CRDInputEvent *ie = [inputEventStack[0] pointerValue];
			[inputEventStack removeObjectAtIndex:0];
			if (ie != NULL)
				[self sendInputOnConnectionThread:ie->time type:ie->type flags:ie->deviceFlags param1:ie->param1 param2:ie->param2];
			
			free(ie);
		}
	}
}


#pragma mark -
#pragma mark Working With CoRD

- (void)cancelConnection
{
	if ( (_connectionStatus != CRDConnectionConnecting) || !_conn)
		return;
	
	_conn->errorCode = ConnectionErrorCanceled;
}

- (NSComparisonResult)compareUsingPreferredOrder:(id)compareTo
{
	int otherOrder = [[compareTo valueForKey:@"preferredRowIndex"] intValue];
	
	if (preferredRowIndex == otherOrder)
		return [[compareTo label] compare:_label];
	else
		return (preferredRowIndex - otherOrder > 0) ? NSOrderedDescending : NSOrderedAscending;
}


#pragma mark -
#pragma mark Keychain

- (void)clearKeychainData
{
	keychain_clear_password([_hostName UTF8String], [_username UTF8String]);
}


#pragma mark -
#pragma mark Accessors

@synthesize status = _connectionStatus;

- (NSView *)tabItemView
{
	return (scrollEnclosure) ? scrollEnclosure : (NSView *)_view;
}

- (NSString *)filename
{
	return rdpFilename;
}

- (void)setFilename:(NSString *)path
{
	if ([path isEqualToString:rdpFilename])
		return;
			
	[self willChangeValueForKey:@"rdpFilename"];
	[rdpFilename autorelease];
	rdpFilename = [[path stringByExpandingTildeInPath] copy];
	[self didChangeValueForKey:@"rdpFilename"];
}

- (void)setIsTemporary:(BOOL)temp
{
	if (temp == _isTemporary)
		return;
		
		
	[self willChangeValueForKey:@"temporary"];
	_isTemporary = temp;
	[self didChangeValueForKey:@"temporary"];
	[self updateCellData];
}


// KVC/KVO compliant setters that are used to propagate changes to the keychain item

- (void)setLabel:(NSString *)newLabel
{	
	[_label autorelease];
	_label = [newLabel copy];
	[self updateCellData];
}

- (void)setHostName:(NSString *)newHost
{	
	[self updateKeychainData:newHost user:_username password:_password force:NO];
	
	[_hostName autorelease];
	_hostName = [newHost copy];
	[self updateCellData];
}

- (void)setUsername:(NSString *)newUser
{
	[self updateKeychainData:_hostName user:newUser password:_password force:NO];
	
	[_username autorelease];
	_username = [newUser copy];
	[self updateCellData];
}

- (void)setPassword:(NSString *)newPassword
{
	[self updateKeychainData:_hostName user:_username password:newPassword force:NO];
	
	[_password autorelease];
	_password = [newPassword copy];
}

- (void)setPort:(int)newPort
{
	if (port == newPort)
		return;
		
	port = newPort;
	[self updateCellData];
}

- (void)setSavePassword:(BOOL)saves
{
	savePassword = saves;
	
	if (!savePassword)	
		[self clearKeychainData];
	else
		[self updateKeychainData:_hostName user:_username password:_password force:YES];
}

@end


#pragma mark -

@implementation CRDSession (Private)

#pragma mark -
#pragma mark Represented file

- (BOOL)readFileAtPath:(NSString *)path
{
	if ([path length] == 0 || ![[NSFileManager defaultManager] isReadableFileAtPath:path])
		return NO;

	NSString *fileContents = [NSString stringWithContentsOfFile:path usedEncoding:&fileEncoding error:NULL];
			
	if (fileContents == nil)
		fileContents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
	
	NSArray *fileLines = [fileContents componentsSeparatedByString:@"\r\n"];

	if (fileLines == nil)
	{
		CRDLog(CRDLogLevelError, @"Couldn't open RDP file '%@'!", path);
		return NO;
	}
		
	[self setFilename:path];
		
	NSScanner *scan;
	NSCharacterSet *colonSet = [NSCharacterSet characterSetWithCharactersInString:@":"],
				   *emptySet = [NSCharacterSet characterSetWithCharactersInString:@""];
				   
	NSString *name, *type, *value;
	int numVal = 0;
	BOOL b;
	
	// Extract the name, type, and value from each line and load into ivars
	id line;
	for (line in fileLines)
	{
		scan = [NSScanner scannerWithString:line];
		[scan setCharactersToBeSkipped:colonSet];
		
		b = YES;
		b &= [scan scanUpToCharactersFromSet:colonSet intoString:&name];
		b &= [scan scanUpToCharactersFromSet:colonSet intoString:&type];
		
		if (![scan scanUpToCharactersFromSet:emptySet intoString:&value])
			value = @"";
		
		// Don't use KVC because none of the side effects in the setters are desirable at load time
		
		if (!b)
			continue;
			
		
		if ([type isEqualToString:@"i"])
			numVal = [value integerValue];
		
		if ([name isEqualToString:@"connect to console"])
			consoleSession = numVal;
		else if ([name isEqualToString:@"redirectdrives"])
			forwardDisks = numVal;
		else if ([name isEqualToString:@"redirectprinters"])
			forwardPrinters = numVal;
		else if ([name isEqualToString:@"disable wallpaper"])
			drawDesktop = !numVal;
		else if ([name isEqualToString:@"disable full window drag"])
			windowDrags = !numVal;
		else if ([name isEqualToString:@"disable menu anims"])
			windowAnimation = !numVal;
		else if ([name isEqualToString:@"disable themes"])
			themes = !numVal;
		else if ([name isEqualToString:@"disable font smoothing"])
			fontSmoothing = !numVal;
		else if ([name isEqualToString:@"audiomode"])
			_forwardAudio = numVal;
		else if ([name isEqualToString:@"desktopwidth"]) 
			screenWidth = numVal;
		else if ([name isEqualToString:@"desktopheight"]) 
			screenHeight = numVal;
		else if ([name isEqualToString:@"session bpp"]) 
			screenDepth = numVal;
		else if ([name isEqualToString:@"username"])
			_username = [value retain];
		else if ([name isEqualToString:@"cord save password"]) 
			savePassword = numVal;
		else if ([name isEqualToString:@"domain"])
			_domain = [value retain];
		else if ([name isEqualToString:@"cord label"])
			_label = [value retain];
		else if ([name isEqualToString:@"cord row index"])
			preferredRowIndex = numVal;
		else if ([name isEqualToString:@"full address"]) {
			CRDSplitHostNameAndPort(value, &_hostName, &port);
			[_hostName retain];
		}
		else if ([name isEqualToString:@"cord fullscreen"])
			fullscreen = numVal;
		else if ([name isEqualToString:@"cord displayMode"])
			_displayMode = numVal;
		else if ([name isEqualToString:@"cord hotkey"]) {
			_hotkey = (numVal == 0) ? (-1) : numVal;
		}

		else
		{
			if ([type isEqualToString:@"i"])
				otherAttributes[name] = @(numVal);
			else
				otherAttributes[name] = value;
		}
	}
		
	_modified = NO;
	[self setIsTemporary:NO];
	
	if (savePassword)
	{
		const char *pass = keychain_get_password([_hostName UTF8String], [_username UTF8String]);
		if (pass != NULL)
		{
			_password = [@(pass) retain];
			free((void*)pass);
		}
	}
	
	[self updateCellData];
	
	return YES;
}


#pragma mark -
#pragma mark Keychain

// Force makes it save data to keychain regardless if it has changed. savePassword  is always respected.
- (void)updateKeychainData:(NSString *)newHost user:(NSString *)newUser password:(NSString *)newPassword force:(BOOL)force
{
	if (savePassword && (force || ![_hostName isEqualToString:newHost] || ![_username isEqualToString:newUser] || ![_password isEqualToString:newPassword]) )
	{
		keychain_update_password([_hostName UTF8String], [_username UTF8String], [newHost UTF8String], [newUser UTF8String], [newPassword UTF8String]);
	}
}


#pragma mark -
#pragma mark Connection status

- (void)setStatus:(CRDConnectionStatus)newStatus
{
	[_cellRepresentation setStatus:newStatus];
	_connectionStatus = newStatus;
	[self updateCellData];
}

// Status needs to be set on the main thread when setting it to Connecting so the the CRDServerCell will create its progress indicator timer in the main run loop
- (void)setStatusAsNumber:(NSNumber *)newStatus
{
	[self setStatus:[newStatus intValue]];
}


#pragma mark -
#pragma mark User Interface

- (void)createScrollEnclosure:(NSRect)frame
{
	[scrollEnclosure release];
	scrollEnclosure = [[NSScrollView alloc] initWithFrame:frame];
	[_view setAutoresizingMask:NSViewNotSizable];
	[_view setFrame:NSMakeRect(0,0, [_view width], [_view height])];
	[scrollEnclosure setAutoresizingMask:(NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin | NSViewWidthSizable | NSViewHeightSizable)];
	[scrollEnclosure setDocumentView:_view];
	[scrollEnclosure setHasVerticalScroller:YES];
	[scrollEnclosure setHasHorizontalScroller:YES];
	[scrollEnclosure setAutohidesScrollers:YES];
	[scrollEnclosure setBorderType:NSNoBorder];
	[scrollEnclosure setDrawsBackground:NO];
}

- (void)createViewWithFrameValue:(NSValue *)frameRect
{	
	if (_conn == NULL)
		return;
	
	_view = [[CRDSessionView alloc] initWithFrame:[frameRect rectValue]];
	[_view setController:self];
	_conn->ui = _view;
}


#pragma mark -
#pragma mark General

- (void)setUpConnectionThread
{
	@synchronized(self)
	{
		connectionThread = [NSThread currentThread];
		connectionRunLoop  = [NSRunLoop currentRunLoop];

		inputEventPort = [[NSMachPort alloc] init];
		[inputEventPort setDelegate:self];
		[connectionRunLoop addPort:inputEventPort forMode:(NSString *)kCFRunLoopCommonModes];
	}
}

- (void)discardConnectionThread
{
	@synchronized(self)
	{
		[connectionRunLoop removePort:inputEventPort forMode:(NSString *)kCFRunLoopCommonModes];
		[inputEventPort invalidate];
		[inputEventPort release];
		inputEventPort = nil;
	
		@synchronized(inputEventStack)
		{
			while ([inputEventStack count] != 0)
			{
				free([inputEventStack[0] pointerValue]);
				[inputEventStack removeObjectAtIndex:0];
			}
		}
		
		connectionThread = nil;
		connectionRunLoop = nil;
	}
}

@end

