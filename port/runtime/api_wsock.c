/* wsock32 (Winsock 1.1) on BSD sockets. A SOCKET is the host file descriptor. */
#include "gp_api.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#undef DLL
#define DLL "wsock32.dll"

#define INVALID_SOCKET 0xffffffffu
#define SOCKET_ERROR 0xffffffffu
#define WSA_FD_MAX 64

static uint32_t wsa_error(int e)
{
    switch (e) {
    case EWOULDBLOCK: return 10035;   /* EAGAIN == EWOULDBLOCK on Darwin */
    case EINPROGRESS: return 10036;
    case EALREADY: return 10037;
    case ENOTSOCK: case EBADF: return 10038;
    case EDESTADDRREQ: return 10039;
    case EMSGSIZE: return 10040;
    case EPROTOTYPE: return 10041;
    case ENOPROTOOPT: return 10042;
    case EPROTONOSUPPORT: return 10043;
    case EOPNOTSUPP: return 10045;
    case EAFNOSUPPORT: return 10047;
    case EADDRINUSE: return 10048;
    case EADDRNOTAVAIL: return 10049;
    case ENETDOWN: return 10050;
    case ENETUNREACH: return 10051;
    case ECONNABORTED: return 10053;
    case ECONNRESET: case EPIPE: return 10054;
    case ENOBUFS: case ENOMEM: return 10055;
    case EISCONN: return 10056;
    case ENOTCONN: return 10057;
    case ESHUTDOWN: return 10058;
    case ETIMEDOUT: return 10060;
    case ECONNREFUSED: return 10061;
    case EHOSTUNREACH: return 10065;
    case EACCES: return 10013;
    case EFAULT: return 10014;
    case EINVAL: return 10022;
    case EMFILE: return 10024;
    default: gp_fatal("wsock32: no Winsock error code for errno %d (%s)", e, strerror(e));
    }
}
static uint32_t fail(gp_thread *t) { set_error(t, wsa_error(errno)); return SOCKET_ERROR; }

/* Windows sockaddr_in: u16 family, u16 port (network), u32 addr (network), 8 zero bytes; no sin_len */
static bool addr_in(gp_thread *t, gaddr a, uint32_t len, struct sockaddr_in *out)
{
    if (!a || len < 16) { set_error(t, 10014); return false; }
    uint16_t fam; memcpy(&fam, G(a), 2);
    if (fam != AF_INET) { set_error(t, 10047); return false; }
    memset(out, 0, sizeof *out);
    out->sin_len = sizeof *out; out->sin_family = AF_INET;
    memcpy(&out->sin_port, (uint8_t *)G(a) + 2, 2);
    memcpy(&out->sin_addr, (uint8_t *)G(a) + 4, 4);
    return true;
}
static bool addr_out(gp_thread *t, const struct sockaddr_in *in, gaddr a, gaddr plen)
{
    if (!a) return true;
    if (!plen || (int32_t)rd32(plen) < 16) { set_error(t, 10014); return false; }
    uint8_t w[16] = {0};
    uint16_t fam = AF_INET;
    memcpy(w, &fam, 2); memcpy(w + 2, &in->sin_port, 2); memcpy(w + 4, &in->sin_addr, 4);
    memcpy(G(a), w, 16);
    wr32(plen, 16);
    return true;
}

static uint32_t WSAStartup_(gp_thread *t)
{
    uint16_t ver = (uint16_t)A(0);
    gaddr data = A(1);
    if ((ver & 0xff) < 1) return 10092;                            /* WSAVERNOTSUPPORTED */
    if (!data) return 10014;
    uint8_t w[400] = {0};                                         /* WSADATA (32-bit) */
    uint16_t v = 0x0101, maxs = 32767, maxdg = 65467;
    memcpy(w, &v, 2); memcpy(w + 2, &v, 2);
    strcpy((char *)w + 4, "WinSock 1.1 (BSD sockets)");
    strcpy((char *)w + 4 + 257, "Running");
    memcpy(w + 390, &maxs, 2); memcpy(w + 392, &maxdg, 2);
    memcpy(G(data), w, sizeof w);
    (void)t;
    return 0;
}
static uint32_t WSACleanup_(gp_thread *t) { (void)t; return 0; }
static uint32_t WSAGetLastError_(gp_thread *t) { return t->last_error; }
static uint32_t WSASetLastError_(gp_thread *t) { t->last_error = A(0); return 0; }

