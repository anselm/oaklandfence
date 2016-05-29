
#import <UIKit/UIKit.h>
#import "GLResourceHandler.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, weak) id<GLResourceHandler> glResourceHandler;
@end

