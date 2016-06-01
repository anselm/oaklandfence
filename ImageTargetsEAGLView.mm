
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <sys/time.h>

#import <Vuforia/Vuforia.h>
#import <Vuforia/State.h>
#import <Vuforia/Tool.h>
#import <Vuforia/Renderer.h>
#import <Vuforia/TrackableResult.h>
#import <Vuforia/ImageTarget.h>
#import <Vuforia/VideoBackgroundConfig.h>
#import <Vuforia/DataSet.h>

#import "ImageTargetsEAGLView.h"
#import "Texture.h"
#import "SampleApplicationUtils.h"
#import "SampleApplicationShaderUtils.h"
#import "Quad.h"

#import "videoPlayerHelper.h"

//******************************************************************************
// *** OpenGL ES thread safety ***
//
// OpenGL ES on iOS is not thread safe.  We ensure thread safety by following
// this procedure:
// 1) Create the OpenGL ES context on the main thread.
// 2) Start the Vuforia camera, which causes Vuforia to locate our EAGLView and start
//    the render thread.
// 3) Vuforia calls our renderFrameVuforia method periodically on the render thread.
//    The first time this happens, the defaultFramebuffer does not exist, so it
//    is created with a call to createFramebuffer.  createFramebuffer is called
//    on the main thread in order to safely allocate the OpenGL ES storage,
//    which is shared with the drawable layer.  The render (background) thread
//    is blocked during the call to createFramebuffer, thus ensuring no
//    concurrent use of the OpenGL ES context.
//
//******************************************************************************

namespace {

#define VIDEOZOOM 215

    NSString* serverName = @"oaklandfenceproject.org.s3-website-us-west-1.amazonaws.com";

    // Model scale factor
    float targetAspect = 1.0f;
    float projectionAspect = 1.0f;
    float videoAspect = 0.5625f;

    GLint framebufferWidth;
    GLint framebufferHeight;
    
    // Video quad texture coordinates
    const GLfloat videoQuadTextureCoords[] = {
        0.0, 1.0,
        1.0, 1.0,
        1.0, 0.0,
        0.0, 0.0,
    };

    VideoPlayerHelper* videoPlayerHelper;
    float videoPlaybackTime;

    // Lock to synchronise data that is (potentially) accessed concurrently
    NSLock* dataLock;

    int playState = -2;  // state machine
    int playCode;   //
    int playCount;  // state counter
    float playSlerp;    // animation slerp timer
    NSString *playName; // name of image found
    
    Texture* introTextureHandle = 0;        // a banner image
    Texture* defaultTextureHandle = 0;      // a fall back image for network failures
    Texture* videoTextureHandle = 0;        // a fake texture that to overload with video
    Texture* preambleTextureHandle = 0;     // prior to the video playing show this image
    Texture* bumperTextureHandle = 0;       // after the video wraps up show this image
    
    Texture* textureHandle = 0;             // currently active texture handle

    GLKTextureInfo* text = 0;
    
    GLKMatrix4 glmvp44;
    GLKMatrix4 pose;
    
    BOOL touched = NO;
    CGPoint touchpoint;
    
    // scale up source vertices to avoid adjusting the kObjectScaleNormal too much because that creates jitter - I guessed that 128 was exact.
    static const float quadVertices2[kNumQuadVertices * 3] = {
        -128.00f,  -128.00f,  0.0f,
        128.00f,  -128.00f,  0.0f,
        128.00f,   128.00f,  0.0f,
        -128.00f,   128.00f,  0.0f,
    };
}


@interface ImageTargetsEAGLView (PrivateMethods)
- (void)initShaders;
- (void)createFramebuffer;
- (void)deleteFramebuffer;
- (void)setFramebuffer;
- (BOOL)presentFramebuffer;
@end


@implementation ImageTargetsEAGLView

@synthesize vapp = vapp;

+ (Class)layerClass {
    return [CAEAGLLayer class];
}

//------------------------------------------------------------------------------
#pragma mark - Lifecycle

- (id)initWithFrame:(CGRect)frame appSession:(SampleApplicationSession *) app
{
    self = [super initWithFrame:frame];
    
    if (!self) return 0;

    vapp = app;
    
    if (YES == [vapp isRetinaDisplay]) {
        [self setContentScaleFactor:[UIScreen mainScreen].nativeScale];
    }
    
    context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    
    if (context != [EAGLContext currentContext]) {
        [EAGLContext setCurrentContext:context];
    }
    
    [self initShaders];
    
    videoPlayerHelper = [[VideoPlayerHelper alloc] initMe];
    videoPlaybackTime = VIDEO_PLAYBACK_CURRENT_POSITION;
    
    defaultTextureHandle = [[Texture alloc] initWithImageFile:@"default.png"];
    introTextureHandle = [[Texture alloc] initWithImageFile:@"startscreen.png"];
    videoTextureHandle = [[Texture alloc] initWithImageFile:@"intro.png"];
    
    //text = [self makeText:@"hello"];

    return self;
}

