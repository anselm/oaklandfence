
#import "ImageTargetsViewController.h"
#import "AppDelegate.h"
#import <Vuforia/Vuforia.h>
#import <Vuforia/TrackerManager.h>
#import <Vuforia/ObjectTracker.h>
#import <Vuforia/Trackable.h>
#import <Vuforia/ImageTarget.h>
#import <Vuforia/DataSet.h>
#import <Vuforia/CameraDevice.h>

//@interface ImageTargetsViewController ()
//@property (weak, nonatomic) IBOutlet UIImageView *ARViewPlaceholder;
//@end

@implementation ImageTargetsViewController

@synthesize vapp, eaglView;

NSString* serverName = @"oaklandfenceproject.org.s3-website-us-west-1.amazonaws.com";

- (CGRect)getCurrentARViewFrame {
    CGRect screenBounds = [[UIScreen mainScreen] bounds];
    CGRect viewFrame = screenBounds;
    if (YES == vapp.isRetinaDisplay) {
        viewFrame.size.width *= [UIScreen mainScreen].nativeScale;
        viewFrame.size.height *= [UIScreen mainScreen].nativeScale;
    }
    return viewFrame;
}

- (void)loadView {

    self.title = @"Oakland Fence";
    
    /*
    if (self.ARViewPlaceholder != nil) {
        [self.ARViewPlaceholder removeFromSuperview];
        self.ARViewPlaceholder = nil;
    }
    */
    
    vapp = [[SampleApplicationSession alloc] initWithDelegate:self];
    
    CGRect viewFrame = [self getCurrentARViewFrame];

    eaglView = [[ImageTargetsEAGLView alloc] initWithFrame:viewFrame appSession:vapp];
    [self setView:eaglView];
    AppDelegate *appDelegate = (AppDelegate*)[[UIApplication sharedApplication] delegate];
    appDelegate.glResourceHandler = eaglView;

    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(dismissARViewController)
                                                 name:@"kDismissARViewController"
                                               object:nil];
    
    // we use the iOS notification to pause/resume the AR when the application goes (or come back from) background
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pauseAR) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resumeAR) name:UIApplicationDidBecomeActiveNotification object:nil];
    
    // initialize AR
    [vapp initAR:Vuforia::GL_20 orientation:[[UIApplication sharedApplication] statusBarOrientation]];

    // Recognize single taps
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tap.delegate = (id<UIGestureRecognizerDelegate>)self;
    [self.view addGestureRecognizer:tap];
    
    // show loading animation while AR is being initialized
    //[self showLoadingAnimation];
}

- (void)handleTap:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateEnded) {
        CGPoint touchPoint = [sender locationInView:eaglView];
        [eaglView handleTouchPoint:touchPoint];
    }
}

- (void) showWebPage:(NSString*)website {
    NSURL *url = [NSURL URLWithString:website];
    NSURLRequest *urlRequest = [NSURLRequest requestWithURL:url];
    CGRect mainBounds = [[UIScreen mainScreen] bounds];
    UIWebView *webView=[[UIWebView alloc] initWithFrame:mainBounds];
    [webView loadRequest:urlRequest];
    [self setView:webView];
}

- (void) pauseAR {
    NSError * error = nil;
    if (![vapp pauseAR:&error]) {
        NSLog(@"Error pausing AR:%@", [error description]);
    }
}

- (void) resumeAR {
    NSError * error = nil;
    if(! [vapp resumeAR:&error]) {
        NSLog(@"Error resuming AR:%@", [error description]);
    }
    // on resume, we reset the flash
    Vuforia::CameraDevice::getInstance().setFlashTorchMode(false);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.navigationController setNavigationBarHidden:YES animated:NO];
    NSLog(@"self.navigationController.navigationBarHidden: %s", self.navigationController.navigationBarHidden ? "Yes" : "No");
}

- (void)viewWillDisappear:(BOOL)animated {
    [vapp stopAR:nil];
    [self finishOpenGLESCommands];
    AppDelegate *appDelegate = (AppDelegate*)[[UIApplication sharedApplication] delegate];
    appDelegate.glResourceHandler = nil;
    [super viewWillDisappear:animated];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)finishOpenGLESCommands {
    [eaglView finishOpenGLESCommands];
}

- (void)freeOpenGLESResources {
    [eaglView freeOpenGLESResources];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}


#pragma mark - loading animation

