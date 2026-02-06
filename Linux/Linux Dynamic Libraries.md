# Linux Dynamic Libraries

Linux'ta programlar **paylaşılan kütüphaneleri (.so)** runtime'da yükler. Bu mekanizma memory tasarrufu sağlar ama **injection** ve **hooking** yüzeyi de oluşturur.

> [!info] İlişkili
> Process memory map'i → [[Linux Debugging Araçları#/proc Filesystem ile Debug]]
> Container güvenliği → [[Docker Security]]

---

## Static vs Dynamic Linking

```
Static Linking                    Dynamic Linking
┌─────────────────┐              ┌─────────────────┐
│    myapp        │              │    myapp        │
│  ┌───────────┐  │              │  ┌───────────┐  │
│  │ app code  │  │              │  │ app code  │  │
│  ├───────────┤  │              │  ├───────────┤  │
│  │ libc code │  │              │  │ PLT/GOT   │──┼──→ libc.so.6
│  ├───────────┤  │              │  └───────────┘  │
│  │ libssl    │  │              └─────────────────┘
│  │ code      │  │
│  └───────────┘  │              Runtime'da ld.so kütüphaneleri yükler
└─────────────────┘              Memory'de paylaşılır
  Büyük binary,                   Küçük binary,
  bağımsız                        .so dosyalarına bağımlı
```

| Özellik | Static | Dynamic |
|---------|--------|---------|
| Binary boyutu | Büyük | Küçük |
| Bağımlılık | Yok (self-contained) | .so dosyaları gerekli |
| Memory | Her process kendi kopyası | Process'ler arası paylaşılır |
| Güncelleme | Binary yeniden derlenmeli | .so güncellenir, binary aynı kalır |
| Startup | Hızlı (yükleme yok) | Biraz yavaş (dynamic linking) |
| Güvenlik | Injection yok | LD_PRELOAD injection riski |
| Kullanım | Go, Rust (default), statik C | C/C++ (default), Python, Node (native modüller) |

```bash
# Static derleme
gcc -static -o myapp myapp.c

# Dynamic derleme (default)
gcc -o myapp myapp.c -lssl -lcrypto

# Binary'nin static mi dynamic mi olduğunu kontrol
file myapp
# myapp: ELF 64-bit LSB executable, dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2
# vs
# myapp: ELF 64-bit LSB executable, statically linked
```

---

## Shared Library (.so) Dosyaları

```bash
# Sistem kütüphaneleri
/lib/x86_64-linux-gnu/        # Temel kütüphaneler
/usr/lib/x86_64-linux-gnu/    # Ek kütüphaneler
/usr/local/lib/                # Manuel kurulumlar

# Yaygın .so dosyaları
libc.so.6          # C standard library (glibc)
libpthread.so.0    # POSIX threads
libdl.so.2         # Dynamic loading (dlopen)
libm.so.6          # Math library
libssl.so.3        # OpenSSL
libstdc++.so.6     # C++ standard library
```

#### Binary'nin Bağımlılıklarını Görme

```bash
# ldd — shared library bağımlılıkları
ldd /bin/ls
#   linux-vdso.so.1 (0x00007ffc12345000)
#   libselinux.so.1 => /lib/x86_64-linux-gnu/libselinux.so.1 (0x00007f1234560000)
#   libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f1234340000)
#   /lib64/ld-linux-x86-64.so.2 (0x00007f12347a0000)  ← dynamic linker

# readelf ile bağımlılıklar
readelf -d /bin/ls | grep NEEDED
#  (NEEDED) Shared library: [libselinux.so.1]
#  (NEEDED) Shared library: [libc.so.6]

# Kütüphanenin export ettiği semboller
nm -D /lib/x86_64-linux-gnu/libc.so.6 | grep " T " | head
# 00000000000a1234 T printf
# 00000000000b5678 T malloc

# objdump ile detay
objdump -T /lib/x86_64-linux-gnu/libc.so.6 | grep printf
```

> [!warning] ldd Güvenliği
> `ldd` güvenilmeyen binary'lerde **tehlikeli** olabilir — binary'yi kısmen çalıştırır.
> Güvenli alternatif: `objdump -p binary | grep NEEDED`