- (GLKTextureInfo*)makeText:(NSString*)words {
    
    CGSize size = CGSizeMake(1024,1024);
    float scale = [[UIScreen mainScreen] scale];
    
    UIGraphicsBeginImageContextWithOptions(size, NO, scale);

    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextScaleCTM(c, 1, -1);
    CGContextSetRGBFillColor(c, 1.0, 1.0, 0.0, 1.0);
    CGContextSetLineWidth(c, 2.0);
    //CGContextSelectFont(c, "Helvetica", 10.0, kCGEncodingMacRoman);
    CGContextSetCharacterSpacing(c, 1.7);
    CGContextSetTextDrawingMode(c, kCGTextFill);
    //CGContextShowTextAtPoint(c, 100.0, 100.0, "SOME TEXT", 9);
    CGContextSetTextDrawingMode(c, kCGTextFill);
    [[UIColor redColor] setFill];
    [words drawAtPoint:CGPointMake(512, 512) withAttributes:@{NSFontAttributeName:[UIFont fontWithName:@"Helvetica"  size:17]}];
    
    
    // drawing with a white stroke color
    CGContextSetRGBStrokeColor(c, 1.0, 1.0, 1.0, 1.0);
    // drawing with a white fill color
    CGContextSetRGBFillColor(c, 1.0, 1.0, 1.0, 1.0);
    // Add Filled Rectangle,
    CGContextFillRect(c, CGRectMake(0.0, 0.0, 500, 500));

    
    CGImageRef image =  CGBitmapContextCreateImage(c);

    UIGraphicsEndImageContext();
    
    GLKTextureInfo *texture = [GLKTextureLoader textureWithCGImage:image options:nil error:nil];
    CGImageRelease(image);

    return texture;
}

- (void)dealloc {
    [self deleteFramebuffer];
    if ([EAGLContext currentContext] == context) {
        [EAGLContext setCurrentContext:nil];
    }
    defaultTextureHandle = 0;
    textureHandle = 0;
    preambleTextureHandle = 0;
    bumperTextureHandle = 0;
    for (int i = 0; i < kMaxAugmentationTextures; ++i) {
        textures[i] = nil;
    }
    [videoPlayerHelper unload];
    videoPlayerHelper = nil;
}

- (void)finishOpenGLESCommands {
    if (context) {
        [EAGLContext setCurrentContext:context];
        glFinish();
    }
}

- (void)freeOpenGLESResources {
    [self deleteFramebuffer];
    glFinish();
}

//------------------------------------------------------------------------------
#pragma mark - OpenGL ES management

- (void)initShaders {
    shaderProgramID = [SampleApplicationShaderUtils createProgramWithVertexShaderFileName:@"Simple.vertsh" fragmentShaderFileName:@"Simple.fragsh"];
    if (shaderProgramID <= 0) {
        NSLog(@"Could not initialise augmentation shader");
        return;
    }
    vertexHandle = glGetAttribLocation(shaderProgramID, "vertexPosition");
    normalHandle = glGetAttribLocation(shaderProgramID, "vertexNormal");
    textureCoordHandle = glGetAttribLocation(shaderProgramID, "vertexTexCoord");
    mvpMatrixHandle = glGetUniformLocation(shaderProgramID, "modelViewProjectionMatrix");
    texSampler2DHandle  = glGetUniformLocation(shaderProgramID,"texSampler2D");
}

- (void)createFramebuffer {
    if (!context) {
        return;
    }
    glGenFramebuffers(1, &defaultFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, defaultFramebuffer);
    
    glGenRenderbuffers(1, &colorRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
    
    [context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer*)self.layer];
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &framebufferWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &framebufferHeight);
    
    glGenRenderbuffers(1, &depthRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, depthRenderbuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, framebufferWidth, framebufferHeight);
    
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, colorRenderbuffer);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthRenderbuffer);
    
    glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
}

- (void)deleteFramebuffer {

    if (!context) {
        return;
    }

    [EAGLContext setCurrentContext:context];
    
    if (defaultFramebuffer) {
        glDeleteFramebuffers(1, &defaultFramebuffer);
        defaultFramebuffer = 0;
    }
    
    if (colorRenderbuffer) {
        glDeleteRenderbuffers(1, &colorRenderbuffer);
        colorRenderbuffer = 0;
    }
    
    if (depthRenderbuffer) {
        glDeleteRenderbuffers(1, &depthRenderbuffer);
        depthRenderbuffer = 0;
    }
}

