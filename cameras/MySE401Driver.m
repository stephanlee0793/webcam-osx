/*
 macam - webcam app and QuickTime driver component
 Copyright (C) 2002 Matthias Krauss (macam@matthias-krauss.de)

 Some parts were inspired by Jeroen B. Vreeken's SE401 Linux driver (although no code was copied) 
 
 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 $Id$
 */

#import "MySE401Driver.h"
#import "MyCameraCentral.h"
#include "Resolvers.h"
#include "MiscTools.h"
#include "unistd.h"	//usleep

#define VENDOR_PHILIPS 0x0471
#define PRODUCT_VESTA_FUN 0x030b

#define VENDOR_ENDPOINTS 0x03e8
#define PRODUCT_SE401 0x0004

#define VENDOR_KENSINGTON 0x047d
#define PRODUCT_VIDEOCAM_67014 0x5001
#define PRODUCT_VIDEOCAM_67015 0x5002
#define PRODUCT_VIDEOCAM_67016 0x5003

/* se401 registers */
#define SE401_OPERATINGMODE	0x2000


@interface MySE401Driver (Private)

- (NSMutableData*) getOldestFullChunkBuffer;
- (NSMutableData*) getEmptyChunkBuffer;
- (void) disposeChunkBuffer:(NSMutableData*)buf;
- (void) passChunkBufferToFullOnes:(NSMutableData*)buf;

- (void) decompressJangGuFrom:(UInt8*)src to:(UInt8*)dst rowBytes:(int)dstRB bpp:(int)dstBPP flip:(BOOL)flip;

- (void) doAutoExposure;
- (void) doAutoResetLevel;
- (CameraError) adjustSensorSensitivityWithForce:(BOOL)force;	//Without force, it's only updated if something changes
- (CameraError) setExternalRegister:(UInt16)sel to:(UInt16)val;
- (UInt8) readExternalRegister:(UInt16)sel;
- (CameraError) setInternalRegister:(UInt16)sel to:(UInt16)val;
- (UInt16) readInternalRegister:(UInt16)sel;
    
@end
@implementation MySE401Driver

+ (NSArray*) cameraUsbDescriptions {
    NSDictionary* dict1=[NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedShort:VENDOR_KENSINGTON],@"idVendor",
        [NSNumber numberWithUnsignedShort:PRODUCT_VIDEOCAM_67014],@"idProduct",
        @"Kensington VideoCAM 67014",@"name",NULL];
    NSDictionary* dict2=[NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedShort:VENDOR_KENSINGTON],@"idVendor",
        [NSNumber numberWithUnsignedShort:PRODUCT_VIDEOCAM_67015],@"idProduct",
        @"Kensington VideoCAM 67015/67017",@"name",NULL];
    NSDictionary* dict3=[NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedShort:VENDOR_KENSINGTON],@"idVendor",
        [NSNumber numberWithUnsignedShort:PRODUCT_VIDEOCAM_67016],@"idProduct",
        @"Kensington VideoCAM 67016",@"name",NULL];
    NSDictionary* dict4=[NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedShort:VENDOR_PHILIPS],@"idVendor",
        [NSNumber numberWithUnsignedShort:PRODUCT_VESTA_FUN],@"idProduct",
        @"Philips Vesta Fun (PCVC665K)",@"name",NULL];
    NSDictionary* dict5=[NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedShort:VENDOR_ENDPOINTS],@"idVendor",
        [NSNumber numberWithUnsignedShort:PRODUCT_SE401],@"idProduct",
        @"Endpoints SE401-based camera",@"name",NULL];
    return [NSArray arrayWithObjects:dict1,dict2,dict3,dict4,dict5,NULL];
}
- (id) initWithCentral:(id)c {
    self=[super initWithCentral:c];
    if (!self) return NULL;
    bayerConverter=[[BayerConverter alloc] init];
    if (!bayerConverter) return NULL;
    [bayerConverter setSourceFormat:2];
    maxWidth=320;
    maxHeight=240;
    aeGain=0.5f;
    aeShutter=0.5f;
    lastExposure=-1;
    lastRedGain=-1;
    lastGreenGain=-1;
    lastBlueGain=-1;
    lastResetLevel=-1;
    resetLevel=32;
    return self;
}

- (void) dealloc {
    if (bayerConverter) [bayerConverter release]; bayerConverter=NULL;
    [super dealloc];
}

