#include <IOKit/IOKitLib.h>
#include <string.h>
#include "CSensors.h"

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    UInt16 release;
} SMCKeyData_vers_t;

typedef struct {
    UInt16 version;
    UInt16 length;
    UInt32 cpuPLimit;
    UInt32 gpuPLimit;
    UInt32 memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    UInt32 key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    unsigned char bytes[32];
} SMCKeyData_t;

static io_connect_t g_conn = 0;

static UInt32 str_to_key(const char *s) {
    return ((UInt32)(unsigned char)s[0] << 24) | ((UInt32)(unsigned char)s[1] << 16) |
           ((UInt32)(unsigned char)s[2] << 8) | (UInt32)(unsigned char)s[3];
}

static int smc_call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t outSize = sizeof(SMCKeyData_t);
    kern_return_t kr = IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC, in, sizeof(SMCKeyData_t), out, &outSize);
    return kr == kIOReturnSuccess ? 0 : -1;
}

int smc_open(void) {
    if (g_conn) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &g_conn);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess) {
        g_conn = 0;
        return -1;
    }
    return 0;
}

void smc_close(void) {
    if (g_conn) {
        IOServiceClose(g_conn);
        g_conn = 0;
    }
}

int smc_read(const char *key, uint32_t *type, uint8_t *bytes, uint32_t *size) {
    if (!g_conn && smc_open() != 0) return -1;
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = str_to_key(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != 0 || out.result != 0) return -1;

    UInt32 dataSize = out.keyInfo.dataSize;
    UInt32 dataType = out.keyInfo.dataType;
    if (dataSize > 32) dataSize = 32;

    memset(&out, 0, sizeof(out));
    in.keyInfo.dataSize = dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(&in, &out) != 0 || out.result != 0) return -1;

    *type = dataType;
    *size = dataSize;
    memcpy(bytes, out.bytes, dataSize);
    return 0;
}

uint32_t smc_key_count(void) {
    uint32_t type = 0, size = 0;
    uint8_t bytes[32] = {0};
    if (smc_read("#KEY", &type, bytes, &size) != 0 || size < 4) return 0;
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
}

int smc_key_at(uint32_t index, char *out) {
    if (!g_conn && smc_open() != 0) return -1;
    SMCKeyData_t in, res;
    memset(&in, 0, sizeof(in));
    memset(&res, 0, sizeof(res));
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    if (smc_call(&in, &res) != 0 || res.result != 0) return -1;
    out[0] = (char)(res.key >> 24);
    out[1] = (char)(res.key >> 16);
    out[2] = (char)(res.key >> 8);
    out[3] = (char)res.key;
    out[4] = 0;
    return 0;
}
