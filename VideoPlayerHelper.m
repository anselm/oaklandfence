
#import "VideoPlayerHelper.h"

#import <AudioToolbox/AudioToolbox.h>
#import <AudioToolbox/AudioServices.h>

#ifdef DEBUG
#define DEBUGLOG(x) NSLog(x)
#else
#define DEBUGLOG(x)
#endif

static const int TIMESCALE = 1000;  // 1 millisecond granularity for time
static const float PLAYER_CURSOR_POSITION_MEDIA_START = 0.0f;
static const float PLAYER_CURSOR_REQUEST_COMPLETE = -1.0f;
static const float PLAYER_VOLUME_DEFAULT = 1.0f;
// The number of bytes per texel (when using kCVPixelFormatType_32BGRA)
static const size_t BYTES_PER_TEXEL = 4;

// Key-value observation contexts
static void* AVPlayerItemStatusObservationContext = &AVPlayerItemStatusObservationContext;
static void* AVPlayerRateObservationContext = &AVPlayerRateObservationContext;

// String constants
static NSString* const kStatusKey = @"status";
static NSString* const kTracksKey = @"tracks";
static NSString* const kRateKey = @"rate";

@interface VideoPlayerHelper (PrivateMethods)
- (void)resetData;
- (BOOL)loadLocalMediaFromURL:(NSURL*)url;
- (BOOL)prepareAssetForPlayback;
- (BOOL)prepareAssetForReading:(CMTime)startTime;
- (void)prepareAVPlayer;
//- (void)createFrameTimer;
- (void)getNextVideoFrame;
- (void)updatePlayerCursorPosition:(float)position;
//- (void)frameTimerFired:(NSTimer*)timer;
- (BOOL)setVolumeLevel:(float)volume;
- (GLuint)createVideoTexture;
- (void)doSeekAndPlayAudio;
- (void)waitForFrameTimerThreadToEnd;
@end

#pragma mark - VideoPlayerHelper

@implementation VideoPlayerHelper

#pragma mark - Lifecycle

- (id)initMe {
    
    self = [super init];
    
    if (nil != self) {
        
        // **********************************************************************
        // *** MUST DO THIS TO BE ABLE TO GET THE VIDEO SAMPLES WITHOUT ERROR ***
        // **********************************************************************
        // AudioSessionInitialize(NULL, NULL, NULL, NULL);

        
        AVAudioSession *audio = [AVAudioSession sharedInstance];
        NSError *err = nil;

        [audio setActive:YES error:nil];
        
        if(![audio setCategory:AVAudioSessionCategoryPlayback error:&err]) {
            NSLog(@"video: audio setup issue");
        }

        if (![audio setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&err]) {
            NSLog(@"video: could not setup audio");
        }
        
        // Initialise data
        [self resetData];
        
        // Video sample buffer lock
        latestSampleBufferLock = [[NSLock alloc] init];
        latestSampleBuffer = NULL;
        currentSampleBuffer = NULL;
        
        // Class data lock
        dataLock = [[NSLock alloc] init];
        
    }
    
    return self;
}


- (void)dealloc {
    (void)[self stop];
    [self resetData];
}

//------------------------------------------------------------------------------
#pragma mark - Class API

// Load a movie
- (BOOL)load:(NSString*)videoURL fromPosition:(float)seekPosition {

    BOOL ret = NO;

    // Load only if there is no media currently loaded
    if (mediaState != NOT_READY && mediaState != ERROR ) {
        NSLog(@"Media already loaded.  Unload current media first.");
        return NO;
    }
    
    mediaURL = [[NSURL alloc] initWithString:videoURL];
    
    if (0.0f <= seekPosition) {
        // If a valid position has been requested, update the player
        // cursor, which will allow playback to begin from the
        // correct position
        [self updatePlayerCursorPosition:seekPosition];
    }
    
    ret = [self loadMediaURL:mediaURL];

    if (!ret) {
        // Some error occurred
        mediaState = ERROR;
    }
    
    return ret;
}