- (CameraError) startupWithUsbDeviceRef:(io_service_t)usbDeviceRef {
    CameraError err;
    UInt8 buf[64];
    int numSizes;
    int i;
    int width=320;	//Assume there's no smaller camera
    int height=240;
    
    //setup connection to camera
    err=[self usbConnectToCam:usbDeviceRef];
    if (err!=CameraErrorOK) return err;

    //Do the camera startup sequence
    [self setInternalRegister:0x57 to:1];					//Switch LED on
    [self usbReadCmdWithBRequest:0x06 wValue:0 wIndex:0 buf:buf len:64];	//Get camera description
    if (buf[1]!=0x41) {
        NSLog(@"SE401-Camera sent wrong description.");
        return CameraErrorUSBProblem;
    }
    numSizes=buf[4]+buf[5]*256;
    for (i=0; i<=ResolutionSVGA; i++) resolutionSupport[i]=0;	//Reset resolution support bit mask
    
    for (i=0; i<numSizes; i++) {
        int j;
        width =buf[6+i*4+0]+buf[6+i*4+1]*256;
        height=buf[6+i*4+2]+buf[6+i*4+3]*256;
        for (j=1;j<=ResolutionSVGA;j++) {
            if ((WidthOfResolution(j)==width)&&(HeightOfResolution(j)==height)) resolutionSupport[j]|=1;
            if ((WidthOfResolution(j)==width/2)&&(HeightOfResolution(j)==height/2)) resolutionSupport[j]|=2;
            if ((WidthOfResolution(j)==width/4)&&(HeightOfResolution(j)==height/4)) resolutionSupport[j]|=4;
        }
    }
    maxWidth=width;						//Remember max width (=last res)
    maxHeight=height;						//Remember max height (=last res)
    for (i=1;i<=ResolutionSVGA;i++) {
        int a,b,c;
        a=(resolutionSupport[i]&1)?1:0;
        b=(resolutionSupport[i]&2)?1:0;
        c=(resolutionSupport[i]&4)?1:0;
    }
    
    [self setInternalRegister:0x56 to:0];					//Switch camera power off
    [self setInternalRegister:0x57 to:0];					//Switch LED off

    //set some defaults
    [self setBrightness:0.5];
    [self setContrast:0.5];
    [self setGamma:0.5];
    [self setSaturation:0.5];
    [self setSharpness:0.5];
    [self setGain:0.5];
    [self setShutter:0.5];
    [self setWhiteBalanceMode:WhiteBalanceLinear];
    
    //Do the remaining, usual connection stuff
    err=[super startupWithUsbDeviceRef:usbDeviceRef];
    if (err!=CameraErrorOK) return err;

    return err;
}


- (BOOL) supportsResolution:(CameraResolution)res fps:(short)rate {
    if (rate!=5) return NO;
    if (WidthOfResolution(res)>maxWidth) return NO;
    if (HeightOfResolution(res)>maxHeight) return NO;
    if (res>ResolutionSVGA) return NO;
    if (resolutionSupport[res]==0) return NO;
    return YES;
}

- (CameraResolution) defaultResolutionAndRate:(short*)rate {
    if (rate) *rate=5;
    return ResolutionSIF;
}

- (BOOL) canSetSharpness {
    return NO;
/* Well, basically, we can adjust this (the Bayer Converter does it for non-compressed video). But doing it with JangGu-compressed video would take much more processing time and high frame rates are probably more valuable... */
}

- (void) setSharpness:(float)v {
    [super setSharpness:v];
    [bayerConverter setSharpness:sharpness];
}

- (BOOL) canSetBrightness {
    return YES;
}

- (void) setBrightness:(float)v {
    [super setBrightness:v];
    [bayerConverter setBrightness:brightness-0.5f];
}

- (BOOL) canSetContrast {
    return YES;
}

- (void) setContrast:(float)v {
    [super setContrast:v];
    [bayerConverter setContrast:contrast+0.5f];
}

- (BOOL) canSetSaturation {
    return YES;
}

- (void) setSaturation:(float)v {
    [super setSaturation:v];
    [bayerConverter setSaturation:saturation*2.0f];
}

- (BOOL) canSetGamma  {
    return NO;	
/* Well, basically, we can adjust this (the Bayer Converter does it for non-compressed video). But doing it with JangGu-compressed video would take additional processing time and high frame rates are probably more valuable... */
}

- (void) setGamma:(float)v {
    [super setGamma:v];
    [bayerConverter setGamma:gamma+0.5f];
}

- (BOOL) canSetWhiteBalanceMode {
    return YES;
}

- (BOOL) canSetWhiteBalanceModeTo:(WhiteBalanceMode)newMode {
    return ((newMode==WhiteBalanceLinear)||(newMode==WhiteBalanceIndoor)||(newMode==WhiteBalanceOutdoor));
}

