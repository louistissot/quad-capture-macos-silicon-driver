// qc_descriptors: print the USB descriptors of the Roland QUAD-CAPTURE (0582:012f).
// The tool reads the descriptors only. It does not change the device state.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>

#define QC_VID 0x0582
#define QC_PID 0x012f

static const char *ep_type(uint8_t attr) {
    static const char *t[] = {"control", "isochronous", "bulk", "interrupt"};
    return t[attr & 3];
}

static const char *ep_sync(uint8_t attr) {
    static const char *s[] = {"none", "async", "adaptive", "sync"};
    return s[(attr >> 2) & 3];
}

static const char *ep_usage(uint8_t attr) {
    static const char *u[] = {"data", "feedback", "implicit-feedback-data", "reserved"};
    return u[(attr >> 4) & 3];
}

static void hexdump(const uint8_t *p, size_t n) {
    for (size_t i = 0; i < n; i++) printf("%02x%s", p[i], (i + 1 == n) ? "" : " ");
}

int main(void) {
    @autoreleasepool {
        CFMutableDictionaryRef match =
            [IOUSBHostDevice createMatchingDictionaryWithVendorID:@QC_VID
                                                        productID:@QC_PID
                                                        bcdDevice:nil
                                                      deviceClass:nil
                                                   deviceSubclass:nil
                                                   deviceProtocol:nil
                                                            speed:nil
                                                   productIDArray:nil];
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
        if (!svc) {
            fprintf(stderr, "QUAD-CAPTURE (0582:012f) not found.\n");
            return 1;
        }

        NSError *err = nil;
        IOUSBHostDevice *dev = [[IOUSBHostDevice alloc] initWithIOService:svc
                                                                  options:IOUSBHostObjectInitOptionsNone
                                                                    queue:nil
                                                                    error:&err
                                                          interestHandler:nil];
        IOObjectRelease(svc);
        if (!dev) {
            fprintf(stderr, "Cannot open the device: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }

        const IOUSBDeviceDescriptor *dd = dev.deviceDescriptor;
        printf("DEVICE  bcdUSB=%04x class=%02x/%02x/%02x maxPacket0=%u vid=%04x pid=%04x bcdDevice=%04x configs=%u\n",
               dd->bcdUSB, dd->bDeviceClass, dd->bDeviceSubClass, dd->bDeviceProtocol, dd->bMaxPacketSize0,
               dd->idVendor, dd->idProduct, dd->bcdDevice, dd->bNumConfigurations);
        NSString *mfr = (NSString *)[dev stringWithIndex:dd->iManufacturer error:nil];
        NSString *prod = (NSString *)[dev stringWithIndex:dd->iProduct error:nil];
        printf("        manufacturer=\"%s\" product=\"%s\"\n", mfr.UTF8String ?: "?", prod.UTF8String ?: "?");

        const IOUSBConfigurationDescriptor *cd = [dev configurationDescriptorWithIndex:0 error:&err];
        if (!cd) {
            fprintf(stderr, "Cannot read the configuration descriptor: %s\n", err.localizedDescription.UTF8String);
            [dev destroy];
            return 1;
        }
        const IOUSBConfigurationDescriptor *cur = dev.configurationDescriptor;
        printf("CONFIG  value=%u interfaces=%u totalLength=%u attributes=%02x maxPower=%umA (active config: %s)\n",
               cd->bConfigurationValue, cd->bNumInterfaces, cd->wTotalLength, cd->bmAttributes,
               cd->MaxPower * 2, cur ? "set" : "none");

        const uint8_t *p = (const uint8_t *)cd;
        const uint8_t *end = p + cd->wTotalLength;
        p += cd->bLength;
        while (p + 2 <= end && p[0] >= 2 && p + p[0] <= end) {
            uint8_t len = p[0], type = p[1];
            if (type == 4) {
                printf("  IFACE  num=%u alt=%u endpoints=%u class=%02x/%02x/%02x\n",
                       p[2], p[3], p[4], p[5], p[6], p[7]);
            } else if (type == 5) {
                uint16_t mps = p[4] | (p[5] << 8);
                printf("    EP   addr=%02x (%s) %s sync=%s usage=%s maxPacket=%u (x%u per microframe) interval=%u",
                       p[2], (p[2] & 0x80) ? "IN" : "OUT", ep_type(p[3]), ep_sync(p[3]), ep_usage(p[3]),
                       mps & 0x7ff, ((mps >> 11) & 3) + 1, p[6]);
                if (len > 7) { printf("  extra: "); hexdump(p + 7, len - 7); }
                printf("\n");
            } else {
                printf("    DESC type=%02x len=%u: ", type, len);
                hexdump(p, len);
                printf("\n");
            }
            p += len;
        }
        [dev destroy];
    }
    return 0;
}
