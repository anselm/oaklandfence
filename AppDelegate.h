
#import <UIKit/UIKit.h>
#import "SampleGLResourceHandler.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, weak) id<SampleGLResourceHandler> glResourceHandler;

@end

