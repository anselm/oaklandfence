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

#import "ImageTargetsEAGLView.h"
#import "Texture.h"
#import "SampleApplicationUtils.h"
#import "SampleApplicationShaderUtils.h"
#import "Quad.h"
#import "Teapot.h"

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

#define kNumAugmentationTextures 1

namespace {
    // --- Data private to this unit ---

    // Teapot texture filenames
    const char* textureFilenames[] = {
        "fantastic1.png",
    };
    // Texture used when rendering augmentation
    Texture* augmentationTexture[kNumAugmentationTextures];
    
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
    const char* playName; // name of image found
    GLKMatrix4 pose;

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

// You must implement this method, which ensures the view's underlying layer is
// of type CAEAGLLayer
+ (Class)layerClass
{
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
        
        // Load the augmentation textures
        for (int i = 0; i < kNumAugmentationTextures; ++i) {
            augmentationTexture[i] = [[Texture alloc] initWithImageFile:[NSString stringWithCString:textureFilenames[i] encoding:NSASCIIStringEncoding]];
            
            int w = [augmentationTexture[i] width];
            int h = [augmentationTexture[0] height];
            NSLog(@"texture is %s %d %d",textureFilenames[i], w,h);

        }

        // Create the OpenGL ES context
        context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        
        // The EAGLContext must be set for each thread that wishes to use it.
        // Set it the first time this method is called (on the main thread)
        if (context != [EAGLContext currentContext]) {
            [EAGLContext setCurrentContext:context];
        }
        
        // Generate the OpenGL ES texture and upload the texture data for use when rendering the augmentation
        for (int i = 0; i < kNumAugmentationTextures; ++i) {
            GLuint textureID;
            glGenTextures(1, &textureID);
            [augmentationTexture[i] setTextureID:textureID];
            glBindTexture(GL_TEXTURE_2D, textureID);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, [augmentationTexture[i] width], [augmentationTexture[i] height], 0, GL_RGBA, GL_UNSIGNED_BYTE, (GLvoid*)[augmentationTexture[i] pngData]);
        }

        [self initShaders];
        
        videoPlayerHelper = [[VideoPlayerHelper alloc] initMe];
        videoPlaybackTime = VIDEO_PLAYBACK_CURRENT_POSITION;
    }
    
    return self;
}


