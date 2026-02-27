Linux'ta her şey bir **process**'tir. Kernel, process'leri `task_struct` yapısı ile yönetir.

> [!info] Docker ile ilişki
> Container'daki PID 1 process'in davranışı kritiktir → [[Linux Namespaces#PID Namespace (process izolasyonu)]]
> `docker stop` signal mekanizmasını kullanır → [[Docker Temelleri#Container Lifecycle]]

---

## Process Nedir?

```
Process = çalışan bir program instance'ı

Her process şunlara sahiptir:
├── PID (Process ID)
├── PPID (Parent Process ID)
├── UID/GID (sahiplik)
├── Memory space (virtual memory)
│   ├── Text segment (kod)
│   ├── Data segment (global değişkenler)
│   ├── Heap (dinamik bellek)
│   └── Stack (fonksiyon çağrıları)
├── File descriptor table
├── Signal handler table
├── Environment variables
└── State (running, sleeping, stopped, zombie)
```

#### Process Durumları

```
[ fork()/clone() ]
        |
        v
+-----------------------+      scheduler seçer       +-----------+
| RUNNABLE / READY (R)  | -------------------------> | RUNNING   |
|  (çalışmaya hazır)    | <------------------------- | (CPU'da)  |
+-----------------------+   preempt / time slice     +-----------+
          ^                                                 |
          |                                                 | exit()
          | wakeup (I/O tamam)                              v
+-----------------------+                           +-----------------+
| SLEEPING              |                           | ZOMBIE (Z)      |
| S: interruptible      |                           | (wait bekliyor) |
| D: uninterruptible    |                           +-----------------+
+-----------------------+                                 | 
                                                          | parent wait()/waitpid()
                                                          |
                                                          v
                                                   +-------------------+
                                                   | REAPED/TERMINATED |
                                                   | (temizlendi)      |
                                                   +-------------------+
```

Durum Karşılıkları:
- R: Hem çalışan hem çalışmaya hazır süreçleri kapsar.
- S: Uyanabilir bekleme (çoğu normal bekleme).
- D: Kernel beklemesi; sinyale hemen tepki vermeyebilir.
- Z: Süreç bitmiştir, parent henüz toplamamıştır.
- wait()/waitpid() sonrası process tablodan tamamen silinir.

---

## fork() — Process Oluşturma

`fork()` mevcut process'in **birebir kopyasını** oluşturur.

```c
#include <unistd.h>
#include <stdio.h>
#include <sys/wait.h>

int main() {
    printf("Parent PID: %d\n", getpid());

    pid_t pid = fork();

    if (pid < 0) {
        // Hata
        perror("fork failed");
    } else if (pid == 0) {
        // Child process
        printf("Child PID: %d, Parent PID: %d\n", getpid(), getppid());
    } else {
        // Parent process (pid = child'ın PID'si)
        printf("Parent: created child with PID %d\n", pid);
        wait(NULL);  // Child'ın bitmesini bekle
    }
    return 0;
}
```

#### fork() Ne Kopyalar?

| Kopyalanan | Paylaşılan |
|-----------|------------|
| Memory space (CoW) | Text segment (read-only kod) |
| File descriptor table | Açık dosyalar (fd'ler aynı dosyayı gösterir) |
| Signal handler'lar | — |
| Environment variables | — |
| PID (yeni atanır) | — |

#### Copy-on-Write (CoW)

`fork()` memory'yi **hemen kopyalamaz**. Her iki process aynı fiziksel sayfaları **read-only** olarak paylaşır. Yazma olduğunda sadece o sayfa kopyalanır.

```
fork() sonrası:
Parent ──→ ┌──────────┐ ←── Child
           │  Page 1  │  (read-only, paylaşımlı)
           │  Page 2  │  (read-only, paylaşımlı)
           └──────────┘

Child Page 1'e yazınca:
Parent ──→ ┌──────────┐     Child ──→ ┌──────────┐
           │  Page 1  │               │  Page 1' │  (kopya, değiştirilmiş)
           │  Page 2  │ ←─────────────│  Page 2  │  (hala paylaşımlı)
           └──────────┘               └──────────┘
```

Bu mekanizma `fork()`'u çok hızlı yapar — GB'larca memory'li process bile anında fork edilir.

---

## exec() Ailesi — Program Çalıştırma

`exec()` mevcut process'in **memory'sini yeni bir program ile değiştirir**. PID değişmez.

```c
// execve — en temel form
execve("/bin/ls", argv, envp);

// exec ailesi (wrapper'lar)
execl("/bin/ls", "ls", "-la", NULL);            // list args
execlp("ls", "ls", "-la", NULL);                // PATH'te arar
execv("/bin/ls", argv);                         // array args
execvp("ls", argv);                             // PATH + array
execvpe("ls", argv, envp);                      // PATH + array + env
```

#### fork() + exec() Paterni

Yeni program çalıştırmanın standart yolu:

```c
pid_t pid = fork();

if (pid == 0) {
    // Child: yeni programı çalıştır
    execvp("ls", (char *[]){"ls", "-la", NULL});
    // execvp başarılıysa buraya asla dönmez
    perror("exec failed");
    exit(1);
} else {
    // Parent: child'ı bekle
    int status;
    waitpid(pid, &status, 0);

    if (WIFEXITED(status)) {
        printf("Child exited with code: %d\n", WEXITSTATUS(status));
    }
}
```

```
Shell'de "ls -la" yazınca:
1. Shell fork() yapar → child oluşur
2. Child execvp("ls", ...) yapar → memory "ls" programı ile değişir
3. ls çalışır, exit() yapar
4. Shell wait() ile child'ı toplar
```

> [!tip] exec() Sonrası
> - PID **aynı kalır**
> - Memory **tamamen değişir** (kod, data, heap, stack)
> - Açık fd'ler **kalır** (`FD_CLOEXEC` set edilmemişse)
> - Signal handler'lar **default'a döner**

---

## wait() / waitpid() — Child Toplama

Parent process, child'ın **exit durumunu** toplamalıdır. Toplanmazsa child **zombie** olur.

```c
// Herhangi bir child'ı bekle
int status;
pid_t child = wait(&status);

// Belirli bir child'ı bekle
waitpid(pid, &status, 0);

// Non-blocking kontrol
waitpid(-1, &status, WNOHANG);  // Hemen döner

// Exit durumunu analiz et
if (WIFEXITED(status)) {
    int code = WEXITSTATUS(status);   // Normal çıkış kodu
}
if (WIFSIGNALED(status)) {
    int sig = WTERMSIG(status);       // Signal ile öldürüldü
}
if (WIFSTOPPED(status)) {
    int sig = WSTOPSIG(status);       // Durduruldu
}
```

---

## Zombie Process

Child process **bitmiş** ama parent henüz `wait()` yapmamış → **zombie**.

```
ps aux | grep Z
USER   PID  %CPU %MEM  STAT  COMMAND
root   1234  0.0  0.0   Z    [myapp] <defunct>
```

#### Neden Oluşur?

```c
// Parent wait() yapmıyor → child zombie olur
pid_t pid = fork();
if (pid == 0) {
    exit(0);  // Child hemen çıkar
}
// Parent burada wait() yapmadan devam ediyor
// Child artık zombie: kernel exit status'u tutuyor, PID table'da yer kaplıyor
sleep(3600);
```

#### Zombie Neden Kötü?
- **PID table** girdisi yer kaplar (sınırlı kaynak)
- Çok fazla zombie → yeni process oluşturulamaz (`fork: Resource temporarily unavailable`)
- Memory değil, **kernel kaynak** tüketir

#### Zombie'den Kaçınma

**Yöntem 1: wait() çağır**
```c
// SIGCHLD handler'da wait
void sigchld_handler(int sig) {
    while (waitpid(-1, NULL, WNOHANG) > 0);
}
signal(SIGCHLD, sigchld_handler);
```

**Yöntem 2: SIGCHLD'i ignore et**
```c
// Kernel otomatik olarak child'ları toplar
signal(SIGCHLD, SIG_IGN);
```

**Yöntem 3: Double fork**
```c
pid_t pid = fork();
if (pid == 0) {
    // İlk child
    if (fork() == 0) {
        // Torun (grandchild) — asıl iş burada yapılır
        // Parent'ı (ilk child) hemen çıkacak
        // Torun'un parent'ı init (PID 1) olur → otomatik toplanır
        execvp("long-running-task", args);
    }
    exit(0);  // İlk child hemen çıkar
}
wait(NULL);  // İlk child'ı topla (hızlı)
// Torun bağımsız çalışmaya devam eder
```

---

## Orphan Process

Parent **child'dan önce** çıkar → child **orphan** olur.

```
Parent (PID 100) ──fork()──→ Child (PID 200, PPID=100)
     │
     └── exit()  (parent çıkar)

Child (PID 200, PPID=1) ← init/systemd tarafından adopt edilir
```

- Orphan process'ler **init (PID 1)** tarafından sahiplenilir
- init otomatik `wait()` yapar → zombie oluşmaz
- Zombie'den farklı olarak orphan **zararsızdır**

> [!warning] Docker'da PID 1 Sorunu
> Container'da PID 1 olan process **init rolünü** üstlenir.
> Eğer uygulama orphan child'ları `wait()` ile toplamazsa → container içinde zombie birikir.
> Çözüm: `--init` flag'i ile tini veya dumb-init kullan:
> ```bash
> docker run --init myapp
> ```
> Bu, `/sbin/tini` veya `/dev/init`'i PID 1 olarak çalıştırır, signal forwarding + zombie reaping yapar.

---

## Signal Handling

Signal'ler process'lere gönderilen **asenkron bildirimlerdir**.

> [!tip] Detaylı bilgi
> Signal türleri ve IPC bağlamı → [[Linux IPC Mekanizmaları#Signal]]

#### Process'te Signal Yakalama
```c
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

volatile sig_atomic_t running = 1;

void handle_sigterm(int sig) {
    printf("SIGTERM alındı, graceful shutdown...\n");
    running = 0;
}

void handle_sigint(int sig) {
    printf("\nSIGINT (Ctrl+C) alındı\n");
    running = 0;
}

void handle_sighup(int sig) {
    printf("SIGHUP alındı, config yeniden yükleniyor...\n");
    // reload_config();
}

int main() {
    // sigaction (signal'den daha güvenli)
    struct sigaction sa_term = {.sa_handler = handle_sigterm};
    struct sigaction sa_int = {.sa_handler = handle_sigint};
    struct sigaction sa_hup = {.sa_handler = handle_sighup};

    sigaction(SIGTERM, &sa_term, NULL);
    sigaction(SIGINT, &sa_int, NULL);
    sigaction(SIGHUP, &sa_hup, NULL);

    // SIGKILL ve SIGSTOP yakalanamaz!
    // signal(SIGKILL, handler);  // Bu çalışmaz

    printf("PID: %d, çalışıyor...\n", getpid());
    while (running) {
        pause();  // Signal gelene kadar bekle
    }

    printf("Temizlik yapılıyor...\n");
    // cleanup: fd'leri kapat, dosyaları flush et, socket'leri kapat
    return 0;
}
```

#### Docker Stop ve Signal Zinciri

```
docker stop mycontainer
    │
    ├─ 1. SIGTERM gönderilir (PID 1'e)
    │
    ├─ 2. Grace period beklenir (default 10s)
    │     └─ Uygulama graceful shutdown yapmalı
    │        - Bağlantıları kapat
    │        - Buffer'ları flush et
    │        - Temp dosyaları temizle
    │
    └─ 3. SIGKILL gönderilir (yakalanamaz, anında öldürür)
```

```bash
# Grace period'u ayarla
docker stop -t 30 mycontainer    # 30 saniye bekle
docker stop -t 0 mycontainer     # Hemen SIGKILL (graceful yok)

# Özel signal gönder
docker kill -s SIGHUP mycontainer   # Config reload
docker kill -s SIGUSR1 mycontainer  # Custom signal
```

---

## Process Oluşturma Syscall'ları

| Syscall | Açıklama |
|---------|----------|
| `fork()` | Process kopyalar (CoW) |
| `vfork()` | fork + child exec yapana kadar parent durur (eski, kullanma) |
| `clone()` | fork'un detaylı versiyonu (namespace flag'leri, thread oluşturma) |
| `posix_spawn()` | fork+exec birleşik (daha verimli) |

#### clone() — Docker'ın Temeli

```c
// clone() ile namespace'li process oluşturma
// Docker'ın (runc'ın) container başlatırken yaptığı şey
int flags = CLONE_NEWPID    // Yeni PID namespace
          | CLONE_NEWNET    // Yeni network namespace
          | CLONE_NEWNS     // Yeni mount namespace
          | CLONE_NEWUTS    // Yeni UTS namespace
          | CLONE_NEWIPC    // Yeni IPC namespace
          | CLONE_NEWUSER   // Yeni user namespace
          | SIGCHLD;

pid_t child = clone(child_func, stack + STACK_SIZE, flags, arg);
```

> [!info] fork vs clone
> `fork()` aslında `clone()` etrafında bir wrapper'dır.
> `clone()` hangi kaynakların paylaşılacağını/izole edileceğini **flag'lerle** kontrol eder.
> Thread'ler de `clone(CLONE_VM | CLONE_FS | CLONE_FILES | ...)` ile oluşturulur.

---

## Process Ağacı

Linux'ta tüm process'ler **ağaç yapısı** oluşturur. Kök = PID 1 (init/systemd).

```bash
# Process ağacını görmek
pstree -p
systemd(1)─┬─dockerd(1234)─┬─containerd(1235)─┬─containerd-shim(5678)───nginx(5700)
           │               │                  └─containerd-shim(5680)───node(5710)
           │               └─docker-proxy(5690)
           ├─sshd(800)───sshd(9000)───bash(9001)
           └─cron(500)

# Belirli process'in ağacı
pstree -p 1234
```

---

## Process Yönetim Komutları

```bash
# Process listesi
ps aux                          # Tüm process'ler
ps -ef                          # Tam format
ps aux --sort=-%mem | head       # Memory'ye göre sırala
ps -eo pid,ppid,state,cmd       # Özel sütunlar

# Canlı izleme
top                             # Klasik
htop                            # İnteraktif (renkleri, ağaç görünümü)

# Process detayı
cat /proc/<pid>/status          # Detaylı bilgi
cat /proc/<pid>/cmdline         # Çalıştırılan komut
cat /proc/<pid>/environ         # Environment variables
ls -la /proc/<pid>/fd/          # Açık dosya descriptor'lar
cat /proc/<pid>/maps            # Memory mapping

# Signal gönderme
kill <pid>                      # SIGTERM (default)
kill -9 <pid>                   # SIGKILL
kill -HUP <pid>                 # SIGHUP (config reload)
killall <name>                  # İsimle signal gönder
pkill -f "pattern"              # Pattern ile signal gönder

# Process bekleme
wait <pid>                      # Shell'de child'ı bekle

# Background / Foreground
myapp &                         # Background'da başlat
jobs                            # Background job'ları listele
fg %1                           # Foreground'a getir
bg %1                           # Background'da devam ettir
Ctrl+Z                          # SIGTSTP (durdur)

# Nice / Priority
nice -n 10 myapp                # Düşük öncelikle başlat (-20 ile 19 arası)
renice -n 5 -p <pid>            # Çalışan process'in önceliğini değiştir
```

---

## Process Lifecycle Özet

```
1. fork()    → Process kopyalanır (CoW ile hızlı)
2. exec()    → Memory yeni program ile değişir
3. Çalışır   → Scheduler CPU atar, I/O bekler, signal alır
4. exit()    → Process biter, exit status kernel'de tutulur
5. wait()    → Parent exit status'u toplar, kernel kaynakları serbest bırakır
```

```
fork() olmadan exec() → mevcut process değişir (geri dönüş yok)
fork() sonra wait() yok → zombie oluşur
Parent önce exit() → child orphan olur (init sahiplenir)
```
