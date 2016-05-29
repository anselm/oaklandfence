
#import <UIKit/UIKit.h>

#import <Vuforia/UIGLViewProtocol.h>
#import <Vuforia/DataSet.h>

#import "Texture.h"
#import "SampleApplicationSession.h"
#import "GLResourceHandler.h"

#import <GLKit/GLKit.h>


#define kMaxAugmentationTextures 50

// EAGLView is a subclass of UIView and conforms to the informal protocol UIGLViewProtocol
@interface ImageTargetsEAGLView : UIView <UIGLViewProtocol, GLResourceHandler> {
@private
    // OpenGL ES context
    EAGLContext *context;
    
    // The OpenGL ES names for the framebuffer and renderbuffers used to render
    // to this view
    GLuint defaultFramebuffer;
    GLuint colorRenderbuffer;
    GLuint depthRenderbuffer;

    // Shader handles
    GLuint shaderProgramID;
    GLint vertexHandle;
    GLint normalHandle;
    GLint textureCoordHandle;
    GLint mvpMatrixHandle;
    GLint texSampler2DHandle;
    
    int numTextures;
    Texture* textures[kMaxAugmentationTextures];
    Texture* texturesBumper[kMaxAugmentationTextures];
}

@property (nonatomic, weak) SampleApplicationSession *vapp;
- (id)initWithFrame:(CGRect)frame appSession:(SampleApplicationSession *) app;
- (bool)cacheImages:(NSString *)localname dataSet:(Vuforia::DataSet*)data;
- (void)finishOpenGLESCommands;
- (void)freeOpenGLESResources;
- (void)handleTouchPoint:(CGPoint)point;
@end