- (BOOL)loadMediaURL:(NSURL*)url {

    asset = [[AVURLAsset alloc] initWithURL:url options:nil];
    
    if (asset == nil) {
        return NO;
    }

    // Can now attempt to load the media, so report success.
    // Later discover if the load actually completes successfully when called back by the system
    
    [asset loadValuesAsynchronouslyForKeys:@[kTracksKey] completionHandler: ^{
        // Completion handler block (dispatched on main queue when loading completes)
        dispatch_async(dispatch_get_main_queue(),^{
            NSError *error = nil;
            AVKeyValueStatus status = [asset statusOfValueForKey:kTracksKey error:&error];
            
            NSDictionary *settings = @{(id) kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
            AVPlayerItemVideoOutput *output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:settings];
            self.videoOutput = output;
            
            if (status == AVKeyValueStatusLoaded) {
                if (![self prepareAssetForPlayback]) {
                    mediaState = ERROR;
                } else {
                    NSLog(@"Video is buffered and ready to play");
                }
            }
            else {
                // Error
                mediaState = ERROR;
            }
        });
    }];

    return YES;
}

- (BOOL)unload {
    // (void)AudioSessionSetActive(false);
    [self stop];
    [self resetData];
    return YES;
}

- (BOOL)isPlayableOnTexture {
    return YES;
}

- (BOOL)isPlayableFullscreen {
    return YES;
}

- (MEDIA_STATE)getStatus {
    return mediaState;
}

- (int)getVideoHeight {
    int ret = -1;
    if (NOT_READY > mediaState) {
        ret = videoSize.height;
    }
    return ret;
}

- (int)getVideoWidth {
    int ret = -1;
    if ([self isPlayableOnTexture]) {
        if (NOT_READY > mediaState) {
            ret = videoSize.width;
        }
        else {
            NSLog(@"Video width not available in current state");
        }
    } else {
        NSLog(@"Video width available only for video that is playable on texture");
    }
    return ret;
}

// Get the length of the media (on-texture player only)
- (float)getLength {
    float ret = -1.0f;
    // Return information only for local files
    if ([self isPlayableOnTexture]) {
        if (NOT_READY > mediaState) {
            ret = (float)videoLengthSeconds;
        }
        else {
            NSLog(@"Video length not available in current state");
        }
    } else {
        NSLog(@"Video length available only for video that is playable on texture");
    }
    return ret;
}

- (BOOL)replay {

    if(mediaState == PLAYING) {
        [self stop];
    }

    requestedCursorPosition = PLAYER_CURSOR_REQUEST_COMPLETE;
    playerCursorPosition = PLAYER_CURSOR_POSITION_MEDIA_START;

    playImmediately = YES;

    playerCursorStartPosition = kCMTimeZero;
    [player seekToTime:playerCursorStartPosition];

    [self play:0];
    
    return YES;
}

// Play the asset
- (BOOL)play:(float)seekPosition {

    if ( mediaState == PLAYING || mediaState == NOT_READY) {
        return NO;
    }

    // Seek to the current playback cursor time (this causes the start and current times to be synchronised as well as starting AVPlayer playback)
    seekRequested = YES;
    
    // If a valid position has been requested, update the player cursor, which will allow playback to begin from the correct position
    if (0.0f <= seekPosition) {
        [self updatePlayerCursorPosition:seekPosition];
    }
    
    mediaState = PLAYING;
    
    [player play];
    
    return YES;
}


// Pause playback (on-texture player only)
- (BOOL)pause {
    
    if (mediaState != PLAYING) {
        return NO;
    }

    [dataLock lock];
    mediaState = PAUSED;
    
    // Stop the audio (if there is any)
    if (YES == playAudio) {
        [player pause];
    }
    
    // Stop the frame pump thread
    [self waitForFrameTimerThreadToEnd];
    
    [dataLock unlock];
 
    return YES;
}


