/*===============================================================================
Copyright (c) 2016 PTC Inc. All Rights Reserved.

Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.

Vuforia is a trademark of PTC Inc., registered in the United States and other 
countries.
===============================================================================*/

#import <UIKit/UIKit.h>
#import "ImageTargetsEAGLView.h"
#import "SampleApplicationSession.h"
#import <Vuforia/DataSet.h>

@interface ImageTargetsViewController : UIViewController <SampleApplicationControl> {
    Vuforia::DataSet*  dataSetCurrent;
}

@property (nonatomic, strong) ImageTargetsEAGLView* eaglView;
@property (nonatomic, strong) SampleApplicationSession * vapp;

@end
