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

@interface CRDAppDelegate : NSObject <CRDApplicationDelegate>

@property (strong) AppController *appController;

@end
