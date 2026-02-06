# Unix Domain Socket

**Unix Domain Socket (UDS)** — aynı host üzerindeki process'ler arası **çift yönlü**, **güvenilir** iletişim sağlayan IPC mekanizması. TCP/IP socket API'si ile **aynı interface**'i kullanır ama network stack'i tamamen **bypass** eder. Kernel içinde doğrudan buffer kopyalama yapılır → TCP loopback'e göre **~2x hızlı**.

> [!info] İlişkili Notlar
> Socket programlama temelleri (TCP/UDP, epoll, non-blocking I/O) → [[Linux Socket Programming]]
> IPC mekanizmaları karşılaştırması → [[Linux IPC Mekanizmaları]]
> Docker daemon socket güvenliği → [[Docker Security]]
> Container runtime ve docker.sock → [[Container Runtime]]
> Network namespace izolasyonu → [[Linux Namespaces#Network Namespace (netns)]]

---

## Neden Unix Domain Socket?

Unix Domain Socket, **aynı host** üzerindeki process'ler arası iletişim için en yaygın kullanılan mekanizmadır. TCP/IP socket API'sini biliyorsan UDS'yi de bilirsin — tek fark `AF_INET` yerine `AF_UNIX` kullanmak.

#### TCP Loopback vs Unix Domain Socket — Kernel Yolu

```
TCP Loopback (127.0.0.1):
  write() → Socket send buffer
         → TCP segmentation (header ekleme, seq number)
         → IP layer (routing, header)
         → Loopback device (lo)
         → IP layer (decapsulation)
         → TCP reassembly (ACK, ordering)
         → Socket receive buffer
         → read()

  Toplam: 2x TCP header + 2x IP header + routing + congestion control
          + checksum hesaplama + TCP state machine

Unix Domain Socket:
  write() → Socket send buffer
         → Kernel buffer copy (doğrudan)
         → Socket receive buffer
         → read()

  Toplam: Tek bir kernel buffer kopyası
          TCP/IP stack YOK, header YOK, routing YOK
```

#### Ne Zaman UDS Kullanılır?

| Senaryo | Neden UDS? |
|---------|-----------|
| Docker daemon iletişimi | CLI → dockerd (`/var/run/docker.sock`) |
| Veritabanı bağlantısı | MySQL, PostgreSQL local bağlantı |
| Web server ↔ uygulama | nginx → PHP-FPM, Gunicorn |
| Sistem servisleri | systemd, D-Bus, X11/Wayland |
| Container içi IPC | Sidecar container'lar arası |
| fd passing gereken durumlar | Sadece UDS bunu destekler |

---

## Adres Türleri

Unix domain socket'ler üç farklı adres türünü destekler:

| Tür | Adres | Filesystem'de Görünür | Kullanım |
|-----|-------|----------------------|----------|
| **Pathname** | `/var/run/docker.sock` | Evet (`srwxr-x---` dosyası) | En yaygın, dosya izinleri ile güvenlik |
| **Abstract** | `\0/my-socket` (null prefix) | Hayır | Linux'a özel, temizlik gerektirmez |
| **Unnamed** | — | Hayır | `socketpair()` ile, parent-child arası |

#### Pathname Socket

Filesystem'de **özel bir dosya** olarak görünür. Dosya izinleri (`chmod`) ile erişim kontrolü sağlanır.

```bash
# Docker daemon socket'i
ls -la /var/run/docker.sock
srw-rw---- 1 root docker 0 ... /var/run/docker.sock
#^                                ^
#socket dosyası (s prefix)         dosya izinleri ile güvenlik
```

```c
struct sockaddr_un addr = {
    .sun_family = AF_UNIX
};
strncpy(addr.sun_path, "/tmp/my.sock", sizeof(addr.sun_path) - 1);

// bind() ile socket dosyası oluşturulur
bind(fd, (struct sockaddr*)&addr, sizeof(addr));

// Dosya zaten varsa bind() EADDRINUSE verir
// Bu yüzden önce unlink() gerekir
unlink("/tmp/my.sock");
```

> [!warning] Pathname Socket Temizliği
> Socket dosyası `close()` ile **silinmez**. Process kapandığında dosya filesystem'de kalır.
> Yeniden `bind()` yapmak için önce `unlink()` gerekir.
> Signal handler'da veya `atexit()` ile temizlik yapılmalı.

#### Abstract Socket (Linux'a Özel)

`sun_path`'in ilk byte'ı `\0` (null) ile başlar. Filesystem'de dosya oluşmaz, kernel'de yaşar.

```c
struct sockaddr_un addr = {
    .sun_family = AF_UNIX
};
// İlk byte \0 → abstract namespace
addr.sun_path[0] = '\0';
memcpy(addr.sun_path + 1, "my-abstract-socket", 18);

// sizeof(sa_family_t) + 1 (null) + strlen("my-abstract-socket")
socklen_t len = offsetof(struct sockaddr_un, sun_path) + 1 + 18;
bind(fd, (struct sockaddr*)&addr, len);
```

Abstract socket avantajları:
- `unlink()` gerektirmez (process bitince otomatik temizlenir)
- Filesystem'e bağımlılık yok
- Dosya izinleri **uygulanmaz** → dikkat: herkes bağlanabilir

```bash
# Abstract socket'leri görmek
ss -xlnp | grep @
# u_str LISTEN 0 128 @/my-abstract-socket 12345 * 0
```

> [!warning] Abstract Socket ve Container
> Abstract socket'ler **network namespace'e** bağlıdır, mount namespace'e değil.
> Farklı network namespace'teki container'lar birbirinin abstract socket'lerini göremez.
> Ama `--net=host` veya aynı network namespace paylaşılıyorsa erişim mümkündür.

#### Unnamed Socket (socketpair)

`socketpair()` ile oluşturulur. Adres yoktur, sadece fd çifti döner. Parent-child process'ler arası çift yönlü iletişim için idealdir.

```c
int sv[2];
socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
// sv[0] ve sv[1]: birbirine bağlı iki socket fd

pid_t pid = fork();
if (pid == 0) {
    // Child: sv[0] kullan
    close(sv[1]);
    write(sv[0], "from child", 10);
    char buf[64];
    read(sv[0], buf, sizeof(buf));
    close(sv[0]);
} else {
    // Parent: sv[1] kullan
    close(sv[0]);
    char buf[64];
    read(sv[1], buf, sizeof(buf));
    write(sv[1], "from parent", 11);
    close(sv[1]);
    wait(NULL);
}
```

> [!tip] socketpair() vs pipe()
> - `pipe()`: tek yönlü, byte stream
> - `socketpair()`: **çift yönlü**, SOCK_STREAM veya SOCK_DGRAM
> - socketpair ile fd passing de yapılabilir (SCM_RIGHTS)

---

## Socket Türleri

Unix domain socket üç farklı iletişim modunu destekler:

| Tür | Bağlantı | Mesaj Sınırı | Güvenilirlik | Kullanım |
|-----|----------|-------------|-------------|----------|
| `SOCK_STREAM` | Connection-oriented | Yok (byte stream) | Sıralamalı, güvenilir | Docker daemon, MySQL, genel IPC |
| `SOCK_DGRAM` | Connectionless | Var (datagram) | Güvenilir (UDS'de!) | systemd notify, syslog |
| `SOCK_SEQPACKET` | Connection-oriented | Var (mesaj sınırlı) | Sıralamalı, güvenilir | Yapılandırılmış mesajlar |

> [!tip] UDS'de SOCK_DGRAM Güvenilir
> TCP/UDP'den farklı olarak, Unix domain socket'te `SOCK_DGRAM` de **güvenilirdir**.
> Network yok → paket kaybı yok. Alıcı buffer doluysa sender **block olur** (backpressure).

---

## SOCK_STREAM — Server/Client Tam Örnek

### Server

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#define SOCKET_PATH "/tmp/my.sock"
#define BUF_SIZE 256

int main() {
    int server_fd, client_fd;
    struct sockaddr_un addr;
    char buf[BUF_SIZE];

    // 1. Socket oluştur
    server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        exit(EXIT_FAILURE);
    }

    // 2. Eski socket dosyasını temizle
    unlink(SOCKET_PATH);

    // 3. Adres ayarla ve bind et
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server_fd);
        exit(EXIT_FAILURE);
    }

    // 4. Dinlemeye başla
    if (listen(server_fd, 5) < 0) {
        perror("listen");
        close(server_fd);
        exit(EXIT_FAILURE);
    }

    printf("UDS server dinliyor: %s\n", SOCKET_PATH);

    // 5. Bağlantı kabul et
    while (1) {
        client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            perror("accept");
            continue;
        }

        // 6. Veri oku ve yanıt gönder
        ssize_t n = read(client_fd, buf, BUF_SIZE - 1);
        if (n > 0) {
            buf[n] = '\0';
            printf("Alındı: %s\n", buf);
            write(client_fd, "OK", 2);
        }

        close(client_fd);
    }

    close(server_fd);
    unlink(SOCKET_PATH);
    return 0;
}
```

### Client

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#define SOCKET_PATH "/tmp/my.sock"

int main() {
    int fd;
    struct sockaddr_un addr;
    char buf[256];

    // 1. Socket oluştur
    fd = socket(AF_UNIX, SOCK_STREAM, 0);

    // 2. Server'a bağlan
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(fd);
        exit(EXIT_FAILURE);
    }

    // 3. Veri gönder
    write(fd, "Merhaba UDS!", 12);

    // 4. Yanıt al
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    if (n > 0) {
        buf[n] = '\0';
        printf("Server: %s\n", buf);
    }

    close(fd);
    return 0;
}
```

