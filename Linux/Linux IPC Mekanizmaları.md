**IPC (Inter-Process Communication)** — Process'ler arası iletişim mekanizmaları.
Linux kernel birden fazla IPC yöntemi sunar, her birinin farklı use case'leri vardır.

> [!info] Docker ile ilişki
> IPC namespace izolasyonu hakkında → [[Linux Namespaces#IPC Namespace]]

---

## IPC Karşılaştırma Tablosu

| Mekanizma | Yön | Hız | Senkronizasyon | Kullanım |
|-----------|-----|-----|---------------|----------|
| **Pipe** | Tek yön | Hızlı | Otomatik (blocking) | Parent-child arası |
| **Named Pipe (FIFO)** | Tek yön | Hızlı | Otomatik (blocking) | İlişkisiz process'ler |
| **Shared Memory** | Çift yön | **En hızlı** | Manuel (semaphore gerekir) | Yüksek throughput |
| **Semaphore** | — | — | Senkronizasyon aracı | Erişim kontrolü |
| **Message Queue** | Çift yön | Orta | Otomatik (kernel lock) | Yapılandırılmış mesajlar |
| **Unix Domain Socket** | Çift yön | Hızlı | Otomatik | Network-like API, fd passing |
| **Signal** | Tek yön | En hızlı | Asenkron | Basit bildirimler |

---

## System V IPC vs POSIX IPC

Linux iki farklı IPC API seti sunar:

| Özellik | System V | POSIX |
|---------|----------|-------|
| Tarih | 1983 (AT&T) | 1993 (IEEE) |
| API Stili | ID bazlı (`shmget`, `msgget`) | İsim bazlı (`shm_open`, `mq_open`) |
| Namespace | `/proc/sysvipc/` | `/dev/shm/`, `/dev/mqueue/` |
| fd Desteği | Hayır | Evet (`select`/`poll`/`epoll` ile kullanılabilir) |
| Temizlik | Manuel (`ipcrm`) | `unlink` ile otomatik |
| Performans | İyi | Daha iyi (fd tabanlı) |

> [!tip] Hangisini Kullanmalı?
> Yeni projeler için **POSIX IPC** tercih edilmeli. Daha temiz API, fd desteği ve daha iyi temizlik mekanizması sunar.
> System V IPC eski kod tabanlarında ve legacy sistemlerde yaygındır.

---

## Pipe (Anonim Boru)

En basit IPC mekanizması. **Parent-child** process'ler arasında **tek yönlü** veri akışı sağlar.

```
Process A (write) ──→ [kernel buffer] ──→ Process B (read)
```

#### Kullanımı
```c
int pipefd[2];
pipe(pipefd);
// pipefd[0] → read end
// pipefd[1] → write end

pid_t pid = fork();
if (pid == 0) {
    // Child: pipe'tan oku
    close(pipefd[1]);  // write end'i kapat
    char buf[128];
    read(pipefd[0], buf, sizeof(buf));
    printf("Child received: %s\n", buf);
    close(pipefd[0]);
} else {
    // Parent: pipe'a yaz
    close(pipefd[0]);  // read end'i kapat
    write(pipefd[1], "hello", 5);
    close(pipefd[1]);
    wait(NULL);
}
```

#### Shell'de Pipe
```bash
# "|" operatörü arka planda pipe() + fork() kullanır
cat /var/log/syslog | grep error | wc -l

# Process A (cat) stdout → pipe → Process B (grep) stdin → pipe → Process C (wc) stdin
```

#### Özellikler
- **Tek yönlü** (unidirectional)
- Sadece **parent-child** (veya fork ile ilişkili) process'ler arasında
- Kernel buffer boyutu: **64 KB** (default, `fcntl` ile artırılabilir)
- Buffer dolunca `write()` **block olur** (backpressure)
- Buffer boşken `read()` **block olur**
- Tüm writer'lar kapatınca reader **EOF** alır

---

## Named Pipe (FIFO)

Pipe'ın filesystem'de **ismi olan** versiyonu. **İlişkisiz process'ler** arasında kullanılabilir.

```bash
# FIFO oluştur
mkfifo /tmp/myfifo

# Terminal 1: Oku (block olur, yazar beklenir)
cat /tmp/myfifo

# Terminal 2: Yaz
echo "hello from another process" > /tmp/myfifo
```

#### C'de Kullanımı
```c
// FIFO oluştur
mkfifo("/tmp/myfifo", 0666);

// Writer process
int fd = open("/tmp/myfifo", O_WRONLY);
write(fd, "data", 4);
close(fd);

// Reader process
int fd = open("/tmp/myfifo", O_RDONLY);
char buf[128];
read(fd, buf, sizeof(buf));
close(fd);
```

#### Pipe vs FIFO

| Özellik | Pipe | FIFO |
|---------|------|------|
| Filesystem'de görünür | Hayır | Evet (`ls -la` ile görünür) |
| İlişkisiz process'ler | Hayır | **Evet** |
| Yön | Tek yön | Tek yön |
| Oluşturma | `pipe()` | `mkfifo()` |
| Ömür | Process ile birlikte | Dosya silinene kadar |

---

## Shared Memory

Process'ler arası paylaşılan bir memory alanıdır, **RAM'de** yaşar.
**En hızlı** IPC mekanizması — veri kopyalanmaz, aynı fiziksel RAM'e erişilir.

```
Process A ──→ ┌─────────────────┐ ←── Process B
              │  Shared Memory  │
              │  (RAM'de)       │
              └─────────────────┘
              Aynı fiziksel sayfa, zero-copy
```

#### System V API
```c
// `shmget` — Shared Memory Segment Oluştur / Al
int shmid = shmget(key, size, IPC_CREAT | 0666);

// `shmat` — Shared Memory'yi Process'e Map Et
// Hiçbir kopyalama yok, aynı RAM, farklı process'ler, `mmap` benzeri davranır
void *addr = shmat(shmid, NULL, 0);

// Process ile shared memory arasındaki bağı koparır, segment silinmez
shmdt(addr);

// Segment'i Kontrol / Silme / Bilgi Alma
// Segment'i silmek için işaretler
// Son process `shmdt` edince gerçekten silinir
shmctl(shmid, IPC_RMID, NULL);
```

#### POSIX API
```c
// Shared memory object oluştur (fd döner)
int fd = shm_open("/myshm", O_CREAT | O_RDWR, 0666);

// Boyut ayarla
ftruncate(fd, 4096);

// Memory map et
void *addr = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);

// Kullan
sprintf(addr, "hello shared memory");

// Unmap
munmap(addr, 4096);

// Sil
shm_unlink("/myshm");
```

> [!tip] POSIX Avantajı
> `shm_open` bir **fd** döner → `select`/`poll`/`epoll` ile kullanılabilir.
> `/dev/shm/` altında dosya olarak görünür.

#### Tipik Shared Memory Lifecycle
```
Producer:
  shmget → shmat → write → shmdt     (System V)
  shm_open → mmap → write → munmap   (POSIX)

Consumer:
  shmget → shmat → read  → shmdt     (System V)
  shm_open → mmap → read  → munmap   (POSIX)

Cleanup:
  shmctl(IPC_RMID)   (System V)
  shm_unlink          (POSIX)
```

> [!warning] Senkronizasyon Gerekli
> Shared memory tek başına **güvensizdir**. Birden fazla process aynı anda yazarsa:
> - Race condition
> - Corrupted data
> - Undefined behavior
>
> Mutlaka **semaphore** veya **mutex** ile korunmalı.

---

## Semaphore

Process'ler arası **senkronizasyon** sağlar. Shared memory **veri taşır**, semaphore **erişim düzenler**.
Kernel tarafından yönetilir, **/dev/shm** altında temsil edilir.

```
Semaphore = Bir tamsayı sayaç + wait queue

sem_wait:  count > 0 → count-- ve geç
           count = 0 → block ol (kernel wait queue'da bekle)

sem_post:  count++ ve bekleyen varsa uyandır
```

#### Semaphore Türleri

| Tür | Initial Value | Kullanım |
|-----|---------------|----------|
| **Binary (Mutex)** | 1 | Mutual exclusion (tek process erişimi) |
| **Counting** | N | N process'e eş zamanlı erişim izni |

#### POSIX API
```c
// `sem_open` — Named semaphore oluştur / aç
// Initial value semaphore tipini belirler (1 = mutex, N = counting)
sem_t *sem = sem_open("/mysem", O_CREAT, 0666, 1);

// `sem_wait` — Semaphore decrement (P operasyonu)
// Value > 0 ise geçer, 0 ise kernel'de block olur (busy-wait yok)
sem_wait(sem);

// === Critical Section (korunan bölge) ===

// `sem_post` — Semaphore increment (V operasyonu)
// Block olmuş bir process varsa uyandırılır
sem_post(sem);

// `sem_close` — Process ile semaphore arasındaki bağı koparır
// Semaphore kernel'de yaşamaya devam eder
sem_close(sem);

// `sem_unlink` — Semaphore'u silmek için işaretler
// Son `sem_close` sonrası gerçekten silinir
sem_unlink("/mysem");
```

#### Non-blocking Deneme
```c
// Block olmadan deneme
if (sem_trywait(sem) == 0) {
    // Başarılı, critical section'a gir
} else {
    // Semaphore müsait değil (EAGAIN)
}

// Timeout ile bekleme
struct timespec ts;
clock_gettime(CLOCK_REALTIME, &ts);
ts.tv_sec += 5;  // 5 saniye timeout
sem_timedwait(sem, &ts);
```

#### Tipik Semaphore Lifecycle
```
Producer / Consumer:
  sem_open → sem_wait → critical_section → sem_post → sem_close

Cleanup:
  sem_unlink
```

#### Shared Memory + Semaphore Birlikte
```c
// Producer
sem_wait(sem);          // Lock al
sprintf(shm_addr, "data %d", counter++);  // Shared memory'ye yaz
sem_post(sem);          // Lock bırak

// Consumer
sem_wait(sem);          // Lock al
printf("%s\n", shm_addr);  // Shared memory'den oku
sem_post(sem);          // Lock bırak
```

#### Dikkat edilmesi gerekenler
- Semaphore **veri tutmaz**, sadece **erişim hakkı** yönetir
- IPC namespace'e tabidir
- Container'lar ancak `--ipc` paylaşırsa aynı semaphore'u görür
- Crash sonrası `sem_unlink` yapılmazsa `/dev/shm` kirlenir
- Permission kritik, yanlış girilirse ulaşılamaz deadlock gibi davranır
- **Priority inversion** riski: düşük öncelikli process lock tutarken yüksek öncelikli bekler

---

## Message Queue

Process'ler arası **mesaj tabanlı iletişim** sağlar.
Shared memory **paylaşılan veri**, message queue **kopyalı mesajlaşma** sunar.
Kernel tarafından tutulur, **IPC namespace'e tabidir**.

#### System V API
```c
// `msgget` — Message Queue oluştur / al
int msqid = msgget(key, IPC_CREAT | 0666);

// Message formatı
struct msgbuf {
    long mtype;        // Mesaj tipi (routing/filtering, >0 olmalı)
    char mtext[128];   // Payload
};

// `msgsnd` — Queue'ya mesaj gönder
// Kernel mesajı kopyalar, producer ile consumer ayrıdır
struct msgbuf msg = {.mtype = 1};
strcpy(msg.mtext, "hello");
msgsnd(msqid, &msg, sizeof(msg.mtext), 0);

// `msgrcv` — Queue'dan mesaj al
// mtype=0: ilk mesajı al, mtype>0: o tipteki ilk mesajı al
struct msgbuf recv;
msgrcv(msqid, &recv, sizeof(recv.mtext), 0, 0);

// `msgctl` — Queue kontrol / silme / bilgi alma
msgctl(msqid, IPC_RMID, NULL);
```

#### POSIX API (mq_\*)
```c
// Queue oluştur
struct mq_attr attr = {
    .mq_flags = 0,
    .mq_maxmsg = 10,      // Max mesaj sayısı
    .mq_msgsize = 256,    // Max mesaj boyutu
    .mq_curmsgs = 0
};
mqd_t mq = mq_open("/myqueue", O_CREAT | O_RDWR, 0666, &attr);

// Mesaj gönder (priority ile)
mq_send(mq, "hello", 5, 1);  // priority = 1

// Mesaj al
char buf[256];
unsigned int prio;
mq_receive(mq, buf, 256, &prio);

// Kapat ve sil
mq_close(mq);
mq_unlink("/myqueue");
```

> [!tip] POSIX mq Avantajı
> - **Priority** desteği (yüksek öncelikli mesajlar önce alınır)
> - **Notification** (`mq_notify` ile mesaj geldiğinde signal veya thread tetikleme)
> - fd bazlı → `select`/`poll`/`epoll` ile kullanılabilir

#### Tipik Message Queue Lifecycle
```
Producer:
  msgget → msgsnd          (System V)
  mq_open → mq_send       (POSIX)

Consumer:
  msgget → msgrcv          (System V)
  mq_open → mq_receive    (POSIX)

Cleanup:
  msgctl(IPC_RMID)         (System V)
  mq_unlink                (POSIX)
```

#### Message Queue Özellikleri
- Kernel buffer'lı FIFO benzeri yapı
- Mesajlar **kopyalanır** (zero-copy değil)
- Otomatik senkronizasyon (lock gerekmez)
- Payload boyutu sınırlıdır

#### Dikkat edilmesi gerekenler
- `msgsnd` / `msgrcv` sırasında:
	- Queue lock alınır
	- Metadata güncellenir
	- Wake-up yapılır

- Birden fazla producer/consumer varsa:
	- Lock contention
	- Scheduler overhead

- Mesaj boyutu sınırlıdır:
	- `cat /proc/sys/kernel/msgmax   # tek mesaj max boyut ≈ 8 KB`
	- `cat /proc/sys/kernel/msgmnb   # queue toplam boyut ≈ 16 KB`

- Büyük payload parçalanır:
	- Extra syscall
	- Extra kopya

---

## Unix Domain Socket

**Aynı host** üzerindeki process'ler arası **çift yönlü** iletişim.
TCP/IP socket API'sini kullanır ama network stack'i **bypass** eder → daha hızlı.

> [!info] Kapsamlı Doküman
> Kernel iç yapısı, fd passing (SCM_RIGHTS), credential passing, Docker socket, performans karşılaştırması ve daha fazlası için → [[Unix Domain Socket]]

```
Process A ←──→ [/tmp/my.sock] ←──→ Process B
               (filesystem path)
```

#### Kullanımı
```c
// Server
int fd = socket(AF_UNIX, SOCK_STREAM, 0);  // SOCK_DGRAM da olabilir

struct sockaddr_un addr = {.sun_family = AF_UNIX};
strcpy(addr.sun_path, "/tmp/my.sock");

bind(fd, (struct sockaddr*)&addr, sizeof(addr));
listen(fd, 5);

int client = accept(fd, NULL, NULL);
char buf[128];
read(client, buf, sizeof(buf));
write(client, "response", 8);

// Client
int fd = socket(AF_UNIX, SOCK_STREAM, 0);
connect(fd, (struct sockaddr*)&addr, sizeof(addr));
write(fd, "request", 7);
read(fd, buf, sizeof(buf));
```

#### Socket Türleri

| Tür | Açıklama |
|-----|----------|
| `SOCK_STREAM` | TCP benzeri, connection-oriented, güvenilir |
| `SOCK_DGRAM` | UDP benzeri, connectionless, mesaj sınırlı |
| `SOCK_SEQPACKET` | Sıralı, güvenilir, mesaj sınırlı |

#### File Descriptor Passing

Unix domain socket'ın **benzersiz özelliği**: process'ler arası **fd gönderebilir**.

```c
// sendmsg() ile fd gönderme (ancillary data olarak)
struct msghdr msg = {0};
struct cmsghdr *cmsg;
char buf[CMSG_SPACE(sizeof(int))];

msg.msg_control = buf;
msg.msg_controllen = sizeof(buf);

cmsg = CMSG_FIRSTHDR(&msg);
cmsg->cmsg_level = SOL_SOCKET;
cmsg->cmsg_type = SCM_RIGHTS;
cmsg->cmsg_len = CMSG_LEN(sizeof(int));
*(int *)CMSG_DATA(cmsg) = fd_to_send;

sendmsg(socket_fd, &msg, 0);
```

#### Docker ve Unix Socket
```bash
# Docker daemon Unix socket üzerinden iletişim kurar
ls -la /var/run/docker.sock
srw-rw---- 1 root docker 0 ... /var/run/docker.sock

# Docker CLI bu socket'e bağlanır
# Bu yüzden socket'i container'a mount etmek = Docker'a tam erişim
```

> [!warning] Performans
> Unix domain socket, TCP loopback'e göre **~2x hızlıdır** (network stack bypass).
> Ama shared memory'ye göre **yavaştır** (kernel copy gerekir).

---

## Signal

Process'lere gönderilen **asenkron bildirimler**. En basit IPC formu.

#### Yaygın Signal'ler

| Signal | Numara | Default | Açıklama |
|--------|--------|---------|----------|
| `SIGTERM` | 15 | Terminate | Graceful shutdown (yakalanabilir) |
| `SIGKILL` | 9 | Kill | Anında öldür (**yakalanamaz**) |
| `SIGINT` | 2 | Terminate | Ctrl+C |
| `SIGHUP` | 1 | Terminate | Terminal kapatıldı / config reload |
| `SIGSTOP` | 19 | Stop | Process dondur (**yakalanamaz**) |
| `SIGCONT` | 18 | Continue | Donmuş process'i devam ettir |
| `SIGCHLD` | 17 | Ignore | Child process durumu değişti |
| `SIGUSR1` | 10 | Terminate | Kullanıcı tanımlı signal 1 |
| `SIGUSR2` | 12 | Terminate | Kullanıcı tanımlı signal 2 |
| `SIGSEGV` | 11 | Core dump | Segmentation fault |

#### Signal Gönderme
```bash
# PID ile signal gönder
kill -SIGTERM 1234
kill -15 1234

# İsimle
kill -SIGTERM $(pidof myapp)

# Tüm process'lere
killall -SIGTERM myapp

# Docker'da
docker stop mycontainer    # SIGTERM → 10s → SIGKILL
docker kill mycontainer    # SIGKILL (anında)
docker kill -s SIGUSR1 mycontainer  # Özel signal
```

#### Signal Yakalama (C)
```c
#include <signal.h>

void handler(int sig) {
    if (sig == SIGTERM) {
        printf("Graceful shutdown başlıyor...\n");
        // Cleanup: bağlantıları kapat, dosyaları flush et
        exit(0);
    }
}

int main() {
    signal(SIGTERM, handler);   // SIGTERM yakalanır
    // veya daha güvenli:
    struct sigaction sa = {.sa_handler = handler};
    sigaction(SIGTERM, &sa, NULL);

    while (1) { /* çalış */ }
}
```

> [!warning] Docker Stop ve Signal
> `docker stop` → PID 1'e SIGTERM → 10s grace period → SIGKILL
> Container'daki uygulama SIGTERM'i **yakalamazsa** 10 saniye boşa beklenir.
> Grace period'u değiştir: `docker stop -t 30 mycontainer`

---

## IPC Debug Araçları

```bash
# System V IPC durumunu görmek
ipcs
# ------ Message Queues --------
# ------ Shared Memory Segments --------
# ------ Semaphore Arrays --------

# Detaylı
ipcs -a        # Tüm IPC object'ler
ipcs -m        # Sadece shared memory
ipcs -s        # Sadece semaphore
ipcs -q        # Sadece message queue
ipcs -l        # Sistem limitleri

# IPC object silmek
ipcrm -m <shmid>    # Shared memory sil
ipcrm -s <semid>    # Semaphore sil
ipcrm -q <msqid>    # Message queue sil

# POSIX IPC (dosya sisteminde görünür)
ls -la /dev/shm/      # Shared memory ve semaphore
ls -la /dev/mqueue/   # POSIX message queue

# Process'in açık fd'lerini görmek
ls -la /proc/<pid>/fd/
lsof -p <pid>

# Socket'leri görmek
ss -xln    # Unix domain socket'ler
lsof -U    # Unix socket kullanan process'ler
```

---

## Hangisini Ne Zaman Kullan?

| Senaryo                                 | Önerilen IPC                      |
| --------------------------------------- | --------------------------------- |
| Shell pipeline                          | **Pipe**                          |
| İlişkisiz process'ler, basit veri       | **FIFO**                          |
| Yüksek throughput, büyük veri           | **Shared Memory** + **Semaphore** |
| Yapılandırılmış mesajlar, routing       | **Message Queue**                 |
| Client-server, çift yön, fd passing     | **Unix Domain Socket**            |
| Basit bildirim, process kontrolü        | **Signal**                        |
| Container'lar arası (network üzerinden) | **TCP/UDP socket (IPC değil)**    |
