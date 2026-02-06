# Linux Socket Programming

**Socket** — iki process arasında network (veya aynı host) üzerinden veri iletişimi için kullanılan temel endpoint mekanizması. Linux'ta her şey bir **file descriptor** olduğu için, socket'ler de fd tabanlı API üzerinden yönetilir.

> [!info] İlişkili Notlar
> Unix Domain Socket detaylı → [[Unix Domain Socket]]
> Unix Domain Socket (IPC bağlamında) → [[Linux IPC Mekanizmaları#Unix Domain Socket]]
> Container networking → [[Docker Networking]]
> Firewall kuralları → [[iptables ve nftables]]

---

## Socket Nedir?

Socket, iki uçlu bir iletişim kanalının **bir endpoint**'idir. Kernel tarafında `struct socket` ile temsil edilir ve user-space'e **file descriptor** olarak sunulur.

```
Process A                              Process B
   |                                       |
   |  fd=3 (socket)                        |  fd=4 (socket)
   |       |                               |
   +-------+--- [ Kernel TCP/IP Stack ] ---+-------+
                          |
                     [ Network ]
```

#### Socket = File Descriptor

Socket oluşturulunca kernel bir **fd** döner. Bu fd üzerinden standart I/O işlemleri yapılabilir:

```c
int sockfd = socket(AF_INET, SOCK_STREAM, 0);
// sockfd artik bir file descriptor
// read(), write(), close() gibi standart fd işlemleri geçerli

// /proc/<pid>/fd/ altında görünür:
// lrwx------ 1 user user 64 ... 3 -> socket:[12345]
```

#### Address Family'ler

| Family | Açıklama | Kullanım |
|--------|----------|----------|
| `AF_INET` | IPv4 | Internet üzerinden TCP/UDP iletişimi |
| `AF_INET6` | IPv6 | IPv6 tabanlı iletişim |
| `AF_UNIX` (= `AF_LOCAL`) | Unix domain | Aynı host üzerinde process'ler arası (network stack bypass) |
| `AF_PACKET` | Raw packet | L2 seviyesinde ham paket yakalama (tcpdump, Wireshark) |
| `AF_NETLINK` | Kernel iletişimi | User-space ile kernel arası iletişim (routing, firewall) |

#### Socket Türleri

| Tür | Protokol | Özellik |
|-----|----------|---------|
| `SOCK_STREAM` | TCP | Connection-oriented, güvenilir, sıralamalı |
| `SOCK_DGRAM` | UDP | Connectionless, güvenilir değil, mesaj sınırlı |
| `SOCK_RAW` | IP | Ham paket erişimi (root gerekir) |
| `SOCK_SEQPACKET` | SCTP / Unix | Sıralamalı, güvenilir, mesaj sınırlı |

> [!tip] socket() Çağrısının Anatomisi
> `socket(domain, type, protocol)` üç parametre alır:
> - **domain**: Hangi adres ailesi (AF_INET, AF_UNIX, ...)
> - **type**: İletişim modeli (SOCK_STREAM, SOCK_DGRAM, ...)
> - **protocol**: Genellikle 0 (kernel otomatik seçer: TCP veya UDP)

---

## TCP Socket Lifecycle

TCP, connection-oriented bir protokoldur. Bağlantı kurulmadan veri gönderilemez. Server ve client tarafında farklı syscall dizileri kullanılır.

```
         SERVER                              CLIENT
      +----------+                        +----------+
      | socket() |                        | socket() |
      +----+-----+                        +----+-----+
           |                                   |
      +----+-----+                             |
      |  bind()  |                             |
      +----+-----+                             |
           |                                   |
      +----+-----+                             |
      | listen() |                             |
      +----+-----+                             |
           |                                   |
           |        SYN                   +----+------+
           |<-----------------------------| connect() |
           |        SYN+ACK               +----+------+
           |---------------------------------->|
           |        ACK                        |
           |<----------------------------------|
      +----+-----+                             |
      | accept() |   <-- 3-way handshake -->   |
      +----+-----+                             |
           |                                   |
      +----+------+                       +----+------+
      | read()    |<---------- data ------| write()   |
      | write()   |---------- data ------>| read()    |
      +----+------+                       +----+------+
           |                                   |
      +----+-----+                        +----+-----+
      | close()  |-------- FIN ---------->| close()  |
      +----------+<------- FIN -----------+----------+
```

#### Syscall Sırası

| Adım | Server | Client |
|------|--------|--------|
| 1 | `socket()` — fd oluştur | `socket()` — fd oluştur |
| 2 | `bind()` — adres ve port ata | — |
| 3 | `listen()` — bağlantı kuyruğu oluştur | — |
| 4 | `accept()` — bağlantı kabul et (block) | `connect()` — sunucuya bağlan |
| 5 | `read()` / `write()` — veri al/gönder | `write()` / `read()` — veri gönder/al |
| 6 | `close()` — bağlantı kapat | `close()` — bağlantı kapat |

---

## TCP Server/Client -- Tam C Örneği

### TCP Server

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#define PORT 8080
#define BUFFER_SIZE 1024

int main() {
    int server_fd, client_fd;
    struct sockaddr_in server_addr, client_addr;
    socklen_t client_len = sizeof(client_addr);
    char buffer[BUFFER_SIZE];

    // 1. Socket olustur
    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        exit(EXIT_FAILURE);
    }

    // SO_REUSEADDR: TIME_WAIT'teki port'u tekrar kullan
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    // 2. Adres ve port ata
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;  // Tum interface'lerden dinle
    server_addr.sin_port = htons(PORT);         // Network byte order

    if (bind(server_fd, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        perror("bind");
        close(server_fd);
        exit(EXIT_FAILURE);
    }

    // 3. Dinlemeye basla (backlog = 128)
    if (listen(server_fd, 128) < 0) {
        perror("listen");
        close(server_fd);
        exit(EXIT_FAILURE);
    }

    printf("Server %d portunda dinliyor...\n", PORT);

    // 4. Baglanti kabul et (blocking)
    while (1) {
        client_fd = accept(server_fd, (struct sockaddr*)&client_addr, &client_len);
        if (client_fd < 0) {
            perror("accept");
            continue;
        }

        char client_ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &client_addr.sin_addr, client_ip, sizeof(client_ip));
        printf("Baglanti: %s:%d\n", client_ip, ntohs(client_addr.sin_port));

        // 5. Veri oku ve yanit gönder
        ssize_t n = read(client_fd, buffer, BUFFER_SIZE - 1);
        if (n > 0) {
            buffer[n] = '\0';
            printf("Alindi: %s\n", buffer);

            const char *response = "Mesaj alindi!\n";
            write(client_fd, response, strlen(response));
        }

        // 6. Baglanti kapat
        close(client_fd);
    }

    close(server_fd);
    return 0;
}
```

### TCP Client

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#define PORT 8080
#define BUFFER_SIZE 1024

int main() {
    int sockfd;
    struct sockaddr_in server_addr;
    char buffer[BUFFER_SIZE];

    // 1. Socket olustur
    sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        perror("socket");
        exit(EXIT_FAILURE);
    }

    // 2. Server adresini ayarla
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(PORT);
    inet_pton(AF_INET, "127.0.0.1", &server_addr.sin_addr);

    // 3. Baglan
    if (connect(sockfd, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        perror("connect");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    printf("Sunucuya baglandi.\n");

    // 4. Veri gönder
    const char *msg = "Merhaba sunucu!";
    write(sockfd, msg, strlen(msg));

    // 5. Yanit oku
    ssize_t n = read(sockfd, buffer, BUFFER_SIZE - 1);
    if (n > 0) {
        buffer[n] = '\0';
        printf("Sunucudan: %s\n", buffer);
    }

    // 6. Kapat
    close(sockfd);
    return 0;
}
```

#### Derleme ve Çalıştırma

```bash
# Server
gcc -o server server.c && ./server

# Client (başka terminalde)
gcc -o client client.c && ./client

# veya netcat ile test
echo "test mesajı" | nc localhost 8080
```

> [!warning] Byte Order
> Network protokolleri **big-endian** (network byte order) kullanır.
> x86 işlemciler **little-endian** kullanır.
> Bu yüzden `htons()`, `htonl()`, `ntohs()`, `ntohl()` dönüşüm fonksiyonları zorunludur.
> - `htons()` — host to network short (port için)
> - `htonl()` — host to network long (IP için)

---

## UDP Socket Lifecycle

UDP, connectionless bir protokoldur. Bağlantı kurulmadan doğrudan datagram gönderilir/alınır. `connect()` / `accept()` yoktur.

```
         SERVER                              CLIENT
      +----------+                        +----------+
      | socket() |                        | socket() |
      +----+-----+                        +----+-----+
           |                                   |
      +----+-----+                             |
      |  bind()  |                             |
      +----+-----+                             |
           |                                   |
      +----+--------+                    +-----+-------+
      | recvfrom()  |<----- datagram ----| sendto()    |
      |             |                    |             |
      | sendto()    |------ datagram --->| recvfrom()  |
      +----+--------+                    +-----+-------+
           |                                   |
      +----+-----+                        +----+-----+
      | close()  |                        | close()  |
      +----------+                        +----------+
```

#### UDP Server/Client Örneği

```c
// ---- UDP Server ----
int sockfd = socket(AF_INET, SOCK_DGRAM, 0);

struct sockaddr_in server_addr = {
    .sin_family = AF_INET,
    .sin_addr.s_addr = INADDR_ANY,
    .sin_port = htons(9090)
};
bind(sockfd, (struct sockaddr*)&server_addr, sizeof(server_addr));

struct sockaddr_in client_addr;
socklen_t client_len = sizeof(client_addr);
char buf[1024];

// Bloklayici: datagram gelene kadar bekler
ssize_t n = recvfrom(sockfd, buf, sizeof(buf), 0,
                     (struct sockaddr*)&client_addr, &client_len);
buf[n] = '\0';
printf("Alindi: %s\n", buf);

// Aynı client'a yanit gönder
sendto(sockfd, "OK", 2, 0,
       (struct sockaddr*)&client_addr, client_len);

close(sockfd);
```

```c
// ---- UDP Client ----
int sockfd = socket(AF_INET, SOCK_DGRAM, 0);

struct sockaddr_in server_addr = {
    .sin_family = AF_INET,
    .sin_port = htons(9090)
};
inet_pton(AF_INET, "127.0.0.1", &server_addr.sin_addr);

sendto(sockfd, "Merhaba", 7, 0,
       (struct sockaddr*)&server_addr, sizeof(server_addr));

char buf[1024];
struct sockaddr_in from_addr;
socklen_t from_len = sizeof(from_addr);
ssize_t n = recvfrom(sockfd, buf, sizeof(buf), 0,
                     (struct sockaddr*)&from_addr, &from_len);
buf[n] = '\0';
printf("Yanit: %s\n", buf);

close(sockfd);
```

#### TCP vs UDP

| Özellik | TCP (`SOCK_STREAM`) | UDP (`SOCK_DGRAM`) |
|---------|--------------------|--------------------|
| Bağlantı | Connection-oriented | Connectionless |
| Güvenilirlik | Garanti (retransmission, ordering) | Garanti yok |
| Veri sınırı | Byte stream (sınır yok) | Datagram (mesaj sınırlı) |
| Hız | Daha yavaş (handshake, ACK) | Daha hızlı (overhead yok) |
| Kullanım | HTTP, SSH, veritabanı | DNS, video stream, oyun |
| Syscall | read/write veya send/recv | recvfrom/sendto |

---

## I/O Multiplexing Evrimi

Tek bir thread'de birden fazla socket'i aynı anda izlemek için **I/O multiplexing** kullanılır. Linux'ta üç temel mekanizma vardır: `select()`, `poll()`, `epoll()`.

```
Sorun: Bir server 10.000 client'a hizmet veriyor.
       Her client için bir thread oluşturmak = 10.000 thread = kaynak israfı

Çözüm: Tek thread, birden fazla fd'yi izle, hazır olana hizmet ver

Evrim: select (1983) --> poll (1986) --> epoll (2002, Linux 2.5.44)
```

#### Karşılaştırma Tablosu

| Özellik | `select()` | `poll()` | `epoll()` |
|---------|-----------|---------|----------|
| Max fd sayısı | **1024** (FD_SETSIZE) | Sınır yok | Sınır yok |
| fd kopyalama | Her çağrı kernel'e kopyalar | Her çağrı kernel'e kopyalar | Sadece `epoll_ctl` ile bir kez |
| Hazır fd bulma | O(n) — tüm set taranır | O(n) — tüm array taranır | **O(1)** — sadece hazır olanlar döner |
| Performans (10K fd) | Çok yavaş | Yavaş | **Hızlı** |
| Taşınabilirlik | POSIX (her yerde) | POSIX (her yerde) | **Sadece Linux** |
| Trigger modu | Level-triggered | Level-triggered | Level + **Edge-triggered** |
| Memory | Stack (fd_set) | Heap (pollfd array) | Kernel (rbtree + rdlist) |
| Tipik kullanım | Eski kod, basit uygulamalar | Orta ölçekli uygulamalar | **Production** (nginx, Redis, Node.js) |

> [!warning] Performans Farkı
> 10.000 eş zamanlı bağlantıda:
> - `select()`: Her çağrı 10.000 fd'yi kernel'e kopyala + tüm set'i tara = **çok yavaş**
> - `poll()`: Aynı sorun, sadece FD_SETSIZE limiti yok
> - `epoll()`: Sadece hazır fd'ler döner, kopyalama yok = **C10K probleminin çözümü**

---

## select()

En eski I/O multiplexing mekanizması. POSIX standardı, her platformda çalışır.

#### Çalışma Mantığı

```
1. fd_set olustur (bitmask: hangi fd'leri izliyorsun?)
2. select() cagir (kernel'e fd_set kopyalanir)
3. Kernel tüm fd'leri tarar, hazir olanlari isaretler
4. fd_set modify edilmiş olarak döner
5. Tum fd'leri tek tek kontrol et: FD_ISSET(fd, &set)
6. Her çağrı için fd_set'i yeniden olustur (cunku modify edildi)
```

#### C Örneği

```c
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <arpa/inet.h>

#define MAX_CLIENTS 1024
#define PORT 8080

int main() {
    int server_fd, client_fds[MAX_CLIENTS];
    int max_fd, nclients = 0;
    fd_set read_fds, tmp_fds;
    char buf[1024];

    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_addr.s_addr = INADDR_ANY,
        .sin_port = htons(PORT)
    };
    bind(server_fd, (struct sockaddr*)&addr, sizeof(addr));
    listen(server_fd, 128);

    FD_ZERO(&read_fds);
    FD_SET(server_fd, &read_fds);
    max_fd = server_fd;

    while (1) {
        // select() fd_set'i modify eder, her seferinde kopyala
        tmp_fds = read_fds;

        // Block: herhangi bir fd hazir olana kadar bekle
        int ready = select(max_fd + 1, &tmp_fds, NULL, NULL, NULL);
        if (ready < 0) {
            perror("select");
            break;
        }

        // Yeni bağlantı geldi mi?
        if (FD_ISSET(server_fd, &tmp_fds)) {
            int client = accept(server_fd, NULL, NULL);
            if (client >= 0 && client < FD_SETSIZE) {
                FD_SET(client, &read_fds);
                client_fds[nclients++] = client;
                if (client > max_fd) max_fd = client;
                printf("Yeni client: fd=%d\n", client);
            }
        }

        // Mevcut client'larda veri var mi?
        for (int i = 0; i < nclients; i++) {
            int fd = client_fds[i];
            if (FD_ISSET(fd, &tmp_fds)) {
                ssize_t n = read(fd, buf, sizeof(buf) - 1);
                if (n <= 0) {
                    // Baglanti kapandi
                    close(fd);
                    FD_CLR(fd, &read_fds);
                    printf("Client ayrildi: fd=%d\n", fd);
                } else {
                    buf[n] = '\0';
                    printf("fd=%d: %s\n", fd, buf);
                    write(fd, buf, n);  // Echo
                }
            }
        }
    }

    close(server_fd);
    return 0;
}
```

#### select() Sınırlamaları

- **FD_SETSIZE = 1024**: Bu değerden büyük fd'ler kullanılamaz (derleme zamanında sabit)
- Her çağrı fd_set'i kernel'e **kopyalar** (O(n))
- Dönüşte tüm fd'leri **taramak** gerekir (O(n))
- fd_set her seferinde **yeniden oluşturulmalı** (modify edilir)
- Timeout hassasiyeti düşük (microsecond, ama pratikte ~10ms)

---

## poll()

`select()`'in geliştirilmiş versiyonu. `FD_SETSIZE` limiti yoktur, dinamik `pollfd` array'i kullanır.

#### struct pollfd

```c
struct pollfd {
    int   fd;       // Izlenecek file descriptor
    short events;   // Izlenen event'ler (POLLIN, POLLOUT, ...)
    short revents;  // Gerceklesen event'ler (kernel doldurur)
};
```

#### Event Türleri

| Event | Açıklama |
|-------|----------|
| `POLLIN` | Okunacak veri var |
| `POLLOUT` | Yazma için hazır (buffer dolu değil) |
| `POLLERR` | Hata oluştu |
| `POLLHUP` | Bağlantı kapandı |
| `POLLNVAL` | Geçersiz fd |

#### C Örneği

```c
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <arpa/inet.h>

#define MAX_FDS 4096
#define PORT 8080

int main() {
    struct pollfd fds[MAX_FDS];
    int nfds = 0;
    char buf[1024];

    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_addr.s_addr = INADDR_ANY,
        .sin_port = htons(PORT)
    };
    bind(server_fd, (struct sockaddr*)&addr, sizeof(addr));
    listen(server_fd, 128);

    // Server socket'i izle
    fds[0].fd = server_fd;
    fds[0].events = POLLIN;
    nfds = 1;

    while (1) {
        int ready = poll(fds, nfds, -1);  // -1 = sinirsiz bekle
        if (ready < 0) {
            perror("poll");
            break;
        }

        // Yeni bağlantı
        if (fds[0].revents & POLLIN) {
            int client = accept(server_fd, NULL, NULL);
            if (client >= 0 && nfds < MAX_FDS) {
                fds[nfds].fd = client;
                fds[nfds].events = POLLIN;
                fds[nfds].revents = 0;
                nfds++;
                printf("Yeni client: fd=%d\n", client);
            }
        }

        // Mevcut client'lar
        for (int i = 1; i < nfds; i++) {
            if (fds[i].revents & POLLIN) {
                ssize_t n = read(fds[i].fd, buf, sizeof(buf) - 1);
                if (n <= 0) {
                    printf("Client ayrildi: fd=%d\n", fds[i].fd);
                    close(fds[i].fd);
                    // Son eleman ile değiştir
                    fds[i] = fds[nfds - 1];
                    nfds--;
                    i--;
                } else {
                    buf[n] = '\0';
                    write(fds[i].fd, buf, n);  // Echo
                }
            }
        }
    }

    close(server_fd);
    return 0;
}
```

#### select() vs poll()

| Özellik | select() | poll() |
|---------|----------|--------|
| fd limiti | 1024 (FD_SETSIZE) | **Yok** (dinamik array) |
| Veri yapısı | Bitmask (fd_set) | Array (struct pollfd) |
| Modify davranışı | fd_set modify edilir | Sadece `revents` dolar, `events` korunur |
| Her çağrı yeniden oluştur | **Evet** | **Hayır** (revents sıfırlanır) |
| Kernel kopyalama | O(n) | O(n) |
| Tarama | O(n) | O(n) |

> [!tip] Ne zaman poll() kullanılır?
> - Portatif kod gerekiyorsa (Linux, macOS, BSD)
> - 1024'ten fazla fd izlenecekse ama çok yüksek performans gerekmiyorsa
> - select()'in limitleri yetmiyorsa ama epoll'un karmaşıklığı gereksizse

---

## epoll()

Linux'a özel, yüksek performanslı I/O multiplexing mekanizması. **C10K probleminin** (10.000 eş zamanlı bağlantı) çözümüdür. nginx, Redis, Node.js (libuv), Go runtime hep epoll kullanır.

#### Mimari

```
User Space                         Kernel Space
+-------------+                    +---------------------------+
|             |   epoll_create()   |  epoll instance           |
|  Program    |<------------------>|  +---------------------+  |
|             |                    |  | Interest List       |  |
|             |   epoll_ctl()      |  | (Red-Black Tree)    |  |
|             |<------------------>|  | fd1, fd2, fd3, ...  |  |
|             |                    |  +---------------------+  |
|             |   epoll_wait()     |  | Ready List          |  |
|             |<------------------>|  | (Linked List)       |  |
|             |                    |  | fd2 -> fd5 -> ...   |  |
+-------------+                    +---------------------------+
```

#### 3 Temel Syscall

```c
// 1. epoll instance olustur
//    Kernel'de red-black tree + ready list oluşturur
//    size parametresi artik kullanilmiyor ama >0 olmali
int epfd = epoll_create(1);
// veya
int epfd = epoll_create1(EPOLL_CLOEXEC);

// 2. fd ekle/değiştir/çıkar
//    Interest list'i yönetir (O(log n) — red-black tree)
struct epoll_event ev;
ev.events = EPOLLIN;         // Hangi event'leri izle
ev.data.fd = sockfd;         // Callback için fd bilgisi

epoll_ctl(epfd, EPOLL_CTL_ADD, sockfd, &ev);  // Ekle
epoll_ctl(epfd, EPOLL_CTL_MOD, sockfd, &ev);  // Degistir
epoll_ctl(epfd, EPOLL_CTL_DEL, sockfd, NULL);  // Cikar

// 3. Hazir event'leri al
//    Sadece hazir olanlar döner (O(1))
struct epoll_event events[MAX_EVENTS];
int n = epoll_wait(epfd, events, MAX_EVENTS, timeout_ms);
// timeout_ms: -1 = sinirsiz bekle, 0 = hemen don, >0 = ms bekle

for (int i = 0; i < n; i++) {
    int fd = events[i].data.fd;
    // fd hazir, işlem yap
}
```

#### Edge-Triggered vs Level-Triggered

| Özellik | Level-Triggered (LT) | Edge-Triggered (ET) |
|---------|----------------------|---------------------|
| Tetiklenme | fd hazır **olduğu sürece** | fd durumu **değiştiğinde** (bir kez) |
| Veri okunmazsa | Tekrar bildirir | Bildirmez (veri kaybı riski) |
| Zorluk | Kolay (default) | Zor (tüm veriyi okumak gerekir) |
| Performans | Daha fazla epoll_wait dönüşü | Daha az epoll_wait dönüşü |
| Non-blocking | Zorunlu değil | **Zorunlu** (EAGAIN'e kadar oku) |
| Kullanım | Genel amaçlı | Yüksek performans (nginx) |

```c
// Level-Triggered (default)
ev.events = EPOLLIN;

// Edge-Triggered
ev.events = EPOLLIN | EPOLLET;
```

```
Level-Triggered (LT):
  Kernel buffer'da 100 byte veri var
  epoll_wait() --> "fd hazir" döner
  50 byte okudun, 50 byte kaldi
  epoll_wait() --> "fd hazir" döner (hala veri var)
  50 byte daha okudun
  epoll_wait() --> block olur (veri kalmadi)

Edge-Triggered (ET):
  Kernel buffer'da 100 byte veri var
  epoll_wait() --> "fd hazir" döner
  50 byte okudun, 50 byte kaldi
  epoll_wait() --> BLOCK! (durum degismedi, yeni veri gelmedi)
  << Kalan 50 byte kayboldu! >>

  Dogru ET kullanimi: EAGAIN donene kadar oku
  while ((n = read(fd, buf, sizeof(buf))) > 0) { ... }
  // n == -1 && errno == EAGAIN --> buffer bos, dur
```

> [!warning] Edge-Triggered Kullanım Kuralı
> ET modunda:
> 1. Socket **mutlaka non-blocking** olmalı (`O_NONBLOCK`)
> 2. `read()` / `write()` **EAGAIN dönene kadar** tekrarlanmalı
> 3. Aksi halde veri kaybı veya starvation oluşur

#### epoll() ile TCP Server -- Tam Örnek

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <arpa/inet.h>

#define PORT        8080
#define MAX_EVENTS  1024
#define BUF_SIZE    4096

// Socket'i non-blocking yap
void set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

int main() {
    int server_fd, epfd;
    struct epoll_event ev, events[MAX_EVENTS];
    char buf[BUF_SIZE];

    // Server socket
    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    set_nonblocking(server_fd);

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_addr.s_addr = INADDR_ANY,
        .sin_port = htons(PORT)
    };
    bind(server_fd, (struct sockaddr*)&addr, sizeof(addr));
    listen(server_fd, 128);

    // epoll instance olustur
    epfd = epoll_create1(EPOLL_CLOEXEC);

    // Server socket'i epoll'e ekle
    ev.events = EPOLLIN;
    ev.data.fd = server_fd;
    epoll_ctl(epfd, EPOLL_CTL_ADD, server_fd, &ev);

    printf("epoll server %d portunda dinliyor...\n", PORT);

    while (1) {
        int nready = epoll_wait(epfd, events, MAX_EVENTS, -1);

        for (int i = 0; i < nready; i++) {
            int fd = events[i].data.fd;

            if (fd == server_fd) {
                // Yeni bağlantı(lar) -- non-blocking, hepsini kabul et
                while (1) {
                    struct sockaddr_in client_addr;
                    socklen_t client_len = sizeof(client_addr);
                    int client = accept(server_fd,
                                        (struct sockaddr*)&client_addr,
                                        &client_len);
                    if (client < 0) {
                        if (errno == EAGAIN || errno == EWOULDBLOCK) {
                            break;  // Tum baglantilar kabul edildi
                        }
                        perror("accept");
                        break;
                    }
                    set_nonblocking(client);

                    // Edge-triggered olarak ekle
                    ev.events = EPOLLIN | EPOLLET;
                    ev.data.fd = client;
                    epoll_ctl(epfd, EPOLL_CTL_ADD, client, &ev);

                    char ip[INET_ADDRSTRLEN];
                    inet_ntop(AF_INET, &client_addr.sin_addr, ip, sizeof(ip));
                    printf("Yeni: %s:%d (fd=%d)\n", ip,
                           ntohs(client_addr.sin_port), client);
                }
            } else {
                // Client verisi -- ET: EAGAIN'e kadar oku
                int closed = 0;
                while (1) {
                    ssize_t n = read(fd, buf, BUF_SIZE);
                    if (n < 0) {
                        if (errno == EAGAIN || errno == EWOULDBLOCK) {
                            break;  // Buffer bos, dur
                        }
                        perror("read");
                        closed = 1;
                        break;
                    } else if (n == 0) {
                        // Client bağlantı kapatti
                        closed = 1;
                        break;
                    } else {
                        // Echo: gelen veriyi geri gönder
                        write(fd, buf, n);
                    }
                }
                if (closed) {
                    printf("Client ayrildi: fd=%d\n", fd);
                    epoll_ctl(epfd, EPOLL_CTL_DEL, fd, NULL);
                    close(fd);
                }
            }
        }
    }

    close(server_fd);
    close(epfd);
    return 0;
}
```

#### Neden epoll Bu Kadar Hızlı?

```
select/poll her çağrı:
  1. fd listesini user-space --> kernel kopyala   O(n)
  2. Tum fd'leri tara, hazir olanlari bul        O(n)
  3. Sonucu kernel --> user-space kopyala         O(n)
  Toplam: O(n) her çağrı, n = toplam fd sayisi

epoll:
  epoll_ctl (bir kez):
    fd'yi kernel'deki red-black tree'ye ekle      O(log n)

  epoll_wait (her çağrı):
    Sadece ready list'i don                       O(k), k = hazir fd sayisi
    Kopyalama yok (kernel zaten izliyor)

  10.000 fd, 10 hazir:
    select: 10.000 fd tara --> 10 hazir bul
    epoll:  direkt 10 hazir döner
```

---

## Non-blocking I/O

Default olarak socket işlemleri **blocking**'dir: veri yoksa `read()` block olur, buffer doluysa `write()` block olur. Non-blocking modda bu işlemler **hemen döner**.

#### O_NONBLOCK Ayarlama

```c
#include <fcntl.h>

// Yontem 1: fcntl ile mevcut socket'i değiştir
int flags = fcntl(fd, F_GETFL, 0);
fcntl(fd, F_SETFL, flags | O_NONBLOCK);

// Yontem 2: socket olusturulurken (Linux 2.6.27+)
int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);