// Stop playback (on-texture player only)
- (BOOL)stop {
    
    // Control available only when playing on texture (not the native player)
    if (mediaState != PLAYING) {
        return NO;
    }

    [dataLock lock];
    mediaState = STOPPED;
    
    // Stop the audio (if there is any)
    if (YES == playAudio) {
        [player pause];
    }
    
    // Stop the frame pump thread
    [self waitForFrameTimerThreadToEnd];
    
    // Reset the playback cursor position
    [self updatePlayerCursorPosition:PLAYER_CURSOR_POSITION_MEDIA_START];
    
    [dataLock unlock];
    
    return YES;
}

- (BOOL)seekTo:(float)position {
    if (NOT_READY > mediaState) {
        if (position < videoLengthSeconds) {
            // Set the new time (the actual seek occurs in getNextVideoFrame)
            [dataLock lock];
            [self updatePlayerCursorPosition:position];
            seekRequested = YES;
            [dataLock unlock];
            return YES;
        }
        else {
            NSLog(@"Requested seek position greater than video length");
        }
    }
    else {
        NSLog(@"Seek control not available in current state");
    }
    return NO;
}

- (float)getCurrentPosition {
    float ret = -1.0f;
    
    if (NOT_READY > mediaState) {
        [dataLock lock];
        ret = (float)playerCursorPosition;
        [dataLock unlock];
    }
    else {
        NSLog(@"Current playback position not available in current state");
    }
    
    return ret;
}


- (BOOL)setVolume:(float)volume {
    BOOL ret = NO;
    
    if (NOT_READY > mediaState) {
        [dataLock lock];
        ret = [self setVolumeLevel:volume];
        [dataLock unlock];
    }
    else {
        NSLog(@"Volume control not available in current state");
    }
    
    return ret;
}


- (GLuint)updateVideoData {
    
    if (mediaState != PLAYING) {
        return 0;
    }

    GLuint textureID = 0;

    [latestSampleBufferLock lock];
        
    playerCursorPosition = CACurrentMediaTime() - mediaStartTime;
    
    unsigned char* pixelBufferBaseAddress = NULL;
    CVPixelBufferRef pixelBuffer;

    pixelBuffer = [self.videoOutput copyPixelBufferForItemTime:player.currentItem.currentTime itemTimeForDisplay:nil];
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    pixelBufferBaseAddress = (unsigned char*)CVPixelBufferGetBaseAddress(pixelBuffer);
    
    if (NULL != pixelBufferBaseAddress) {
        // If we haven't created the video texture, do so now
        if (0 == videoTextureHandle) {
            videoTextureHandle = [self createVideoTexture];
        }
        
        glBindTexture(GL_TEXTURE_2D, videoTextureHandle);
        const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
        
        if (bytesPerRow / BYTES_PER_TEXEL == videoSize.width) {
            // No padding between lines of decoded video
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei) videoSize.width, (GLsizei) videoSize.height, 0, GL_BGRA, GL_UNSIGNED_BYTE, pixelBufferBaseAddress);
        }
        else {
            // Decoded video contains padding between lines.  We must not
            // upload it to graphics memory as we do not want to display it
            
            // Allocate storage for the texture (correctly sized)
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei) videoSize.width, (GLsizei) videoSize.height, 0, GL_BGRA, GL_UNSIGNED_BYTE, NULL);
            
            // Now upload each line of texture data as a sub-image
            for (int i = 0; i < videoSize.height; ++i) {
                GLubyte* line = pixelBufferBaseAddress + i * bytesPerRow;
                glTexSubImage2D(GL_TEXTURE_2D, 0, 0, i, (GLsizei) videoSize.width, 1, GL_BGRA, GL_UNSIGNED_BYTE, line);
            }
        }
        
        glBindTexture(GL_TEXTURE_2D, 0);
        
        // Unlock the buffers
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        
        textureID = videoTextureHandle;
    }
    
    if (pixelBuffer) {
        CFRelease(pixelBuffer);
    }
    
    [latestSampleBufferLock unlock];

    return textureID;
}

- (void)setPlayImmediately:(BOOL)state {
    playImmediately = state;
}