---

## ld.so — Dynamic Linker/Loader

Program başlatıldığında **ld.so** (dynamic linker) shared library'leri yükler ve bağlar.

```
Kernel execve("myapp") çalıştırır
    │
    ▼
ELF header okunur → "interpreter: /lib64/ld-linux-x86-64.so.2"
    │
    ▼
ld.so başlatılır
    │
    ├── 1. LD_PRELOAD kütüphanelerini yükle (varsa)
    ├── 2. DT_NEEDED kütüphanelerini bul ve yükle
    │      ├── LD_LIBRARY_PATH'te ara
    │      ├── /etc/ld.so.cache'te ara (ldconfig cache)
    │      └── Default dizinlerde ara (/lib, /usr/lib)
    ├── 3. Symbol'leri çözümle (relocation)
    ├── 4. PLT/GOT tablolarını doldur
    └── 5. Kontrolü main()'e ver
```

#### Library Arama Sırası

1. `LD_PRELOAD` (environment variable)
2. `DT_RPATH` (binary içinde hardcoded)
3. `LD_LIBRARY_PATH` (environment variable)
4. `DT_RUNPATH` (binary içinde)
5. `/etc/ld.so.cache` (ldconfig cache)
6. `/lib`, `/usr/lib` (default dizinler)

```bash
# Library arama sürecini debug et
LD_DEBUG=libs ./myapp
LD_DEBUG=bindings ./myapp
LD_DEBUG=all ./myapp           # Çok verbose

# ldconfig — library cache yönetimi
ldconfig -p                    # Cache'deki tüm kütüphaneler
ldconfig -p | grep libssl      # Belirli kütüphaneyi ara
sudo ldconfig                  # Cache'i güncelle

# Custom library dizini ekle
echo "/opt/mylibs" >> /etc/ld.so.conf.d/myapp.conf
sudo ldconfig
```

---

## PLT/GOT — Lazy Binding

Dynamic linking'in kalbi. Library fonksiyonları **ilk çağrıda** çözümlenir (lazy binding).

#### PLT (Procedure Linkage Table)
- Her external fonksiyon için bir **PLT entry**
- İlk çağrıda → ld.so'ya yönlendirir (resolve et)
- Sonraki çağrılarda → doğrudan fonksiyona atlar

#### GOT (Global Offset Table)
- Çözümlenmiş fonksiyon **adresleri** burada tutulur
- PLT, GOT'tan adresi okur ve oraya atlar
- İlk başta GOT entry'si ld.so resolver'ına işaret eder

```
İlk çağrı: printf("hello")
┌─────┐    ┌────────────┐    ┌────────────┐    ┌──────────────┐
│ kod │──→ │ PLT[printf]│──→ │ GOT[printf]│──→ │ld.so resolver│
└─────┘    └────────────┘    └────────────┘    └──────┬───────┘
                                                      │ resolve
                                                      ▼
                                                libc: printf()
                                                      │
	                                            GOT güncellenir
	                                            GOT[printf] = 0x7f...printf adresi

Sonraki çağrılar:
┌─────┐    ┌────────────┐    ┌────────────┐
│ kod │──→ │ PLT[printf]│──→ │ GOT[printf]│──→ libc: printf() (direkt)
└─────┘    └────────────┘    └────────────┘
```

```bash
# PLT/GOT'u görmek
objdump -d myapp | grep -A5 "printf@plt"
readelf -r myapp | grep printf

# GOT entry'lerini runtime'da görmek
gdb ./myapp
(gdb) x/gx 0x601030    # GOT adresi
```

> [!warning] GOT Overwrite Saldırısı
> GOT'taki adres **yazılabilir** memory'de. Exploit ile GOT entry değiştirilirse fonksiyon çağrısı **farklı yere** yönlendirilir. Bu binary exploitation'da yaygın bir tekniktir.
> Koruma: **RELRO** (Relocation Read-Only):
> - Partial RELRO: GOT yazılabilir (default)
> - Full RELRO: GOT read-only yapılır (güvenli) → `gcc -Wl,-z,relro,-z,now`