- (void)setFramebuffer {
    if (context != [EAGLContext currentContext]) {
        [EAGLContext setCurrentContext:context];
    }
    if (!defaultFramebuffer) {
        [self performSelectorOnMainThread:@selector(createFramebuffer) withObject:self waitUntilDone:YES];
    }
    glBindFramebuffer(GL_FRAMEBUFFER, defaultFramebuffer);
}

- (BOOL)presentFramebuffer {
    glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
    return [context presentRenderbuffer:GL_RENDERBUFFER];
}

- (void) handleTouchPoint:(CGPoint)point {
    touched = YES;
    touchpoint = point;
}

GLKVector3 GLKVector3Slerp(GLKVector3 a, GLKVector3 b, float slerp) {
    return { a.v[0] * (1-slerp) + b.v[0] * slerp, a.v[1] * (1-slerp) + b.v[1] * slerp, a.v[2] * (1-slerp) + b.v[2] * slerp };
}

//------------------------------------------------------------------------------
#pragma mark - UIGLViewProtocol methods

- (void)renderFrameVuforia
{
    [self setFramebuffer];
    
    {
        // Clear colour and depth buffers
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        
        // Render video background and retrieve tracking state
        Vuforia::State state = Vuforia::Renderer::getInstance().begin();

        {
            // a bit of a hack - when an image is full screen don't render camera
            //if(playSlerp<1)
            Vuforia::Renderer::getInstance().drawVideoBackground();
            
            glDisable(GL_DEPTH_TEST);
            glDisable(GL_CULL_FACE);
            //glCullFace(GL_BACK);
            if(Vuforia::Renderer::getInstance().getVideoBackgroundConfig().mReflection == Vuforia::VIDEO_BACKGROUND_REFLECTION_ON)
                glFrontFace(GL_CW);  //Front camera
            else
                glFrontFace(GL_CCW);   //Back camera
            
            glViewport(vapp.viewport.posX, vapp.viewport.posY, vapp.viewport.sizeX, vapp.viewport.sizeY);
            
            [self renderTrackablesNew:state];
        
            glDisable(GL_DEPTH_TEST);
            glDisable(GL_CULL_FACE);
        }

        Vuforia::Renderer::getInstance().end();
    }

    [self presentFramebuffer];

}

//------------------------------------------------------------------------------
#pragma mark - touch handling


#define FRAMES_BEFORE_ZOOM 10
#define FRAMES_DURING_ZOOM 5

- (UIViewController *)parentViewController {
    UIResponder *responder = self;
    while ([responder isKindOfClass:[UIView class]]) responder = [responder nextResponder];
    return (UIViewController *)responder;
}

- (NSString*) findSupporter:(NSString*)name {
    // XXX this is pretty sloppy...
    if( [name isEqualToString:@"fantastic1"]) return @"fantasticnegrito.com";
    if( [name isEqualToString:@"fantastic2"]) return @"fantasticnegrito.com";
    if( [name isEqualToString:@"fantastic3"]) return @"fantasticnegrito.com";
    if( [name isEqualToString:@"fantastic4"]) return @"fantasticnegrito.com";
    if( [name isEqualToString:@"fantastic5"]) return @"fantasticnegrito.com";
    if( [name isEqualToString:@"fantastic6"]) return @"fantasticnegrito.com";
    if( [name isEqualToString:@"sunshine1"]) return @"instagram.com/demahjiae";
    if( [name isEqualToString:@"silas1"]) return @"instagram.com/ovrkast";
    if( [name isEqualToString:@"tonea1"]) return nil;
    if( [name isEqualToString:@"britt1"]) return @"brittsense.com";
    if( [name isEqualToString:@"britt2"]) return @"brittsense.com";
    if( [name isEqualToString:@"tyrone"]) return @"chrisjohnsonphotographer.com";
    return nil;
}

- (NSString*) findLearn:(NSString*)name {
    // XXX this is pretty sloppy...
    if( [name isEqualToString:@"fantastic1"]) return @"www.todaysfuturesound.org";
    if( [name isEqualToString:@"fantastic2"]) return @"blavity.com";
    if( [name isEqualToString:@"fantastic3"]) return @"www.accfb.org";
    if( [name isEqualToString:@"fantastic4"]) return @"acsbcd.org";
    if( [name isEqualToString:@"fantastic5"]) return @"protectoaklandkids.org";
    if( [name isEqualToString:@"fantastic6"]) return @"www.eocp.net";
    if( [name isEqualToString:@"sunshine1"]) return @"www.hiddengeniusproject.org";
    if( [name isEqualToString:@"silas1"]) return @"www.eastsideartsalliance.com";
    if( [name isEqualToString:@"tonea1"]) return @"www.xanthos.org/behavioral-health-care-services.html";
    if( [name isEqualToString:@"britt1"]) return @"eoydc.org";
    if( [name isEqualToString:@"britt2"]) return @"www.destinyarts.org";
    if( [name isEqualToString:@"tyrone"]) return @"www.hiddengeniusproject.org";
    return nil;
}