//------------------------------------------------------------------------------
#pragma mark - AVPlayer observation
// Called when the value at the specified key path relative to the given object has changed.  Note, this method is invoked on the main queue
- (void)observeValueForKeyPath:(NSString*) path ofObject:(id)object change:(NSDictionary*)change context:(void*)context {

    if (AVPlayerItemStatusObservationContext == context) {
        long val = ([[change objectForKey:NSKeyValueChangeNewKey] integerValue]);
        AVPlayerItemStatus status = val; //static_cast<AVPlayerItemStatus>val;

        switch (status) {
            case AVPlayerItemStatusUnknown:
                DEBUGLOG(@"AVPlayerItemStatusObservationContext -> AVPlayerItemStatusUnknown");
                mediaState = NOT_READY;
                break;
            case AVPlayerItemStatusReadyToPlay:
                DEBUGLOG(@"AVPlayerItemStatusObservationContext -> AVPlayerItemStatusReadyToPlay");
                mediaState = READY;
                if (YES == playImmediately) {
                    [self play:VIDEO_PLAYBACK_CURRENT_POSITION];
                    NSLog(@"video is starting to play");
                }
                break;
            case AVPlayerItemStatusFailed:
                DEBUGLOG(@"AVPlayerItemStatusObservationContext -> AVPlayerItemStatusFailed");
                NSLog(@"Error - AVPlayer unable to play media: %@", [[[player currentItem] error] localizedDescription]);
                mediaState = ERROR;
                break;
            default:
                DEBUGLOG(@"AVPlayerItemStatusObservationContext -> Unknown");
                mediaState = NOT_READY;
                break;
        }
    }
    else if (AVPlayerRateObservationContext == context && NO == playVideo && PLAYING == mediaState) {
        // We must detect the end of playback here when playing audio-only
        // media, because the video frame pump is not running (end of playback
        // is detected by the frame pump when playing video-only and audio/video
        // media).  We detect the difference between reaching the end of the
        // media and the user pausing/stopping playback by testing the value of
        // mediaState
        DEBUGLOG(@"AVPlayerRateObservationContext");
        float rate = [[change objectForKey:NSKeyValueChangeNewKey] floatValue];
        
        if (0.0f == rate) {
            // Playback has reached end of media
            mediaState = REACHED_END;
            
            // Reset AVPlayer cursor position (audio)
            CMTime startTime = CMTimeMake(PLAYER_CURSOR_POSITION_MEDIA_START * TIMESCALE, TIMESCALE);
            [player seekToTime:startTime];
        }
    }
}

//------------------------------------------------------------------------------
#pragma mark - Private methods

- (void)resetData {
    
    // Reset media state and information
    mediaState = NOT_READY;
    syncStatus = SYNC_DEFAULT;
    requestedCursorPosition = PLAYER_CURSOR_REQUEST_COMPLETE;
    playerCursorPosition = PLAYER_CURSOR_POSITION_MEDIA_START;
    playImmediately = NO;
    videoSize.width = 0.0f;
    videoSize.height = 0.0f;
    videoLengthSeconds = 0.0f;
    videoFrameRate = 0.0f;
    playAudio = NO;
    playVideo = NO;
    
    // Remove KVO observers
    [[player currentItem] removeObserver:self forKeyPath:kStatusKey];
    [player removeObserver:self forKeyPath:kRateKey];
    
    // Release AVPlayer, AVAsset, etc.
    player = nil;
    asset = nil;
    assetReader = nil;
    assetReaderTrackOutputVideo = nil;
    mediaURL = nil;
}