static uint32_t socket_(gp_thread *t)
{
    int fd = socket((int)A(0), (int)A(1), (int)A(2));
    if (fd < 0) { set_error(t, wsa_error(errno)); return INVALID_SOCKET; }
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one) != 0) {   /* Windows never raises SIGPIPE */
        int e = errno; close(fd); set_error(t, wsa_error(e)); return INVALID_SOCKET;
    }
    return (uint32_t)fd;
}
static uint32_t closesocket_(gp_thread *t) { return close((int)A(0)) == 0 ? 0 : fail(t); }
static uint32_t shutdown_(gp_thread *t) { return shutdown((int)A(0), (int)A(1)) == 0 ? 0 : fail(t); }

static uint32_t bind_(gp_thread *t)
{
    struct sockaddr_in sa;
    if (!addr_in(t, A(1), A(2), &sa)) return SOCKET_ERROR;
    return bind((int)A(0), (struct sockaddr *)&sa, sizeof sa) == 0 ? 0 : fail(t);
}
static uint32_t connect_(gp_thread *t)
{
    struct sockaddr_in sa;
    if (!addr_in(t, A(1), A(2), &sa)) return SOCKET_ERROR;
    if (connect((int)A(0), (struct sockaddr *)&sa, sizeof sa) == 0) return 0;
    if (errno == EINPROGRESS) { set_error(t, 10035); return SOCKET_ERROR; }   /* non-blocking connect */
    return fail(t);
}
static uint32_t getsockname_(gp_thread *t)
{
    struct sockaddr_in sa; socklen_t l = sizeof sa;
    if (getsockname((int)A(0), (struct sockaddr *)&sa, &l) != 0) return fail(t);
    return addr_out(t, &sa, A(1), A(2)) ? 0 : SOCKET_ERROR;
}

static uint32_t send_(gp_thread *t)
{
    ssize_t n = send((int)A(0), A(2) ? G(A(1)) : NULL, A(2), (int)A(3));
    return n < 0 ? fail(t) : (uint32_t)n;
}
static uint32_t sendto_(gp_thread *t)
{
    struct sockaddr_in sa;
    if (!A(4)) return send_(t);
    if (!addr_in(t, A(4), A(5), &sa)) return SOCKET_ERROR;
    ssize_t n = sendto((int)A(0), A(2) ? G(A(1)) : NULL, A(2), (int)A(3), (struct sockaddr *)&sa, sizeof sa);
    return n < 0 ? fail(t) : (uint32_t)n;
}
static uint32_t recv_common(gp_thread *t, gaddr from, gaddr fromlen)
{
    struct sockaddr_in sa = {0};
    struct iovec iov = { A(2) ? G(A(1)) : NULL, A(2) };
    struct msghdr m = { .msg_name = &sa, .msg_namelen = sizeof sa, .msg_iov = &iov, .msg_iovlen = 1 };
    ssize_t n = recvmsg((int)A(0), &m, (int)A(3));
    if (n < 0) return fail(t);
    if (m.msg_flags & MSG_TRUNC) { set_error(t, 10040); return SOCKET_ERROR; }   /* Windows: WSAEMSGSIZE, data truncated */
    if (from && m.msg_namelen && !addr_out(t, &sa, from, fromlen)) return SOCKET_ERROR;
    return (uint32_t)n;
}
static uint32_t recv_(gp_thread *t) { return recv_common(t, 0, 0); }
static uint32_t recvfrom_(gp_thread *t) { return recv_common(t, A(4), A(5)); }

static uint32_t setsockopt_(gp_thread *t)
{
    int fd = (int)A(0), level = (int)A(1), opt = (int)A(2);
    gaddr val = A(3);
    uint32_t len = A(4);
    if (!val || len < 4) { set_error(t, 10014); return SOCKET_ERROR; }
    int v = (int)rd32(val);
    int r;
    if (level == 0xffff) {                                        /* SOL_SOCKET */
        int host;
        switch (opt) {
        case 0x0004: host = SO_REUSEADDR; break;
        case 0x0008: host = SO_KEEPALIVE; break;
        case 0x0020: host = SO_BROADCAST; break;
        case 0x1001: host = SO_SNDBUF; break;
        case 0x1002: host = SO_RCVBUF; break;
        case 0x0080: {                                            /* SO_LINGER: u16 onoff, u16 linger */
            struct linger l = { (int)(v & 0xffff), (int)((uint32_t)v >> 16) };
            r = setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, sizeof l);
            return r == 0 ? 0 : fail(t);
        }
        case (int)0xffffff7f: {                                   /* SO_DONTLINGER */
            struct linger l = { v ? 0 : 1, 0 };
            r = setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, sizeof l);
            return r == 0 ? 0 : fail(t);
        }
        default: gp_fatal("wsock32 setsockopt: SOL_SOCKET option 0x%x", opt);
        }
        r = setsockopt(fd, SOL_SOCKET, host, &v, sizeof v);
    } else if (level == IPPROTO_TCP && opt == 1) {
        r = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &v, sizeof v);
    } else if (level == IPPROTO_IP && (opt == 7 || opt == 3)) {   /* wsock32 IP_TTL / IP_MULTICAST_TTL */
        if (opt == 7) r = setsockopt(fd, IPPROTO_IP, IP_TTL, &v, sizeof v);
        else { u_char c = (u_char)v; r = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &c, sizeof c); }
    } else gp_fatal("wsock32 setsockopt: level 0x%x option 0x%x", level, opt);
    return r == 0 ? 0 : fail(t);
}