- (void) bumperTouch {
    
    if(!touched) return;
    touched = NO;
    NSLog(@"state 3: touched at %f,%f",touchpoint.x,touchpoint.y);

    CGRect mainBounds = [[UIScreen mainScreen] bounds];

    int state = 10;
    if(touchpoint.x > mainBounds.size.width * 0.8f) {
        // top row
        if(touchpoint.y < mainBounds.size.height * 0.2f) {
            // home
            state = 20;
        } else if(touchpoint.y < mainBounds.size.height * 0.65f) {
            // nothing
        } else {
            // menu
            state = 30;
        }
    } else if (touchpoint.x > mainBounds.size.width * 0.2f) {
        // middle row
        if(touchpoint.y < mainBounds.size.height * 0.36f) {
            // support
            state = 40;
        } else if(touchpoint.y < mainBounds.size.height * 0.65f) {
            // learn
            state = 50;
        } else {
            // join
            state = 60;
        }
    } else {
        // bottom row
        if(touchpoint.y < mainBounds.size.height * 0.2) {
            // replay
            state = 70;
        } else if(touchpoint.y < mainBounds.size.height * 0.56f) {
            // nothing
        } else if(touchpoint.y < mainBounds.size.height * 0.66f) {
            // facebook
            state = 80;
        } else if(touchpoint.y < mainBounds.size.height * 0.76f) {
            // twitter
            state = 90;
        } else if(touchpoint.y < mainBounds.size.height * 0.86f) {
            // instagram
            state = 100;
        } else if(touchpoint.y < mainBounds.size.height * 0.86f) {
            // mail
            state = 110;
        }
    }
    
    switch(state) {
        case 10:
            break;
        case 20:
            // fall through
        case 30:
            NSLog(@"button: home & menu");
            playCount = 0;
            playState = 4;
            break;
        case 40:
            if(TRUE) {
                NSLog(@"button: support an artist");
                [videoPlayerHelper setPlayImmediately:FALSE];
                [videoPlayerHelper stop];
                playSlerp = 0;
                playCount = 0;
                playCode = -1;
                textureHandle = 0;
                playState = 999;
                NSString* path = [self findSupporter:playName];
                if(path) {
                    NSString *urlstr = [NSString stringWithFormat:@"http://%@",path];
                    //NSString *urlstr = [NSString stringWithFormat:@"http://%@/%@-more.html",serverName,playName];
                    NSURL *url = [NSURL URLWithString:urlstr];
                    [[UIApplication sharedApplication] openURL:url];
                }
            }
            break;
        case 50:
            if(TRUE) {
                NSLog(@"button: learn more");
                [videoPlayerHelper setPlayImmediately:FALSE];
                [videoPlayerHelper stop];
                playSlerp = 0;
                playCount = 0;
                playCode = -1;
                textureHandle = 0;
                playState = 999;
                NSString* path = [self findLearn:playName];
                if(path) {
                    NSString *urlstr = [NSString stringWithFormat:@"http://%@",path];
                    //NSString *urlstr = [NSString stringWithFormat:@"http://%@/%@-more.html",serverName,playName];
                    NSURL *url = [NSURL URLWithString:urlstr];
                    [[UIApplication sharedApplication] openURL:url];
                }
            }
            break;
        case 60:
            if(TRUE) {
                NSLog(@"button: help");
                [videoPlayerHelper setPlayImmediately:FALSE];
                [videoPlayerHelper stop];
                playSlerp = 0;
                playCount = 0;
                playCode = -1;
                textureHandle = 0;
                playState = 999;
                NSURL *url = [NSURL URLWithString:@"http://oaklandfenceproject.org/volunteer"];
                [[UIApplication sharedApplication] openURL:url];
            }
            break;
        case 70:
            if(TRUE) {
                NSLog(@"button: replay");
                playCount = 0;
                playSlerp = 1;
                textureHandle = preambleTextureHandle;
                if(FALSE) {
                    playState = 1;
                    NSString* url = [NSString stringWithFormat:@"http://%@/%@.mp4",serverName,playName];
                    [videoPlayerHelper stop];
                    [videoPlayerHelper unload];
                    [videoPlayerHelper setPlayImmediately:TRUE];
                    [videoPlayerHelper load:url fromPosition:0];
                } else {
                    playState = 2;
                    videoTextureHandle.textureID = 0;
                    [videoPlayerHelper setPlayImmediately:TRUE];
                    [videoPlayerHelper replay];
                }
            }
            break;
        case 80:
            //facebook
            [videoPlayerHelper setPlayImmediately:FALSE];
            [videoPlayerHelper stop];
            playSlerp = 0;
            playCount = 0;
            playCode = -1;
            textureHandle = 0;
            playState = 999;
            if(![[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"fb://profile"]]) {
                [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://www.facebook.com/oaklandfenceproject"]];
            }
            break;
        case 90:
            //twitter
            [videoPlayerHelper setPlayImmediately:FALSE];
            [videoPlayerHelper stop];
            playSlerp = 0;
            playCount = 0;
            playCode = -1;
            textureHandle = 0;
            playState = 999;
            if(![[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"twitter://user?screen_name=oaklandfenceproject"]]) {
                [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://twitter.com/oaklandfenceproject"]];
            }
            break;
        case 100:
            if(TRUE) {
                [videoPlayerHelper setPlayImmediately:FALSE];
                [videoPlayerHelper stop];
                playSlerp = 0;
                playCount = 0;
                playCode = -1;
                textureHandle = 0;
                playState = 999;
                NSURL *instagramURL = [NSURL URLWithString:@"instagram://user?username=USERNAME"];
                if ([[UIApplication sharedApplication] canOpenURL:instagramURL]) {
                    [[UIApplication sharedApplication] openURL:instagramURL];
                }
            }
            break;
        case 110:
            // mail
            if(TRUE) {
                [videoPlayerHelper setPlayImmediately:FALSE];
                [videoPlayerHelper stop];
                playSlerp = 0;
                playCount = 0;
                playCode = -1;
                textureHandle = 0;
                playState = 999;
                NSString *subject = [NSString stringWithFormat:@"oaklandfenceproject.org"];
                NSString *mail = [NSString stringWithFormat:@"Check out the oaklandfenceproject at http://oaklandfenceproject.org!"];
                NSURL *url = [[NSURL alloc] initWithString:[NSString stringWithFormat:@"mailto:?to=%@&subject=%@",
                                                            [mail stringByAddingPercentEscapesUsingEncoding:NSASCIIStringEncoding],
                                                            [subject stringByAddingPercentEscapesUsingEncoding:NSASCIIStringEncoding]]];
                [[UIApplication sharedApplication] openURL:url];
            }
            break;
        case 120:
            break;
    }
}

//------------------------------------------------------------------------------
#pragma mark - state engine

- (void) stateSet:(int)state texture:(Texture*)texture slerp:(float)slerp {
    playState = state;          // set state
    playCount = 0;              // reset a state timer helper
    playCode = -1;              // reset the id of the last seen marker to nothing
    playSlerp = slerp;              // typically wipe the front facing image
    textureHandle = texture;    // set which front facing image will be up
}

- (void) renderTrackablesNew:(Vuforia::State)state {
 
    //[dataLock lock];

    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // state engine
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
 
    MEDIA_STATE currentStatus = [videoPlayerHelper getStatus];
    int numActiveTrackables = state.getNumTrackableResults();

    // try to always use the default aspect - which can be set by the target
    targetAspect = projectionAspect;

    switch(playState) {
        case -2:
            if(touched) {
                touched = 0;
                [self stateSet:0 texture:nil slerp:0];
            } else {
                [self stateSet:playState texture:introTextureHandle slerp:0.999];
            }
            break;

        case -1:
            // force a delay so replays cannot happen so easily
            playCount++;
            if(playCount>60*2) {
                [self stateSet:0 texture:nil slerp:0];
            }
            break;

        case 0:
            // looking for a target
            // once a given target has been observed for n frames then go to state 1
            if(numActiveTrackables>0) {
                const Vuforia::TrackableResult* trackableResult = state.getTrackableResult(0);
                const Vuforia::ImageTarget& imageTarget = (const Vuforia::ImageTarget&) trackableResult->getTrackable();
                
                // Get size and aspect ratio
                {
                    Vuforia::Vec3F size = imageTarget.getSize();
                    float targetWidth = size.data[0];
                    float targetHeight = size.data[1];
                    projectionAspect = targetAspect = targetHeight/targetWidth;
                }
                
                // keep counting how long we see this id
                if(playCode == imageTarget.getId() && textureHandle != nil) {
                    playCount++;
                    if(playCount > FRAMES_BEFORE_ZOOM) {
                        playCount = 0;
                        videoTextureHandle.textureID = 0;
                        playSlerp = 0;
                        NSString  *name = [NSString stringWithFormat:@"%s",imageTarget.getName()];
                        if(playName != nil && [playName isEqualToString:name] && currentStatus == STOPPED) {
                            // If the last video is the same video and it is stopped then simply restart it
                            playName = name;
                            if(TRUE) {
                                playState = 2;
                                NSString* url = [NSString stringWithFormat:@"http://%@/%@.mp4",serverName,playName];
                                [videoPlayerHelper stop];
                                [videoPlayerHelper unload];
                                [videoPlayerHelper setPlayImmediately:TRUE];
                                [videoPlayerHelper load:url fromPosition:0];
                            } else {
                                // unused approach - couldn't replay sadly so forced to reload
                                playState = 2;
                                videoTextureHandle.textureID = 0;
                                [videoPlayerHelper setPlayImmediately:TRUE];
                                [videoPlayerHelper replay];
                            }
                            NSLog(@"state 0->2: playing same video again");
                        } else {
                            // play a different video
                            playState = 2;
                            playName = name;
                            NSString* url = [NSString stringWithFormat:@"http://%@/%@.mp4",serverName,playName];
                            [videoPlayerHelper stop];
                            [videoPlayerHelper unload];
                            [videoPlayerHelper setPlayImmediately:TRUE];
                            [videoPlayerHelper load:url fromPosition:0];
                            NSLog(@"state 0->1: entering interstitial zoom");
                        }
                    }
                } else {
                    // am seeing a new image - may as well start showing it NOW (prior to state transition)
                    // immediately set the texturehandle - to begin showing the new image
                    playCount = 0;
                    playCode = imageTarget.getId();
                    NSString  *name = [NSString stringWithFormat:@"%s",imageTarget.getName()];
                    preambleTextureHandle = [self renderGetTexture:name];
                    bumperTextureHandle = [self renderGetTextureBumper:name];
                    textureHandle = preambleTextureHandle;
                    NSLog(@"state 0: found target");
                }
            }
            break;
            
        case 1:
            playState = 2;
/*
            // present interstitial image for "a while"
            // this gives the video time to prebuffer
            // it may be that the video arrives prior to this reaching full screen
            // or the video could arrive after
            // in either case we transition out of this mode after a moment, but continue to zoom in
            // continue zooming in on previously established texture

            playSlerp = playSlerp + 0.03f; if(playSlerp>1) playSlerp = 1;

            playCount++;
            if(playCount > FRAMES_DURING_ZOOM) {
                playCount = 0;
                playState = 2;
                NSLog(@"state 1->2: allowing video to display");
            }

            // touch during warm up to just stop
            if(touched) {
                touched = 0;
                [self stateSet:-1 texture:nil slerp:0];
                [videoPlayerHelper stop];
            }

            break;
*/
        case 2:
            
            // touch during play to exit
            if(touched) {
                NSLog(@"state 2->3: touched during play - showing end bumper");
                touched = 0;
                videoTextureHandle.textureID = 0;
                [videoPlayerHelper setPlayImmediately:FALSE];
                [videoPlayerHelper stop];
                [self stateSet:3 texture:bumperTextureHandle slerp:1];
                break;
            }

            switch(currentStatus) {
                case PLAYING: {
                    GLuint t = [videoPlayerHelper updateVideoData];
                    if(t) {
                        playSlerp = playSlerp + 0.05f; if(playSlerp>1) playSlerp = 1;
                        videoTextureHandle.textureID = t;
                        textureHandle = videoTextureHandle;
                        // find the video aspect as soon was we have data
                        videoAspect = (float)[videoPlayerHelper getVideoHeight] / (float)[videoPlayerHelper getVideoWidth];
                    }
                    break;
                }
                case REACHED_END:
                    NSLog(@"state 2->3: Video hit end - showing end bumper");
                    touched = 0;
                    [self stateSet:3 texture:bumperTextureHandle slerp:1];
                    break;

                case PAUSED:
                    if(videoTextureHandle.textureID) {
                        textureHandle = videoTextureHandle;
                    }
                    break;
                    
                case NOT_READY:
                    // thats ok
                    break;

                case ERROR:
                    NSLog(@"Error: something went wrong %d",currentStatus);
                    videoTextureHandle.textureID = 0;
                    [videoPlayerHelper setPlayImmediately:FALSE];
                    [videoPlayerHelper stop];
                    [self stateSet:-1 texture:0 slerp:0];
                    break;
                    
                default:
                    break;
            }
            break;
            
        case 3:

            // show bumper for a while
            textureHandle = bumperTextureHandle;
            playSlerp = 1;
            playCount++;
            if(playCount > 60*5) {
                NSLog(@"state 3->4: Bumper done - going to fade");
                [self stateSet:4 texture:bumperTextureHandle slerp:1];
            }
            
            [self bumperTouch];
            
            break;

        case 4:
            // fade the after blurb away quickly
            playSlerp = playSlerp - 0.1; if(playSlerp<0) playSlerp = 0;
            playCount++;
            if(playCount > 10) {
                videoTextureHandle.textureID = 0;
                [videoPlayerHelper setPlayImmediately:FALSE];
                [videoPlayerHelper stop];
                [self stateSet:-1 texture:nil slerp:0];
                NSLog(@"state 4->end: Fade done");
            }
            break;
            
        case 999:
            playSlerp = playSlerp - 0.1; if(playSlerp<0) playSlerp = 0;
            playState = -1;
            playCount = 0;
            playCode = -1;
            textureHandle = 0;
            videoTextureHandle.textureID = 0;
            [videoPlayerHelper setPlayImmediately:FALSE];
            [videoPlayerHelper stop];
            NSLog(@"state 999: returning to default");
            break;

        default:
            break;
    }
    
    //[dataLock unlock];

    // update pose if we have it - not a big deal if we don't
    if(state.getNumTrackableResults() > 0) {
        [self buildPose:state];
    }

    // render the texture in textureID to an interpolation of pose and animated coordinates
    if(textureHandle && textureHandle.textureID) {
        [self renderQuad];
    }

    /*
    // text
    if(text) {
        [self buildTrans:1];
        [self renderQuad:text.target name:text.name blend:TRUE];
    }
    */

}

- (void) buildPose:(Vuforia::State)state {

    if(state.getNumTrackableResults() < 1) return;

    // Get the trackable
    const Vuforia::TrackableResult* trackableResult = state.getTrackableResult(0);
    
    // Get full pose matrix
    const Vuforia::Matrix34F& trackablePose = trackableResult->getPose();
    Vuforia::Matrix44F qm44 = Vuforia::Tool::convertPose2GLMatrix(trackablePose);
    for(int i=0; i<16; i++) pose.m[i] = qm44.data[i];
}


- (void) renderQuad {
    
    // get translation from matrix
    GLKVector3 glxyz1 = { pose.m[12], pose.m[13], pose.m[14] };
    
    // get rotation from matrix
    GLKQuaternion glrot1 = GLKQuaternionMakeWithMatrix4(pose);
    
    // bounce target
    GLKQuaternion glrot2 = GLKQuaternionMake(-1,0,0,0); // GLKQuaternionMakeWithAngleAndAxis(-3.14159265359,1,0,0);
    GLKVector3 glxyz2 = { 0,0, VIDEOZOOM };

    // slerp to it
    GLKQuaternion glrot = GLKQuaternionSlerp(glrot1,glrot2,playSlerp);
    GLKVector3 glxyz = GLKVector3Slerp(glxyz1,glxyz2,playSlerp);
    
    // remake
    GLKMatrix4 gl44 = GLKMatrix4MakeWithQuaternion(glrot);
    gl44.m[12] = glxyz.v[0];
    gl44.m[13] = glxyz.v[1];
    gl44.m[14] = glxyz.v[2];
    
    BOOL blend = FALSE;
    if(textureHandle == introTextureHandle || textureHandle == bumperTextureHandle) blend = TRUE;
    
    GLuint name = textureHandle.textureID;

    // This is sloppy but the idea is:
    //  - aspect ratio for startup image and preamble and bumper want to be coincidentally similar to the videoAspect
    //  - aspect ratio for the market image wants to be 1

    float aspect = targetAspect * (1.0f - playSlerp) + videoAspect * playSlerp;

    if(textureHandle == videoTextureHandle) {
        aspect = videoAspect;
    } else if(textureHandle == introTextureHandle) {
    } else if(textureHandle == preambleTextureHandle) {
        aspect = projectionAspect;
    } else if(textureHandle == bumperTextureHandle) {
    }
    
    SampleApplicationUtils::scalePoseMatrix(1.0f,aspect,1.0f,&gl44.m[0]);
    //SampleApplicationUtils::scalePoseMatrix(targetWidth, targetWidth * targetAspect,targetWidth,&gl44.m[0]);
    SampleApplicationUtils::multiplyMatrix(&vapp.projectionMatrix.data[0], &gl44.m[0], &glmvp44.m[0]);

    glUseProgram(shaderProgramID);

    glVertexAttribPointer(vertexHandle, 3, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)quadVertices2);
    glVertexAttribPointer(normalHandle, 3, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)quadNormals);

    if(textureHandle == videoTextureHandle) {
        glVertexAttribPointer(textureCoordHandle, 2, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)videoQuadTextureCoords);
    } else {
        glVertexAttribPointer(textureCoordHandle, 2, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)quadTexCoords);
    }

    glEnableVertexAttribArray(vertexHandle);
    glEnableVertexAttribArray(normalHandle);
    glEnableVertexAttribArray(textureCoordHandle);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D,name);
    
    glUniformMatrix4fv(mvpMatrixHandle, 1, GL_FALSE, (GLfloat*)&glmvp44.m[0]);
    glUniform1i(texSampler2DHandle, 0 /*GL_TEXTURE0*/);
    
    if(blend) {
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDepthMask(false);
    } else {
        glDisable(GL_BLEND);
    }
    
    glDrawElements(GL_TRIANGLES, kNumQuadIndices, GL_UNSIGNED_SHORT, (const GLvoid*)quadIndices);

    glDisableVertexAttribArray(vertexHandle);
    glDisableVertexAttribArray(normalHandle);
    glDisableVertexAttribArray(textureCoordHandle);

    glDisable(GL_BLEND);

    SampleApplicationUtils::checkGlError("EAGLView renderFrameVuforia");
    
}