- (void) showLoadingAnimation {
    /*
    CGRect indicatorBounds;
    CGRect mainBounds = [[UIScreen mainScreen] bounds];
    int smallerBoundsSize = MIN(mainBounds.size.width, mainBounds.size.height);
    int largerBoundsSize = MAX(mainBounds.size.width, mainBounds.size.height);
    UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
    if (orientation == UIInterfaceOrientationPortrait || orientation == UIInterfaceOrientationPortraitUpsideDown ) {
        indicatorBounds = CGRectMake(smallerBoundsSize / 2 - 12,
                                     largerBoundsSize / 2 - 12, 24, 24);
    }
    else {
        indicatorBounds = CGRectMake(largerBoundsSize / 2 - 12,
                                     smallerBoundsSize / 2 - 12, 24, 24);
    }
    
    UIActivityIndicatorView *loadingIndicator = [[UIActivityIndicatorView alloc]
                                                  initWithFrame:indicatorBounds];
    
    loadingIndicator.tag  = 1;
    loadingIndicator.activityIndicatorViewStyle = UIActivityIndicatorViewStyleWhiteLarge;
    [eaglView addSubview:loadingIndicator];
    [loadingIndicator startAnimating];
    */
}

- (void) hideLoadingAnimation {
    /*
    UIActivityIndicatorView *loadingIndicator = (UIActivityIndicatorView *)[eaglView viewWithTag:1];
    [loadingIndicator removeFromSuperview];
     */
}


#pragma mark - SampleApplicationControl

- (bool) doInitTrackers {
    // Initialize the object tracker
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::Tracker* trackerBase = trackerManager.initTracker(Vuforia::ObjectTracker::getClassType());
    if (trackerBase == NULL)
    {
        NSLog(@"Failed to initialize ObjectTracker.");
        return false;
    }
    return true;
}

//
// Update local cache from remote server
//
- (bool) preloadData:(NSString *)name local:(NSString *)localname {
    
    NSArray   *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString  *documentsDirectory = [paths objectAtIndex:0];
    NSFileManager* fm = [NSFileManager defaultManager];

    NSString  *filePath1 = [NSString stringWithFormat:@"%@/%@.xml", documentsDirectory,localname];
    NSString  *filePath2 = [NSString stringWithFormat:@"%@/%@.dat", documentsDirectory,localname];
    
    //////////////////////////////////////////////////////
    // if we have the same local file then we should not fetch again
    // actually - by the time we get here - always fetch
    
    //NSDictionary* attrs1 = [fm attributesOfItemAtPath:filePath1 error:nil];
    //NSDictionary* attrs2 = [fm attributesOfItemAtPath:filePath1 error:nil];
    //if(attrs1 != nil && attrs2 != nil ) {
    //    NSLog(@"File already in cache: %@", filePath1 );
    //    NSLog(@"File already in cache: %@", filePath2 );
    //    return YES;
    //}

    // if(attrs1 != nil)[fm removeItemAtPath:filePath1 error:nil];
    // if(attrs2 != nil)[fm removeItemAtPath:filePath2 error:nil];

    //NSDate* date2 = nil;
    //if (attrs2 != nil) {
    //   date2 = (NSDate*)[attrs2 objectForKey: NSFileCreationDate];
    //    NSLog(@"Date Created: %@", [date2 description]);
    //}
    //if (date2 != nil) {} // [[NSFileManager defaultManager] fileExistsAtPath:filePath2]) {}

    //NSDate* date1 = nil;
    //if (attrs1 != nil) {
    //    date1 = (NSDate*)[attrs1 objectForKey: NSFileCreationDate];
    //    NSLog(@"Date Created: %@", [date1 description]);
    //}
    //if(date1 != nil) {} // [[NSFileManager defaultManager] fileExistsAtPath:filePath1]) {}
    
    NSString  *stringURL1 = [NSString stringWithFormat:@"%http://@/%@.xml",serverName,name];
    NSURL* url1 = [NSURL URLWithString:stringURL1];
    NSData* urlData1 = [NSData dataWithContentsOfURL:url1];
    if (!urlData1) return NO;
    
    NSString  *stringURL2 = [NSString stringWithFormat:@"http://%@/%@.dat",serverName,name];
    NSURL* url2 = [NSURL URLWithString:stringURL2];
    NSData* urlData2 = [NSData dataWithContentsOfURL:url2];
    if (!urlData2) return NO;

    /////////////////////////////////////////////////////
    
    //[urlData1 writeToFile:filePath1 atomically:YES];
    if(![fm createFileAtPath:filePath1 contents:urlData1 attributes:nil]) return NO;
    NSLog(@"Created file: %@", filePath1 );
    
    //[urlData2 writeToFile:filePath2 atomically:YES];
    if(![fm createFileAtPath:filePath2 contents:urlData2 attributes:nil]) return NO;
    NSLog(@"Created file: %@", filePath2 );
    
    return YES;
}