- (void)dealloc {
    [self deleteFramebuffer];
    
    // Tear down context
    if ([EAGLContext currentContext] == context) {
        [EAGLContext setCurrentContext:nil];
    }

    for (int i = 0; i < kNumAugmentationTextures; ++i) {
        augmentationTexture[i] = nil;
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
    shaderProgramID = [SampleApplicationShaderUtils createProgramWithVertexShaderFileName:@"Simple.vertsh"
                                                                   fragmentShaderFileName:@"Simple.fragsh"];

    if (0 < shaderProgramID) {
        vertexHandle = glGetAttribLocation(shaderProgramID, "vertexPosition");
        normalHandle = glGetAttribLocation(shaderProgramID, "vertexNormal");
        textureCoordHandle = glGetAttribLocation(shaderProgramID, "vertexTexCoord");
        mvpMatrixHandle = glGetUniformLocation(shaderProgramID, "modelViewProjectionMatrix");
        texSampler2DHandle  = glGetUniformLocation(shaderProgramID,"texSampler2D");
    }
    else {
        NSLog(@"Could not initialise augmentation shader");
    }
}


- (void)createFramebuffer {
    if (context) {
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
}


- (void)deleteFramebuffer {
    if (context) {
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

- (void) handleTouchPoint {
    playState = 3;
    playCount = 0;
    playCode = -1;
    [videoPlayerHelper pause];
}

- (void) beginLoadingVideo {
    NSString* myfile = @"http://makerlab.com/oaklandfence/fantastic1.mp4";
    //NSString* myfile = @"http://makerlab.com/oaklandfence/big_buck_bunny_240p_50mb.mp4";
    [videoPlayerHelper load:myfile playImmediately:YES fromPosition:0];
    NSLog(@"beginning to load video");
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
            
            [self renderTrackablesOld:state];
        
            glDisable(GL_DEPTH_TEST);
            glDisable(GL_CULL_FACE);
        }

        Vuforia::Renderer::getInstance().end();
    }

    [self presentFramebuffer];

}

#define USETEAPOT FALSE
#define USEGLK TRUE

- (void) renderTrackablesOld:(Vuforia::State)state {

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
    Vuforia::Matrix44F modelViewMatrix = Vuforia::Tool::convertPose2GLMatrix(trackableResult->getPose());
    const Vuforia::Matrix34F& trackablePose = trackableResult->getPose();
    Vuforia::Matrix44F qm44 = Vuforia::Tool::convertPose2GLMatrix(trackablePose);
    for(int i=0; i<16; i++) pose.m[i] = qm44.data[i];

    // get translation from matrix
    GLKVector3 glxyz1 = { pose.m[12], pose.m[13], pose.m[14] };
    
    // get rotation from matrix
    GLKQuaternion glrot1 = GLKQuaternionMakeWithMatrix4(pose);

    // bounce target
    GLKQuaternion glrot2 = GLKQuaternionMakeWithAngleAndAxis(-3.14159265359,1,0,0);
    GLKVector3 glxyz2 = { 0,0,220 }; // 200 covers screen, 300 fits with margin

    // bounce
    static int bounce = 0;
    if(bounce == 0) {
        playSlerp = playSlerp + 0.05f; if(playSlerp>1) { bounce = 1; playSlerp = 1; }
    } else {
        playSlerp = playSlerp - 0.05f; if(playSlerp<0) { bounce = 0; playSlerp = 0; }
    }

    // slerp to it
    GLKQuaternion glrot = GLKQuaternionSlerp(glrot1,glrot2,playSlerp);
    GLKVector3 glxyz = GLKVector3Slerp(glxyz1,glxyz2,playSlerp);

    // remake
    GLKMatrix4 gl44 = GLKMatrix4MakeWithQuaternion(glrot);
    gl44.m[12] = glxyz.v[0];
    gl44.m[13] = glxyz.v[1];
    gl44.m[14] = glxyz.v[2];

    GLKMatrix4 glmvp44;
    Vuforia::Matrix44F modelViewProjection;
    //float kObjectScaleNormal = 1.0f;

    if(USEGLK) {
        //SampleApplicationUtils::translatePoseMatrix(0.0f, 0.0f, kObjectScaleNormal, &gl44.m[0]);
        //SampleApplicationUtils::scalePoseMatrix(kObjectScaleNormal, kObjectScaleNormal, kObjectScaleNormal, &gl44.m[0]);
        SampleApplicationUtils::scalePoseMatrix(1.0f,targetAspect,1.0f,&gl44.m[0]);
        SampleApplicationUtils::multiplyMatrix(&vapp.projectionMatrix.data[0], &gl44.m[0], &glmvp44.m[0]);

    } else {
        //SampleApplicationUtils::translatePoseMatrix(0.0f, 0.0f, kObjectScaleNormal, &modelViewMatrix.data[0]);
        //SampleApplicationUtils::scalePoseMatrix(kObjectScaleNormal, kObjectScaleNormal, kObjectScaleNormal, &modelViewMatrix.data[0]);
        SampleApplicationUtils::scalePoseMatrix(1.0f, targetAspect, 1.0f, &modelViewMatrix.data[0]);
        SampleApplicationUtils::multiplyMatrix(&vapp.projectionMatrix.data[0], &modelViewMatrix.data[0], &modelViewProjection.data[0]);
    }

    // scale up source vertices to avoid adjusting the kObjectScaleNormal too much because that creates jitter - I guessed that 128 was exact.
    static const float quadVertices2[kNumQuadVertices * 3] = {
        -128.00f,  -128.00f,  0.0f,
         128.00f,  -128.00f,  0.0f,
         128.00f,   128.00f,  0.0f,
        -128.00f,   128.00f,  0.0f,
    };

    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    glUseProgram(shaderProgramID);
    
    if(USETEAPOT) {
        glVertexAttribPointer(vertexHandle, 3, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)teapotVertices);
        glVertexAttribPointer(normalHandle, 3, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)teapotNormals);
        glVertexAttribPointer(textureCoordHandle, 2, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)teapotTexCoords);
    } else {
        glVertexAttribPointer(vertexHandle, 3, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)quadVertices2);
        glVertexAttribPointer(normalHandle, 3, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)quadNormals);
        glVertexAttribPointer(textureCoordHandle, 2, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)quadTexCoords);
    }
    
    glEnableVertexAttribArray(vertexHandle);
    glEnableVertexAttribArray(normalHandle);
    glEnableVertexAttribArray(textureCoordHandle);
    
    // Choose the texture based on the target name
    
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, augmentationTexture[0].textureID);

    if(USEGLK) {
        glUniformMatrix4fv(mvpMatrixHandle, 1, GL_FALSE, (GLfloat*)&glmvp44.m[0]);
    } else {
        glUniformMatrix4fv(mvpMatrixHandle, 1, GL_FALSE, (const GLfloat*)&modelViewProjection.data[0]);
    }
    glUniform1i(texSampler2DHandle, 0 /*GL_TEXTURE0*/);
    
    if(USETEAPOT) {
        glDrawElements(GL_TRIANGLES, NUM_TEAPOT_OBJECT_INDEX, GL_UNSIGNED_SHORT, (const GLvoid*)teapotIndices);
    } else {
        glDrawElements(GL_TRIANGLES, kNumQuadIndices, GL_UNSIGNED_SHORT, (const GLvoid*)quadIndices);
    }
    
    glDisableVertexAttribArray(vertexHandle);
    glDisableVertexAttribArray(normalHandle);
    glDisableVertexAttribArray(textureCoordHandle);
    
    SampleApplicationUtils::checkGlError("EAGLView renderFrameVuforia");

}