//
// a side process which loads associated jpegs for this particular app
//
- (bool) cacheImages:(NSString *)localname dataSet:(Vuforia::DataSet*)data {

    /*
    UIApplication * application = [UIApplication sharedApplication];
    if([[UIDevice currentDevice] respondsToSelector:@selector(isMultitaskingSupported)]) {
        NSLog(@"Multitasking not supported");
        return NO;
    }
    
    __block UIBackgroundTaskIdentifier background_task;

    background_task = [application beginBackgroundTaskWithExpirationHandler:^ {
        [application endBackgroundTask: background_task];
        background_task = UIBackgroundTaskInvalid;
    }];
    */
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        NSLog(@"Image Loader - running in the background\n");

        // set number of trackables
        numTextures = data->getNumTrackables();

        // texture manager has its own local cache - ask it to update remote if needed - and always move images all into RAM right now
        for(int i = 0; i < numTextures && i < kMaxAugmentationTextures; i++ ) {
            const char* playName = data->getTrackable(i)->getName();
            NSString  *localstr = [NSString stringWithFormat:@"%s.png",playName];
            NSString *urlstr = [NSString stringWithFormat:@"http://%@/%@",serverName,localstr];
            textures[i] = [[Texture alloc] initWithImageFile3:urlstr local:localstr];
            NSLog(@"Image loaded name=%s width=%d height=%d",playName, textures[i].width, textures[i].height);
            //[NSThread sleepForTimeInterval:10];
        }

        // load a parallel set of bumpers
        // XXX inelegant waste of memory - I don't see a quick way to do this timewise, would be better to compose a page procedurally
        for(int i = 0; i < numTextures && i < kMaxAugmentationTextures; i++ ) {
            const char* playName = data->getTrackable(i)->getName();
            NSString  *localstr = [NSString stringWithFormat:@"%s-bumper.png",playName];
            NSString *urlstr = [NSString stringWithFormat:@"http://%@/%@",serverName,localstr];
            texturesBumper[i] = [[Texture alloc] initWithImageFile3:urlstr local:localstr];
            NSLog(@"Image bumper loaded name=%s width=%d height=%d",playName, texturesBumper[i].width, texturesBumper[i].height);
            //[NSThread sleepForTimeInterval:10];
        }

        /*
         [application endBackgroundTask: background_task];
        background_task = UIBackgroundTaskInvalid;
         */
    });

    return YES;
}