```bash
# Derleme ve çalıştırma
gcc -o uds_server server.c && ./uds_server
gcc -o uds_client client.c && ./uds_client

# socat ile test
socat - UNIX-CONNECT:/tmp/my.sock
```

---

## SOCK_DGRAM — Datagram Örnek

Bağlantı kurulmaz. Her mesaj bağımsızdır ve **mesaj sınırları korunur**.

```c
// ---- Server (receiver) ----
int fd = socket(AF_UNIX, SOCK_DGRAM, 0);

unlink("/tmp/dgram_server.sock");
struct sockaddr_un addr = {.sun_family = AF_UNIX};
strncpy(addr.sun_path, "/tmp/dgram_server.sock", sizeof(addr.sun_path) - 1);
bind(fd, (struct sockaddr*)&addr, sizeof(addr));

char buf[256];
struct sockaddr_un client_addr;
socklen_t client_len = sizeof(client_addr);

// Mesaj al (gönderici adresi ile birlikte)
ssize_t n = recvfrom(fd, buf, sizeof(buf), 0,
                     (struct sockaddr*)&client_addr, &client_len);
buf[n] = '\0';
printf("Alındı: %s\n", buf);

// Yanıt gönder (gönderici adresine)
sendto(fd, "OK", 2, 0, (struct sockaddr*)&client_addr, client_len);
```

