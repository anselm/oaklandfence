/*===============================================================================
Copyright (c) 2016 PTC Inc. All Rights Reserved.

Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.

Vuforia is a trademark of PTC Inc., registered in the United States and other 
countries.
===============================================================================*/

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
    
    NSString* serverName = @"oaklandfenceproject.org.s3-website-us-west-1.amazonaws.com";

    // Model scale factor
    float targetWidth = 0.0f;
    float targetHeight = 0.0f;
    float targetAspect = 1.0f;
    const GLvoid* texCoords;
    GLuint previousTexture = 0;
    
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

    int playState;  // state machine
    int playCode;   //
    int playCount;  // state counter
    float playSlerp;    // animation slerp timer
    NSString *playName; // name of image found
    
    Texture* defaultTextureHandle = 0;
    Texture* textureHandle = 0;
    Texture* textureHandlePreamble = 0;
    Texture* textureHandleBumper = 0;

    GLuint defaultTextureID = 0;
    GLuint textureID = 0;
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
    
    if (self) {
        vapp = app;

        // Enable retina mode if available on this device
        if (YES == [vapp isRetinaDisplay]) {
            [self setContentScaleFactor:[UIScreen mainScreen].nativeScale];
        }

        // Create the OpenGL ES context
        context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        
        // The EAGLContext must be set for each thread that wishes to use it.
        // Set it the first time this method is called (on the main thread)
        if (context != [EAGLContext currentContext]) {
            [EAGLContext setCurrentContext:context];
        }

        [self initShaders];
    
        // start video player
        videoPlayerHelper = [[VideoPlayerHelper alloc] initMe];
        videoPlaybackTime = VIDEO_PLAYBACK_CURRENT_POSITION;

        // manually load a fall back image to use in some cases if no network provided image
        defaultTextureHandle = [[Texture alloc] initWithImageFile:@"default.png"];
        if(defaultTextureHandle != NULL && [defaultTextureHandle isLoaded]) {
            glGenTextures(1, &defaultTextureID);
            [defaultTextureHandle setTextureID:defaultTextureID];
            glBindTexture(GL_TEXTURE_2D, defaultTextureID);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, [defaultTextureHandle width], [defaultTextureHandle height], 0, GL_RGBA, GL_UNSIGNED_BYTE, (GLvoid*)[defaultTextureHandle pngData]);
        }
    }
    
    return self;
}

- (void)dealloc {
    [self deleteFramebuffer];
    if ([EAGLContext currentContext] == context) {
        [EAGLContext setCurrentContext:nil];
    }
    defaultTextureHandle = 0;
    textureHandle = 0;
    textureHandlePreamble = 0;
    textureHandleBumper = 0;
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
    if (0 < shaderProgramID) {
        vertexHandle = glGetAttribLocation(shaderProgramID, "vertexPosition");
        normalHandle = glGetAttribLocation(shaderProgramID, "vertexNormal");
        textureCoordHandle = glGetAttribLocation(shaderProgramID, "vertexTexCoord");
        mvpMatrixHandle = glGetUniformLocation(shaderProgramID, "modelViewProjectionMatrix");
        texSampler2DHandle  = glGetUniformLocation(shaderProgramID,"texSampler2D");
    } else {
        NSLog(@"Could not initialise augmentation shader");
    }
}

- (void)createFramebuffer {
    if (!context) {
        return;
    }
    // Create default framebuffer object
    glGenFramebuffers(1, &defaultFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, defaultFramebuffer);
    
    // Create colour renderbuffer and allocate backing store
    glGenRenderbuffers(1, &colorRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
    
    // Allocate the renderbuffer's storage (shared with the drawable object)
    [context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer*)self.layer];
    GLint framebufferWidth;
    GLint framebufferHeight;
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &framebufferWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &framebufferHeight);
    
    // Create the depth render buffer and allocate storage
    glGenRenderbuffers(1, &depthRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, depthRenderbuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, framebufferWidth, framebufferHeight);
    
    // Attach colour and depth render buffers to the frame buffer
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, colorRenderbuffer);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthRenderbuffer);
    
    // Leave the colour render buffer bound so future rendering operations will act on it
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

#define FRAMES_BEFORE_ZOOM 10
#define FRAMES_DURING_ZOOM 10

- (UIViewController *)parentViewController {
    UIResponder *responder = self;
    while ([responder isKindOfClass:[UIView class]]) responder = [responder nextResponder];
    return (UIViewController *)responder;
}