- (BOOL)loadLocalMediaFromURL:(NSURL*)url {
    asset = [[AVURLAsset alloc] initWithURL:url options:nil];
    if (!asset) {
        return NO;
    }
    // Attempt to load media - discover success or fail when called back
    [asset loadValuesAsynchronouslyForKeys:[NSArray arrayWithObject:kTracksKey] completionHandler: ^{
        // Completion handler block (dispatched on main queue when loading completes)
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *error = nil;
            AVKeyValueStatus status = [asset statusOfValueForKey:kTracksKey error:&error];
            if (status == AVKeyValueStatusLoaded) {
                if (NO == [self prepareAssetForPlayback]) {
                    NSLog(@"Error - Unable to prepare media for playback");
                    mediaState = ERROR;
                }
            }
            else {
                NSLog(@"Error - The asset's tracks were not loaded: %@", [error localizedDescription]);
                mediaState = ERROR;
            }
        });
    }];
    return YES;
}

// Prepare the AVPlayer object for media playback
- (void)prepareAVPlayer {
    // Create a player item
    AVPlayerItem* item = [AVPlayerItem playerItemWithAsset:asset];
    
    // Add player item status KVO observer
    NSKeyValueObservingOptions opts = NSKeyValueObservingOptionNew;
    [item addObserver:self forKeyPath:kStatusKey options:opts context:AVPlayerItemStatusObservationContext];
    
    // Create an AV player
    player = [[AVPlayer alloc] initWithPlayerItem:item];
    [item addOutput:self.videoOutput];
    
    // Add player rate KVO observer
    [player addObserver:self forKeyPath:kRateKey options:opts context:AVPlayerRateObservationContext];
}

// Prepare the AVURLAsset for playback
- (BOOL)prepareAssetForPlayback {
    // Get video properties
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    AVAssetTrack *videoTrack = videoTracks[0];
    videoSize = videoTrack.naturalSize;
    
    videoLengthSeconds = CMTimeGetSeconds([asset duration]);
    
    // Start playback at time 0.0
    playerCursorStartPosition = kCMTimeZero;
    
    // Start playback at full volume (audio mix level, not system volume level)
    currentVolume = PLAYER_VOLUME_DEFAULT;
    
    // Create asset tracks for reading
    BOOL ret = [self prepareAssetForReading:playerCursorStartPosition];
    
    if (ret) {
        // Prepare the AVPlayer to play the audio
        [self prepareAVPlayer];
        // Inform our client that the asset is ready to play
        mediaState = READY;
    }
    
    return ret;
}

// Prepare the AVURLAsset for reading so we can obtain video frame data from it
- (BOOL)prepareAssetForReading:(CMTime)startTime {

    NSArray * arrayTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if ([arrayTracks count] <= 0) {
        return NO;
    }

    playAudio = YES;
    AVAssetTrack* assetTrackAudio = arrayTracks[0];
    
    AVMutableAudioMixInputParameters* audioInputParams = [AVMutableAudioMixInputParameters audioMixInputParameters];
    [audioInputParams setVolume:1.0f atTime:playerCursorStartPosition];
    [audioInputParams setTrackID:[assetTrackAudio trackID]];
    
    NSArray* audioParams = @[audioInputParams];
    AVMutableAudioMix* audioMix = [AVMutableAudioMix audioMix];
    [audioMix setInputParameters:audioParams];
    
    AVPlayerItem* item = [player currentItem];
    [item setAudioMix:audioMix];

    return YES;
}

/*
- (void)frameTimerFired:(NSTimer*)timer {
    if (NO == stopFrameTimer) {
        [self getNextVideoFrame];
    } else {
        // NSTimer invalidate must be called on the timer's thread
        [frameTimer invalidate];
    }
}
*/