- (void) setWhiteBalanceMode:(WhiteBalanceMode)newMode {
    [super setWhiteBalanceMode:newMode];
    switch (newMode) {
        case WhiteBalanceLinear:
            whiteBalanceRed=5.0f;
            whiteBalanceGreen=5.0f;
            whiteBalanceBlue=5.0f;
            break;
        case WhiteBalanceIndoor:
            whiteBalanceRed=0.0f;
            whiteBalanceGreen=5.0f;
            whiteBalanceBlue=10.0f;
            break;
        case WhiteBalanceOutdoor:
            whiteBalanceRed=10.0f;
            whiteBalanceGreen=5.0f;
            whiteBalanceBlue=0.0f;
            break;
        default:
            break;
    }
    [self adjustSensorSensitivityWithForce:NO];
}

- (BOOL) canSetGain {
    return YES;
}

- (void) setGain:(float)v {
    [super setGain:v];
    [self adjustSensorSensitivityWithForce:NO];
}

- (BOOL) canSetShutter {
    return YES;
}

- (void) setShutter:(float)v {
    [super setShutter:v];
    [self adjustSensorSensitivityWithForce:NO];
}

- (BOOL) canSetAutoGain {
    return YES;
}

- (void) setAutoGain:(BOOL)v {
    if (v==autoGain) return;
    [super setAutoGain:v];
    [bayerConverter setMakeImageStats:v];
    lastMeanBrightness=-1.0f;
}

- (BOOL) canSetHFlip {
    return YES;
}

- (short) maxCompression {
    return 1;
}

- (CameraError) startupGrabbing {
    CameraError err=CameraErrorOK;
    int mode=0x03;	//Mode: 0x03=raw, 0x40=JangGu compr. (2x2 subsample), 0x42=JangGu compr. (4x4 subsample)
    int subsampling;
    
    //Set needed variables, calculate values
    videoBulkReadsPending=0;
    grabBufferSize=([self width]*[self height]*3+4096)&0xfffff000;	//This should be enough for all... ***
    resetLevelFrameCounter=0;
    //Allocate memory, locks
    emptyChunks=NULL;
    fullChunks=NULL;
    emptyChunkLock=NULL;
    fullChunkLock=NULL;
    chunkReadyLock=NULL;
    fillingChunk=NULL;
    emptyChunks=[[NSMutableArray alloc] initWithCapacity:SE401_NUM_CHUNKS];
    if (!emptyChunks) return CameraErrorNoMem;
    fullChunks=[[NSMutableArray alloc] initWithCapacity:SE401_NUM_CHUNKS];
    if (!fullChunks) return CameraErrorNoMem;
    emptyChunkLock=[[NSLock alloc] init];
    if (!emptyChunkLock) return CameraErrorNoMem;
    fullChunkLock=[[NSLock alloc] init];
    if (!fullChunkLock) return CameraErrorNoMem;
    chunkReadyLock=[[NSLock alloc] init];
    if (!chunkReadyLock) return CameraErrorNoMem;
    [chunkReadyLock tryLock];								//Should be locked by default
    jangGuBuffer=[[NSMutableData alloc] initWithCapacity:[self width]*[self height]+1000];
    if (!jangGuBuffer) return CameraErrorNoMem;
    
    //Initialize bayer decoder
    if (!err) {
        [bayerConverter setSourceWidth:[self width] height:[self height]];
        [bayerConverter setDestinationWidth:[self width] height:[self height]];
    }

    //Find subsampling
    if (resolutionSupport[resolution]&4) subsampling=4;
    else if (resolutionSupport[resolution]&2) subsampling=2;
    else subsampling=1;

    //Find camera mode
    if (subsampling==1) { mode=0x03; streamIsCompressed=NO;  }
    if (subsampling==2) { mode=0x40; streamIsCompressed=YES; }
    if (subsampling==4) { mode=0x42; streamIsCompressed=YES; }

    //Startup camera
    NSLog(@"Starting up...");
    if (!err) err=[self setInternalRegister:0x56 to:1];					//Switch power on
    if (!err) err=[self setInternalRegister:0x57 to:1];					//Switch LED on
    if (!err) err=[self setExternalRegister:0x01 to:0x05];				//Set win+pix intg.
    if (!err) err=[self adjustSensorSensitivityWithForce:YES];				//Set exposure, gain etc.
    if (!err) err=[self setInternalRegister:0x4d to:[self width]*subsampling];		//Set width
    if (!err) err=[self setInternalRegister:0x4f to:[self height]*subsampling];		//Set height
    if (!err) err=[self setExternalRegister:SE401_OPERATINGMODE to:mode];		//Set data mode
    if (!err) err=[self setInternalRegister:0x41 to:0];					//Start cont. capture

    return err;
}

