// qc_rate: read and change the sample rate of the Roland QUAD-CAPTURE (0582:012f).
//
// The audio endpoints have no sampling-frequency control. The device clock changes with a
// vendor request on endpoint 0 (see docs/PROTOCOL.md, "Sample rate"):
//   set:    bmRequestType 0x40, bRequest 0x03, wValue 0x0008, wIndex 0, 4 bytes:
//           0x40, then the rate in Hz as a 24-bit little-endian value
//   status: bmRequestType 0xc0, bRequest 0x03, wValue 0x0001, wIndex 0, 4 bytes:
//           the rate in Hz (24-bit little-endian), then a flag byte
//           (bit 0: the change is not complete yet, bit 1: error)
// The device also sends 8-byte status messages on the interrupt endpoint 0x82 (interface 3,
// alternate setting 1).
//
// Usage:
//   qc_rate                 read the rate (status request) and the status messages
//   qc_rate <hz>            change the rate to 44100, 48000, 96000 or 192000 Hz
// CAUTION: change the rate only while no app and no test tool uses the QUAD-CAPTURE.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <stdlib.h>
#include <unistd.h>

#define QC_VID 0x0582
#define QC_PID 0x012f

static IOUSBHostDevice *gDev;

// Status request. Returns false if the request fails.
static bool readRate(uint32_t *rate, uint8_t *flags) {
    IOUSBDeviceRequest req = {.bmRequestType = 0xc0, .bRequest = 0x03, .wValue = 0x0001, .wIndex = 0, .wLength = 4};
    NSMutableData *data = [NSMutableData dataWithLength:4];
    NSUInteger done = 0;
    NSError *err = nil;
    if (![gDev sendDeviceRequest:req data:data bytesTransferred:&done completionTimeout:1.0 error:&err]) {
        fprintf(stderr, "Status request failed: %s\n", err.localizedDescription.UTF8String);
        return false;
    }
    if (done != 4) {
        fprintf(stderr, "Status request: %lu bytes (expected 4)\n", (unsigned long)done);
        return false;
    }
    const uint8_t *b = data.bytes;
    *rate = b[0] | (b[1] << 8) | (b[2] << 16);
    *flags = b[3];
    return true;
}

static bool setRate(uint32_t rate) {
    IOUSBDeviceRequest req = {.bmRequestType = 0x40, .bRequest = 0x03, .wValue = 0x0008, .wIndex = 0, .wLength = 4};
    uint8_t b[4] = {0x40, rate & 0xff, (rate >> 8) & 0xff, (rate >> 16) & 0xff};
    NSMutableData *data = [NSMutableData dataWithBytes:b length:4];
    NSUInteger done = 0;
    NSError *err = nil;
    if (![gDev sendDeviceRequest:req data:data bytesTransferred:&done completionTimeout:1.0 error:&err]) {
        fprintf(stderr, "Set request failed: %s\n", err.localizedDescription.UTF8String);
        return false;
    }
    // The device changes its clock. Poll the status each 200 ms, for 8 s at most.
    // The first status after the request can still show the old rate (seen at 48 -> 96 kHz).
    for (int i = 0; i < 40; i++) {
        uint32_t r;
        uint8_t f;
        if (!readRate(&r, &f)) return false;
        printf("  poll %2d: rate %u Hz, flags %02x\n", i, r, f);
        if (f & 0x02) { fprintf(stderr, "The device reports an error.\n"); return false; }
        if (r == rate && !(f & 0x01)) return true;
        usleep(200000);
    }
    fprintf(stderr, "The change did not complete in 8 s.\n");
    return false;
}

