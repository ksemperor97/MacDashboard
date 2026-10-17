#include <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include "CSensors.h"

// Private IOHIDEventSystem API (stable since macOS 10.x, used by every Apple Silicon sensor tool).
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define IOHIDEventFieldBase(type) ((type) << 16)

static IOHIDEventSystemClientRef g_client = NULL;

static void ensure_client(void) {
    if (g_client) return;
    g_client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!g_client) return;
    int page = 0xff00, usage = 5;
    CFNumberRef pageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *vals[] = {pageNum, usageNum};
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 2,
                                               &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(g_client, match);
    CFRelease(match);
    CFRelease(pageNum);
    CFRelease(usageNum);
}

int hid_read_temperatures(char *names, double *values, int max) {
    ensure_client();
    if (!g_client) return 0;
    CFArrayRef services = IOHIDEventSystemClientCopyServices(g_client);
    if (!services) return 0;
    int count = 0;
    CFIndex n = CFArrayGetCount(services);
    for (CFIndex i = 0; i < n && count < max; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef product = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        if (!product) continue;
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(svc, kIOHIDEventTypeTemperature, 0, 0);
        if (event) {
            double v = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
            char *name = names + count * 64;
            name[0] = 0;
            if (CFGetTypeID(product) == CFStringGetTypeID()) {
                CFStringGetCString((CFStringRef)product, name, 64, kCFStringEncodingUTF8);
            }
            values[count] = v;
            count++;
            CFRelease(event);
        }
        CFRelease(product);
    }
    CFRelease(services);
    return count;
}