```c
// ---- Client (sender) ----
int fd = socket(AF_UNIX, SOCK_DGRAM, 0);

// Client da bind etmeli (server'ın yanıt göndermesi için)
unlink("/tmp/dgram_client.sock");
struct sockaddr_un client_addr = {.sun_family = AF_UNIX};
strncpy(client_addr.sun_path, "/tmp/dgram_client.sock",
        sizeof(client_addr.sun_path) - 1);
bind(fd, (struct sockaddr*)&client_addr, sizeof(client_addr));

// Server adresine gönder
struct sockaddr_un server_addr = {.sun_family = AF_UNIX};
strncpy(server_addr.sun_path, "/tmp/dgram_server.sock",
        sizeof(server_addr.sun_path) - 1);

sendto(fd, "hello", 5, 0,
       (struct sockaddr*)&server_addr, sizeof(server_addr));
```

> [!tip] SOCK_DGRAM Kullanımı
> systemd'nin `sd_notify()` mekanizması `SOCK_DGRAM` kullanır.
> `NOTIFY_SOCKET` environment variable'ı ile servisin hazır olduğu bildirilir:
> ```bash
> # systemd unit'te
> Type=notify
> # Uygulama sd_notify(0, "READY=1") gönderir → SOCK_DGRAM UDS üzerinden
> ```