---

## LD_PRELOAD — Library Injection

`LD_PRELOAD` environment variable'ı ile **herhangi bir kütüphane fonksiyonunu** override edebilirsin.

#### Nasıl Çalışır?

```
Normal:     myapp → libc.so.6 → malloc()
LD_PRELOAD: myapp → myhook.so → malloc() (override) → libc malloc (isteğe bağlı)
```

LD_PRELOAD'daki kütüphane **en önce** yüklenir. Aynı isimli fonksiyon varsa **o kullanılır**.

#### Örnek: malloc Hook

```c
// hook.c — malloc çağrılarını logla
#define _GNU_SOURCE
#include <stdio.h>
#include <dlfcn.h>

// Orijinal malloc'u bulmak için
typedef void* (*orig_malloc_t)(size_t);

void *malloc(size_t size) {
    // Orijinal malloc'u bul
    orig_malloc_t orig_malloc = (orig_malloc_t)dlsym(RTLD_NEXT, "malloc");

    // Logla
    void *ptr = orig_malloc(size);
    fprintf(stderr, "[HOOK] malloc(%zu) = %p\n", size, ptr);

    return ptr;
}
```

```bash
# Shared library olarak derle
gcc -shared -fPIC -o hook.so hook.c -ldl

# Herhangi bir programla kullan
LD_PRELOAD=./hook.so ls
# [HOOK] malloc(128) = 0x55a4c4c42a70
# [HOOK] malloc(4096) = 0x55a4c4c42b00
# ...
```

#### Örnek: Network Çağrılarını Logla

```c
// net_hook.c
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdio.h>

typedef int (*orig_connect_t)(int, const struct sockaddr*, socklen_t);

int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    orig_connect_t orig_connect = (orig_connect_t)dlsym(RTLD_NEXT, "connect");

    if (addr->sa_family == AF_INET) {
        struct sockaddr_in *sin = (struct sockaddr_in*)addr;
        char ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &sin->sin_addr, ip, sizeof(ip));
        fprintf(stderr, "[NET] connect → %s:%d\n", ip, ntohs(sin->sin_port));
    }

    return orig_connect(sockfd, addr, addrlen);
}
```

```bash
gcc -shared -fPIC -o net_hook.so net_hook.c -ldl
LD_PRELOAD=./net_hook.so curl http://example.com
# [NET] connect → 93.184.216.34:80
```

#### Pratik Kullanımlar

| Senaryo | Açıklama |
|---------|----------|
| **Debug** | malloc/free hook ile memory leak tespiti |
| **Profiling** | Fonksiyon çağrı süreleri |
| **Testing** | time() override ile zaman simülasyonu |
| **Monitoring** | Network/file erişim logları |
| **Security** | Syscall/library call interception |

---

## dlopen / dlsym — Runtime Library Loading

Program çalışırken **dinamik** olarak kütüphane yüklemek.

```c
#include <dlfcn.h>

// Kütüphaneyi runtime'da yükle
void *handle = dlopen("libplugin.so", RTLD_LAZY);
if (!handle) {
    fprintf(stderr, "dlopen: %s\n", dlerror());
    exit(1);
}

// Fonksiyonu bul
typedef int (*plugin_func_t)(const char*);
plugin_func_t func = (plugin_func_t)dlsym(handle, "plugin_init");
if (!func) {
    fprintf(stderr, "dlsym: %s\n", dlerror());
    exit(1);
}

// Çağır
func("hello from host");

// Kütüphaneyi kapat
dlclose(handle);
```

```bash
# Derleme (-ldl gerekir)
gcc -o myapp myapp.c -ldl

# Plugin'i shared library olarak derle
gcc -shared -fPIC -o libplugin.so plugin.c
```

#### Plugin Sistemi Paterni
```
myapp
├── dlopen("plugins/auth.so")    → auth_init()
├── dlopen("plugins/logging.so") → log_init()
└── dlopen("plugins/cache.so")   → cache_init()
```

---

## Library Injection Teknikleri

