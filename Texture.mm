/*===============================================================================
 Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.
 
 Vuforia is a trademark of PTC Inc., registered in the United States and other
 countries.
 ===============================================================================*/

#import "Texture.h"
#import <UIKit/UIKit.h>


// Private method declarations
@interface Texture (PrivateMethods)
- (BOOL)loadImage:(NSString*)filename;
- (BOOL)copyImageDataForOpenGL:(CFDataRef)imageData;
@end


@implementation Texture

//------------------------------------------------------------------------------
#pragma mark - Lifecycle

- (id)initWithImageFile:(NSString*)filename
{
    self = [super init];
    
    _tag = [filename copy];
    
    if (nil != self) {
        if (NO == [self loadImage:filename]) {
            NSLog(@"Failed to load texture image from file %@", filename);
            self = nil;
        }
    }
    
    return self;
}



- (id)initWithImageFile2:(NSString*)filename
{
    self = [super init];

    _tag = [filename copy];

    if (nil != self) {
        if (NO == [self loadImage2:filename]) {
            NSLog(@"Failed to load texture image from file %@", filename);
            self = nil;
        }
    }
    
    return self;
}

- (id)initWithImageFile3:(NSString*)url local:(NSString*)local
{
    self = [super init];
    
    _tag = [local copy];

    if (nil != self) {
        if (NO == [self loadImage3:url local:local]) {
            NSLog(@"Failed to load texture image from file %@", url);
            self = nil;
        }
    }
    
    return self;
}

- (id)initTagOnly:(NSString*)local
{
    self = [super init];
    
    _tag = [local copy];
    _pngData = 0;
    
    return self;
}


- (void)dealloc
{
    if (_pngData) {
        delete[] _pngData;
    }
    
    _tag = 0;
}


//------------------------------------------------------------------------------
#pragma mark - Private methods

- (BOOL)loadImage:(NSString*)filename
{
    BOOL ret = NO;
    
    // Build the full path of the image file
    NSString* fullPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:filename];
    
    // Create a UIImage with the contents of the file
    UIImage* uiImage = [UIImage imageWithContentsOfFile:fullPath];
    
    if (uiImage) {
        // Get the inner CGImage from the UIImage wrapper
        CGImageRef cgImage = uiImage.CGImage;
        
        // Get the image size
        _width = (int)CGImageGetWidth(cgImage);
        _height = (int)CGImageGetHeight(cgImage);
        
        // Record the number of channels
        _channels = (int)CGImageGetBitsPerPixel(cgImage)/CGImageGetBitsPerComponent(cgImage);
        
        // Generate a CFData object from the CGImage object (a CFData object represents an area of memory)
        CFDataRef imageData = CGDataProviderCopyData(CGImageGetDataProvider(cgImage));
        
        // Copy the image data for use by Open GL
        ret = [self copyImageDataForOpenGL: imageData];
        
        CFRelease(imageData);
    }
    
    return ret;
}


- (BOOL)loadImage2:(NSString*)filename
{
    BOOL ret = NO;
    
    NSArray   *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString  *documentsDirectory = [paths objectAtIndex:0];
    //NSFileManager* fm = [NSFileManager defaultManager];
    NSString  *fullPath = [NSString stringWithFormat:@"%@/%@", documentsDirectory,filename];
    //NSDictionary* attrs1 = [fm attributesOfItemAtPath:filePath1 error:nil];
    
    // Create a UIImage with the contents of the file
    UIImage* uiImage = [UIImage imageWithContentsOfFile:fullPath];
    
    if (uiImage) {
        // Get the inner CGImage from the UIImage wrapper
        CGImageRef cgImage = uiImage.CGImage;
        
        // Get the image size
        _width = (int)CGImageGetWidth(cgImage);
        _height = (int)CGImageGetHeight(cgImage);
        
        // Record the number of channels
        _channels = (int)CGImageGetBitsPerPixel(cgImage)/CGImageGetBitsPerComponent(cgImage);
        
        // Generate a CFData object from the CGImage object (a CFData object represents an area of memory)
        CFDataRef imageData = CGDataProviderCopyData(CGImageGetDataProvider(cgImage));
        
        // Copy the image data for use by Open GL
        ret = [self copyImageDataForOpenGL: imageData];
        
        CFRelease(imageData);
    }
    
    return ret;
}

- (BOOL)loadImage3:(NSString*)url local:(NSString*)filename
{
    BOOL ret = NO;

    NSArray   *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString  *documentsDirectory = [paths objectAtIndex:0];
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString  *fullPath = [NSString stringWithFormat:@"%@/%@", documentsDirectory,filename];
    NSDictionary* attrs1 = [fm attributesOfItemAtPath:fullPath error:nil];

    if(attrs1 == nil) {
        NSURL* url1 = [NSURL URLWithString:url];
        NSData* urlData1 = [NSData dataWithContentsOfURL:url1];
        if (!urlData1) return NO;
        // [fm removeItemAtPath:fullPath error:nil];
        if(![fm createFileAtPath:fullPath contents:urlData1 attributes:nil]) return NO;
    }
    
    // Create a UIImage with the contents of the file
    UIImage* uiImage = [UIImage imageWithContentsOfFile:fullPath];
    
    if (uiImage) {
        // Get the inner CGImage from the UIImage wrapper
        CGImageRef cgImage = uiImage.CGImage;
        
        // Get the image size
        _width = (int)CGImageGetWidth(cgImage);
        _height = (int)CGImageGetHeight(cgImage);
        
        // Record the number of channels
        _channels = (int)CGImageGetBitsPerPixel(cgImage)/CGImageGetBitsPerComponent(cgImage);
        
        // Generate a CFData object from the CGImage object (a CFData object represents an area of memory)
        CFDataRef imageData = CGDataProviderCopyData(CGImageGetDataProvider(cgImage));
        
        // Copy the image data for use by Open GL
        ret = [self copyImageDataForOpenGL: imageData];
        
        CFRelease(imageData);
    }
    
    return ret;
}


- (BOOL)copyImageDataForOpenGL:(CFDataRef)imageData {

    // conceivably this could be called twice
    
    if (_pngData) {
        delete[] _pngData;
        glDeleteTextures(1,&_textureID);
        _textureID = 0;
    }

    // some attempt at failure handling
    
    _pngData = new unsigned char[_width * _height * _channels];
    if(!_pngData) return NO;

    // Copy the row data from bottom to top
    
    const int rowSize = _width * _channels;
    const unsigned char* pixels = (unsigned char*)CFDataGetBytePtr(imageData);
    for (int i = 0; i < _height; ++i) {
        memcpy(_pngData + rowSize * i, pixels + rowSize * (_height - 1 - i), _width * _channels);
    }

    // Copy over to OpenGL right now - although this is a conflation of textures with opengl
    
    {
        _textureID = 0;
        glGenTextures(1, &_textureID);
        glBindTexture(GL_TEXTURE_2D, _textureID);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, _width, _height, 0, GL_RGBA, GL_UNSIGNED_BYTE, (GLvoid*)_pngData);
    }

    
    return YES;
}

- (BOOL)isLoaded {
    if(_pngData != 0) return TRUE;
    return FALSE;
}

@end