---

## File Descriptor Passing (SCM_RIGHTS)

Unix domain socket'ın **en güçlü ve benzersiz** özelliği: process'ler arası **open file descriptor gönderebilme**. Dosya, socket, pipe, device — herhangi bir fd gönderilebilir.

```
Process A                          Process B
  fd=5 (open file)                   fd=?
    │                                  ▲
    │  sendmsg() + SCM_RIGHTS          │  recvmsg() + SCM_RIGHTS
    │  [fd=5'in kernel referansı]      │  [kernel yeni fd atar]
    └──────── UDS ─────────────────────┘
                                     fd=8 (aynı dosya, yeni fd numarası)
```

Kernel ne yapar:
1. Gönderici process'in fd tablosundaki **dosya referansını** (struct file) alır
2. Bu referansı alıcı process'in fd tablosuna **yeni bir fd numarası ile** ekler
3. Dosyanın **referans sayacı** (refcount) artırılır
4. İki process artık **aynı kernel dosya objesine** erişir

#### fd Gönderme (Sender)

```c
#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>

void send_fd(int unix_sock, int fd_to_send) {
    struct msghdr msg = {0};
    struct iovec iov;
    char buf[1] = {'F'};  // En az 1 byte payload gerekli

    // Payload (zorunlu, boş olamaz)
    iov.iov_base = buf;
    iov.iov_len = sizeof(buf);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;

    // Ancillary data (fd taşıyan kontrol mesajı)
    char cmsgbuf[CMSG_SPACE(sizeof(int))];
    msg.msg_control = cmsgbuf;
    msg.msg_controllen = sizeof(cmsgbuf);

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;         // fd passing
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    *(int *)CMSG_DATA(cmsg) = fd_to_send; // gönderilecek fd

    msg.msg_controllen = cmsg->cmsg_len;

    sendmsg(unix_sock, &msg, 0);
}
```

#### fd Alma (Receiver)

```c
int recv_fd(int unix_sock) {
    struct msghdr msg = {0};
    struct iovec iov;
    char buf[1];

    iov.iov_base = buf;
    iov.iov_len = sizeof(buf);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;

    char cmsgbuf[CMSG_SPACE(sizeof(int))];
    msg.msg_control = cmsgbuf;
    msg.msg_controllen = sizeof(cmsgbuf);

    recvmsg(unix_sock, &msg, 0);

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    if (cmsg && cmsg->cmsg_level == SOL_SOCKET
             && cmsg->cmsg_type == SCM_RIGHTS) {
        return *(int *)CMSG_DATA(cmsg);  // alınan fd
    }

    return -1;  // fd alınamadı
}
```

#### fd Passing Kullanım Alanları

| Kullanım | Açıklama |
|----------|----------|
| **nginx worker** | Master process listen socket'i → worker process'lere fd olarak geçer |
| **systemd socket activation** | systemd listen socket'i açar → servise fd olarak verir |
| **Privilege separation** | Privileged process dosyayı açar → unprivileged process'e fd gönderir |
| **Container runtime** | containerd-shim, container process'e fd'leri geçer |
| **Zero-downtime restart** | Eski process listen fd'yi yeni process'e aktarır → bağlantı kesilmez |