- (void) renderTrackablesNew:(Vuforia::State)state {
 
    //[dataLock lock];

    // choose static image boundaries every frame unless video chooses to override later on

    textureID = textureHandle ? textureHandle.textureID : 0;
    texCoords = quadTexCoords;

    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // state engine
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
 
    MEDIA_STATE currentStatus = [videoPlayerHelper getStatus];
    int numActiveTrackables = state.getNumTrackableResults();

    switch(playState) {
        case 0:
            // looking for a target
            // once a given target has been observed for n frames then go to state 1
            if(numActiveTrackables>0) {
                const Vuforia::TrackableResult* trackableResult = state.getTrackableResult(0);
                const Vuforia::ImageTarget& imageTarget = (const Vuforia::ImageTarget&) trackableResult->getTrackable();
                if(playCode == imageTarget.getId() && textureHandle != nil) {
                    // keep counting how long we see this id
                    playCount++;
                    if(playCount > FRAMES_BEFORE_ZOOM) {
                        playCount = 0;
                        previousTexture = 0;
                        playSlerp = 0;
                        NSString  *name = [NSString stringWithFormat:@"%s",imageTarget.getName()];
                        if(playName != nil && [playName isEqualToString:name] && currentStatus == STOPPED) {
                            // If the last video is the same video and it is stopped then simply restart it
                            playName = name;
                            if(TRUE) {
                                playState = 1;
                                NSString* url = [NSString stringWithFormat:@"http://%@/%@.mp4",serverName,playName];
                                [videoPlayerHelper stop];
                                [videoPlayerHelper unload];
                                [videoPlayerHelper setPlayImmediately:TRUE];
                                [videoPlayerHelper load:url fromPosition:0];
                            } else {
                                playState = 2;
                                previousTexture = 0;
                                [videoPlayerHelper setPlayImmediately:TRUE];
                                [videoPlayerHelper replay];
                            }
                            NSLog(@"state 0->2: playing same video again");
                        } else {
                            // play a different video
                            playState = 1;
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
                    textureHandlePreamble = [self renderGetTexture:name];
                    textureHandleBumper = [self renderGetTextureBumper:name];
                    textureHandle = textureHandlePreamble;
                    NSLog(@"state 0: found target");
                }
            }
            textureID = textureHandle ? textureHandle.textureID : 0;
            break;
            
        case 1:
            
            // present interstitial image for "a while"
            // this gives the video time to prebuffer
            // it may be that the video arrives prior to this reaching full screen
            // or the video could arrive after
            // in either case we transition out of this mode after a moment, but continue to zoom in
            // continue zooming in on previously established texture

            playSlerp = playSlerp + 0.05f; if(playSlerp>1) playSlerp = 1;
            textureID = textureHandle ? textureHandle.textureID : 0;

            playCount++;
            if(playCount > FRAMES_DURING_ZOOM) {
                playCount = 0;
                playState = 2;
                NSLog(@"state 1->2: allowing video to display");
            }

            // touch during warm up to just stop
            if(touched) {
                touched = 0;
                playState = 0;
                playCount = 0;
                playCode = -1;
                textureHandle = 0;
                [videoPlayerHelper stop];
            }

            break;
            
        case 2:
            
            // play video if any frames (else stick with previous texture handle)
            // continue zooming in
            
            playSlerp = playSlerp + 0.05f; if(playSlerp>1) playSlerp = 1;
            textureID = textureHandle ? textureHandle.textureID : 0;

            // touch during play to exit
            if(touched) {
                touched = 0;
                playState = 3;
                playCount = 0;
                playCode = -1;
                previousTexture = 0;
                textureHandle = textureHandleBumper;
                [videoPlayerHelper setPlayImmediately:FALSE];
                [videoPlayerHelper stop];
            }

            switch(currentStatus) {
                case PLAYING: {
                    GLuint t = [videoPlayerHelper updateVideoData];
                    if(t) previousTexture = t;
                    if(!t) t = previousTexture;
                    if(t) {
                        textureID = t;
                        texCoords = videoQuadTextureCoords;
                    }
                    // arguably use video dimensions but this has very little effect give current hard coded display sizes
                    //targetWidth = (float)[videoPlayerHelper getVideoHeight];
                    //targetHeight = (float)[videoPlayerHelper getVideoWidth];
                    //targetAspect = (float)[videoPlayerHelper getVideoHeight] / (float)[videoPlayerHelper getVideoWidth];
                    break;
                }
                case REACHED_END:
                    NSLog(@"state 2->3: Video hit end - showing end bumper");
                    touched = 0;
                    playState = 3;
                    playCount = 0;
                    playCode = -1;
                    textureHandle = textureHandleBumper;
                    break;

                case PAUSED:
                    if(previousTexture) {
                        textureID = previousTexture;
                        texCoords = videoQuadTextureCoords;
                    }
                    break;
                    
                case NOT_READY:
                    // thats ok
                    break;

                case ERROR:
                    previousTexture = 0;
                    playState = 999;
                    NSLog(@"Error: something went wrong %d",currentStatus);
                    break;
                    
                default:
                    break;
            }
            break;
            
        case 3:

            // show bumper for a while
            textureHandle = textureHandleBumper;
            playSlerp = 1;
            playCount++;
            if(playCount > 60*5) {
                NSLog(@"state 3->4: Bumper done - going to fade");
                playCount = 0;
                playState = 4;
            }
            
            if(touched) {
                touched = NO;
                NSLog(@"state 3: touched at %f,%f",touchpoint.x,touchpoint.y);
                CGRect mainBounds = [[UIScreen mainScreen] bounds];
                if(touchpoint.y < mainBounds.size.height * 0.3f) {
                    if(touchpoint.x > mainBounds.size.width * 0.5f) {
                        NSLog(@"state 3: dismiss");
                        playCount = 0;
                        playState = 4;
                    } else {
                        NSLog(@"state 3: replay touched");
                        playCount = 0;
                        playSlerp = 1;
                        textureHandle = textureHandlePreamble;
                        if(FALSE) {
                            playState = 1;
                            NSString* url = [NSString stringWithFormat:@"http://%@/%@.mp4",serverName,playName];
                            [videoPlayerHelper stop];
                            [videoPlayerHelper unload];
                            [videoPlayerHelper setPlayImmediately:TRUE];
                            [videoPlayerHelper load:url fromPosition:0];
                        } else {
                            playState = 2;
                            previousTexture = 0;
                            [videoPlayerHelper setPlayImmediately:TRUE];
                            [videoPlayerHelper replay];
                        }
                    }
                }
                else if(touchpoint.y < mainBounds.size.height * 0.6f) {
                    [videoPlayerHelper setPlayImmediately:FALSE];
                    [videoPlayerHelper stop];
                    playSlerp = 0;
                    playCount = 0;
                    playCode = -1;
                    textureHandle = 0;
                    playState = 999; // XXX TODO - we really should suspend
                    NSString *urlstr = [NSString stringWithFormat:@"http://%@/%@-more.html",serverName,playName];
                    NSURL *url = [NSURL URLWithString:urlstr];
                    [[UIApplication sharedApplication] openURL:url];
                }
                else {
                    [videoPlayerHelper setPlayImmediately:FALSE];
                    [videoPlayerHelper stop];
                    playSlerp = 0;
                    playCount = 0;
                    playCode = -1;
                    textureHandle = 0;
                    playState = 999; // XXX TODO - we really should suspend
                    NSString *urlstr = [NSString stringWithFormat:@"http://%@/%@-buy.html",serverName,playName];
                    NSURL *url = [NSURL URLWithString:urlstr];
                    [[UIApplication sharedApplication] openURL:url];
                }
            }
            break;

        case 4:
            // fade the after blurb away quickly
            playSlerp = playSlerp - 0.1; if(playSlerp<0) playSlerp = 0;
            playCount++;
            if(playCount > 10) {
                NSLog(@"state 4->end: Fade done");
                playCount = 0;
                playState = 999;
            }
            break;
            
        case 999:
            playSlerp = playSlerp - 0.1; if(playSlerp<0) playSlerp = 0;
            playState = 0;
            playCount = 0;
            playCode = -1;
            textureHandle = 0;
            previousTexture = 0;
            [videoPlayerHelper setPlayImmediately:FALSE];
            [videoPlayerHelper stop];
            break;

        default:
            break;
    }
    
    //[dataLock unlock];

    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // finalize rendering baed on state
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    // render overlay if state engine mode is in a post detection mode
    if(playState < 1) return;

    // if the system doesn't have an idea of what it is going to render then get out
    if(!textureHandle || !textureID) return;

    // update pose if we have it - not a big deal if we don't
    if(state.getNumTrackableResults() > 0) {
        [self buildPose:state];
    }

    // render the texture in textureID to an interpolation of pose and animated coordinates
    [self buildTrans];
    [self renderQuad];

}

- (void) buildPose:(Vuforia::State)state {

    if(state.getNumTrackableResults() < 1) return;

    // Get the trackable
    const Vuforia::TrackableResult* trackableResult = state.getTrackableResult(0);
    const Vuforia::ImageTarget& imageTarget = (const Vuforia::ImageTarget&) trackableResult->getTrackable();
    
    // Get size and aspect ratio
    Vuforia::Vec3F size = imageTarget.getSize();
    targetWidth = size.data[0];
    targetHeight = size.data[1];
    targetAspect = targetHeight/targetWidth;
    
    // Get full pose matrix
    const Vuforia::Matrix34F& trackablePose = trackableResult->getPose();
    Vuforia::Matrix44F qm44 = Vuforia::Tool::convertPose2GLMatrix(trackablePose);
    for(int i=0; i<16; i++) pose.m[i] = qm44.data[i];
}


- (void) buildTrans {

    // get translation from matrix
    GLKVector3 glxyz1 = { pose.m[12], pose.m[13], pose.m[14] };
    
    // get rotation from matrix
    GLKQuaternion glrot1 = GLKQuaternionMakeWithMatrix4(pose);
    
    // bounce target
    GLKQuaternion glrot2 = GLKQuaternionMakeWithAngleAndAxis(-3.14159265359,1,0,0);
    GLKVector3 glxyz2 = { 0,0,220 }; // 200 covers screen, 300 fits with margin

    // slerp to it
    GLKQuaternion glrot = GLKQuaternionSlerp(glrot1,glrot2,playSlerp);
    GLKVector3 glxyz = GLKVector3Slerp(glxyz1,glxyz2,playSlerp);
    
    // remake
    GLKMatrix4 gl44 = GLKMatrix4MakeWithQuaternion(glrot);
    gl44.m[12] = glxyz.v[0];
    gl44.m[13] = glxyz.v[1];
    gl44.m[14] = glxyz.v[2];

    SampleApplicationUtils::scalePoseMatrix(1.0f,targetAspect,1.0f,&gl44.m[0]);
    //SampleApplicationUtils::scalePoseMatrix(targetWidth, targetWidth * targetAspect,targetWidth,&gl44.m[0]);
    SampleApplicationUtils::multiplyMatrix(&vapp.projectionMatrix.data[0], &gl44.m[0], &glmvp44.m[0]);

}

- (void) renderQuad {
    
    glUseProgram(shaderProgramID);
    
    glVertexAttribPointer(vertexHandle, 3, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)quadVertices2);
    glVertexAttribPointer(normalHandle, 3, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)quadNormals);
    glVertexAttribPointer(textureCoordHandle, 2, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)texCoords);

    glEnableVertexAttribArray(vertexHandle);
    glEnableVertexAttribArray(normalHandle);
    glEnableVertexAttribArray(textureCoordHandle);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, textureID);
    
    glUniformMatrix4fv(mvpMatrixHandle, 1, GL_FALSE, (GLfloat*)&glmvp44.m[0]);
    glUniform1i(texSampler2DHandle, 0 /*GL_TEXTURE0*/);
    
    glDrawElements(GL_TRIANGLES, kNumQuadIndices, GL_UNSIGNED_SHORT, (const GLvoid*)quadIndices);
    
    glDisableVertexAttribArray(vertexHandle);
    glDisableVertexAttribArray(normalHandle);
    glDisableVertexAttribArray(textureCoordHandle);
    
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
            NSLog(@"Image Loader - Background time Remaining: %f",[[UIApplication sharedApplication] backgroundTimeRemaining]);
            //[NSThread sleepForTimeInterval:10];
        }

        // load a parallel set of bumpers
        // XXX inelegant waste of memory - I don't see a quick way to do this timewise, would be better to compose a page procedurally
        for(int i = 0; i < numTextures && i < kMaxAugmentationTextures; i++ ) {
            const char* playName = data->getTrackable(i)->getName();
            NSString  *localstr = [NSString stringWithFormat:@"%s-bumper.png",playName];
            NSString *urlstr = [NSString stringWithFormat:@"http://%@/%@",serverName,localstr];
            texturesBumper[i] = [[Texture alloc] initWithImageFile3:urlstr local:localstr];
            NSLog(@"Image Bumper Loader - Background time Remaining: %f",[[UIApplication sharedApplication] backgroundTimeRemaining]);
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