> [!warning] Güvenlik Notu
> Bu bilgiler **savunma amaçlıdır** — saldırı yüzeyini anlamak savunmayı güçlendirir.

#### 1. LD_PRELOAD Injection

```bash
# Legitimate (debugging)
LD_PRELOAD=./debug_malloc.so ./myapp

# Kalıcı hale getirme
echo "/path/to/hook.so" >> /etc/ld.so.preload
# /etc/ld.so.preload → TÜM programlar için LD_PRELOAD etkisi
```

#### 2. ptrace Injection

```c
// Çalışan process'e .so enjekte etme (ptrace ile)
// 1. ptrace ile process'e bağlan
ptrace(PTRACE_ATTACH, target_pid, NULL, NULL);

// 2. Register'ları kaydet
ptrace(PTRACE_GETREGS, target_pid, NULL, &regs);

// 3. Process memory'sine dlopen çağrısı enjekte et
// 4. dlopen("malicious.so") çalıştır
// 5. Register'ları geri yükle
// 6. Detach et
```

#### 3. /proc/pid/mem ile Memory Yazma

```bash
# Process memory'sine doğrudan yazma (root gerekir)
# /proc/<pid>/maps → yazılabilir bölgeleri bul
# /proc/<pid>/mem → o bölgelere yaz
```

---

## Korunma Yöntemleri

#### LD_PRELOAD'a Karşı

```bash
# SUID/SGID binary'ler LD_PRELOAD'u otomatik IGNORE eder
chmod u+s myapp   # ld.so LD_PRELOAD'u es geçer

# Static derleme (dynamic linking yok = injection yok)
gcc -static -o myapp myapp.c

# Docker'da LD_PRELOAD engelleme
docker run --read-only myapp    # Filesystem'e .so yazılamaz
```

#### Full RELRO (GOT koruması)

```bash
# GOT'u read-only yap
gcc -Wl,-z,relro,-z,now -o myapp myapp.c

# Kontrol
checksec --file=myapp
# RELRO: Full RELRO ✓
```

#### Binary Güvenlik Kontrolleri

```bash
# checksec aracı ile binary güvenlik özelliklerini kontrol et
checksec --file=./myapp

# RELRO:     Full RELRO          ← GOT read-only
# Stack:     Canary found        ← Stack buffer overflow koruması
# NX:        NX enabled          ← Stack'te kod çalıştırma engeli
# PIE:       PIE enabled         ← Address randomization
# FORTIFY:   Enabled             ← Buffer overflow checks

# ASLR durumu (sistem geneli)
cat /proc/sys/kernel/randomize_va_space
# 0 = kapalı
# 1 = stack, mmap, VDSO randomize
# 2 = + heap randomize (full ASLR)
```

#### Docker'da Library Güvenliği

```bash
# Distroless image (shell bile yok, injection çok zor)
FROM gcr.io/distroless/base-debian12
COPY myapp /
CMD ["/myapp"]

# Read-only filesystem
docker run --read-only --tmpfs /tmp myapp

# Capabilities kısıtla (ptrace engelle)
docker run --cap-drop=ALL myapp

# Seccomp ile ptrace syscall'ını engelle (Docker default'ta zaten engeller)
```

---

## Komut Özeti

```bash
# Bağımlılık kontrolü
ldd binary                      # Shared library bağımlılıkları
readelf -d binary | grep NEEDED # ELF level bağımlılık
nm -D library.so                # Export edilen semboller

# Library arama
ldconfig -p | grep libname      # Cache'te ara
LD_DEBUG=libs ./binary          # Arama sürecini debug et

# Güvenlik kontrolü
checksec --file=binary          # Binary güvenlik özellikleri
readelf -l binary | grep RELRO  # RELRO durumu

# Injection debug
LD_PRELOAD=./hook.so ./binary   # Library hook
strace -e trace=openat ./binary # Hangi .so'lar yükleniyor

# Shared library oluşturma
gcc -shared -fPIC -o libfoo.so foo.c     # .so oluştur
gcc -o myapp myapp.c -L. -lfoo -Wl,-rpath,.  # Kullan
```
