/* Shared socket I/O loops for the bridge, proxy and shim (review R-4:
 * four same-shaped loops lived in four files and drifted independently).
 *
 * Each translation unit defines these static primitives BEFORE including
 * this header; every function here is `static inline`, so each side gets
 * its own compiled copy against its own platform calls:
 *
 *   static int64_t uurbs_now_ms(void);                     // monotonic ms
 *   static int uurbs_wait(int fd, int readable, int64_t deadline);
 *       // 1 = ready, 0 = timeout/deadline; folds uurbs_stopped into 0
 *   static long uurbs_pull(int fd, void *buffer, size_t size);
 *       // >0 = bytes, 0 = EOF, <0 = error (uurbs_retriable may continue)
 *   static long uurbs_push(int fd, const void *buffer, size_t size);
 *       // >0 = bytes, <0 = error
 *   static int uurbs_retriable(void);   // EINTR/EAGAIN predicate
 *   static int uurbs_stopped(void);     // bridge: stop_requested
 */
#ifndef UURB_TRANSPORT_COMMON_H
#define UURB_TRANSPORT_COMMON_H

#include <stddef.h>

typedef long (*uurbs_push_fn)(int fd, const void *buffer, size_t size);

static inline int uurbs_read_exact(int fd, void *buffer, size_t size,
                                   int64_t deadline)
{
    unsigned char *cursor = buffer;

    while (size > 0) {
        long received;

        if (!uurbs_wait(fd, 1, deadline))
            return uurbs_stopped() ? -2 : 0;
        received = uurbs_pull(fd, cursor, size);
        if (received == 0)
            return 0;
        if (received < 0) {
            if (!uurbs_retriable())
                return -1;
            continue;
        }
        cursor += received;
        size -= (size_t)received;
    }
    return 1;
}

static inline int uurbs_push_all(int fd, const void *buffer, size_t size,
                                 int64_t deadline, uurbs_push_fn push)
{
    const unsigned char *cursor = buffer;

    while (size > 0) {
        long sent;

        if (!uurbs_wait(fd, 0, deadline))
            return uurbs_stopped() ? -2 : 0;
        sent = push(fd, cursor, size);
        if (sent <= 0) {
            if (!uurbs_retriable())
                return 0;
            continue;
        }
        cursor += sent;
        size -= (size_t)sent;
    }
    return 1;
}

static inline int uurbs_write_all(int fd, const void *buffer, size_t size,
                                  int64_t deadline)
{
    return uurbs_push_all(fd, buffer, size, deadline, uurbs_push);
}

#endif
