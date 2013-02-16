//
//  CRDAppDelegate.h
//  Cord
//
//  Created by Jon Shier on 1/19/13.
//
//

#import <Foundation/Foundation.h>
#import "CRDShared.h"

@class AppController;
@class CRDServerList;

@interface CRDAppDelegate : NSObject <CRDApplicationDelegate>

@property (assign) AppController *appController;
@property (assign) BOOL appIsTerminating;

@end
