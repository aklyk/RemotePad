#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

// libusbmuxd 2.x's public usbmuxd_device_info_t layout.
struct device_info {
    uint32_t handle;
    uint32_t product_id;
    char udid[44];
    int connection_type;
    uint8_t connection_data[200];
};

typedef int (*get_device_fn)(const char *, struct device_info *, int);
typedef int (*connect_device_fn)(uint32_t, uint16_t);

struct buffer {
    uint8_t bytes[16384];
    size_t offset;
    size_t length;
};

static bool retryable(void) {
    return errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK;
}

static bool prepare_socket(int fd) {
    int one = 1;
    int flags = fcntl(fd, F_GETFL);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
        && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one) == 0;
}

static bool read_bytes(struct buffer *buffer, int fd) {
    ssize_t count = recv(fd, buffer->bytes, sizeof buffer->bytes, 0);
    if (count <= 0) return count < 0 && retryable();
    buffer->offset = 0;
    buffer->length = (size_t)count;
    return true;
}

static bool write_bytes(struct buffer *buffer, int fd) {
    if (buffer->length == 0) return true;
    ssize_t count = send(fd, buffer->bytes + buffer->offset, buffer->length, 0);
    if (count <= 0) return count < 0 && retryable();
    buffer->offset += (size_t)count;
    buffer->length -= (size_t)count;
    return true;
}

static void relay(int local, int device) {
    int one = 1;
    if (setsockopt(local, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one) != 0
        || !prepare_socket(local) || !prepare_socket(device)) return;

    struct buffer to_device = {0}, to_local = {0};
    while (true) {
        struct pollfd fds[] = {
            {local, (to_device.length ? 0 : POLLIN) | (to_local.length ? POLLOUT : 0), 0},
            {device, (to_local.length ? 0 : POLLIN) | (to_device.length ? POLLOUT : 0), 0}
        };
        if (poll(fds, 2, -1) < 0) {
            if (errno == EINTR) continue;
            return;
        }
        if ((fds[0].revents | fds[1].revents) & (POLLERR | POLLNVAL)) return;
        if (((fds[0].revents & POLLHUP) && !(fds[0].revents & POLLIN))
            || ((fds[1].revents & POLLHUP) && !(fds[1].revents & POLLIN))) return;
        if ((fds[0].revents & POLLIN) && !read_bytes(&to_device, local)) return;
        if ((fds[1].revents & POLLIN) && !read_bytes(&to_local, device)) return;
        if (!write_bytes(&to_device, device) || !write_bytes(&to_local, local)) return;
    }
}

static uint16_t port_number(const char *text) {
    char *end;
    long port = strtol(text, &end, 10);
    return *end == '\0' && port > 0 && port <= UINT16_MAX ? (uint16_t)port : 0;
}

int main(int argc, char **argv) {
    if (argc != 3) return EXIT_FAILURE;
    uint16_t local_port = port_number(argv[1]), device_port = port_number(argv[2]);
    if (!local_port || !device_port) return EXIT_FAILURE;

    const char *libraries[] = {
        "/opt/homebrew/lib/libusbmuxd-2.0.dylib",
        "/usr/local/lib/libusbmuxd-2.0.dylib"
    };
    void *library = NULL;
    for (size_t i = 0; i < sizeof libraries / sizeof *libraries && !library; i++) {
        library = dlopen(libraries[i], RTLD_NOW | RTLD_LOCAL);
    }
    if (!library) return EXIT_FAILURE;
    get_device_fn get_device = (get_device_fn)dlsym(library, "usbmuxd_get_device");
    connect_device_fn connect_device = (connect_device_fn)dlsym(library, "usbmuxd_connect");
    if (!get_device || !connect_device) return EXIT_FAILURE;

    int listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener < 0) return EXIT_FAILURE;
    int one = 1;
    struct sockaddr_in address = {
        .sin_len = sizeof address, .sin_family = AF_INET, .sin_port = htons(local_port),
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK)
    };
    if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one) != 0
        || bind(listener, (struct sockaddr *)&address, sizeof address) != 0
        || listen(listener, 1) != 0) return EXIT_FAILURE;

    while (true) {
        int local = accept(listener, NULL, NULL);
        if (local < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            return EXIT_FAILURE;
        }
        struct device_info device = {0};
        // DEVICE_LOOKUP_USBMUX (2) includes USB only. CONNECTION_TYPE_USB is 1.
        if (get_device(NULL, &device, 2) > 0 && device.connection_type == 1) {
            int remote = connect_device(device.handle, device_port);
            if (remote >= 0) {
                relay(local, remote);
                close(remote);
            }
        }
        close(local);
    }
}