// Yontem 3: accept4 ile (Linux 2.6.28+)
int client = accept4(server_fd, &addr, &len, SOCK_NONBLOCK);
```

#### EAGAIN / EWOULDBLOCK

Non-blocking modda işlem yapılamazsa `errno` bu değerlerden birine set edilir:

```c
ssize_t n = read(fd, buf, sizeof(buf));
if (n < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
        // Okunacak veri yok, daha sonra tekrar dene
        // Bu bir HATA değil, beklenen durum
    } else {
        // Gercek hata
        perror("read");
    }
} else if (n == 0) {
    // Baglanti kapandi (EOF)
} else {
    // n byte basariyla okundu
}
```

#### Blocking vs Non-blocking

| Özellik | Blocking | Non-blocking |
|---------|----------|-------------|
| Veri yoksa | Thread block olur | EAGAIN döner, hemen devam |
| Buffer doluysa | write() block olur | EAGAIN döner |
| Kullanım | Basit programlar, thread-per-connection | Event loop, I/O multiplexing |
| epoll ET ile | Kullanılamaz | **Zorunlu** |
| Karmaşıklık | Düşük | Yüksek (partial read/write yönetimi) |

> [!tip] Non-blocking Ne Zaman Gerekli?
> - **epoll edge-triggered** modda zorunlu
> - **Event loop** tabanlı mimarilerde (Node.js, nginx)
> - Tek thread'de birden fazla socket yönetirken
> - `connect()` non-blocking yapılabilir (async bağlantı kurma)

---

## Socket Options

`setsockopt()` ve `getsockopt()` ile socket davranışını kontrol eden seçenekler.

```c
int setsockopt(int sockfd, int level, int optname, const void *optval, socklen_t optlen);
int getsockopt(int sockfd, int level, int optname, void *optval, socklen_t *optlen);
```

### SO_REUSEADDR

Server restart sonrası "Address already in use" hatasını önler.

```c
int opt = 1;
setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
```

```
Neden gerekli:
  Server kapaninca TCP bağlantı TIME_WAIT durumuna girer (2*MSL ~ 60 saniye)
  Bu süre boyunca aynı port bind() yapilamaz
  SO_REUSEADDR: TIME_WAIT'teki port'a bind() izni verir

  Server restart --> bind() --> "Address already in use" HATASI
  SO_REUSEADDR ile --> bind() --> BASARILI