/*
// Decode the next video frame and make it available for use (do not assume the timer driving the frame pump will be accurate)
- (void)getNextVideoFrame {

    // Synchronise access to publicly accessible internal data.  We use tryLock
    // here to prevent possible deadlock when pause or stop are called on
    // another thread
    if (NO == [dataLock tryLock]) {
        return;
    }
    
    @try {
        // If we've been told to seek to a new time, do so now
        if (YES == seekRequested) {
            seekRequested = NO;
            [self doSeekAndPlayAudio];
        }
        
        // Simple video synchronisation mechanism:
        // If the video frame time is within tolerance, make it available to our
        // client.  This state is SYNC_READY.
        // If the video frame is behind, throw it away and get the next one.  We
        // will either catch up with the reference time (and become SYNC_READY),
        // or run out of frames.  This state is SYNC_BEHIND.
        // If the video frame is ahead, make it available to the client, but do
        // not retrieve more frames until the reference time catches up.  This
        // state is SYNC_AHEAD.
        
        while (SYNC_READY != syncStatus) {
            Float64 delta;
            
            if (SYNC_AHEAD != syncStatus) {
                currentSampleBuffer = [assetReaderTrackOutputVideo copyNextSampleBuffer];
            }
            
            if (NULL == currentSampleBuffer) {
                // Failed to read the next sample buffer
                break;
            }
            
            // Get the time stamp of the video frame
            CMTime frameTimeStamp = CMSampleBufferGetPresentationTimeStamp(currentSampleBuffer);
            
            // Get the time since playback began
            playerCursorPosition = CACurrentMediaTime() - mediaStartTime;
            CMTime caCurrentTime = CMTimeMake(playerCursorPosition * TIMESCALE, TIMESCALE);
            
            // Compute delta of video frame and current playback times
            delta = CMTimeGetSeconds(caCurrentTime) - CMTimeGetSeconds(frameTimeStamp);
            
            if (delta < 0) {
                delta *= -1;
                syncStatus = SYNC_AHEAD;
            }
            else {
                syncStatus = SYNC_BEHIND;
            }
            
            if (delta < 1 / videoFrameRate) {
                // Video in sync with audio
                syncStatus = SYNC_READY;
            }
            else if (SYNC_AHEAD == syncStatus) {
                // Video ahead of audio: stay in SYNC_AHEAD state, exit loop
                break;
            }
            else {
                // Video behind audio (SYNC_BEHIND): stay in loop
                CFRelease(currentSampleBuffer);
            }
        }
    }
    @catch (NSException* e) {
        // Assuming no other error, we are trying to read past the last sample
        // buffer
        DEBUGLOG(@"Failed to copyNextSampleBuffer");
        currentSampleBuffer = NULL;
    }
    
    if (NULL == currentSampleBuffer) {
        switch ([assetReader status]) {
            case AVAssetReaderStatusCompleted:
                // Playback has reached the end of the video media
                DEBUGLOG(@"getNextVideoFrame -> AVAssetReaderStatusCompleted");
                mediaState = REACHED_END;
                break;
            case AVAssetReaderStatusFailed: {
                NSError* error = [assetReader error];
                NSLog(@"getNextVideoFrame -> AVAssetReaderStatusFailed: %@", [error localizedDescription]);
                mediaState = ERROR;
                break;
            }
            default:
                DEBUGLOG(@"getNextVideoFrame -> Unknown");
                break;
        }
        
        // Stop the frame pump
        [frameTimer invalidate];
        
        // Reset the playback cursor position
        [self updatePlayerCursorPosition:PLAYER_CURSOR_POSITION_MEDIA_START];
    }
    
    [latestSampleBufferLock lock];
    
    if (NULL != latestSampleBuffer) {
        // Release the latest sample buffer
        CFRelease(latestSampleBuffer);
    }
    
    if (SYNC_READY == syncStatus) {
        // Audio and video are synchronised, so transfer ownership of
        // currentSampleBuffer to latestSampleBuffer
        latestSampleBuffer = currentSampleBuffer;
    }
    else {
        // Audio and video not synchronised, do not supply a sample buffer
        latestSampleBuffer = NULL;
    }
    
    [latestSampleBufferLock unlock];
    
    // Reset the sync status, unless video is ahead of the reference time
    if (SYNC_AHEAD != syncStatus) {
        syncStatus = SYNC_DEFAULT;
    }
    
    [dataLock unlock];
}
 */