> [!tip] systemd Socket Activation
> systemd, service başlamadan **önce** socket'i açar ve service'e fd olarak geçer.
> Bu sayede service restart sırasında bile bağlantılar kaybolmaz.
> ```ini
> # myapp.socket
> [Socket]
> ListenStream=/run/myapp.sock
>
> # myapp.service
> [Service]
> ExecStart=/usr/bin/myapp
> # fd=3 olarak listen socket'i alır (SD_LISTEN_FDS_START)
> ```

---

## Credential Passing (Peer Kimlik Doğrulama)

Unix domain socket üzerinden bağlanan process'in **UID, GID ve PID** bilgisi kernel tarafından doğrulanabilir. İki yöntem vardır:

#### SO_PEERCRED (Basit)

Bağlı socket'in karşı tarafının kimliğini sorgular. Kernel tarafından **doğrulanmıştır**, sahte gönderilemez.

```c
struct ucred cred;
socklen_t len = sizeof(cred);
getsockopt(client_fd, SOL_SOCKET, SO_PEERCRED, &cred, &len);

printf("PID: %d\n", cred.pid);
printf("UID: %d\n", cred.uid);
printf("GID: %d\n", cred.gid);

// Erişim kontrolü
if (cred.uid != 0 && cred.gid != getgrnam("docker")->gr_gid) {
    fprintf(stderr, "Yetkisiz erişim: uid=%d\n", cred.uid);
    close(client_fd);
}
```

#### SCM_CREDENTIALS (Ancillary Data)

`sendmsg()` / `recvmsg()` ile credential bilgisi gönderilir/alınır.

```c
// Alıcı tarafta SO_PASSCRED etkinleştir
int opt = 1;
setsockopt(server_fd, SOL_SOCKET, SO_PASSCRED, &opt, sizeof(opt));

// recvmsg() ile credential al
struct msghdr msg = {0};
char cmsgbuf[CMSG_SPACE(sizeof(struct ucred))];
msg.msg_control = cmsgbuf;
msg.msg_controllen = sizeof(cmsgbuf);

// ... iov ayarları ...

recvmsg(client_fd, &msg, 0);

struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
if (cmsg && cmsg->cmsg_type == SCM_CREDENTIALS) {
    struct ucred *cred = (struct ucred *)CMSG_DATA(cmsg);
    printf("PID=%d UID=%d GID=%d\n", cred->pid, cred->uid, cred->gid);
}
```

> [!tip] Docker ve SO_PEERCRED
> Docker daemon, `/var/run/docker.sock` üzerinden bağlanan client'ın UID/GID'ini kontrol eder.
> `docker` grubundaki kullanıcılar socket'e erişebilir:
> ```bash
> srw-rw---- 1 root docker 0 ... /var/run/docker.sock
> #                  ^^^^^^
> #                  docker grubundaki kullanıcılar bağlanabilir
> ```

---

## Docker ve Unix Domain Socket

Docker daemon varsayılan olarak **Unix domain socket** üzerinden iletişim kurar. Bu, Docker ekosisteminin temel iletişim mekanizmasıdır.

```
docker CLI                          dockerd
    │                                  │
    │  HTTP over Unix Socket           │
    │  POST /v1.44/containers/create   │
    │──── /var/run/docker.sock ───────→│
    │                                  │
    │  HTTP Response (JSON)            │
    │←─────────────────────────────────│
```

#### docker.sock Neden TCP Değil?

| Özellik | Unix Socket (`/var/run/docker.sock`) | TCP (`tcp://0.0.0.0:2375`) |
|---------|--------------------------------------|---------------------------|
| Güvenlik | Dosya izinleri (root/docker grubu) | IP bazlı, TLS gerekir |
| Performans | Network stack bypass | TCP overhead |
| Erişim alanı | Sadece local host | Remote erişim mümkün |
| Kimlik doğrulama | SO_PEERCRED (kernel) | TLS sertifika |
| Varsayılan | **Evet** | Hayır (açıkça etkinleştirilmeli) |

#### API Erişimi

