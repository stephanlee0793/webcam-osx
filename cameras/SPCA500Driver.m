//
//  SPCA500Driver.m
//  macam
//
//  Created by Harald on 11/14/07.
//  Copyright 2007 HXR. All rights reserved.
//


#import "SPCA500Driver.h"


@implementation SPCA500Driver

+ (NSArray *) cameraUsbDescriptions 
{
    return [NSArray arrayWithObjects:
        /*
        [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithUnsignedShort:PRODUCT_DSC_13M_SMART], @"idProduct",
            [NSNumber numberWithUnsignedShort:VENDOR_GENIUS], @"idVendor",
            @"Genius DSC 1.3M Smart", @"name", NULL], 
        */
        NULL];
}


@end


@implementation SPCA500ADriver 

+ (NSArray *) cameraUsbDescriptions 
{
    return [NSArray arrayWithObjects:
        /*
         [NSDictionary dictionaryWithObjectsAndKeys:
             [NSNumber numberWithUnsignedShort:PRODUCT_DSC_13M_SMART], @"idProduct",
             [NSNumber numberWithUnsignedShort:VENDOR_GENIUS], @"idVendor",
             @"Genius DSC 1.3M Smart", @"name", NULL], 
         */
        NULL];
}

@end


@implementation SPCA500CDriver 

+ (NSArray *) cameraUsbDescriptions 
{
    return [NSArray arrayWithObjects:
        /*
         [NSDictionary dictionaryWithObjectsAndKeys:
             [NSNumber numberWithUnsignedShort:PRODUCT_DSC_13M_SMART], @"idProduct",
             [NSNumber numberWithUnsignedShort:VENDOR_GENIUS], @"idVendor",
             @"Genius DSC 1.3M Smart", @"name", NULL], 
         */
        NULL];
}

@end