// Read the status messages of the interrupt endpoint 0x82 (interface 3) for about 1 s.
static void readStatusMessages(void) {
    CFMutableDictionaryRef m =
        [IOUSBHostInterface createMatchingDictionaryWithVendorID:@QC_VID productID:@QC_PID bcdDevice:nil
                                                 interfaceNumber:@3 configurationValue:@1
                                                  interfaceClass:nil interfaceSubclass:nil
                                               interfaceProtocol:nil speed:nil productIDArray:nil];
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!svc) { printf("Interface 3 not found (is the configuration set?).\n"); return; }
    NSError *err = nil;
    IOUSBHostInterface *ifc = [[IOUSBHostInterface alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone
                                                                      queue:nil error:&err interestHandler:nil];
    IOObjectRelease(svc);
    if (!ifc) { printf("Cannot open interface 3: %s\n", err.localizedDescription.UTF8String); return; }
    // Alternate setting 0 has no endpoint. Endpoint 0x82 is in alternate setting 1.
    if (![ifc selectAlternateSetting:1 error:&err]) {
        printf("Cannot select alternate setting 1: %s\n", err.localizedDescription.UTF8String);
        [ifc destroy];
        return;
    }
    IOUSBHostPipe *pipe = [ifc copyPipeWithAddress:0x82 error:&err];
    if (!pipe) { printf("Cannot open endpoint 0x82: %s\n", err.localizedDescription.UTF8String); [ifc destroy]; return; }
    NSMutableData *data = [ifc ioDataWithCapacity:8 error:&err];
    for (int i = 0; i < 8; i++) {
        NSUInteger n = 0;
        if (![pipe sendIORequestWithData:data bytesTransferred:&n completionTimeout:0.25 error:&err]) {
            printf("  message %d: none (%s)\n", i, err.localizedDescription.UTF8String);
            break;
        }
        const uint8_t *b = data.bytes;
        printf("  message %d:", i);
        for (NSUInteger k = 0; k < n; k++) printf(" %02x", b[k]);
        if (n == 8 && b[0] == 1) printf("   (rate %u Hz)", b[3] | (b[4] << 8) | (b[5] << 16));
        printf("\n");
    }
    [ifc selectAlternateSetting:0 error:nil];
    [ifc destroy];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        uint32_t target = 0;
        if (argc == 2) {
            target = (uint32_t)strtoul(argv[1], NULL, 10);
            if (target != 44100 && target != 48000 && target != 96000 && target != 192000) {
                fprintf(stderr, "usage: qc_rate [44100|48000|96000|192000]\n");
                return 2;
            }
        } else if (argc != 1) {
            fprintf(stderr, "usage: qc_rate [44100|48000|96000|192000]\n");
            return 2;
        }
        CFMutableDictionaryRef match =
            [IOUSBHostDevice createMatchingDictionaryWithVendorID:@QC_VID productID:@QC_PID bcdDevice:nil deviceClass:nil
                                                   deviceSubclass:nil deviceProtocol:nil speed:nil productIDArray:nil];
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
        if (!svc) { fprintf(stderr, "QUAD-CAPTURE (0582:012f) not found.\n"); return 1; }
        NSError *err = nil;
        gDev = [[IOUSBHostDevice alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:nil
                                                    error:&err interestHandler:nil];
        IOObjectRelease(svc);
        if (!gDev) { fprintf(stderr, "Cannot open the device: %s\n", err.localizedDescription.UTF8String); return 1; }
        if (!gDev.configurationDescriptor && ![gDev configureWithValue:1 matchInterfaces:YES error:&err]) {
            fprintf(stderr, "Cannot set configuration 1: %s\n", err.localizedDescription.UTF8String);
            [gDev destroy];
            return 1;
        }

        int rc = 0;
        uint32_t rate;
        uint8_t flags;
        if (readRate(&rate, &flags)) printf("Rate: %u Hz, flags %02x\n", rate, flags);
        else rc = 1;
        if (target && rc == 0) {
            printf("Change the rate to %u Hz:\n", target);
            if (setRate(target)) printf("Rate changed to %u Hz.\n", target);
            else rc = 1;
        }
        // The device object is necessary only for endpoint 0. Close it before the interface opens.
        [gDev destroy];
        gDev = nil;
        printf("Status messages (interrupt endpoint 0x82):\n");
        readStatusMessages();
        return rc;
    }
}