- (Texture*) renderGetTexture:(NSString *)name {
    NSString  *localstr = [NSString stringWithFormat:@"%@.png",name];
    for(int i = 0; i < numTextures; i++ ) {
        Texture *tex = textures[i];
        if( [tex.tag isEqualToString:localstr] ) {
            if([tex isLoaded]) {
                GLuint gltexture = tex.textureID;
                if(gltexture == 0) {
                    glGenTextures(1, &gltexture);
                    [tex setTextureID:gltexture];
                    glBindTexture(GL_TEXTURE_2D, gltexture);
                    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, [tex width], [tex height], 0, GL_RGBA, GL_UNSIGNED_BYTE, (GLvoid*)[tex pngData]);
                    //     glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
                    //     glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
                }
                if(gltexture != 0) {
                    return tex;
                }
            }
            break;
        }
     }

    return defaultTextureHandle;
}

- (Texture*) renderGetTextureBumper:(NSString*)name {
    NSString  *localstr = [NSString stringWithFormat:@"%@.png",name];
    for(int i = 0; i < numTextures; i++ ) {
        Texture *tex = textures[i];
        if( [tex.tag isEqualToString:localstr] ) {
            tex = texturesBumper[i];
            if(tex && [tex isLoaded]) {
                GLuint gltexture = tex.textureID;
                if(gltexture == 0) {
                    glGenTextures(1, &gltexture);
                    [tex setTextureID:gltexture];
                    glBindTexture(GL_TEXTURE_2D, gltexture);
                    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, [tex width], [tex height], 0, GL_RGBA, GL_UNSIGNED_BYTE, (GLvoid*)[tex pngData]);
                    //     glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
                    //     glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
                }
                if(gltexture != 0) {
                    return tex;
                }
            }
            break;
        }
    }
    
    return defaultTextureHandle;
}



@end