static uint32_t ioctlsocket_(gp_thread *t)
{
    int fd = (int)A(0);
    uint32_t cmd = A(1);
    gaddr arg = A(2);
    if (!arg) { set_error(t, 10014); return SOCKET_ERROR; }
    if (cmd == 0x8004667eu) {                                     /* FIONBIO */
        int fl = fcntl(fd, F_GETFL);
        if (fl < 0) return fail(t);
        fl = rd32(arg) ? fl | O_NONBLOCK : fl & ~O_NONBLOCK;
        return fcntl(fd, F_SETFL, fl) == 0 ? 0 : fail(t);
    }
    if (cmd == 0x4004667fu) {                                     /* FIONREAD */
        int n = 0;
        if (ioctl(fd, FIONREAD, &n) != 0) return fail(t);
        wr32(arg, (uint32_t)n);
        return 0;
    }
    gp_fatal("wsock32 ioctlsocket: command 0x%x", cmd);
}

/* fd_set (32-bit): u32 fd_count, SOCKET fd_array[64] */
static int set_count(gaddr s) { if (!s) return 0; uint32_t n = rd32(s); if (n > WSA_FD_MAX) gp_fatal("wsock32 select: fd_count %u", n); return (int)n; }

static uint32_t select_(gp_thread *t)
{
    gaddr sets[3] = { A(1), A(2), A(3) };
    gaddr tv = A(4);
    struct pollfd p[3 * WSA_FD_MAX];
    int n = 0;
    static const short ev[3] = { POLLIN, POLLOUT, POLLPRI };
    for (int k = 0; k < 3; k++) {
        int c = set_count(sets[k]);
        for (int i = 0; i < c; i++) p[n++] = (struct pollfd){ (int)rd32(sets[k] + 4 + 4 * (uint32_t)i), ev[k], 0 };
    }
    if (!n) { set_error(t, 10022); return SOCKET_ERROR; }         /* Windows: WSAEINVAL when all sets are empty */
    int ms = -1;
    if (tv) {
        int32_t sec = (int32_t)rd32(tv), usec = (int32_t)rd32(tv + 4);
        if (sec < 0 || usec < 0) { set_error(t, 10022); return SOCKET_ERROR; }
        int64_t total = (int64_t)sec * 1000 + (usec + 999) / 1000;
        ms = total > 0x7fffffff ? 0x7fffffff : (int)total;
    }
    int r;
    do r = poll(p, (nfds_t)n, ms); while (r < 0 && errno == EINTR);
    if (r < 0) return fail(t);
    for (int i = 0; i < n; i++) if (p[i].revents & POLLNVAL) { set_error(t, 10038); return SOCKET_ERROR; }
    /* rewrite each set with its ready sockets; errors/hangups count as readable and (for connects) exceptional */
    uint32_t total = 0;
    n = 0;
    for (int k = 0; k < 3; k++) {
        int c = set_count(sets[k]);
        uint32_t out = 0;
        for (int i = 0; i < c; i++, n++) {
            short re = p[n].revents;
            bool ready = k == 0 ? (re & (POLLIN | POLLHUP | POLLERR)) != 0
                       : k == 1 ? (re & POLLOUT) != 0
                       : (re & (POLLPRI | POLLERR)) != 0;
            if (ready) { wr32(sets[k] + 4 + 4 * out, (uint32_t)p[n].fd); out++; }
        }
        if (sets[k]) wr32(sets[k], out);
        total += out;
    }
    return total;
}
static uint32_t WSAFDIsSet_(gp_thread *t)
{
    uint32_t s = A(0); gaddr set = A(1);
    int c = set_count(set);
    for (int i = 0; i < c; i++) if (rd32(set + 4 + 4 * (uint32_t)i) == s) return 1;
    (void)t;
    return 0;
}

static uint32_t htons_(gp_thread *t) { return htons((uint16_t)A(0)); }
static uint32_t htonl_(gp_thread *t) { return htonl(A(0)); }
static uint32_t inet_addr_(gp_thread *t)
{
    const char *s = gstr(A(0));
    if (!s) return INADDR_NONE;
    struct in_addr a;
    if (!inet_aton(s, &a)) return INADDR_NONE;
    return a.s_addr;
}

