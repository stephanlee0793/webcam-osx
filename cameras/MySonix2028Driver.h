/*

    MySonix2028Driver - Driver class for the Sonix SN9C2028F chip, e.g. used in the AEL Auracam DC-31UC

    Copyright (C) 2002 Matthias Krauss (macam@matthias-krauss.de)

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

#import <Cocoa/Cocoa.h>
#import "MyCameraDriver.h"
#include <Carbon/Carbon.h>
#include <QuickTime/QuickTime.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include "GlobalDefs.h"


#define SONIX_NUM_CHUNK_BUFFERS 5
#define SONIX_NUM_TRANSFERS 10
#define SONIX_FRAMES_PER_TRANSFER 50

typedef struct SONIXTransferContext {	//Everything a usb completion callback need to know
    IOUSBIsocFrame frameList[SONIX_FRAMES_PER_TRANSFER];		//The results of the usb frames I received
    unsigned char* buffer;		//This is the place the transfer goes to
} SONIXTransferContext;

typedef struct SONIXChunkBuffer {
    unsigned char* buffer;		//The data
    long numBytes;			//The amount of valid data filled in
} SONIXChunkBuffer;

typedef struct SONIXGrabContext {
    short bytesPerFrame;		//So many bytes are at max transferred per usb frame
    long chunkBufferLength;		//The chunk buffers have each this size
    short numEmptyBuffers;		//So many empty buffers are there
    SONIXChunkBuffer emptyChunkBuffers[SONIX_NUM_CHUNK_BUFFERS];	//The pool of empty, ready-to-use chunk buffers
    short numFullBuffers;		//So many full buffers are there
    SONIXChunkBuffer fullChunkBuffers[SONIX_NUM_CHUNK_BUFFERS];	//A list of full buffers waiting to be decoded
    bool fillingChunk;			//If there is currently a chunk buffer being read
    SONIXChunkBuffer fillingChunkBuffer;	//The buffer that is currently being filled up (valid only if fillingChunk==true)
    short finishedTransfers;		//So many transfers have already finished (for cleanup)
    SONIXTransferContext transferContexts[SONIX_NUM_TRANSFERS];	//The transfer contexts
    IOUSBInterfaceInterface** intf;	//Just a copy from our interface interface so the callback can issue usb
    UInt64 initiatedUntil;		//next usb frame number to initiate a transfer for
    NSLock* chunkReadyLock;		//Our "traffic light" for decodingThread
    NSLock* chunkListLock;		//Mutex for chunkBuffer manipulation
    BOOL* shouldBeGrabbing;		//Ref to the global indicator if the grab should go on
    CameraError err;			//Return value for common errors during grab
    long framesSinceLastChunk;		//Counter to find out an invalid data stream
} SONIXGrabContext;

@interface MySonix2028Driver : MyCameraDriver {
//Parameters set by setResolution:fps: 
    CameraResolution 	camNativeResolution;
    unsigned long 	camRangeOfInterest;	//4 bytes: colstart, colend, rowstart, rowend
    short 	camSensorBaseRate;
    short 	camSensorClkDivider;
    short 	camSkipFrames;
//The context for grabbingThread
   SONIXGrabContext grabContext;		//the grab context (everything the async usb read callbacks need)
   unsigned char *mergeBuffer;		//a SONIX-style 422 yuv buffer to merge compressed images
   BOOL grabbingThreadRunning;		//For active wait for grabbingThread finish
   long frameCounter;			//The first frame of a sequence will always be sent uncompressed to avoid old pixels
}

+ (unsigned short) cameraUsbProductID;
+ (unsigned short) cameraUsbVendorID;
+ (NSString*) cameraName;

- (CameraError) startupWithUsbDeviceRef:(io_service_t)usbDeviceRef;
- (void) dealloc;

- (BOOL) supportsResolution:(CameraResolution)r fps:(short)fr;
- (void) setResolution:(CameraResolution)r fps:(short)fr;
- (CameraResolution) defaultResolutionAndRate:(short*)dFps;

@end