```bash
# curl ile Docker API'sine doğrudan erişim
curl --unix-socket /var/run/docker.sock http://localhost/v1.44/containers/json | jq

# Image listesi
curl --unix-socket /var/run/docker.sock http://localhost/v1.44/images/json

# Yeni container oluştur
curl --unix-socket /var/run/docker.sock \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"Image":"nginx","HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":"8080"}]}}}' \
  http://localhost/v1.44/containers/create
```

#### docker.sock'u Container'a Mount Etmek

```bash
# Docker socket'ini container'a mount etmek
docker run -v /var/run/docker.sock:/var/run/docker.sock docker:cli
```

```
Host
├── dockerd (daemon)
│   └── /var/run/docker.sock
│
└── Container (docker.sock mount edilmiş)
    └── docker CLI → /var/run/docker.sock → dockerd
        │
        └── Host üzerinde container oluşturabilir!
            Volume mount edebilir!
            Host filesystem'e erişebilir!
```

> [!warning] docker.sock Mount = Root Erişimi
> Container'a `/var/run/docker.sock` mount etmek, container'a **host üzerinde root yetkisi** vermek demektir.
> Container içinden:
> ```bash
> # Host filesystem'e erişim
> docker run -v /:/host alpine cat /host/etc/shadow
>
> # Host'ta privileged container çalıştırma
> docker run --privileged -v /:/host alpine chroot /host
> ```
> **Production'da asla mount etme.** CI/CD gibi zorunlu durumlarda Docker-in-Docker (DinD) veya Kaniko kullan.

---

## Kernel İç Yapısı

#### sock Yapısı

Kernel'de Unix domain socket `struct unix_sock` ile temsil edilir:

```
struct unix_sock {
    struct sock          sk;          // Genel socket yapısı
    struct unix_address  *addr;       // Socket adresi (path veya abstract)
    struct path          path;        // Filesystem path (pathname socket)
    struct mutex         iolock;      // I/O mutex
    struct sock          *peer;       // Bağlı olan karşı socket
    struct sock          *other;      // DGRAM için hedef
    struct list_head     link;        // Global unix socket listesi
    unsigned long        inflight;    // In-flight fd sayısı (SCM_RIGHTS)
    spinlock_t           lock;
    struct sk_buff_head  recvq;       // Receive queue
    // ...
};
```

#### Veri Akışı (Kernel İçi)

```
Sender write()                          Receiver read()
      │                                       ▲
      ▼                                       │
┌─────────────┐                        ┌─────────────┐
│ sender sock │                        │ receiver    │
│ send buffer │                        │ recv buffer │
└──────┬──────┘                        └──────┬──────┘
       │                                      ▲
       │  unix_stream_sendmsg()               │
       │  → skb_queue_tail()                  │
       │     sk_buff oluştur                  │
       │     veriyi kopyala                   │
       └──────→ receiver->recvq ──────────────┘
               (doğrudan karşı socket'in
                receive queue'suna eklenir)

TCP'den fark: routing, segmentation, congestion control,
              checksum, header ekleme → HİÇBİRİ YOK
```

---

## Performans Karşılaştırması

| Metrik | TCP Loopback | Unix Domain Socket | Shared Memory |
|--------|-------------|-------------------|---------------|
| **Throughput** | ~5 GB/s | ~10 GB/s | ~50 GB/s |
| **Latency** | ~10-15 μs | ~3-5 μs | ~0.1 μs |
| **Kernel kopyası** | 2+ (send/recv buffer + TCP processing) | 1 (doğrudan buffer copy) | 0 (zero-copy) |
| **TCP/IP stack** | Tam stack (TCP + IP + routing) | **Bypass** | N/A |
| **API karmaşıklığı** | Socket API | Socket API (aynı) | mmap + senkronizasyon |
| **fd passing** | Yok | **Var** (SCM_RIGHTS) | Yok |
| **Credential** | Yok (IP bazlı) | **Var** (SO_PEERCRED) | Yok |