- (void) shutdownGrabbing {
    NSLog(@"Shutting down...");
    //Stop grabbing action
    [self setInternalRegister:0x42 to:0];
    [self setInternalRegister:0x57 to:0];						//Switch LED off
    [self setInternalRegister:0x56 to:0];						//Switch power off
    if (emptyChunks) {
        [emptyChunks release];
        emptyChunks=NULL;
    }
    if (fullChunks) {
        [fullChunks release];
        fullChunks=NULL;
    }
    if (emptyChunkLock) {
        [emptyChunkLock release];
        emptyChunkLock=NULL;
    }
    if (fullChunkLock) {
        [fullChunkLock release];
        fullChunkLock=NULL;
    }
    if (chunkReadyLock) {
        [chunkReadyLock release];
        chunkReadyLock=NULL;
    }
    if (jangGuBuffer) {
        [jangGuBuffer release];
        jangGuBuffer=NULL;
    }
    if (fillingChunk) {
        [fillingChunk release];
        fillingChunk=NULL;
    }
}

static void handleFullChunk(void *refcon, IOReturn result, void *arg0) {
    MySE401Driver* driver=(MySE401Driver*)refcon;
    long size=((long)arg0);
    [driver handleFullChunkWithReadBytes:size error:result];
}

- (void) handleFullChunkWithReadBytes:(UInt32)readSize error:(IOReturn)err  {
    videoBulkReadsPending--;
    if (err) {
        if (!grabbingError) grabbingError=CameraErrorUSBProblem;
        shouldBeGrabbing=NO;
    }
    if (shouldBeGrabbing) {			//no usb error
        [self passChunkBufferToFullOnes:fillingChunk];
        fillingChunk=NULL;			//to be sure...
    } else {					//Incorrect chunk -> ignore (but back to empty chunks)
        [self disposeChunkBuffer:fillingChunk];
        fillingChunk=NULL;			//to be sure...
    }
    [self doAutoResetLevel];
    if (shouldBeGrabbing) [self fillNextChunk];
//We can only stop if there's no read request left. If there is an error, no new one was issued
    if (videoBulkReadsPending<=0) CFRunLoopStop(CFRunLoopGetCurrent());
}

- (void) fillNextChunk {
    IOReturn err;
    //Get an empty chunk
    if (shouldBeGrabbing) {
        fillingChunk=[self getEmptyChunkBuffer];
        if (!fillingChunk) {
            if (!grabbingError) grabbingError=CameraErrorNoMem;
            shouldBeGrabbing=NO;
        }
    }
//start the bulk read
    if (shouldBeGrabbing) {
        err=((IOUSBInterfaceInterface182*)(*intf))->ReadPipeAsyncTO(intf,1,
                                     [fillingChunk mutableBytes],
                                     grabBufferSize,1000,2000,
                                     (IOAsyncCallback1)(handleFullChunk),self);	//Read one chunk
        CheckError(err,"grabbingThread:ReadPipeAsync");
        if (err) {
            grabbingError=CameraErrorUSBProblem;
            shouldBeGrabbing=NO;
        } else videoBulkReadsPending++;
    }
}


- (void) grabbingThread:(id)data {
    NSAutoreleasePool* pool=[[NSAutoreleasePool alloc] init];
    IOReturn err;
    CFRunLoopSourceRef cfSource;
    
    grabbingError=CameraErrorOK;

//Run the grabbing loob
    if (shouldBeGrabbing) {
        err = (*intf)->CreateInterfaceAsyncEventSource(intf, &cfSource);	//Create an event source
        CheckError(err,"CreateInterfaceAsyncEventSource");
        if (err) {
            if (!grabbingError) grabbingError=CameraErrorNoMem;
            shouldBeGrabbing=NO;
        }
    }

    if (shouldBeGrabbing) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), cfSource, kCFRunLoopDefaultMode);	//Add it to our run loop
        [self fillNextChunk];
        CFRunLoopRun();
    }

    shouldBeGrabbing=NO;			//error in grabbingThread or abort? initiate shutdown of everything else
    [chunkReadyLock unlock];			//give the decodingThread a chance to abort
    [pool release];
    grabbingThreadRunning=NO;
    [NSThread exit];
}

//This is the "netto" decoder - maybe some work left to do :)

#define PEEK_BITS(num,to) {\
    if (bitBufCount<num) {\
        do {\
            if (bitBufRemaining>=8) {\
                bitBuf=(bitBuf<<8)|(src[bitBufOff++]);\
                bitBufCount+=8;\
                bitBufRemaining-=8;\
            } else {\
                if (bitBufRemaining>0) {\
                    bitBuf=((bitBuf<<8)|(src[bitBufOff++]))>>(8-bitBufRemaining);\
                }\
                bitBufCount+=bitBufRemaining;\
                bitBufOff=(bitBufOff+1)&0xfffffffe;\
                bitBufRemaining=src[bitBufOff+2]*256+src[bitBufOff+3];\
                if (!bitBufRemaining) return;	/*will return broken image but prevents segmentation faults*/\
                bitBufOff+=4;\
            }\
        } while (bitBufCount<24);\
    }\
    to=bitBuf>>(bitBufCount-num);\
}

