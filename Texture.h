/*===============================================================================
 Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.
 
 Vuforia is a trademark of PTC Inc., registered in the United States and other
 countries.
 ===============================================================================*/

#import <Foundation/Foundation.h>
#import <OpenGLES/ES2/gl.h>

@interface Texture : NSObject {
}


// --- Properties ---
@property (nonatomic, readonly) int width;
@property (nonatomic, readonly) int height;
@property (nonatomic, readonly) int channels;
@property (nonatomic, readwrite) GLuint textureID;
@property (nonatomic, readonly) unsigned char* pngData;
@property (nonatomic, readonly) NSString* tag;

// --- Public methods ---
- (id)initWithImageFile:(NSString*)filename;
- (id)initWithImageFile2:(NSString*)filename;
- (id)initWithImageFile3:(NSString*)url local:(NSString*)local;
- (id)initTagOnly:(NSString*)tag;
- (BOOL)isLoaded;

@end
