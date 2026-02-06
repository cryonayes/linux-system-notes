# Linux Debugging Araçları

Process'lerin **syscall'larını**, **library call'larını**, **memory erişimlerini** ve **davranışlarını** izlemek için kullanılan araçlar.

> [!info] İlişkili
> Process yapısı → [[Linux Process Management]]
> Syscall filtering (seccomp) → [[Docker Security#Seccomp (Secure Computing Mode)]]

---

## Araç Karşılaştırma

| Araç | Ne İzler | Seviye | Kullanım |
|------|---------|--------|----------|
| **strace** | Syscall'lar | Kernel API | Neden hata alıyor? Hangi dosyalara erişiyor? |
| **ltrace** | Library call'lar | User-space | Hangi kütüphane fonksiyonlarını çağırıyor? |
| **gdb** | Her şey (step-by-step) | CPU instruction | Breakpoint, memory inspection, core dump |
| **perf** | Performance counter'lar | Hardware + kernel | CPU profiling, cache miss, branch prediction |
| **bpftrace** | Kernel + user probes | eBPF | Dinamik tracing, production-safe |

---

## ptrace Syscall

**ptrace (process trace)**, bir process'in başka bir process'i **kontrol etmesini** sağlayan syscall.
`strace`, `ltrace`, `gdb` hepsi ptrace üzerine kuruludur.

```c
#include <sys/ptrace.h>

// ptrace(request, pid, addr, data)
long ptrace(enum __ptrace_request request, pid_t pid, void *addr, void *data);
```

#### ptrace Ne Yapabilir?

| Request | Açıklama |
|---------|----------|
| `PTRACE_TRACEME` | "Beni izle" (child → parent) |
| `PTRACE_ATTACH` | Çalışan process'e bağlan |
| `PTRACE_PEEKTEXT` | Process memory'sinden oku |
| `PTRACE_POKETEXT` | Process memory'sine yaz |
| `PTRACE_GETREGS` | Register'ları oku |
| `PTRACE_SETREGS` | Register'ları değiştir |
| `PTRACE_SYSCALL` | Syscall giriş/çıkışında dur |
| `PTRACE_SINGLESTEP` | Tek instruction çalıştır |
| `PTRACE_CONT` | Devam ettir |
| `PTRACE_DETACH` | Bağlantıyı kes |

#### Basit ptrace Tracer

```c
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/user.h>
#include <unistd.h>
#include <stdio.h>
#include <sys/syscall.h>

int main() {
    pid_t child = fork();

    if (child == 0) {
        // Child: "beni izle" de ve program çalıştır
        ptrace(PTRACE_TRACEME, 0, NULL, NULL);
        execl("/bin/ls", "ls", NULL);
    } else {
        // Parent: tracer
        int status;
        struct user_regs_struct regs;

        waitpid(child, &status, 0);  // Child duruncaya kadar bekle

        while (1) {
            // Syscall girişinde dur
            ptrace(PTRACE_SYSCALL, child, NULL, NULL);
            waitpid(child, &status, 0);

            if (WIFEXITED(status)) break;

            // Register'ları oku (syscall numarası rax'ta)
            ptrace(PTRACE_GETREGS, child, NULL, &regs);
            printf("Syscall: %lld\n", regs.orig_rax);

            // Syscall çıkışında dur
            ptrace(PTRACE_SYSCALL, child, NULL, NULL);
            waitpid(child, &status, 0);

            if (WIFEXITED(status)) break;
        }
    }
    return 0;
}
```

#### ptrace Güvenlik

```bash
# ptrace erişim kontrolü
cat /proc/sys/kernel/yama/ptrace_scope
# 0 = herkes herkesi trace edebilir (tehlikeli)
# 1 = sadece parent child'ı trace edebilir (default)
# 2 = sadece CAP_SYS_PTRACE ile
# 3 = hiç kimse (en güvenli)
```

> [!warning] Docker ve ptrace
> Docker default seccomp profili `ptrace`'i **engeller**.
> Container'da strace/gdb kullanmak için:
> ```bash
> docker run --cap-add=SYS_PTRACE myapp
> # veya
> docker run --security-opt seccomp=unconfined myapp
> ```

---

## strace — Syscall Tracer

Process'in yaptığı **tüm syscall'ları** yakalar ve gösterir. "Neden çalışmıyor?" sorusunun cevabı genellikle strace'te.

#### Temel Kullanım

```bash
# Programı strace ile başlat
strace ls -la

# Çalışan process'e bağlan
strace -p 1234

# Sadece belirli syscall'ları izle
strace -e trace=open,read,write ls
strace -e trace=network curl google.com
strace -e trace=file ls -la
strace -e trace=process bash -c "ls"
strace -e trace=memory cat /etc/passwd

# Syscall kategorileri
strace -e trace=%file ls          # Dosya işlemleri
strace -e trace=%process ls       # Process (fork, exec, exit)
strace -e trace=%network curl x   # Network (socket, connect, send)
strace -e trace=%signal ls        # Signal
strace -e trace=%memory ls        # Memory (mmap, brk)
```

#### Çıktı Formatı

```bash
# strace çıktı formatı:
# syscall(args...) = return_value

open("/etc/passwd", O_RDONLY)     = 3        # Başarılı, fd=3
open("/nonexistent", O_RDONLY)    = -1 ENOENT (No such file or directory)
read(3, "root:x:0:0:...", 4096)  = 1024     # 1024 byte okundu
write(1, "hello\n", 6)           = 6         # stdout'a 6 byte yazıldı
```

#### Detaylı Analiz

```bash
# Zaman bilgisi ile
strace -t ls                      # Saat:dakika:saniye
strace -tt ls                     # Mikrosaniye
strace -T ls                      # Her syscall'ın süresi
strace -r ls                      # Relative timestamp (öncekine göre)

# String'leri tam göster (default 32 karakter keser)
strace -s 1024 cat /etc/passwd

# Child process'leri de izle (fork takibi)
strace -f bash -c "ls | grep foo"

# Dosyaya yaz
strace -o output.txt ls

# Syscall istatistikleri
strace -c ls
# % time     seconds  usecs/call     calls    errors syscall
# ------ ----------- ----------- --------- --------- ------
#  45.23    0.000234          11        21           read
#  22.15    0.000115           5        23         3 open
#  10.42    0.000054           2        23           close
#  ...
```

#### Pratik Senaryolar

```bash
# Uygulama hangi dosyaları açıyor?
strace -e trace=openat myapp 2>&1 | grep -v ENOENT

# Neden bağlantı kuramıyor?
strace -e trace=connect,socket curl http://myapi:3000

# Neden yavaş? (hangi syscall zaman harcıyor)
strace -c -p $(pidof myapp)
# Ctrl+C ile durdur → istatistik tablosu

# Config dosyası nerede aranıyor?
strace -e trace=openat -f nginx 2>&1 | grep "\.conf"

# DNS çözümleme sorunları
strace -e trace=connect,sendto,recvfrom dig google.com

# Permission denied sorunu
strace -e trace=openat,access myapp 2>&1 | grep EACCES

# Docker container'da debug
docker run --cap-add=SYS_PTRACE myimage strace -f myapp
```

> [!tip] strace Performans Etkisi
> strace **ciddi performans kaybı** yaratır (%10-100x yavaşlama).
> Production'da kısa süreli kullan veya `perf`/`bpftrace` tercih et.

---

## ltrace — Library Call Tracer

Process'in çağırdığı **shared library fonksiyonlarını** izler.

```bash
# Temel kullanım
ltrace ls

# Çıktı:
# __libc_start_main(...)
# setlocale(LC_ALL, "")
# opendir(".")
# readdir(0x55a4c4c42a70) = { 4, "file.txt" }
# strlen("file.txt") = 8
# puts("file.txt")
# closedir(0x55a4c4c42a70)

# Belirli kütüphane
ltrace -l /lib/x86_64-linux-gnu/libc.so.6 ls

# Sadece belirli fonksiyonlar
ltrace -e malloc+free myapp
ltrace -e "strlen+strcmp" myapp

# İstatistik
ltrace -c ls
# % time     seconds  usecs/call     calls    function
# ------ ----------- ----------- --------- ----------
#  42.11    0.000345          17        20 strlen
#  23.55    0.000193           9        21 strcmp
#  12.40    0.000102          10        10 malloc
```

#### strace vs ltrace

```
ls -la

strace görür:                    ltrace görür:
  openat("/tmp", ...)              opendir("/tmp")
  getdents64(3, ...)               readdir(...)
  fstat(3, ...)                    strlen("file.txt")
  write(1, "file.txt\n", 9)       puts("file.txt")

strace = kernel API (syscall)    ltrace = library API (libc, libssl...)
```

---

## /proc Filesystem ile Debug

`/proc` pseudo-filesystem, **çalışan process'ler** hakkında canlı bilgi sunar.

```bash
# Process bilgileri
ls /proc/<pid>/

# Çalıştırılan komut
cat /proc/<pid>/cmdline | tr '\0' ' '

# Environment variable'lar
cat /proc/<pid>/environ | tr '\0' '\n'

# Çalışma dizini
ls -la /proc/<pid>/cwd

# Executable path
ls -la /proc/<pid>/exe

# Açık file descriptor'lar
ls -la /proc/<pid>/fd/
# lrwx------ 1 root root 0 ... 0 -> /dev/pts/0  (stdin)
# lrwx------ 1 root root 0 ... 1 -> /dev/pts/0  (stdout)
# lrwx------ 1 root root 0 ... 2 -> /dev/pts/0  (stderr)
# lr-x------ 1 root root 0 ... 3 -> /var/log/app.log
# lrwx------ 1 root root 0 ... 4 -> socket:[12345]

# Memory mapping
cat /proc/<pid>/maps
# 7f8a1c000000-7f8a1c021000 rw-p  [heap]
# 7f8a1c400000-7f8a1c5c4000 r-xp  /lib/x86_64-linux-gnu/libc-2.31.so
# 7fffd2c00000-7fffd2c21000 rw-p  [stack]

# Memory kullanımı
cat /proc/<pid>/status | grep -i "vm\|rss\|threads"
# VmPeak: 123456 kB    (max virtual memory)
# VmRSS:   45678 kB    (resident memory — gerçek RAM kullanımı)
# Threads: 8

# Syscall bilgisi (şu an yapılan)
cat /proc/<pid>/syscall

# Namespace bilgisi
ls -la /proc/<pid>/ns/

# Cgroup bilgisi
cat /proc/<pid>/cgroup

# I/O istatistikleri
cat /proc/<pid>/io
# read_bytes: 1234567
# write_bytes: 7654321

# Limitler
cat /proc/<pid>/limits
# Max open files  1024  1048576  files
# Max processes   63304 63304    processes
```

#### Sistem Geneli /proc Dosyaları

```bash
# CPU bilgisi
cat /proc/cpuinfo

# Memory bilgisi
cat /proc/meminfo
# MemTotal:     16384000 kB
# MemFree:       2048000 kB
# MemAvailable:  8192000 kB

# Yük ortalaması
cat /proc/loadavg
# 0.52 0.58 0.59 2/378 12345
# 1min 5min 15min running/total last_pid

# Mount bilgisi
cat /proc/mounts

# Network bağlantıları
cat /proc/net/tcp
cat /proc/net/udp

# Kernel parametreleri
cat /proc/sys/kernel/hostname
cat /proc/sys/net/ipv4/ip_forward
cat /proc/sys/vm/swappiness
```

---

## GDB — GNU Debugger

Source-level ve assembly-level debugging. Breakpoint, memory inspection, core dump analizi.

```bash
# Programı debug modunda derle
gcc -g -o myapp myapp.c

# GDB ile başlat
gdb ./myapp

# Çalışan process'e bağlan
gdb -p <pid>
```

#### GDB Temel Komutları

```
# Çalıştır
(gdb) run
(gdb) run arg1 arg2

# Breakpoint
(gdb) break main              # Fonksiyona
(gdb) break myapp.c:42        # Satıra
(gdb) break *0x4005a0         # Adrese
(gdb) info breakpoints        # Listele
(gdb) delete 1                # Sil

# Adım adım
(gdb) next                    # Sonraki satır (fonksiyona girmez)
(gdb) step                    # Sonraki satır (fonksiyona girer)
(gdb) finish                  # Fonksiyondan çık
(gdb) continue                # Devam et

# Değişkenler
(gdb) print variable          # Değeri göster
(gdb) print *ptr              # Pointer dereference
(gdb) print array[0]@10       # Array'in 10 elemanı
(gdb) set variable = 42       # Değeri değiştir

# Memory
(gdb) x/16xb 0x7ffff7a0      # 16 byte hex dump
(gdb) x/s 0x4005c0            # String olarak oku
(gdb) x/10i $rip              # 10 instruction disassemble

# Stack
(gdb) backtrace               # Call stack
(gdb) frame 2                 # 2. frame'e git
(gdb) info locals             # Local değişkenler
(gdb) info registers          # Register'lar

# Core dump analizi
(gdb) gdb ./myapp core.1234
(gdb) backtrace               # Crash anındaki stack
```

#### Core Dump

```bash
# Core dump'ı aktifleştir
ulimit -c unlimited

# Core dump pattern
echo "/tmp/core.%e.%p" > /proc/sys/kernel/core_pattern

# Program crash olunca:
# /tmp/core.myapp.1234 dosyası oluşur
gdb ./myapp /tmp/core.myapp.1234
(gdb) backtrace
```

> [!tip] Docker'da Core Dump
> Container'da core dump almak için:
> ```bash
> docker run --ulimit core=-1 myapp
> ```
> Core dump host'un `core_pattern` ayarına göre yazılır.

---

## perf — Performance Profiler

Linux kernel'inin hardware performance counter'larına erişim sağlar. **Production-safe**.

```bash
# CPU profiling (hangi fonksiyonlar CPU harcıyor)
perf record -g -p <pid> -- sleep 10
perf report

# Syscall istatistikleri
perf stat -p <pid> -- sleep 5

# Tüm event'leri say
perf stat ls
#  1,234,567  cycles
#    456,789  instructions
#     12,345  cache-misses
#      5,678  branch-misses

# Flame graph oluştur
perf record -g -p <pid> -- sleep 30
perf script > out.perf
# stackcollapse-perf.pl < out.perf | flamegraph.pl > flame.svg
```

---

## Debug Karar Ağacı

```
Program çalışmıyor / hata veriyor
├── Hangi dosyalara erişiyor? → strace -e trace=%file
├── Network sorunu mu? → strace -e trace=%network
├── Permission denied? → strace 2>&1 | grep EACCES
├── Hangi library'leri kullanıyor? → ltrace / ldd
├── Crash oluyor (segfault)? → gdb + core dump + backtrace
├── Yavaş çalışıyor? → perf record + perf report
├── Memory leak? → valgrind --leak-check=full
├── Açık fd'leri görmek? → ls /proc/<pid>/fd/ veya lsof -p <pid>
├── Environment sorunları? → cat /proc/<pid>/environ
└── Container'da debug? → docker run --cap-add=SYS_PTRACE
```