-(bool) doLoadTrackersData {

    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Fetch a remote copy of current version inforomation
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    NSString  *serverVersion = [NSString stringWithFormat:@"http://%@/version.txt",serverName];

    NSData* remoteVersionBlob = [NSData dataWithContentsOfURL:[NSURL URLWithString:serverVersion]];
    if (!remoteVersionBlob) {
        // Even just not getting the version is bad because it means subsequent fetch operations will fail.
        NSLog(@"Error: could not connect to version server");
    }

    NSString *remoteVersion = nil;
    
    if(remoteVersionBlob != nil) {
        remoteVersion = [[NSString alloc] initWithData:remoteVersionBlob encoding:NSUTF8StringEncoding];
        remoteVersion = [remoteVersion stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    }

    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Fetch a local version info file if any
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    NSArray   *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString  *documentsDirectory = [paths objectAtIndex:0];
    NSFileManager* fm = [NSFileManager defaultManager];

    NSString  *filePath1 = [NSString stringWithFormat:@"%@/version.txt", documentsDirectory];
    NSDictionary* attrs1 = [fm attributesOfItemAtPath:filePath1 error:nil];
    
    if(attrs1 == nil && remoteVersionBlob == nil) {
        NSLog(@"Error: cannot fetch local OR remote version info...");
        return NO;
    }
    
    NSString *localVersion = nil;

    if(attrs1 != nil) {
        NSData* localVersionBlob = [fm contentsAtPath:filePath1];
        localVersion = [[NSString alloc] initWithData:localVersionBlob encoding:NSUTF8StringEncoding];
        localVersion = [localVersion stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    }
    
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Decide if need to fetch fresh state
    // - update if remote exists and is better
    // - update if remote exists and no local
    // - can end up in a case where there is no data at all locally; thats ok - will fail later
    // - can end up in a case where it has stale data due to intermittent net connect - also ok
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    NSString* version = nil;

    if(remoteVersion && localVersion && ![localVersion isEqualToString:remoteVersion]) {
        version = remoteVersion;
    }

    if(remoteVersion && !localVersion) {
        version = remoteVersion;
    }
    
    if(version) {
        if([self preloadData:version local:@"local"]) {
            [fm createFileAtPath:filePath1 contents:remoteVersionBlob attributes:nil];
        }
    }

    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Let Vuforia have at it
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    Vuforia::DataSet* data = [self loadObjectTrackerDataSet:@"local"];
    if (data == NULL) {
        NSLog(@"Failed to load datasets");
        return NO;
    }
    if (! [self activateDataSet:data]) {
        NSLog(@"Failed to activate dataset");
        return NO;
    }

    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Kick off a side process to incrementally fetch all the poster images in the backdrop - run every time the app runs
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    [eaglView cacheImages:@"local" dataSet:data];
    
    NSLog(@"INFO: successfully activated data set");
    return YES;
}

- (bool) doStartTrackers {
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::Tracker* tracker = trackerManager.getTracker(Vuforia::ObjectTracker::getClassType());
    if(tracker == 0) {
        return false;
    }
    tracker->start();
    return true;
}

- (void) onInitARDone:(NSError *)initError {
    UIActivityIndicatorView *loadingIndicator = (UIActivityIndicatorView *)[eaglView viewWithTag:1];
    [loadingIndicator removeFromSuperview];
    if (initError == nil) {
        NSError * error = nil;
        [vapp startAR:Vuforia::CameraDevice::CAMERA_DIRECTION_BACK error:&error];
        Vuforia::CameraDevice::getInstance().setFocusMode(Vuforia::CameraDevice::FOCUS_MODE_CONTINUOUSAUTO);
    } else {
        NSLog(@"Error initializing AR:%@", [initError description]);
        dispatch_async( dispatch_get_main_queue(), ^{
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Error"
                                                            message:[initError localizedDescription]
                                                           delegate:self
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
            [alert show];
        });
    }
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"kDismissARViewController" object:nil];
}

- (void)dismissARViewController {
    [self.navigationController setNavigationBarHidden:NO animated:YES];
    [self.navigationController popToRootViewControllerAnimated:NO];
}

// Load the image tracker data set
- (Vuforia::DataSet *)loadObjectTrackerDataSet:(NSString*)dataFileName {

    NSLog(@"loadObjectTrackerDataSet (%@)", dataFileName);
    Vuforia::DataSet * dataSet = NULL;

    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
    
    if (NULL == objectTracker) {
        NSLog(@"ERROR: failed to get the ObjectTracker from the tracker manager");
        return NULL;
    }

    dataSet = objectTracker->createDataSet();
    
    if (NULL == dataSet) {
        NSLog(@"ERROR: failed to create data set");
        return NULL;
    }

    NSLog(@"INFO: successfully loaded data set");
    
    // Load the data set from the app's resources location
    NSArray   *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString  *documentsDirectory = [paths objectAtIndex:0];
    NSString  *dataFilePath = [NSString stringWithFormat:@"%@/%@.xml", documentsDirectory,dataFileName];
    
    if (!dataSet->load([dataFilePath cStringUsingEncoding:NSASCIIStringEncoding], Vuforia::STORAGE_ABSOLUTE)) {
        NSLog(@"ERROR: failed to load data set %@",dataFilePath);
        objectTracker->destroyDataSet(dataSet);
        dataSet = NULL;
    }

    return dataSet;
}


- (bool) doStopTrackers {
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::Tracker* tracker = trackerManager.getTracker(Vuforia::ObjectTracker::getClassType());
    if (NULL != tracker) {
        tracker->stop();
        NSLog(@"INFO: successfully stopped tracker");
        return YES;
    } else {
        NSLog(@"ERROR: failed to get the tracker from the tracker manager");
        return NO;
    }
}

- (bool) doUnloadTrackersData {
    [self deactivateDataSet: dataSetCurrent];
    dataSetCurrent = nil;
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
    if (!objectTracker->destroyDataSet(dataSetCurrent)) {
        NSLog(@"Failed to destroy data set.");
    }
    NSLog(@"datasets destroyed");
    return YES;
}

- (BOOL)activateDataSet:(Vuforia::DataSet *)theDataSet {

    if (dataSetCurrent != nil) {
        [self deactivateDataSet:dataSetCurrent];
    }
    BOOL success = NO;
    
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
    
    if (objectTracker == NULL) {
        NSLog(@"Failed to load tracking data set because the ObjectTracker has not been initialized.");
    } else {
        if (!objectTracker->activateDataSet(theDataSet)) {
            NSLog(@"Failed to activate data set.");
        } else {
            NSLog(@"Successfully activated data set.");
            dataSetCurrent = theDataSet;
            success = YES;
        }
    }
    
    if (success) {
        [self setExtendedTrackingForDataSet:dataSetCurrent start:NO];
    }
    
    return success;
}

- (BOOL)deactivateDataSet:(Vuforia::DataSet *)theDataSet {
    if ((dataSetCurrent == nil) || (theDataSet != dataSetCurrent)) {
        NSLog(@"Invalid request to deactivate data set.");
        return NO;
    }

    BOOL success = NO;
    
    // we deactivate the enhanced tracking
    [self setExtendedTrackingForDataSet:theDataSet start:NO];
    
    // Get the image tracker:
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
    
    if (objectTracker == NULL) {
        NSLog(@"Failed to unload tracking data set because the ObjectTracker has not been initialized.");
    } else {
        if (!objectTracker->deactivateDataSet(theDataSet)) {
            NSLog(@"Failed to deactivate data set.");
        }
        else {
            success = YES;
        }
    }
    
    dataSetCurrent = nil;
    
    return success;
}

- (BOOL) setExtendedTrackingForDataSet:(Vuforia::DataSet *)theDataSet start:(BOOL) start {
    BOOL result = YES;
    for (int tIdx = 0; tIdx < theDataSet->getNumTrackables(); tIdx++) {
        Vuforia::Trackable* trackable = theDataSet->getTrackable(tIdx);
        if (start) {
            if (!trackable->startExtendedTracking())
            {
                NSLog(@"Failed to start extended tracking on: %s", trackable->getName());
                result = false;
            }
        } else {
            if (!trackable->stopExtendedTracking())
            {
                NSLog(@"Failed to stop extended tracking on: %s", trackable->getName());
                result = false;
            }
        }
    }
    return result;
}

- (bool) doDeinitTrackers {
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    trackerManager.deinitTracker(Vuforia::ObjectTracker::getClassType());
    return YES;
}

- (void)cameraPerformAutoFocus {
    Vuforia::CameraDevice::getInstance().setFocusMode(Vuforia::CameraDevice::FOCUS_MODE_TRIGGERAUTO);
}

@end
