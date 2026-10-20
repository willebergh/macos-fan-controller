#include "SMCBridge.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <libproc.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } PLimit;
typedef struct { uint32_t size, type; uint8_t attributes; } KeyInfo;
typedef struct {
    uint32_t key;
    Version version;
    PLimit limit;
    KeyInfo info;
    uint8_t result, status, command;
    uint32_t data32;
    uint8_t bytes[32];
} SMCData;
_Static_assert(sizeof(SMCData) == 80, "SMC ABI must be 80 bytes");
_Static_assert(offsetof(SMCData, info) == 28, "SMC key info offset");
_Static_assert(offsetof(SMCData, result) == 40, "SMC result offset");
_Static_assert(offsetof(SMCData, data32) == 44, "SMC index offset");
_Static_assert(offsetof(SMCData, bytes) == 48, "SMC bytes offset");
static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0]<<24) | ((uint32_t)(uint8_t)s[1]<<16) |
           ((uint32_t)(uint8_t)s[2]<<8) | (uint8_t)s[3];
}
static uint32_t call(uint32_t c, SMCData *in, SMCData *out) {
    size_t size = sizeof(*out);
    kern_return_t r = IOConnectCallStructMethod(c, 2, in, sizeof(*in), out, &size);
    if (r) return r;
    if (size != sizeof(*out)) return kIOReturnUnderrun;
    return out->result ? (0xE0000000u | out->result) : 0;
}
uint32_t smc_open(uint32_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return kIOReturnNotFound;
    kern_return_t r = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return r;
}
void smc_close(uint32_t c) { if (c) IOServiceClose(c); }
uint32_t smc_read(uint32_t c, const char *key, char *type, uint8_t *bytes, uint32_t *size) {
    SMCData in = {0}, out = {0};
    in.key = fourcc(key); in.command = 9;
    uint32_t r = call(c, &in, &out); if (r) return r;
    if (out.info.size > 32) return kIOReturnNoSpace;
    uint32_t t = out.info.type;
    for (int i=0; i<4; i++) type[i] = (char)(t >> (24-i*8));
    type[4] = 0; *size = out.info.size;
    in.info.size = *size; in.command = 5;
    r = call(c, &in, &out);
    if (!r) memcpy(bytes, out.bytes, *size);
    return r;
}
uint32_t smc_write(uint32_t c, const char *key, const uint8_t *bytes, uint32_t size) {
    if (size > 32) return kIOReturnBadArgument;
    SMCData in = {0}, out = {0};
    in.key = fourcc(key); in.command = 6; in.info.size = size;
    memcpy(in.bytes, bytes, size);
    return call(c, &in, &out);
}
uint32_t smc_key_at(uint32_t c, uint32_t index, char *key) {
    SMCData in = {0}, out = {0}; in.command = 8; in.data32 = index;
    uint32_t r = call(c, &in, &out);
    if (!r) { for (int i=0;i<4;i++) key[i] = (char)(out.key >> (24-i*8)); key[4]=0; }
    return r;
}
static struct sockaddr_un address(uint32_t uid) {
    struct sockaddr_un a = {0}; a.sun_family = AF_UNIX;
    snprintf(a.sun_path, sizeof(a.sun_path), "/var/run/personal-fan-%u.sock", uid);
    a.sun_len = sizeof(a); return a;
}
static void configure(int fd, int receiveSeconds) {
    struct timeval timeout = {receiveSeconds, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    timeout.tv_sec = 2;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
}
int fan_server(uint32_t uid) {
    struct sockaddr_un a = address(uid);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd < 0) return -1;
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) {
        int bindError = errno;
        // A killed helper can leave a socket behind. Only remove a socket in this
        // root-controlled directory, owned by this user, with no live listener.
        struct stat st;
        int probe = socket(AF_UNIX, SOCK_STREAM, 0);
        int connected = probe < 0 ? 0 : connect(probe, (struct sockaddr *)&a, sizeof(a));
        int connectError = errno;
        if (probe >= 0) close(probe);
        if (bindError != EADDRINUSE || connected == 0 || connectError != ECONNREFUSED ||
            lstat(a.sun_path, &st) || !S_ISSOCK(st.st_mode) || st.st_uid != uid ||
            unlink(a.sun_path) || bind(fd, (struct sockaddr *)&a, sizeof(a))) {
            close(fd); return -1;
        }
    }
    if (chown(a.sun_path, uid, (gid_t)-1) || chmod(a.sun_path, 0600) || listen(fd, 4)) {
        close(fd); unlink(a.sun_path); return -1;
    }
    return fd;
}
int fan_accept(int server, uint32_t uid) {
    int fd = accept(server, NULL, NULL); if (fd < 0) return -1;
    uid_t peer; gid_t group;
    if (getpeereid(fd, &peer, &group) || peer != uid) { close(fd); return -1; }
    configure(fd, 2); return fd;
}
int fan_connect(uint32_t uid) {
    struct sockaddr_un a = address(uid);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd < 0) return -1;
    configure(fd, 12);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a))) { close(fd); return -1; }
    uid_t peer; gid_t group;
    if (getpeereid(fd, &peer, &group) || peer != 0) { close(fd); return -1; }
    return fd;
}
uint64_t fan_process_identity(int32_t pid) {
    struct proc_bsdinfo info = {0};
    if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    return (uint64_t)info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
}
int32_t fan_peer_pid(int fd) {
    pid_t pid = 0;
    socklen_t size = sizeof(pid);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) || size != sizeof(pid)) return 0;
    return pid;
}
void fan_remove_socket(uint32_t uid) { struct sockaddr_un a = address(uid); unlink(a.sun_path); }