//PEEK_BITS puts the next <num> bits into the low bits of <to>. when the buffer is empty, it is completely refilled. This strategy tries to reduce memory access. Note that the high bits are NOT set to zero!

#define EAT_BITS(num) { bitBufCount-=num; }
//EAT_BITS consumes <num> bits (PEEK_BITS does not consume anything, it just peeks)


- (void) decompressJangGuFrom:(UInt8*)src to:(UInt8*)dst rowBytes:(int)dstRB bpp:(int)dstBPP flip:(BOOL)flip {
    //General values for decoding loop
    int width=[self width];
    int height=[self height];
    int x,y;
    UInt32 bits;
    int delta=0;
    int quantScale=4;
    //vbl bit buffer properties
    UInt32 bitBuf=0;
    UInt8 bitBufCount=0;
    UInt16 bitBufRemaining=src[2]*256+src[3];
    UInt32 bitBufOff=4;
    //Destination pixmap properties
    int dstRowSkip=dstRB-dstBPP*width;
    int dstMode=dstBPP;
    //Color adjustment values
    int iBrightness=(brightness*256.0f)-128.0f;
    int iContrast=contrast*512.0f;
    int iSaturation=saturation*512.0f;
    UInt32 sum=0;
    
    if (flip) {
        dstRowSkip+=2*dstBPP*width;
        dst+=width*dstBPP;
        dstMode+=256;
    }
    
    for (y=0;y<height;y++) {
        int r,g,b,r2,g2,b2;
        r=g=b=1;
        for (x=0;x<width;x++) {
            //RED COMPONENT
            PEEK_BITS(17,bits);			//Get enough bits for longest vbl code
            if (!(bits&0x00010000)) {		//0...		= 0 bit data length, no change
                delta=0;
                EAT_BITS(1);
            } else if (!(bits&0x00008000)) {	//10...		= 1 bit data length, +/- 1
                delta=(int)(bits&0x00004000)?1:-1;
                EAT_BITS(3);
            } else if (!(bits&0x00004000)) {	//110...	= 2 bit data length, +/- 2..3
                delta=(int)((bits>>12)&0x00000001)+((bits&0x00002000)?2:-3);
                EAT_BITS(5);
            } else if (!(bits&0x00002000)) {	//1110...	= 3 bit data length, +/- 4..7
                delta=(int)((bits>>10)&0x00000003)+((bits&0x00001000)?4:-7);
                EAT_BITS(7);
            } else if (!(bits&0x00001000)) {	//11110...	= 4 bit data length, +/- 8..15
                delta=(int)((bits>>8)&0x00000007) +((bits&0x00000800)?8:-15);
                EAT_BITS(9);
            } else if (!(bits&0x00000800)) {	//111110...	= 5 bit data length, +/- 16..31
                delta=(int)((bits>>6)&0x0000000f) +((bits&0x00000400)?16:-31);
                EAT_BITS(11);
            } else if (!(bits&0x00000400)) {	//1111110...	= 6 bit data length, +/- 32..63
                delta=(int)((bits>>4)&0x0000001f) +((bits&0x00000200)?32:-63);
                EAT_BITS(13);
            } else if (!(bits&0x00000200)) {	//11111110...	= 7 bit data length, +/- 64..127
                delta=(int)((bits>>2)&0x0000003f) +((bits&0x00000100)?64:-127);
                EAT_BITS(15);
            } else if (!(bits&0x00000100)) {	//111111110...	= 8 bit data length, +/- 128..255
                delta=(int)(bits&0x0000007f)      +((bits&0x00000080)?128:-255);
                EAT_BITS(17);
            }
            r+=delta*quantScale;
            //GREEN COMPONENT
            PEEK_BITS(17,bits);			//Get enough bits for longest vbl code
            if (!(bits&0x00010000)) {		//0...		= 0 bit data length, no change
                delta=0;
                EAT_BITS(1);
            } else if (!(bits&0x00008000)) {	//10...		= 1 bit data length, +/- 1
                delta=(int)(bits&0x00004000)?1:-1;
                EAT_BITS(3);
            } else if (!(bits&0x00004000)) {	//110...	= 2 bit data length, +/- 2..3
                delta=(int)((bits>>12)&0x00000001)+((bits&0x00002000)?2:-3);
                EAT_BITS(5);
            } else if (!(bits&0x00002000)) {	//1110...	= 3 bit data length, +/- 4..7
                delta=(int)((bits>>10)&0x00000003)+((bits&0x00001000)?4:-7);
                EAT_BITS(7);
            } else if (!(bits&0x00001000)) {	//11110...	= 4 bit data length, +/- 8..15
                delta=(int)((bits>>8)&0x00000007) +((bits&0x00000800)?8:-15);
                EAT_BITS(9);
            } else if (!(bits&0x00000800)) {	//111110...	= 5 bit data length, +/- 16..31
                delta=(int)((bits>>6)&0x0000000f) +((bits&0x00000400)?16:-31);
                EAT_BITS(11);
            } else if (!(bits&0x00000400)) {	//1111110...	= 6 bit data length, +/- 32..63
                delta=(int)((bits>>4)&0x0000001f) +((bits&0x00000200)?32:-63);
                EAT_BITS(13);
            } else if (!(bits&0x00000200)) {	//11111110...	= 7 bit data length, +/- 64..127
                delta=(int)((bits>>2)&0x0000003f) +((bits&0x00000100)?64:-127);
                EAT_BITS(15);
            } else if (!(bits&0x00000100)) {	//111111110...	= 8 bit data length, +/- 128..255
                delta=(int)(bits&0x0000007f)      +((bits&0x00000080)?128:-255);
                EAT_BITS(17);
            }
            g+=delta*quantScale;
            //BLUE COMPONENT
            PEEK_BITS(17,bits);			//Get enough bits for longest vbl code
            if (!(bits&0x00010000)) {		//0...		= 0 bit data length, no change
                delta=0;
                EAT_BITS(1);
            } else if (!(bits&0x00008000)) {	//10...		= 1 bit data length, +/- 1
                delta=(int)(bits&0x00004000)?1:-1;
                EAT_BITS(3);
            } else if (!(bits&0x00004000)) {	//110...	= 2 bit data length, +/- 2..3
                delta=(int)((bits>>12)&0x00000001)+((bits&0x00002000)?2:-3);
                EAT_BITS(5);
            } else if (!(bits&0x00002000)) {	//1110...	= 3 bit data length, +/- 4..7
                delta=(int)((bits>>10)&0x00000003)+((bits&0x00001000)?4:-7);
                EAT_BITS(7);
            } else if (!(bits&0x00001000)) {	//11110...	= 4 bit data length, +/- 8..15
                delta=(int)((bits>>8)&0x00000007) +((bits&0x00000800)?8:-15);
                EAT_BITS(9);
            } else if (!(bits&0x00000800)) {	//111110...	= 5 bit data length, +/- 16..31
                delta=(int)((bits>>6)&0x0000000f) +((bits&0x00000400)?16:-31);
                EAT_BITS(11);
            } else if (!(bits&0x00000400)) {	//1111110...	= 6 bit data length, +/- 32..63
                delta=(int)((bits>>4)&0x0000001f) +((bits&0x00000200)?32:-63);
                EAT_BITS(13);
            } else if (!(bits&0x00000200)) {	//11111110...	= 7 bit data length, +/- 64..127
                delta=(int)((bits>>2)&0x0000003f) +((bits&0x00000100)?64:-127);
                EAT_BITS(15);
            } else if (!(bits&0x00000100)) {	//111111110...	= 8 bit data length, +/- 128..255
                delta=(int)(bits&0x0000007f)      +((bits&0x00000080)?128:-255);
                EAT_BITS(17);
            }
            b+=delta*quantScale;

            sum+=r+g+b;
            
            //color adjustments
            r2=((((g+(((r-g)*iSaturation)/256)+iBrightness)-128)*iContrast)/256)+128;
            r2=CLAMP(r2,0,255);
            g2=((((g+iBrightness)-128)*iContrast)/256)+128;
            g2=CLAMP(g2,0,255);
            b2=((((g+(((b-g)*iSaturation)/256)+iBrightness)-128)*iContrast)/256)+128;
            b2=CLAMP(b2,0,255);
            //Write pixel
            switch (dstMode) {
                case 3:
                    *(dst++)=r2;
                    *(dst++)=g2;
                    *(dst++)=b2;
                    break;
                case 4:
                    *(dst++)=255;
                    *(dst++)=r2;
                    *(dst++)=g2;
                    *(dst++)=b2;
                    break;
                case 259:
                    *(--dst)=b2;
                    *(--dst)=g2;
                    *(--dst)=r2;
                    break;
                case 260:
                    *(--dst)=b2;
                    *(--dst)=g2;
                    *(--dst)=r2;
                    *(--dst)=255;
                    break;
            }
        }
        dst+=dstRowSkip;
    }
    lastMeanBrightness=((float)sum)/(((float)width)*((float)height)*768.0f);
}