```

### SO_REUSEPORT

Birden fazla process'in **aynı port'u** dinlemesine izin verir (Linux 3.9+).

```c
int opt = 1;
setsockopt(server_fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
```

```
SO_REUSEPORT ile:
  Process A --> bind(:8080) --> listen()  --> accept()
  Process B --> bind(:8080) --> listen()  --> accept()
  Process C --> bind(:8080) --> listen()  --> accept()

  Kernel gelen bağlantıları process'ler arasında dagitir
  --> Daha iyi CPU çekirdeği kullanimi
  --> nginx, envoy bu özelliği kullanir
```

### TCP_NODELAY (Nagle Algoritması)

```c
int opt = 1;
setsockopt(sockfd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
```

```
Nagle algoritması (default ACIK):
  Kucuk paketleri birlestirir, batch olarak gönderir
  --> Bant genisligi verimli, ama LATENCY artar

  Örnek: 1 byte + 1 byte + 1 byte gönderme
  Nagle ACIK:  [1+1+1] --> tek paket (bekler, birlestirir)
  Nagle KAPALI: [1] [1] [1] --> uc ayri paket (hemen gönderir)

TCP_NODELAY = 1 --> Nagle KAPALI
  Kullanim: düşük latency gereken uygulamalar
  - Interaktif protokoller (SSH, telnet)
  - Gercek zamanli oyunlar
  - Finansal işlem sistemleri
```

### TCP_KEEPALIVE

Idle bağlantıların canlı olup olmadığını kontrol eder.

```c
int opt = 1;
setsockopt(sockfd, SOL_SOCKET, SO_KEEPALIVE, &opt, sizeof(opt));

// Keepalive parametreleri (Linux)
int idle = 60;     // 60 saniye idle sonrasi probe başlat
int interval = 10; // Her 10 saniyede bir probe gönder
int count = 5;     // 5 başarısız probe sonrasi bağlantı kapat

setsockopt(sockfd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
setsockopt(sockfd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, sizeof(interval));
setsockopt(sockfd, IPPROTO_TCP, TCP_KEEPCNT, &count, sizeof(count));
```

```
Keepalive olmadan:
  Client cokerse (crash, network kopma) server habersiz kalir
  Server hala fd tutar --> kaynak sizintisi

Keepalive ile:
  [60s idle] --> probe --> ACK --> canli
  [60s idle] --> probe --> cevap yok --> 10s --> probe --> ... --> 5 başarısız --> RST
```

### SO_LINGER

`close()` çağrıldığında bekleyen verinin ne olacağını kontrol eder.

```c
struct linger lg;

// Default: close() hemen döner, kernel veriyi arka planda gönderir
lg.l_onoff = 0;
lg.l_linger = 0;

// Linger ACIK: close() belirtilen süre kadar bekler
lg.l_onoff = 1;
lg.l_linger = 5;  // 5 saniye bekle
setsockopt(sockfd, SOL_SOCKET, SO_LINGER, &lg, sizeof(lg));

// Hard close: close() hemen döner, gonderilmemis veri ATILIR, RST gönderilir
lg.l_onoff = 1;
lg.l_linger = 0;  // 0 saniye = hemen kapat
setsockopt(sockfd, SOL_SOCKET, SO_LINGER, &lg, sizeof(lg));
```

#### Socket Options Özet Tablosu

| Option | Level | Varsayılan | Açıklama |
|--------|-------|-----------|----------|
| `SO_REUSEADDR` | SOL_SOCKET | Kapalı | TIME_WAIT'teki port'a bind izni |
| `SO_REUSEPORT` | SOL_SOCKET | Kapalı | Birden fazla process aynı port'u dinler |
| `TCP_NODELAY` | IPPROTO_TCP | Kapalı | Nagle'i kapatır, düşük latency |
| `SO_KEEPALIVE` | SOL_SOCKET | Kapalı | Idle bağlantı kontrolü |
| `SO_LINGER` | SOL_SOCKET | Kapalı | close() davranışı kontrolü |
| `SO_RCVBUF` | SOL_SOCKET | Sistem | Receive buffer boyutu |
| `SO_SNDBUF` | SOL_SOCKET | Sistem | Send buffer boyutu |
| `TCP_CORK` | IPPROTO_TCP | Kapalı | Veriyi biriktir, tek seferde gönder |

---

## Zero-Copy

Normal veri transferinde veriler user-space ile kernel-space arasında defalarca kopyalanır. Zero-copy teknikleri bu kopyalamaları ortadan kaldırır.

```
Normal dosya --> socket transferi (4 kopya):
  1. Disk --> Kernel buffer  (DMA)
  2. Kernel buffer --> User buffer  (CPU copy)
  3. User buffer --> Socket buffer  (CPU copy)
  4. Socket buffer --> NIC  (DMA)

  read(file_fd, buf, len);
  write(sock_fd, buf, len);

sendfile() ile (2 kopya, zero-copy):
  1. Disk --> Kernel buffer  (DMA)
  2. Kernel buffer --> NIC  (DMA, gather)

  Veri user-space'e HIC cikmaz
```

### sendfile()

Dosyadan socket'e doğrudan veri aktarımı. En yaygın zero-copy yöntemi.

```c
#include <sys/sendfile.h>

// file_fd --> sock_fd (kernel içinde, user-space'e cikmaz)
off_t offset = 0;
ssize_t sent = sendfile(sock_fd, file_fd, &offset, file_size);

// Tipik kullanım: HTTP dosya sunumu
int file_fd = open("index.html", O_RDONLY);
struct stat st;
fstat(file_fd, &st);

// HTTP header'i normal write ile
const char *header = "HTTP/1.1 200 OK\r\nContent-Length: ...\r\n\r\n";
write(sock_fd, header, strlen(header));

// Dosya içeriği zero-copy ile
sendfile(sock_fd, file_fd, NULL, st.st_size);
close(file_fd);
```

> [!info] nginx ve sendfile
> nginx konfigurasyonundaki `sendfile on;` direktifi bu syscall'i etkinleştirir.
> Statik dosya sunumunda büyük performans artışı sağlar.

### splice()

İki fd arasında kernel içinde veri aktarımı. En az bir ucun **pipe** olması gerekir.

```c
#include <fcntl.h>

// pipe üzerinden fd-to-fd zero-copy
int pipefd[2];
pipe(pipefd);

// Adim 1: socket --> pipe (kernel içinde)
ssize_t n = splice(sock_in, NULL, pipefd[1], NULL, 65536,
                   SPLICE_F_MOVE | SPLICE_F_NONBLOCK);

// Adim 2: pipe --> socket (kernel içinde)
splice(pipefd[0], NULL, sock_out, NULL, n,
       SPLICE_F_MOVE | SPLICE_F_NONBLOCK);
```

```
Tipik kullanım: Proxy / Load Balancer
  Client --> [proxy socket_in] --> pipe --> [proxy socket_out] --> Backend

  Veri user-space'e cikmaz, kernel içinde pipe üzerinden akar
  HAProxy bu yaklaşımı kullanir
```

### vmsplice()

User-space buffer'ını pipe'a zero-copy olarak aktarır.

```c
#include <fcntl.h>
#include <sys/uio.h>

struct iovec iov = {
    .iov_base = user_buffer,
    .iov_len = buffer_size
};

// User buffer --> pipe (zero-copy: sayfa tablosu manipulasyonu)
ssize_t n = vmsplice(pipefd[1], &iov, 1, SPLICE_F_GIFT);
// SPLICE_F_GIFT: kernel buffer'i sahiplenir, user-space bunu artik kullanmamali
```

#### Zero-Copy Karşılaştırma

| Yöntem | Kaynak --> Hedef | Pipe Gerekir | Kullanım |
|--------|-----------------|-------------|----------|
| `sendfile()` | Dosya --> Socket | Hayır | Statik dosya sunumu (nginx) |
| `splice()` | fd --> fd | **Evet** (ara pipe) | Proxy, veri yönlendirme |
| `vmsplice()` | User buffer --> Pipe | **Evet** | Kullanıcı verisi zero-copy aktarımı |
| `mmap()` + `write()` | Dosya --> Socket | Hayır | Dosya erişimine ihtiyaç varsa |

---

## Unix Domain Socket Hatırlatma

Aynı host üzerinde process'ler arası iletişim için kullanılır. TCP/IP socket API'si ile aynı interface'i kullanır ama network stack'i **bypass** eder.

> [!info] Detaylı Bilgi
> Unix Domain Socket'in kapsamlı açıklaması, fd passing, Docker bağlantısı için → [[Unix Domain Socket]]
> IPC bağlamında özet → [[Linux IPC Mekanizmaları#Unix Domain Socket]]

```c
// Hizli hatirlatma
int fd = socket(AF_UNIX, SOCK_STREAM, 0);

struct sockaddr_un addr = {.sun_family = AF_UNIX};
strcpy(addr.sun_path, "/tmp/my.sock");

// Geri kalan API aynı: bind, listen, accept, connect, read, write, close
```

#### Önemli Farklar

| Özellik | AF_INET (TCP) | AF_UNIX |
|---------|--------------|---------|
| Kapsam | Ağlar arası | Sadece aynı host |
| Adres | IP:Port | Dosya yolu veya abstract |
| Performans | Network stack overhead | **~2x hızlı** (stack bypass) |
| Özel yetenek | — | **fd passing** (SCM_RIGHTS) |
| Güvenlik | IP/port bazlı | Dosya izinleri (chmod) |
| Örnek | Docker daemon TCP mode | Docker daemon default (`/var/run/docker.sock`) |

---

## Pratik Araçlar: Socket Debug ve İzleme

### ss (Socket Statistics)

`netstat`'in modern ve hızlı alternatifi.

```bash
# Tum TCP socket'leri listele
ss -t -a
# -t: TCP, -a: tüm durumlar (LISTEN, ESTABLISHED, TIME_WAIT, ...)

# Sadece dinleyen (LISTEN) socket'ler
ss -tlnp
# -l: listening, -n: numerik (DNS çözümleme), -p: process bilgisi

# Cikti örneği:
# State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port  Process
# LISTEN  0       128     0.0.0.0:8080        0.0.0.0:*          users:(("nginx",pid=1234,fd=6))

# UDP socket'ler
ss -ulnp

# Unix domain socket'ler
ss -xlnp

# Belirli port'u filtrele
ss -tlnp 'sport = :8080'

# ESTABLISHED bağlantıları say
ss -t state established | wc -l

# TIME_WAIT bağlantıları
ss -t state time-wait

# TCP detay (timer, retransmission, window)
ss -ti

# Baglantiyi kaynaga gore filtrele
ss -tnp dst 10.0.0.5
ss -tnp src :443
```

### netstat (eski, ama yaygın)

```bash
# Tum TCP bağlantıları
netstat -tlnp

# Tum socket'ler (TCP + UDP + Unix)
netstat -anp

# Istatistikler
netstat -s         # Protokol bazli istatistikler
netstat -st        # Sadece TCP istatistikleri
```

### lsof -i (List Open Files - Network)

```bash
# Tum network bağlantıları
lsof -i

# Belirli port
lsof -i :8080

# Belirli process
lsof -i -p 1234

# Sadece TCP LISTEN
lsof -i TCP -sTCP:LISTEN

# IPv4 ve IPv6 ayri
lsof -i 4    # Sadece IPv4
lsof -i 6    # Sadece IPv6

# Belirli host'a baglantilar
lsof -i @10.0.0.5

# Cikti örneği:
# COMMAND  PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
# nginx   1234 root    6u  IPv4  12345      0t0  TCP *:8080 (LISTEN)
# nginx   1234 root    7u  IPv4  12346      0t0  TCP 10.0.0.1:8080->10.0.0.2:45678 (ESTABLISHED)
```

### /proc/net/tcp

Kernel'in TCP bağlantı tablosuna doğrudan erişim.

```bash
# Ham TCP tablosu
cat /proc/net/tcp
#   sl  local_address rem_address   st tx_queue rx_queue ...
#    0: 00000000:1F90 00000000:0000 0A 00000000:00000000 ...
#    1: 0100007F:1F91 0100007F:C5A2 01 00000000:00000000 ...

# Durum kodları:
#   0A = LISTEN
#   01 = ESTABLISHED
#   06 = TIME_WAIT
#   08 = CLOSE_WAIT

# Adresler hex olarak: 00000000:1F90 = 0.0.0.0:8080
# 1F90 hex = 8080 decimal

# Ayristirma örneği (bash ile):
# local_address = 0100007F:1F91
# 0100007F = 127.0.0.1 (little-endian hex)
# 1F91 hex = 8081 decimal
```

```bash
# UDP için
cat /proc/net/udp

# Unix socket'ler için
cat /proc/net/unix

# IPv6 için
cat /proc/net/tcp6
```

#### Debug Senaryoları

```bash
# Senaryo 1: "Address already in use" hatasi
ss -tlnp 'sport = :8080'
# Hangi process o port'u kullaniyor?

# Senaryo 2: Cok fazla TIME_WAIT
ss -t state time-wait | wc -l
# 10.000+ ise SO_REUSEADDR ve tcp_tw_reuse kontrol et

# Senaryo 3: Connection leak (bağlantı sizintisi)
ss -tnp | awk '{print $5}' | sort | uniq -c | sort -rn | head
# Hangi hedefe en çok bağlantı var?

# Senaryo 4: Recv-Q / Send-Q yüksek
ss -tn
# Recv-Q yüksek = uygulama yeterince hızlı okumuyor
# Send-Q yüksek = karsi taraf yeterince hızlı okumuyor veya network yavaş

# Senaryo 5: Container icindeki socket'ler
# Host'tan container'in network namespace'ine gir
nsenter -t <container_pid> -n ss -tlnp
```

> [!tip] Tercih Sırası
> Modern sistemlerde tercih: `ss` > `netstat` (daha hızlı, daha fazla bilgi)
> Process bazlı: `lsof -i` (hangi process hangi port'u kullanıyor)
> Ham veri: `/proc/net/tcp` (scripting, monitoring)

---

## Özet

```
Socket Temelleri:
  socket()  --> fd olustur (AF_INET, SOCK_STREAM/SOCK_DGRAM)
  bind()    --> adres:port ata
  listen()  --> bağlantı kuyruğu olustur (sadece TCP server)
  accept()  --> bağlantı kabul et (sadece TCP server)
  connect() --> sunucuya bağlan (sadece TCP client)
  read/write veya send/recv --> veri al/gönder
  close()   --> bağlantı kapat

I/O Multiplexing:
  select()  --> eski, 1024 fd limiti, her çağrı O(n)
  poll()    --> limit yok ama hala O(n)
  epoll()   --> Linux'a özel, O(1), production standardi

Performans:
  Non-blocking I/O  --> EAGAIN/EWOULDBLOCK, event loop ile
  Zero-copy         --> sendfile(), splice(), kernel içinde transfer
  Socket options    --> SO_REUSEADDR, TCP_NODELAY, SO_KEEPALIVE

Debug:
  ss -tlnp          --> dinleyen TCP socket'ler
  lsof -i :port     --> port kullanan process
  /proc/net/tcp     --> kernel TCP tablosu
```