/*
// Create a timer to drive the video frame pump
- (void)createFrameTimer {

    frameTimer = [NSTimer scheduledTimerWithTimeInterval:(1 / videoFrameRate) target:self selector:@selector(frameTimerFired:) userInfo:nil repeats:YES];
    
    // Set thread priority explicitly to the default value (0.5),
    // to ensure that the frameTimer can tick at the expected rate.
    [[NSThread currentThread] setThreadPriority:0.5];
    
    // Execute the current run loop (it will terminate when its associated timer
    // becomes invalid)
    [[NSRunLoop currentRunLoop] run];
    
    // Release frameTimer (set to nil to notify any threads waiting for the
    // frame pump to stop)
    frameTimer = nil;
    
    // Make sure we do not leak a sample buffer
    [latestSampleBufferLock lock];
    
    if (NULL != latestSampleBuffer) {
        // Release the latest sample buffer
        CFRelease(latestSampleBuffer);
        latestSampleBuffer = NULL;
    }
    
    [latestSampleBufferLock unlock];
    
}
*/

// Create an OpenGL texture for the video data
- (GLuint)createVideoTexture {
    GLuint handle;
    glGenTextures(1, &handle);
    glBindTexture(GL_TEXTURE_2D, handle);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, 0);
    return handle;
}


// Update the playback cursor position
// [Always called with dataLock locked]
- (void)updatePlayerCursorPosition:(float)position {
    // Set the player cursor position so the native player can restart from the
    // appropriate time if play (fullscreen) is called again
    playerCursorPosition = position;
    
    // Set the requested cursor position to cause the on texture player to seek
    // to the appropriate time if play (on texture) is called again
    requestedCursorPosition = position;
}


// Set the volume level (on-texture player only)
// [Always called with dataLock locked]
- (BOOL)setVolumeLevel:(float)volume {
    BOOL ret = NO;
    NSArray* arrayTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    
    if (0 < [arrayTracks count]) {
        // Get the asset's audio track
        AVAssetTrack* assetTrackAudio = [arrayTracks objectAtIndex:0];
        
        if (nil != assetTrackAudio) {
            // Set up the audio mix
            AVMutableAudioMixInputParameters* audioInputParams = [AVMutableAudioMixInputParameters audioMixInputParameters];
            [audioInputParams setVolume:volume atTime:playerCursorStartPosition];
            [audioInputParams setTrackID:[assetTrackAudio trackID]];
            NSArray* audioParams = [NSArray arrayWithObject:audioInputParams];
            AVMutableAudioMix* audioMix = [AVMutableAudioMix audioMix];
            [audioMix setInputParameters:audioParams];
            
            // Apply the audio mix the the AVPlayer's current item
            [[player currentItem] setAudioMix:audioMix];
            
            // Store the current volume level
            currentVolume = volume;
            ret = YES;
        }
    }
    
    return ret;
}


// Seek to a particular playback position (when playing on texture)
// [Always called with dataLock locked]
- (void)doSeekAndPlayAudio {
    if (PLAYER_CURSOR_REQUEST_COMPLETE < requestedCursorPosition) {
        // Store the cursor position from which playback will start
        playerCursorStartPosition = CMTimeMake(requestedCursorPosition * TIMESCALE, TIMESCALE);
        
        // Ensure the volume continues at the current level
        [self setVolumeLevel:currentVolume];
        
        if (YES == playAudio) {
            // Set AVPlayer cursor position (audio)
            [player seekToTime:playerCursorStartPosition];
        }
        
        // Set the asset reader's start time to the new time (video)
        [self prepareAssetForReading:playerCursorStartPosition];
        
        // Indicate seek request is complete
        requestedCursorPosition = PLAYER_CURSOR_REQUEST_COMPLETE;
    }
    
    if (YES == playAudio) {
        // Play the audio (if there is any)
        [player play];
    }
    
    // Store the media start time for reference
    mediaStartTime = CACurrentMediaTime() - playerCursorPosition;
}


// Request the frame timer to terminate and wait for its thread to end
- (void)waitForFrameTimerThreadToEnd {
    stopFrameTimer = YES;
    
    // Wait for the frame pump thread to stop
    while (nil != frameTimer) {
        [NSThread sleepForTimeInterval:0.01];
    }
    
    stopFrameTimer = NO;
}
@end