/* per-thread result buffers, as Winsock documents for inet_ntoa and gethostbyname */
static __thread gaddr ntoa_buf, host_buf;
static uint32_t inet_ntoa_(gp_thread *t)
{
    (void)t;
    struct in_addr a = { A(0) };
    if (!ntoa_buf && !(ntoa_buf = gp_heap_alloc(16, true))) gp_fatal("inet_ntoa: out of guest memory");
    strlcpy((char *)G(ntoa_buf), inet_ntoa(a), 16);
    return ntoa_buf;
}
static uint32_t gethostname_(gp_thread *t)
{
    gaddr buf = A(0); int32_t len = (int32_t)A(1);
    char h[256];
    if (gethostname(h, sizeof h) != 0) return fail(t);
    h[sizeof h - 1] = 0;
    if (!buf || len <= 0 || strlen(h) >= (size_t)len) { set_error(t, 10014); return SOCKET_ERROR; }
    memcpy(G(buf), h, strlen(h) + 1);
    return 0;
}

#define HOST_ADDRS 16
static uint32_t gethostbyname_(gp_thread *t)
{
    const char *name = gstr(A(0));
    char local[256];
    if (!name || !*name) {                                        /* NULL/empty: the local host */
        if (gethostname(local, sizeof local) != 0) { set_error(t, wsa_error(errno)); return 0; }
        local[sizeof local - 1] = 0;
        name = local;
    }
    struct addrinfo hints = { .ai_family = AF_INET }, *res = NULL;
    int r = getaddrinfo(name, NULL, &hints, &res);
    if (r != 0) {
        set_error(t, r == EAI_NONAME ? 11001 : r == EAI_AGAIN ? 11002 : r == EAI_FAIL ? 11003 : 11004);
        return 0;
    }
    /* layout: hostent(16) | aliases[1] | addr_list[HOST_ADDRS+1] | addrs[HOST_ADDRS] | name[256] */
    enum { H = 0, AL = 16, LIST = 20, ADDRS = LIST + 4 * (HOST_ADDRS + 1), NAME = ADDRS + 4 * HOST_ADDRS, SIZE = NAME + 256 };
    if (!host_buf && !(host_buf = gp_heap_alloc(SIZE, true))) gp_fatal("gethostbyname: out of guest memory");
    memset(G(host_buf), 0, SIZE);
    uint32_t n = 0;
    for (struct addrinfo *a = res; a && n < HOST_ADDRS; a = a->ai_next) {
        uint32_t ip = ((struct sockaddr_in *)a->ai_addr)->sin_addr.s_addr;
        bool dup = false;
        for (uint32_t i = 0; i < n; i++) if (rd32(host_buf + ADDRS + 4 * i) == ip) dup = true;
        if (dup) continue;
        wr32(host_buf + ADDRS + 4 * n, ip);
        wr32(host_buf + LIST + 4 * n, host_buf + ADDRS + 4 * n);
        n++;
    }
    freeaddrinfo(res);
    strlcpy((char *)G(host_buf + NAME), name, 256);
    wr32(host_buf + H, host_buf + NAME);
    wr32(host_buf + H + 4, host_buf + AL);
    uint32_t type_len = AF_INET | (4u << 16);                     /* short h_addrtype, short h_length */
    wr32(host_buf + H + 8, type_len);
    wr32(host_buf + H + 12, host_buf + LIST);
    return host_buf;
}

const gp_api gp_api_wsock32[] = {
    API(WSAStartup_, "WSAStartup", 2), API(WSACleanup_, "WSACleanup", 0),
    API(WSAGetLastError_, "WSAGetLastError", 0), API(WSASetLastError_, "WSASetLastError", 1),
    API(socket_, "socket", 3), API(closesocket_, "closesocket", 1), API(shutdown_, "shutdown", 2),
    API(bind_, "bind", 3), API(connect_, "connect", 3), API(getsockname_, "getsockname", 3),
    API(send_, "send", 4), API(sendto_, "sendto", 6), API(recv_, "recv", 4), API(recvfrom_, "recvfrom", 6),
    API(setsockopt_, "setsockopt", 5), API(ioctlsocket_, "ioctlsocket", 3),
    API(select_, "select", 5), API(WSAFDIsSet_, "__WSAFDIsSet", 2),
    API(htons_, "htons", 1), API(htons_, "ntohs", 1), API(htonl_, "htonl", 1), API(htonl_, "ntohl", 1),
    API(inet_addr_, "inet_addr", 1), API(inet_ntoa_, "inet_ntoa", 1),
    API(gethostname_, "gethostname", 2), API(gethostbyname_, "gethostbyname", 1),
    { 0 }
};

#undef DLL
#define DLL "ws2_32.dll"
const gp_api gp_api_ws2_32[] = { API(htons_, "ntohs", 1), { 0 } };
