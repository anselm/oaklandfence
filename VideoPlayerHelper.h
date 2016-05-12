
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES1/gl.h>
#import <OpenGLES/ES1/glext.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>

@class VideoPlaybackViewController;

// Media states
typedef enum tagMEDIA_STATE {
    REACHED_END,
    PAUSED,
    STOPPED,
    PLAYING,
    READY,
    NOT_READY,
    ERROR
} MEDIA_STATE;


// Used to specify that playback should start from the current position when
// calling the load and play methods
static const float VIDEO_PLAYBACK_CURRENT_POSITION = -1.0f;

@interface VideoPlayerHelper : NSObject {
@private
    
    // AVPlayer
    AVPlayer* player;
    CMTime playerCursorStartPosition;
    
    // Timing
    CFTimeInterval mediaStartTime;
    CFTimeInterval playerCursorPosition;
    NSTimer* frameTimer;
    BOOL stopFrameTimer;
    
    // Asset
    NSURL* mediaURL;
    AVAssetReader* assetReader;
    AVAssetReaderTrackOutput* assetReaderTrackOutputVideo;
    AVURLAsset* asset;
    BOOL seekRequested;
    float requestedCursorPosition;
    BOOL localFile;
    BOOL playImmediately;
    
    // Playback status
    MEDIA_STATE mediaState;
    
    // Class data lock
    NSLock* dataLock;
    
    // Sample and pixel buffers for video frames
    CMSampleBufferRef latestSampleBuffer;
    CMSampleBufferRef currentSampleBuffer;
    NSLock* latestSampleBufferLock;
    
    // Video properties
    CGSize videoSize;
    Float64 videoLengthSeconds;
    float videoFrameRate;
    BOOL playVideo;
    
    // Audio properties
    float currentVolume;
    BOOL playAudio;
    
    // OpenGL data
    GLuint videoTextureHandle;
    
    // Audio/video synchronisation state
    enum tagSyncState {
        SYNC_DEFAULT,
        SYNC_READY,
        SYNC_AHEAD,
        SYNC_BEHIND
    } syncStatus;
}

@property (nonatomic, retain) AVPlayerItemVideoOutput *videoOutput;


- (id)initMe;
- (BOOL)load:(NSString*)filename fromPosition:(float)seekPosition;
- (BOOL)unload;
- (MEDIA_STATE)getStatus;
- (int)getVideoHeight;
- (int)getVideoWidth;
- (float)getLength;
- (BOOL)play:(float)seekPosition;
- (BOOL)replay;
- (BOOL)pause;
- (BOOL)stop;
- (GLuint)updateVideoData;
- (BOOL)seekTo:(float)position;
- (float)getCurrentPosition;
- (BOOL)setVolume:(float)volume;
- (void)setPlayImmediately:(BOOL)state;

@end