```bash
# Basit benchmark: socat ile throughput testi

# TCP loopback
socat -u /dev/zero TCP-LISTEN:12345 &
socat -u TCP:127.0.0.1:12345 /dev/null

# Unix domain socket
socat -u /dev/zero UNIX-LISTEN:/tmp/bench.sock &
socat -u UNIX-CONNECT:/tmp/bench.sock /dev/null
```

> [!tip] Performans Tercihi
> - **En hızlı IPC**: Shared memory (ama senkronizasyon karmaşık)
> - **Hızlı + kolay API**: Unix domain socket
> - **Remote erişim gerekli**: TCP/IP socket
> - **fd passing gerekli**: Unix domain socket (tek seçenek)

---

## Gerçek Dünya Kullanımları

```
┌─────────────────────────────────────────────────────────────┐
│               Unix Domain Socket Kullananlar                │
├──────────────┬──────────────────────────────────────────────┤
│ Docker       │ /var/run/docker.sock (CLI ↔ daemon)          │
│ containerd   │ /run/containerd/containerd.sock              │
│ MySQL        │ /var/run/mysqld/mysqld.sock                  │
│ PostgreSQL   │ /var/run/postgresql/.s.PGSQL.5432            │
│ Redis        │ /var/run/redis/redis-server.sock             │
│ nginx        │ /var/run/php-fpm.sock (→ PHP-FPM)            │
│ systemd      │ /run/systemd/notify (sd_notify)              │
│ D-Bus        │ /var/run/dbus/system_bus_socket              │
│ X11          │ /tmp/.X11-unix/X0                            │
│ Wayland      │ $XDG_RUNTIME_DIR/wayland-0                   │
│ SSH Agent    │ $SSH_AUTH_SOCK                               │
│ gpg-agent    │ $GPG_AGENT_INFO socket                       │
│ snapd        │ /run/snapd.socket                            │
└──────────────┴──────────────────────────────────────────────┘
```

#### MySQL/PostgreSQL Local Bağlantı

```bash
# MySQL: TCP yerine UDS ile bağlantı (daha hızlı)
mysql -u root -p --socket=/var/run/mysqld/mysqld.sock

# PostgreSQL: local bağlantı otomatik UDS kullanır
psql -h /var/run/postgresql -U postgres

# my.cnf'de socket yolu
[mysqld]
socket=/var/run/mysqld/mysqld.sock
```

#### nginx → PHP-FPM

```nginx
# nginx.conf — TCP yerine UDS
upstream php {
    # TCP: server 127.0.0.1:9000;
    server unix:/var/run/php-fpm.sock;  # UDS: daha hızlı
}

location ~ \.php$ {
    fastcgi_pass php;
    # ...
}
```

```ini
# php-fpm.conf
listen = /var/run/php-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
```

---

## Debug ve İzleme

```bash
# Unix domain socket'leri listele
ss -xlnp
# Netid State  Recv-Q Send-Q  Local Address:Port   Peer Address:Port Process
# u_str LISTEN 0      4096    /var/run/docker.sock  12345 *  0        users:(("dockerd",pid=1234))
# u_str LISTEN 0      128     /tmp/my.sock          12346 *  0        users:(("myapp",pid=5678))

# Detaylı bilgi
ss -xlnpe

# Belirli socket
ss -xlnp | grep docker

# Socket kullanan process'leri bul
lsof -U
# COMMAND   PID   USER   FD   TYPE             DEVICE SIZE/OFF   NODE NAME
# dockerd  1234   root    4u  unix 0x...  0t0  12345 /var/run/docker.sock type=STREAM

# Belirli socket dosyasını kullanan process
lsof /var/run/docker.sock

# /proc üzerinden
cat /proc/net/unix
# Num  RefCount Protocol Flags  Type St Inode Path
# ...  00000002 00000000 00010000 0001 01 12345 /var/run/docker.sock

# strace ile UDS iletişimini izle
strace -e trace=network -p $(pidof dockerd) 2>&1 | head

# Socket dosya tipini kontrol et
file /var/run/docker.sock
# /var/run/docker.sock: socket
stat /var/run/docker.sock
```