- (void) renderTrackablesNew:(Vuforia::State)state {
    
    [dataLock lock];
    
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // anselm state engine
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    
    MEDIA_STATE currentStatus = [videoPlayerHelper getStatus];
    int numActiveTrackables = state.getNumTrackableResults();
    
    if(numActiveTrackables>0) {
        // use this as an opportunity to stash the pose
        const Vuforia::TrackableResult* trackableResult = state.getTrackableResult(0);
        //const Vuforia::ImageTarget& imageTarget = (const Vuforia::ImageTarget&) trackableResult->getTrackable();
        //Vuforia::Vec3F size = imageTarget.getSize();
        targetWidth = 160; //size.data[0] / 2.0f;
        targetHeight = 100; //size.data[1] / 2.0f;
        targetAspect = targetWidth/targetHeight;

        const Vuforia::Matrix34F& trackablePose = trackableResult->getPose();
        Vuforia::Matrix44F qm44 = Vuforia::Tool::convertPose2GLMatrix(trackablePose);
        for(int i=0; i<16; i++) pose.m[i] = qm44.data[i];
    }
    
    switch(playState) {
        case 0:
            // looking for a target
            // once a given target has been observed for a few frames then go to state 1
            if(numActiveTrackables>0) {
                const Vuforia::TrackableResult* trackableResult = state.getTrackableResult(0);
                const Vuforia::ImageTarget& imageTarget = (const Vuforia::ImageTarget&) trackableResult->getTrackable();
                if(playCode == imageTarget.getId()) { // if (playName && !strcmp(playName,imageTarget.getName())
                    // keep counting how long we see this id
                    playCount++;
                    if(playCount > 10) {
                        playCount = 0;
                        playState = 1;
                        playSlerp = 0;
                        [self beginLoadingVideo];
                        NSLog(@"going to play state 1");
                    }
                } else {
                    // id has changed during this wait period - restart
                    playCount = 0;
                    playCode = imageTarget.getId();
                    playName = imageTarget.getName();

                    {
/*
                        NSString  *url = [NSString stringWithFormat:@"%@/%s.png",@"http://makerlab.com/oaklandfence/",playName];

                        augmentationTexture[0] = [[Texture alloc] initWithImageFile3:url local:@"image.png"];
                        
                        // TODO throw away current texture
                        
                        GLuint textureID;
                        glGenTextures(1, &textureID);
                        [augmentationTexture[0] setTextureID:textureID];
                        glBindTexture(GL_TEXTURE_2D, textureID);
                        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, [augmentationTexture[0] width], [augmentationTexture[0] height], 0, GL_RGBA, GL_UNSIGNED_BYTE, (GLvoid*)[augmentationTexture[0] pngData]);
                        
                        //     glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
                        //     glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  */
                    }
                }
            }
            break;
        case 1:
            // have seen a target and now have committed to it
            // use this as an opportunity to show some interstitial animation data prior to adequate buffering
            playCount++;
            if(playCount > 10) {
                playCount = 0;
                playState = 2;
                NSLog(@"going to play state 2");
            }
            break;
        case 2:
            // wait for video to end - it will reset play state to 0
            break;
        case 3:
            // paused and waiting to stop
            playCount++;
            if(playCount > 10) {
                playState = 0;
                playCount = 0;
                [videoPlayerHelper stop];
                [videoPlayerHelper unload];
            }
            break;
        default:
            break;
    }
    
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // end anselm state engine
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    GLuint texture = 0;

    // If playing then preferentially use texture from video (note this doesn't change between frames but we pretend it does)

    if(currentStatus == PLAYING) {
        texture = [videoPlayerHelper updateVideoData];
        if(texture) {
            previousTexture = texture;
        } else {
            texture = previousTexture;
        }
        playSlerp = playSlerp + 0.05f; if(playSlerp>1) playSlerp = 1;
        texCoords = videoQuadTextureCoords;
        // xxx todo TODO - it is arguable if the original target dimensions should be forgotten in favor of video dimensions
        //targetWidth = (float)[videoPlayerHelper getVideoHeight];
        //targetHeight = (float)[videoPlayerHelper getVideoWidth];
        targetAspect = (float)[videoPlayerHelper getVideoHeight] / (float)[videoPlayerHelper getVideoWidth];
    }

    // If paused then use previous - if any

    else if(currentStatus == PAUSED) {
        texture = previousTexture;
    }

    // If not playing then revert
    
    else {
        playSlerp = playSlerp - 0.1; if(playSlerp<0) playSlerp = 0;
        texture = previousTexture = 0;
    }

    // If not playing or no texture found at all then show static image

    if(true) { //!texture) {
        previousTexture = 0;
        Texture* t = augmentationTexture[0];
        texture = [t textureID];
        texCoords = quadTexCoords;
        targetAspect = (float)[t height] / (float)[t width];
    }

    [dataLock unlock];

    // render overlay if state engine mode is post detection
    
    if(playState < 1) return;

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    
    // fiddle with texture coordinates based on what is being shown

    // get translation from matrix
    GLKVector3 glxyz1 = { pose.m[12], pose.m[13], pose.m[14] };
    
    // get rotation from matrix
    GLKQuaternion glrot1 = GLKQuaternionMakeWithMatrix4(pose);
    
    // this is the target rotation and translation we want to be at
    GLKQuaternion glrot2 = GLKQuaternionMakeWithAngleAndAxis(-3.14159265359,1,0,0);
    GLKVector3 glxyz2 = { 0,0,200 };
    
    // slerp to it
    GLKQuaternion glrot = GLKQuaternionSlerp(glrot1,glrot2,playSlerp);
    GLKVector3 glxyz = GLKVector3Slerp(glxyz1,glxyz2,playSlerp);
    
    // remake matrix from rot and trans
    GLKMatrix4 gl44 = GLKMatrix4MakeWithQuaternion(glrot);
    gl44.m[12] = glxyz.v[0];
    gl44.m[13] = glxyz.v[1];
    gl44.m[14] = glxyz.v[2];
    
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    // paint
    
    GLKMatrix4 glmvp44;
    
    // ostensibly we want to use the boundaries of the target region that was tracked
    // the video itself also has ideal boundaries... and arguably that could be used instead - the aspect ratio does reflect that
    //
    
    // xxx do not want to use target width but rather the video width ideally - or a scale factor that is dynamic and fits to box of target
    // ostensibly the trackable has dime
    
  //? SampleApplicationUtils::translatePoseMatrix(0.0f, 0.0f, kObjectScaleNormal,&gl44.m[0]);
    SampleApplicationUtils::scalePoseMatrix(targetWidth, targetWidth * targetAspect,targetWidth,&gl44.m[0]);
    SampleApplicationUtils::multiplyMatrix(vapp.projectionMatrix.data,&gl44.m[0],&glmvp44.m[0]);

    //SampleApplicationUtils::translatePoseMatrix(0.0f, 0.0f, kObjectScaleNormal, &modelViewMatrix.data[0]);
//    SampleApplicationUtils::scalePoseMatrix(kObjectScaleNormal, kObjectScaleNormal, kObjectScaleNormal, &modelViewMatrix.data[0]);
//    SampleApplicationUtils::multiplyMatrix(&vapp.projectionMatrix.data[0], &modelViewMatrix.data[0], &modelViewProjection.data[0]);

    
    glUseProgram(shaderProgramID);
    
    glVertexAttribPointer(vertexHandle, 3, GL_FLOAT, GL_FALSE, 0, quadVertices);
    glVertexAttribPointer(normalHandle, 3, GL_FLOAT, GL_FALSE, 0, quadNormals);
    glVertexAttribPointer(textureCoordHandle, 2, GL_FLOAT, GL_FALSE, 0, texCoords);
    
    glEnableVertexAttribArray(vertexHandle);
    glEnableVertexAttribArray(normalHandle);
    glEnableVertexAttribArray(textureCoordHandle);
    
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture);
    glUniformMatrix4fv(mvpMatrixHandle, 1, GL_FALSE, (GLfloat*)&glmvp44.m[0]);
    glUniform1i(texSampler2DHandle, 0 /*GL_TEXTURE0*/);
    glDrawElements(GL_TRIANGLES, kNumQuadIndices, GL_UNSIGNED_SHORT, quadIndices);
    
    glDisableVertexAttribArray(vertexHandle);
    glDisableVertexAttribArray(normalHandle);
    glDisableVertexAttribArray(textureCoordHandle);
    
    //glUseProgram(0);

    SampleApplicationUtils::checkGlError("EAGLView renderFrameVuforia");

}

@end

// - initial texture is not working yet? or slerping seems fucked up
// - there is a flickr to fiddle with
// - width and height of stand in image seems off
// - target is too small and it seems hard to bring it close due to clipping