- (CameraError) decodingThread {
    CameraError err=CameraErrorOK;
    NSMutableData* currChunk;
    unsigned char* imgData;
    long width=4;	//Just some stupid values to keep the compiler happy
    long height=4;
    BOOL bufferSet;
    grabbingThreadRunning=NO;
    
    err=[self startupGrabbing];

    if (err) shouldBeGrabbing=NO;
    
    if (shouldBeGrabbing) {
        grabbingError=CameraErrorOK;
        grabbingThreadRunning=YES;
        [NSThread detachNewThreadSelector:@selector(grabbingThread:) toTarget:self withObject:NULL];    //start grabbingThread
        width=[self width];						//Should remain constant during grab
        height=[self height];						//Should remain constant during grab
        while (shouldBeGrabbing) {
            [chunkReadyLock lock];					//wait for new chunks to arrive
            while ((shouldBeGrabbing)&&([fullChunks count]>0)) {	//decode all full chunks we have
                currChunk=[self getOldestFullChunkBuffer];
                [imageBufferLock lock];					//Get image data
                lastImageBuffer=nextImageBuffer;
                lastImageBufferBPP=nextImageBufferBPP;
                lastImageBufferRowBytes=nextImageBufferRowBytes;
                bufferSet=nextImageBufferSet;
                nextImageBufferSet=NO;
                if (bufferSet) {
                    imgData=[currChunk mutableBytes];
                    if (streamIsCompressed) {				//Decode JangGu-compressed Stream
                        [self decompressJangGuFrom:imgData
                                                to:lastImageBuffer
                                          rowBytes:lastImageBufferRowBytes
                                               bpp:lastImageBufferBPP
                                              flip:!hFlip];
                    } else {						//Decode raw Bayer stream
                        [bayerConverter convertFromSrc:imgData+width
                                                toDest:lastImageBuffer
                                           srcRowBytes:width
                                           dstRowBytes:lastImageBufferRowBytes
                                                dstBPP:lastImageBufferBPP
                                                  flip:!hFlip];
                    }
                    [imageBufferLock unlock];
                    [self mergeImageReady];
                    if (autoGain) [self doAutoExposure];
                } else {
                    [imageBufferLock unlock];
                }
                [emptyChunkLock lock];			//recycle our chunk - it's empty again
                [emptyChunks addObject:currChunk];
                [currChunk release];
                currChunk=NULL;
                [emptyChunkLock unlock];
            }
        }
    }
    while (grabbingThreadRunning) { usleep(10000); }	//Wait for grabbingThread finish
    //We need to sleep here because otherwise the compiler would optimize the loop away

    if (!err) err=grabbingError;			//Take error from grabbing thread
    [self shutdownGrabbing];
    return err;
}