#### Debug Senaryoları

```bash
# Senaryo 1: "Connection refused" — socket dosyası var ama dinleyen yok
ss -xlnp | grep /tmp/my.sock
# Çıktı boş → process çökmüş veya socket dosyası eski kalmış
# Çözüm: process'i yeniden başlat

# Senaryo 2: "Permission denied" — dosya izinleri
ls -la /var/run/docker.sock
# Kullanıcı docker grubunda mı?
groups $USER | grep docker

# Senaryo 3: "Address already in use" — eski socket dosyası
# Process kapanmış ama socket dosyası kalmış
rm /tmp/my.sock   # veya unlink() çağır
# Not: abstract socket'lerde bu sorun olmaz

# Senaryo 4: Recv-Q birikiyor — alıcı yeterince hızlı okumuyor
ss -xlnp | grep my.sock
# Recv-Q yüksek → alıcı process yavaş veya block olmuş
```

---

## Güvenlik

#### Dosya İzinleri (Pathname Socket)

```bash
# Socket dosyası oluşturulduktan sonra izin ayarla
chmod 0660 /var/run/my.sock
chown root:mygroup /var/run/my.sock

# Sadece mygroup grubundaki kullanıcılar bağlanabilir
```

```c
// Programatik olarak
// bind() sonrası chmod/chown
bind(fd, (struct sockaddr*)&addr, sizeof(addr));
chmod(SOCKET_PATH, 0660);
```

#### Abstract Socket Güvenliği

Abstract socket'lerde dosya izinleri **uygulanmaz**. Aynı network namespace'teki **herhangi bir process** bağlanabilir.

Korunma yöntemleri:
- `SO_PEERCRED` ile bağlanan process'in UID/GID'ini kontrol et
- Network namespace izolasyonu (container)
- Uygulama seviyesinde kimlik doğrulama

#### chroot/Container İçinde

```
Pathname socket:
  Container mount namespace'e bağlı
  Host'taki /var/run/docker.sock görünmez (mount edilmedikçe)

Abstract socket:
  Container network namespace'e bağlı
  --net=host kullanılmadıkça izole
```

---

## Özet

```
Unix Domain Socket Temel Bilgiler:

  Oluşturma:
    socket(AF_UNIX, SOCK_STREAM, 0)     // connection-oriented
    socket(AF_UNIX, SOCK_DGRAM, 0)      // datagram (UDS'de güvenilir!)
    socket(AF_UNIX, SOCK_SEQPACKET, 0)  // sıralı mesajlar
    socketpair(AF_UNIX, SOCK_STREAM, 0, sv)  // unnamed pair

  Adres türleri:
    Pathname:  /var/run/docker.sock     (dosya izinleri ile güvenlik)
    Abstract:  \0my-socket              (Linux'a özel, otomatik temizlik)
    Unnamed:   socketpair()             (parent-child arası)

  Özel yetenekler (sadece UDS):
    SCM_RIGHTS     → fd passing (dosya, socket, pipe gönderme)
    SO_PEERCRED    → peer UID/GID/PID doğrulama (kernel garantili)

  Performans:
    TCP loopback ~10-15 μs  →  UDS ~3-5 μs  (2-3x hızlı)
    Network stack tamamen bypass edilir

  Gerçek dünya:
    Docker     → /var/run/docker.sock
    MySQL      → /var/run/mysqld/mysqld.sock
    PostgreSQL → /var/run/postgresql/.s.PGSQL.5432
    nginx      → /var/run/php-fpm.sock
    systemd    → socket activation (fd passing)

  Debug:
    ss -xlnp           → Unix socket listesi
    lsof -U            → Socket kullanan process'ler
    cat /proc/net/unix → Kernel socket tablosu
```