//(internal) tool functions

- (void) doAutoExposure {
//Auto exposure currently only changes the exposure time, not the gain. This could improve frame rates with low light conditions, for example... ***
    float tolerance=0.05f;
    float scale=0.2f;
    float wanted=0.5f;

    float avg=streamIsCompressed?lastMeanBrightness:[bayerConverter lastMeanBrightness];
    if (avg<0.0f) return;	//Invalid value - bayer decoder didn't count yet
    avg-=wanted;		//Shift wanted value to zero

    //Free the tolerance corridor
    if (avg>tolerance) avg-=tolerance;	
    else if (avg<-tolerance) avg+=tolerance;
    else return;

    //Do the correction
    aeShutter-=scale*avg;
    if (aeShutter<0.0f) aeShutter=0.0f;
    if (aeShutter>1.0f) aeShutter=1.0f;
    [self adjustSensorSensitivityWithForce:NO];
}

- (void) doAutoResetLevel {
    int lowCount=0;
    int highCount=0;

    //Count frames so we don't adjust each frame (see Hynix docs)
    resetLevelFrameCounter++;
    if (resetLevelFrameCounter<2) return;
    resetLevelFrameCounter=0;

    //Read high/low pixel statistics
    lowCount +=[self readExternalRegister:0x57]*256;
    lowCount +=[self readExternalRegister:0x58];
    highCount+=[self readExternalRegister:0x59]*256;
    highCount+=[self readExternalRegister:0x5a];

    //see if we have to change the reset level
    if(lowCount>10) resetLevel++;
    if(highCount>20) resetLevel--;
    if (resetLevel<0) resetLevel=0;
    if (resetLevel>63) resetLevel=63;

    //Trigger second time to reset
    [self readExternalRegister:0x57];
    [self readExternalRegister:0x58];
    [self readExternalRegister:0x59];
    [self readExternalRegister:0x5a];

    //Commit changes
    [self adjustSensorSensitivityWithForce:NO];
}

- (CameraError) adjustSensorSensitivityWithForce:(BOOL)force {
    CameraError err=CameraErrorOK;
    SInt32 exposure=(autoGain?aeShutter:shutter)*((float)1000000);
    SInt16 redGain=63.0f-((autoGain?aeGain:gain)*23.0f+whiteBalanceRed);
    SInt16 greenGain=63.0f-((autoGain?aeGain:gain)*23.0f+whiteBalanceGreen);
    SInt16 blueGain=63.0f-((autoGain?aeGain:gain)*23.0f+whiteBalanceBlue);
    if (isGrabbing) {
        if (force||(exposure!=lastExposure)) {
            if (!err) err=[self setExternalRegister:0x25 to:((exposure>>16)&0xff)];		//Set exposure high
            if (!err) err=[self setExternalRegister:0x26 to:((exposure>>8)&0xff)];		//Set exposure mid
            if (!err) err=[self setExternalRegister:0x27 to:(exposure&0xff)];			//Set exposure low
            lastExposure=exposure;
        }
        if (force||(resetLevel!=lastResetLevel)) {
            if (!err) err=[self setExternalRegister:0x30 to:resetLevel];			//Set reset level
            lastResetLevel=resetLevel;
        }
        if (force||(redGain!=lastRedGain)) {
            if (!err) err=[self setExternalRegister:0x31 to:redGain];				//Set red gain
            lastRedGain=redGain;
        }
        if (force||(greenGain!=lastGreenGain)) {
            if (!err) err=[self setExternalRegister:0x32 to:greenGain];				//Set green gain
            lastGreenGain=greenGain;
        }
        if (force||(blueGain!=lastBlueGain)) {
            if (!err) err=[self setExternalRegister:0x33 to:blueGain];				//Set blue gain
            lastBlueGain=blueGain;
        }
    }
    return err;
}

- (CameraError) setExternalRegister:(UInt16)sel to:(UInt16)val {
    BOOL ok;
    ok=[self usbWriteCmdWithBRequest:0x53 wValue:val wIndex:sel buf:NULL len:0];
    return (ok)?CameraErrorOK:CameraErrorUSBProblem;
}

- (UInt8) readExternalRegister:(UInt16)sel {
    BOOL ok;
    UInt8 buf[2];
    ok=[self usbReadCmdWithBRequest:0x52 wValue:0 wIndex:sel buf:buf len:2];
    if (!ok) return 0;
    return buf[0]+256*buf[1];
}

- (CameraError) setInternalRegister:(UInt16)sel to:(UInt16)val {
    BOOL ok;
    ok=[self usbWriteCmdWithBRequest:sel wValue:val wIndex:0 buf:NULL len:0];
    return (ok)?CameraErrorOK:CameraErrorUSBProblem;
}

- (UInt16) readInternalRegister:(UInt16)sel {
    UInt8 buf[2];
    BOOL ok;
    ok=[self usbReadCmdWithBRequest:sel wValue:0 wIndex:0 buf:buf len:2];
    if (!ok) return 0;
    return buf[0]+256*buf[1];
}

//Chunk buffer queues management

- (NSMutableData*) getEmptyChunkBuffer {
    NSMutableData* buf;
    if ([emptyChunks count]>0) {						//We have a recyclable buffer
        [emptyChunkLock lock];
        buf=[emptyChunks lastObject];
        [buf retain];
        [emptyChunks removeLastObject];
        [emptyChunkLock unlock];
    } else {									//We need to allocate a new one
        buf=[[NSMutableData alloc] initWithCapacity:grabBufferSize];
    }
    return buf;
}

- (void) disposeChunkBuffer:(NSMutableData*)buf {
    if (buf) {
        [emptyChunkLock lock];
        [emptyChunks addObject:buf];
        [buf release];
        [emptyChunkLock unlock];
    }
}

- (void) passChunkBufferToFullOnes:(NSMutableData*)buf {
    if ([fullChunks count]>SE401_NUM_CHUNKS) {	//the full chunk list is already full - discard the oldest
        [self disposeChunkBuffer:[self getOldestFullChunkBuffer]];
    }
    [fullChunkLock lock];			//Append our full chunk to the list
    [fullChunks addObject:fillingChunk];
    [buf release];
    [fullChunkLock unlock];
    [chunkReadyLock tryLock];			//New chunk is there. Try to wake up the decoder
    [chunkReadyLock unlock];
}

- (NSMutableData*) getOldestFullChunkBuffer {
    NSMutableData* buf;
    [fullChunkLock lock];					//Take the oldest chunk to decode
    buf=[fullChunks objectAtIndex:0];
    [buf retain];
    [fullChunks removeObjectAtIndex:0];
    [fullChunkLock unlock];
    return buf;
}


@end	
