# Linux Virtual Memory

Linux kernel'inin en kritik alt sistemlerinden biri olan **Virtual Memory (Sanal Bellek)**, her process'e kendi **bağımsız adres alanını** sunar. Fiziksel RAM'den soyutlama sağlar, process izolasyonunu garanti eder ve fiziksel bellekten daha fazla bellek kullanımına olanak tanır.

> [!info] İlişkili
> Process'lerin memory yapısı → [[Linux Process Management]]
> Container memory limitleri ve OOM → [[Linux Cgroups#Memory Kontrolü]]
> Memory debugging araçları → [[Linux Debugging Araçları]]
> Container izolasyonu → [[Docker Temelleri]]

---

## Virtual Address Space Yapısı

Her process **kendi sanal adres alanına** sahiptir. 64-bit sistemlerde teorik olarak 2^64 byte adreslenebilir, ancak pratikte 48-bit (256 TB) kullanılır.

```
Yüksek Adresler (0xFFFFFFFFFFFFFFFF)
┌─────────────────────────────────┐
│                                 │
│         KERNEL SPACE            │  Kernel kodu, veri yapıları, modüller
│      (user erişemez)            │  Her process'te aynı mapping
│                                 │
├─────────────────────────────────┤ ← 0xFFFF800000000000 (canonical boundary)
│                                 │
│    (kullanılamayan boşluk)      │  Non-canonical adresler
│                                 │
├─────────────────────────────────┤ ← 0x00007FFFFFFFFFFF (user space üst sınır)
│                                 │
│          STACK                  │  Fonksiyon çağrıları, local değişkenler
│          ↓ (aşağı büyür)        │  LIFO yapısı
│                                 │
├ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┤
│                                 │
│     (boş alan — kullanılabilir) │
│                                 │
├ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┤
│                                 │
│     Memory Mapped Region        │  mmap(), shared libraries
│     (aşağı veya yukarı büyür)   │
│                                 │
├ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┤
│                                 │
│          HEAP                   │  malloc(), calloc(), realloc()
│          ↑ (yukarı büyür)       │  brk()/sbrk() ile genişler
│                                 │
├─────────────────────────────────┤ ← program break
│          BSS Segment            │  Sıfırlanmış global/static değişkenler
│          (uninitialized data)   │  Dosyada yer kaplamaz, runtime'da sıfırlanır
├─────────────────────────────────┤
│          Data Segment           │  Başlangıç değeri olan global/static değişkenler
│          (initialized data)     │  Binary'de saklanan veriler
├─────────────────────────────────┤
│          Text Segment           │  Makine kodu (read-only, executable)
│          (code)                 │  Birden fazla process paylaşabilir
├─────────────────────────────────┤
│          (reserved)             │  NULL pointer dereference koruması
└─────────────────────────────────┘ ← 0x0000000000000000
```

#### Segment Detayları

| Segment | İçerik | Büyüme | Koruma |
|---------|--------|--------|--------|
| **Text** | Derlenmiş makine kodu | Sabit | `r-x` (read + execute) |
| **Data** | `int x = 42;` gibi initialized global'ler | Sabit | `rw-` (read + write) |
| **BSS** | `int y;` gibi uninitialized global'ler | Sabit | `rw-` |
| **Heap** | `malloc()` ile ayrılan bellek | Yukarı (artan adres) | `rw-` |
| **mmap** | Dosya mapping'leri, shared library'ler | Değişken | Ayarlanabilir |
| **Stack** | Local değişkenler, return adresleri | Aşağı (azalan adres) | `rw-` |

```c
#include <stdio.h>
#include <stdlib.h>

int global_init = 42;        // Data segment
int global_uninit;            // BSS segment
const char *str = "hello";   // str → Data, "hello" → Text (rodata)

int main() {
    int local_var = 10;       // Stack
    static int s_var = 5;     // Data segment
    int *heap_ptr = malloc(100);  // Heap

    printf("Text  (main):       %p\n", (void *)main);
    printf("Data  (global_init): %p\n", (void *)&global_init);
    printf("BSS   (global_uninit): %p\n", (void *)&global_uninit);
    printf("Heap  (malloc):     %p\n", (void *)heap_ptr);
    printf("Stack (local_var):  %p\n", (void *)&local_var);

    free(heap_ptr);
    return 0;
}
```

```bash
# Derleme ve çalıştırma
gcc -o segments segments.c
./segments
# Text  (main):       0x55a3c4401169
# Data  (global_init): 0x55a3c4404010
# BSS   (global_uninit): 0x55a3c4404018
# Heap  (malloc):     0x55a3c52926b0
# Stack (local_var):  0x7ffc8a3b1c5c
```

> [!tip] Adres Sıralaması
> Text < Data < BSS < Heap < ... boşluk ... < mmap < ... boşluk ... < Stack
> Her çalıştırmada ASLR nedeniyle adresler değişir (ilerideki bölümde açıklanacak).

---

## Page Table ve Adres Çevirisi

Sanal adresler fiziksel adreslere **page table** aracılığıyla çevrilir. Bellek **page** (sayfa) birimleriyle yönetilir — x86-64'te varsayılan page boyutu **4 KB** (4096 byte).

```
Sanal Adres Cevirisi (x86-64, 4-Level Paging)

  Sanal Adres (48 bit kullanılan)
  ┌────────┬────────┬────────┬────────┬──────────────┐
  │ PML4   │ PDPT   │  PD    │  PT    │   Offset     │
  │ 9 bit  │ 9 bit  │ 9 bit  │ 9 bit  │   12 bit     │
  └───┬────┴───┬────┴───┬────┴───┬────┴──────┬───────┘
      │        │        │        │           │
      ▼        ▼        ▼        ▼           │
   ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐       │
   │PML4  │→│PDPT  │→│ Page │→│ Page │       │
   │Table │ │Table │ │ Dir  │ │Table │       │
   │      │ │      │ │      │ │      │       │
   │[512] │ │[512] │ │[512] │ │[512] │       │
   └──────┘ └──────┘ └──────┘ └──┬───┘       │
                                 │           │
                                 ▼           ▼
                              ┌──────────────────┐
                              │  Fiziksel Sayfa  │
                              │  (4 KB)          │
                              │  offset ile      │
                              │  hedef byte      │
                              └──────────────────┘

CR3 register'i → PML4 tablosunun fiziksel adresini tutar
```

#### Multi-Level Page Table

Neden tek seviye değil de 4 seviye page table kullanılır?

```
Tek seviye page table sorunu (48-bit adres, 4 KB page):
  2^48 / 2^12 = 2^36 = 64 milyar girdi
  Her girdi 8 byte → 512 GB sadece page table için!

Multi-level çözüm:
  Sadece kullanılan bolgelere ait alt tablolar oluşturulur.
  Bos adres araliklari için tablo olusturulmaz → devasa tasarruf.

  Örnek: Sadece 100 MB kullanan process
  - Tek seviye: 512 GB page table (!)
  - 4 seviye: ~birkaç KB page table
```

| Seviye | x86-64 Adı | Girdi Sayısı | Kapsadığı Alan |
|--------|-----------|--------------|----------------|
| L4 | PML4 (Page Map Level 4) | 512 | 512 GB per entry |
| L3 | PDPT (Page Directory Pointer Table) | 512 | 1 GB per entry |
| L2 | PD (Page Directory) | 512 | 2 MB per entry |
| L1 | PT (Page Table) | 512 | 4 KB per entry (page) |

> [!info] 5-Level Paging
> Linux 4.14+ ile **5 seviye** paging desteği eklendi (LA57).
> 57-bit sanal adres → 128 PB adreslenebilir alan.
> Büyük veri tabanları ve in-memory sistemler için gerekli.

#### TLB (Translation Lookaside Buffer)

Her bellek erişiminde 4 seviye tablo yürümek çok yavaş olur. **TLB**, en son kullanılan sayfa çevrimlerini önbellekleyen donanım bileşenidir.

```
CPU ──→ TLB kontrolü
          │
          ├─ TLB Hit → Fiziksel adres aninda bulunur (1-2 cycle)
          │
          └─ TLB Miss → Page table walk (10-100+ cycle)
                │
                └─ Sonuc TLB'ye yüklenir
```

```bash
# TLB istatistiklerini gorme (perf ile)
perf stat -e dTLB-loads,dTLB-load-misses,iTLB-loads,iTLB-load-misses ./myapp

# Örnek çıktı:
#  150,000,000  dTLB-loads
#       50,000  dTLB-load-misses    # %0.03 miss oranı (iyi)
#   80,000,000  iTLB-loads
#       10,000  iTLB-load-misses
```

> [!tip] Huge Pages ile TLB Optimizasyonu
> 4 KB yerine **2 MB** veya **1 GB** sayfa kullanılarak TLB miss oranı düşürülür.
> ```bash
> # Transparent Huge Pages (THP) durumu
> cat /sys/kernel/mm/transparent_hugepage/enabled
> # [always] madvise never
>
> # Manuel huge page ayırma
> echo 1024 > /proc/sys/vm/nr_hugepages   # 1024 x 2MB = 2 GB
> ```
> Veritabanı uygulamaları (PostgreSQL, Redis) için THP dikkatli kullanılmalı — bazı workload'larda **latency spike** yaratabilir.

---

## Page Fault

Process bir sanal adrese eriştiğinde, o adres fiziksel bellekte haritalanmamışsa **page fault** oluşur. Kernel bu durumu yakalar ve uygun işlemi yapar.

```
Process sanal adrese erisiyor
          │
          ▼
     MMU kontrolü
          │
          ├─ Page tabloda var + fiziksel bellekte → Normal erişim
          │
          └─ Page fault oluşur → Kernel'e trap
                    │
                    ├─ Minor Page Fault
                    │   Sayfa fiziksel bellekte var ama
                    │   page table'da haritalanmamis.
                    │   Disk I/O yok, hızlı cozulur.
                    │   Ornekler:
                    │   - CoW sayfası (fork sonrasi ilk yazma)
                    │   - mmap edilmiş ama henuz erisılmemis sayfa
                    │   - Shared library sayfası başka process'te yüklü
                    │
                    ├─ Major Page Fault
                    │   Sayfa fiziksel bellekte YOK.
                    │   Diskten okunmasi gerekir (yavaş!).
                    │   Ornekler:
                    │   - Swap'a gönderilmiş sayfa
                    │   - mmap ile dosyadan ilk okuma
                    │   - Demand paging ile program kodu yükleme
                    │
                    └─ Invalid (Segfault)
                        Gecersiz adres erişimi.
                        Kernel SIGSEGV gönderir → process olur.
                        Ornekler:
                        - NULL pointer dereference
                        - Stack overflow
                        - Free edilmiş bellek erişimi
```

#### Demand Paging

Kernel, bir programı başlattığında **tüm sayfalarını belleğe yüklemez**. Sayfaları sadece erişildiklerinde yükler — bu **demand paging** (talep üzerine sayfalama) olarak adlandırılır.

```c
// Bu program başlatıldığında text segment'in tamami yuklenmez.
// Her fonksiyon ilk cagrildiginda minor/major page fault oluşur
// ve ilgili sayfa belleğe yüklenir.

#include <stdio.h>

void rarely_called_function() {
    // Bu fonksiyon cagrilana kadar fiziksel bellekte yer almaz
    printf("Bu sayfa demand paging ile yuklendi\n");
}

int main() {
    printf("main yuklendi\n");
    // rarely_called_function henuz bellekte değil
    rarely_called_function();  // Burada page fault → sayfa yüklenir
    return 0;
}
```

```bash
# Process'in page fault sayilarini gorme
ps -o pid,minflt,majflt -p <pid>
#   PID  MINFLT  MAJFLT
#  1234  15230       3

# Detayli page fault izleme
perf stat -e page-faults,minor-faults,major-faults ./myapp

# /proc üzerinden
cat /proc/<pid>/stat | awk '{print "MinFlt:"$10, "MajFlt:"$12}'
```

> [!warning] Major Page Fault Performans Etkisi
> Minor fault: ~1-10 mikrosaniye (us)
> Major fault: ~1-10 milisaniye (ms) — **1000x daha yavaş!**
> Production sistemlerde major fault sayısının yüksek olması ciddi performans sorununa işaret eder.
> `vmstat` çıktısındaki `si` (swap in) ve `so` (swap out) değerlerini izleyin.

---

## mmap() — Memory Mapped I/O

`mmap()` sistem çağrısı, dosyaları veya anonim belleği doğrudan process'in adres alanına haritalar. Geleneksel `read()`/`write()` yerine bellek erişimi ile dosya okuma/yazma yapılmasını sağlar.

```c
#include <sys/mman.h>

void *mmap(void *addr, size_t length, int prot, int flags,
           int fd, off_t offset);

int munmap(void *addr, size_t length);
```

#### File Mapping

```c
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int main() {
    int fd = open("data.txt", O_RDONLY);
    struct stat sb;
    fstat(fd, &sb);

    // Dosyayi belleğe haritala
    char *mapped = mmap(NULL, sb.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (mapped == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    // Artik dosya icerigine pointer ile erisebiliriz
    // Kernel page fault mekanizması ile gerekli sayfaları otomatik yükler
    printf("Ilk 100 byte: %.100s\n", mapped);

    munmap(mapped, sb.st_size);
    close(fd);
    return 0;
}
```

#### Anonymous Mapping

Dosya ile ilişkilendirilmemiş bellek ayırma. `malloc()` büyük bloklar için arka planda `mmap(MAP_ANONYMOUS)` kullanır.

```c
#include <sys/mman.h>
#include <string.h>
#include <stdio.h>

int main() {
    // 1 MB anonim bellek ayir
    size_t size = 1024 * 1024;
    void *ptr = mmap(NULL, size,
                     PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS,
                     -1, 0);  // fd=-1, offset=0 (anonim)

    if (ptr == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    // Bellek sifirlanmis olarak gelir (kernel garantisi)
    memset(ptr, 'A', size);
    printf("Ilk byte: %c\n", ((char *)ptr)[0]);

    munmap(ptr, size);
    return 0;
}
```

#### MAP_SHARED vs MAP_PRIVATE

| Özellik | MAP_SHARED | MAP_PRIVATE |
|---------|-----------|-------------|
| **Değişiklikler** | Diğer process'ler ve dosya tarafından görünür | Sadece bu process'te görünür (CoW kopya) |
| **Dosyaya yazma** | `msync()` ile veya otomatik flush | Dosya **değişmez** |
| **IPC için** | Evet — process'ler arası paylaşım | Hayır |
| **fork() sonrası** | Parent ve child aynı fiziksel sayfayı paylaşır | CoW ile ayrılır |
| **Kullanım alanı** | Shared memory, IPC, veritabanı dosyaları | Dosya okuma, private çalışma kopyası |

```c
// MAP_SHARED ile IPC örneği
#include <sys/mman.h>
#include <sys/wait.h>
#include <stdio.h>
#include <unistd.h>

int main() {
    // Paylasilan anonim bellek
    int *shared_counter = mmap(NULL, sizeof(int),
                                PROT_READ | PROT_WRITE,
                                MAP_SHARED | MAP_ANONYMOUS,
                                -1, 0);
    *shared_counter = 0;

    pid_t pid = fork();

    if (pid == 0) {
        // Child: counter'i artir
        (*shared_counter)++;
        printf("Child: counter = %d\n", *shared_counter);
        return 0;
    }

    wait(NULL);
    // Parent degisikligi görür (MAP_SHARED sayesinde)
    printf("Parent: counter = %d\n", *shared_counter);  // 1

    munmap(shared_counter, sizeof(int));
    return 0;
}
```

> [!tip] mmap Avantajları
> - **Zero-copy**: Veri kernel-user space arasında kopyalanmaz
> - **Lazy loading**: Sayfalar erişildikçe yüklenir (demand paging)
> - **Page cache**: Kernel dosya sayfalarını önbelleğine alır, tekrar okumalarda disk I/O olmaz
> - **Büyük dosyalar**: RAM'den büyük dosyalar bile haritalanabilir (sadece gereken sayfalar yüklenir)

---

## Copy-on-Write (CoW)

CoW, bellek sayfalarının **yazma anına kadar paylaşılmasını** sağlayan optimizasyon tekniği. `fork()` sistemi bu mekanizmaya dayanır.

```
fork() ONCESI:
Parent Process
├── Page Table ──→ Fiziksel Sayfa A (rw-)
├── Page Table ──→ Fiziksel Sayfa B (rw-)
└── Page Table ──→ Fiziksel Sayfa C (rw-)

fork() SONRASI (CoW aktif):
Parent Process                     Child Process
├── PT ──→ Fiziksel Sayfa A (r--)  ←── PT ─┤
├── PT ──→ Fiziksel Sayfa B (r--)  ←── PT ─┤  Tum sayfalar READ-ONLY
└── PT ──→ Fiziksel Sayfa C (r--)  ←── PT ─┘  ve PAYLASILIR

Child, Sayfa B'ye YAZIYOR:
Parent Process                     Child Process
├── PT ──→ Fiziksel Sayfa A (r--)  ←── PT ─┤  Hala paylasimli
├── PT ──→ Fiziksel Sayfa B (rw-)          │
│                                  ┌── PT ─┘
│                                  ▼
│                          Fiziksel Sayfa B' (rw-)  ← KOPYA olusturuldu
└── PT ──→ Fiziksel Sayfa C (r--)  ←── PT ─┘  Hala paylasimli
```

#### CoW Mekanizması Adım Adım

1. `fork()` çağrıldıktan sonra kernel, tüm parent sayfa tablosu girdilerini child'a kopyalar
2. Tüm sayfalar **read-only** olarak işaretlenir (hem parent hem child için)
3. Herhangi bir process yazmaya çalıştığında **page fault** oluşur
4. Kernel fault'u yakalar, sayfanın bir **kopyasını** oluşturur
5. Yazan process'in page table'ı yeni kopyaya işaretlenir (artık `rw-`)
6. Diğer process'in sayfası değişmez

```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>

int main() {
    // 100 MB bellek ayir
    size_t size = 100 * 1024 * 1024;
    char *buffer = malloc(size);

    // Buffer'i doldur (fiziksel sayfaların tahsis edilmesini sagla)
    memset(buffer, 'X', size);

    printf("fork() oncesi: 100 MB tahsis edildi\n");

    pid_t pid = fork();
    // fork() burada ANINDA döner — 100 MB KOPYALANMAZ
    // Sadece page table kopyalanir (~birkaç KB)

    if (pid == 0) {
        // Child: sadece ilk sayfaya yaz
        buffer[0] = 'Y';
        // Sadece 1 sayfa (4 KB) kopyalandi, 99.99 MB hala paylasimli

        printf("Child: sadece 1 sayfa kopyalandi (CoW)\n");
        free(buffer);
        return 0;
    }

    wait(NULL);
    printf("Parent: buffer[0] hala '%c'\n", buffer[0]);  // 'X'
    free(buffer);
    return 0;
}
```

> [!warning] CoW ve exec()
> `fork()` + `exec()` patterninde CoW özellikle verimlidir:
> - `fork()`: Sayfa tabloları kopyalanır, fiziksel sayfalar paylaşılır
> - `exec()`: Child'in tüm adres alanı yeni programla değiştirilir
> - Sonuç: fork sırasında hiçbir fiziksel sayfa kopyalanmaz!
> Bu yüzden `fork()` gigabyte'larca bellek kullanan process'lerde bile hızlıdır.

---

## Swap Mekanizması

Fiziksel RAM dolduğunda, kernel nadir kullanılan sayfaları **diske (swap alanına)** taşıyarak bellekte yer açar. Bu işlem sayesinde toplam kullanılabilir bellek fiziksel RAM'i aşar.

```
Fiziksel RAM doldu
        │
        ▼
Kernel "kurban" sayfaları secer (LRU benzeri algoritma)
        │
        ├─ Anonim sayfa (heap, stack) → Swap alanina yazılır
        │
        └─ File-backed sayfa (mmap) → Page cache'den dusurulur (Tekrar erisimde dosyadan okunur)
        │
        ▼
Fiziksel RAM'de yer acildi
Yeni sayfa için kullanılabilir
```

#### Swap Partition vs Swap File

| Özellik | Swap Partition | Swap File |
|---------|---------------|-----------|
| **Hız** | Biraz daha hızlı (continuous blocks) | Yeterince hızlı |
| **Esneklik** | Boyut değiştirmek zor (repartition) | Kolayca büyütülüp küçültülür |
| **Kurulum** | Disk bölümü gerekli | Herhangi bir dosya sisteminde |
| **Tavsiye** | Server'lar, sabit ortamlar | Desktop, bulut, dinamik ortamlar |

```bash
# --- Swap File Olusturma ---

# 2 GB swap dosyasi olustur
sudo fallocate -l 2G /swapfile
# veya (fallocate desteklenmiyorsa)
sudo dd if=/dev/zero of=/swapfile bs=1M count=2048

# Izinleri ayarla (sadece root erisebilmeli)
sudo chmod 600 /swapfile

# Swap alanı olarak formatla
sudo mkswap /swapfile

# Aktif et
sudo swapon /swapfile

# Kalici hale getir (/etc/fstab'a ekle)
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# --- Swap Yonetimi ---

# Aktif swap alanlarini gor
swapon --show
# NAME      TYPE  SIZE  USED PRIO
# /swapfile file    2G  128M   -2

# Swap kullanım özeti
free -h
#               total   used   free   shared  buff/cache  available
# Mem:           16G    8.5G   1.2G    512M      6.3G       6.8G
# Swap:           2G    128M   1.9G

# Swap'i devre dışı bırak
sudo swapoff /swapfile

# Tum swap'i devre dışı bırak
sudo swapoff -a
```

#### Swappiness

`swappiness` parametresi, kernel'in ne kadar agresif swap kullanacağını belirler.

```bash
# Mevcut değeri gor (0-200 arasi, varsayilan 60)
cat /proc/sys/vm/swappiness

# Gecici olarak değiştir
sudo sysctl vm.swappiness=10

# Kalici hale getir
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

| Değer | Davranış |
|-------|----------|
| **0** | Swap neredeyse hiç kullanılmaz (sadece OOM önlemek için) |
| **10** | Çok az swap — veritabanı sunucuları için önerilen |
| **60** | Varsayılan — dengeli |
| **100** | Agresif swap — anonim ve dosya sayfaları eşit öncelikli |
| **200** | (cgroup v2) Maksimum agresif swap |

> [!tip] Production Tavsiyesi
> - **Veritabanı sunucuları** (PostgreSQL, MySQL): `swappiness=10` veya daha düşük
> - **Redis/Memcached**: `swappiness=0` (latency kritik)
> - **Genel sunucu**: `swappiness=10-30`
> - Container ortamlarında swap davranışı cgroup memory limitleri ile birlikte değerlendirilmeli → [[Linux Cgroups#Swap Limiti]]

---

## OOM Killer

Sistem belleği tükendiğinde kernel **OOM (Out of Memory) Killer**'ı devreye sokar. En "uygun" process'i seçip **SIGKILL** gönderir.

```
Bellek talebi geliyor
        │
        ▼
Fiziksel RAM bos var mi? ──── Evet ──→ Tahsis et
        │
       Hayir
        │
        ▼
Swap alanı bos var mi? ──── Evet ──→ Sayfayi swap'a tasi, tahsis et
        │
       Hayir
        │
        ▼
Page cache'den yer acilabiilr mi? ──── Evet ──→ Cache'i bos at, tahsis et
        │
       Hayir
        │
        ▼
OOM Killer devreye girer
        │
        ▼
oom_score'a gore process sec ──→ SIGKILL gönder
```

```bash
# Process'in OOM score'unu gor
cat /proc/<pid>/oom_score       # Hesaplanmis skor (yüksek = önce oldurulur)
cat /proc/<pid>/oom_score_adj   # Manuel ayar (-1000 ile 1000)

# Kritik process'i OOM'dan koru
echo -1000 > /proc/<pid>/oom_score_adj

# OOM olay loglarini gor
dmesg | grep -i "oom\|killed process"

# Örnek OOM log:
# [  123.456789] Out of memory: Killed process 4567 (java)
#                total-vm:8234567kB, anon-rss:4123456kB, file-rss:1234kB
```

> [!warning] Docker ve OOM
> Container'larda memory limiti aşıldığında cgroup OOM Killer tetiklenir.
> Bu, host OOM Killer'dan **bağımsız** çalışır.
> Detaylı bilgi → [[Linux Cgroups#OOM Killer (Out of Memory Killer)]]
> ```bash
> # Container OOM olaylarini izle
> docker events --filter event=oom
>
> # Container'in OOM durumunu kontrol et
> docker inspect <container> | grep -i oom
> ```

---

## ASLR (Address Space Layout Randomization)

ASLR, process'in bellek bölgelerinin (stack, heap, mmap, shared library) adreslerini her çalıştırmada **rastgele** yerleştiren güvenlik mekanizmasıdır. Buffer overflow ve ROP (Return-Oriented Programming) saldırılarına karşı koruma sağlar.

```
ASLR KAPALI (tahmin edilebilir adresler):
Her calistirmada:
Stack:   0x7FFFFFFDE000
Heap:    0x555555559000
mmap:    0x7FFFF7D00000
Text:    0x555555554000

ASLR ACIK (rastgele adresler):
1. çalıştırma:              2. çalıştırma:
Stack:   0x7FFD2A3B1000     Stack:   0x7FFC8E4F2000
Heap:    0x5601A3200000     Heap:    0x55D7B8100000
mmap:    0x7F2B4C600000     mmap:    0x7F9A1D800000
Text:    0x5601A2E00000     Text:    0x55D7B7C00000
```

```bash
# ASLR durumunu kontrol et
cat /proc/sys/kernel/randomize_va_space

# Degerler:
# 0 = ASLR kapali
# 1 = Stack, mmap, VDSO rastgele (parcali)
# 2 = Tam ASLR — heap de rastgele (varsayilan ve onerilen)

# Gecici olarak kapat (test/debug için)
echo 0 | sudo tee /proc/sys/kernel/randomize_va_space

# Tekrar ac
echo 2 | sudo tee /proc/sys/kernel/randomize_va_space

# Tek bir program için ASLR'yi kapat
setarch $(uname -m) -R ./myapp
```

```c
// ASLR'nin etkisini gorme
#include <stdio.h>
#include <stdlib.h>

int global_var;

int main() {
    int stack_var;
    int *heap_var = malloc(1);

    printf("Text  (main):     %p\n", (void *)main);
    printf("Data  (global):   %p\n", (void *)&global_var);
    printf("Heap  (malloc):   %p\n", (void *)heap_var);
    printf("Stack (local):    %p\n", (void *)&stack_var);
    printf("libc  (printf):   %p\n", (void *)printf);

    free(heap_var);
    return 0;
}
```

```bash
# Iki kez calistirdiginda farkli adresler gorursun (ASLR=2 iken)
gcc -o aslr_test aslr_test.c && ./aslr_test && echo "---" && ./aslr_test

# PIE (Position Independent Executable) ile derlenmis binary'lerde
# text segment de rastgele olur (modern gcc varsayilani)
gcc -pie -o aslr_test aslr_test.c

# PIE olmadan (text sabit kalir)
gcc -no-pie -o aslr_test aslr_test.c
```

> [!warning] ASLR ve Güvenlik
> - ASLR **tek başına yeterli değildir** — entropy düşüklüğü brute-force'a açık olabilir
> - **PIE** (Position Independent Executable) ile birlikte kullanılmalı
> - **Stack canary**, **NX bit**, **RELRO** gibi diğer korumalarla katmanlı savunma oluşturur
> - Container içinde ASLR **host kernel** tarafından yönetilir — container'dan kapatılamaz

---

## Kernel Memory Allocator'lar

Kernel, fiziksel belleği verimli yönetmek için iki ana mekanizma kullanır: **Buddy System** ve **Slab Allocator**.

#### Buddy System (Sayfa Tahsis)

Buddy system, fiziksel belleğin **sayfa (page)** birimlerinde tahsis edilmesini sağlar. Sayfalar 2^n boyutunda bloklara ayrılır.

```
Buddy System çalışması (basitleştirilmiş):

Baslangic: 16 sayfa'lik bos blok
[________________]  (2^4 = 16 sayfa, order 4)

4 sayfa talep edildi (order 2):
[____][____][________]
 ^     ^     ^
 A     bos   bos (order 3)
 (tahsis edildi)

Serbest birakma:
A serbest birakildi → komsularla birlestirilir (buddy merge)
[________________]  (tekrar 16 sayfa'lik blok)
```

```bash
# Buddy system durumunu gor
cat /proc/buddyinfo
# Node 0, zone   Normal  12541  6230  3215  1580  790  420  210  105  52  26  13
#                         2^0    2^1   2^2   2^3  ...               2^9  2^10
# Her sayi o boyuttaki bos blok adedini gösterir
```

| Order | Boyut | Kullanım |
|-------|-------|----------|
| 0 | 4 KB (1 sayfa) | Tek sayfa tahsisi |
| 1 | 8 KB (2 sayfa) | Küçük yapılar |
| 2 | 16 KB (4 sayfa) | Stack (varsayılan 2 sayfa, bazı arch'lerde 4) |
| ... | ... | ... |
| 9 | 2 MB (512 sayfa) | Huge page |
| 10 | 4 MB (1024 sayfa) | Maksimum buddy tahsisi |

#### Slab Allocator

Buddy system **sayfa boyutunda** tahsis yapar. Ama kernel sürekli küçük nesneler oluşturur (inode, dentry, task_struct gibi). Her biri için tam sayfa ayırmak israf olur. **Slab allocator**, aynı boyuttaki nesneler için önbellekler (cache) oluşturarak bu sorunu çözer.

```
Slab Allocator yapısı:

Cache: "task_struct" (örnek boyut: 6 KB)
┌────────────────────────────────────────────────┐
│  Slab 1 (1 veya daha fazla sayfa)              │
│  ┌──────┬──────┬──────┬──────┬──────┬──────┐   │
│  │ obj  │ obj  │ obj  │ obj  │ obj  │ bos  │   │
│  │(kullanımda) (kullanımda) (bos)   │      │   │
│  └──────┴──────┴──────┴──────┴──────┴──────┘   │
├────────────────────────────────────────────────┤
│  Slab 2                                        │
│  ┌──────┬──────┬──────┬──────┬──────┬──────┐   │
│  │ bos  │ bos  │ bos  │ bos  │ bos  │ bos  │   │
│  └──────┴──────┴──────┴──────┴──────┴──────┘   │
└────────────────────────────────────────────────┘

kmalloc(size) → uygun boyuttaki slab cache'inden nesne al
kfree(ptr)    → nesneyi slab cache'ine geri ver (belleği OS'e dondurmez)
```

```bash
# Slab cache istatistikleri
sudo cat /proc/slabinfo | head -20
# name            <active_objs> <num_objs> <objsize> <objperslab> <pagesperslab>
# task_struct          1234       1280       6016           5            8
# inode_cache          8500       8520        608          26            4
# dentry              15000      15120        192          21            1

# Daha okunakli format
sudo slabtop -s c   # Cache boyutuna gore sirala

# Kernel bellek tahsis fonksiyonları:
# kmalloc(size, flags)  → genel amaçlı kernel bellek tahsisi
# kfree(ptr)            → serbest birakma
# kmem_cache_create()   → özel nesne cache'i oluşturma
# kmem_cache_alloc()    → cache'den nesne alma
```

> [!info] SLUB vs SLAB vs SLOB
> Linux kernel'inde üç farklı slab implementasyonu vardır:
> - **SLAB**: Orijinal, karmaşık, büyük sistemler için
> - **SLUB**: Modern varsayılan (Linux 2.6.23+), daha basit ve hızlı
> - **SLOB**: Gömülü sistemler için minimalist
> Çoğu modern dağıtım **SLUB** kullanır.

---

## User-Space Memory Allocator'lar

User-space programlar belleği `malloc()` ile alır. `malloc()`, kernel'den ham sayfa alıp kullanıcıya küçük bloklar halinde sunan bir **kütüphane fonksiyonudur**.

#### malloc() Internals — brk vs mmap

```
malloc() arka planda iki yöntem kullanir:

Kucuk tahsisler (< MMAP_THRESHOLD, varsayilan 128 KB):
  malloc(64) → brk()/sbrk() ile heap'i genisletir
  ┌──────────────────────────┐
  │  HEAP                    │
  │  ┌────┬────┬────┬────┐   │
  │  │ 64B│128B│ 32B│bos │   │  ← brk pointer'i saga kayar
  │  └────┴────┴────┴────┘   │
  └──────────────────────────┘

Buyuk tahsisler (>= MMAP_THRESHOLD):
  malloc(256KB) → mmap(MAP_ANONYMOUS) ile ayri bölge oluşturur
  ┌──────────────────────────┐
  │  mmap region (256 KB)    │  ← Dogrudan kernel'den
  │  free() ile munmap()     │  ← Hemen OS'e döner
  └──────────────────────────┘
```

```c
#include <stdio.h>
#include <stdlib.h>
#include <malloc.h>  // mallopt için

int main() {
    // MMAP_THRESHOLD'u değiştir
    mallopt(M_MMAP_THRESHOLD, 64 * 1024);  // 64 KB

    // Bu brk ile tahsis edilir (< 64 KB)
    void *small = malloc(32 * 1024);

    // Bu mmap ile tahsis edilir (>= 64 KB)
    void *large = malloc(128 * 1024);

    // malloc istatistikleri
    malloc_stats();  // stderr'e basar
    // Arena 0:
    // system bytes =   ...
    // in use bytes =   ...

    free(small);
    free(large);
    return 0;
}
```

> [!warning] free() ve Bellek İadesi
> `free()` **çoğu zaman belleği OS'e iade etmez!**
> - brk ile alınmış bellek: `free()` listeye ekler, sonraki `malloc()` için yeniden kullanır
> - Sadece heap'in **tepesindeki** boş blok `brk()` ile geri çekilebilir
> - mmap ile alınmış büyük bloklar: `free()` hemen `munmap()` yapar → OS'e döner
> - Bu yüzden process'in RSS'i `free()` sonrası düşmeyebilir (`malloc_trim(0)` zorlar)

#### jemalloc ve tcmalloc

Standart glibc malloc, çoklu thread ortamlarında **kilit çatışması (lock contention)** nedeniyle yavaşlayabilir. Alternatif allocator'lar bu sorunu çözer.

| Özellik | glibc malloc | jemalloc | tcmalloc |
|---------|-------------|----------|----------|
| **Geliştirici** | GNU | Facebook/Meta | Google |
| **Thread performansı** | Orta (arena'lar) | Çok iyi | Çok iyi |
| **Fragmentasyon** | Orta-yüksek | Düşük | Düşük |
| **Profiling** | malloc_stats() | MALLOC_CONF | HEAPPROFILE |
| **Kullananlar** | Varsayılan | Redis, Rust, Firefox | Go runtime, gperftools |
| **LD_PRELOAD** | — | `LD_PRELOAD=libjemalloc.so` | `LD_PRELOAD=libtcmalloc.so` |

```bash
# jemalloc ile çalıştırma (uygulamayi değiştirmeden)
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so ./myapp

# jemalloc profiling
MALLOC_CONF="prof:true,prof_prefix:jeprof" LD_PRELOAD=libjemalloc.so ./myapp

# tcmalloc ile çalıştırma
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc.so ./myapp

# tcmalloc heap profiling
HEAPPROFILE=/tmp/myapp.hprof LD_PRELOAD=libtcmalloc.so ./myapp
google-pprof --text ./myapp /tmp/myapp.hprof.0001.heap
```

> [!tip] Allocator Seçimi
> - **Genel amaç**: glibc malloc yeterli
> - **Yüksek thread sayısı**: jemalloc veya tcmalloc
> - **Redis**: jemalloc varsayılan ve önerilen
> - **Container'lar**: Allocator seçimi `LD_PRELOAD` ile runtime'da değiştirilebilir
>   → [[Linux Dynamic Libraries#LD_PRELOAD]]

---

## /proc ile Memory Analizi

#### /proc/meminfo

Sistem genelindeki bellek durumunu gösterir.

```bash
cat /proc/meminfo
```

| Alan | Açıklama |
|------|----------|
| **MemTotal** | Toplam fiziksel RAM |
| **MemFree** | Tamamen boş RAM (düşük olması normal) |
| **MemAvailable** | Uygulamaların kullanabileceği tahmini boş bellek (free + reclaimable cache) |
| **Buffers** | Block device I/O için tampon |
| **Cached** | Page cache (dosya içerikleri) |
| **SwapTotal** | Toplam swap alanı |
| **SwapFree** | Boş swap alanı |
| **Dirty** | Diske yazılmayı bekleyen sayfa miktarı |
| **Slab** | Kernel slab allocator kullanımı |
| **SReclaimable** | Geri alınabilir slab belleği |
| **SUnreclaim** | Geri alınamayan slab belleği |
| **PageTables** | Page table'lar için kullanılan bellek |
| **Committed_AS** | Tahsis edilen toplam sanal bellek (overcommit) |
| **VmallocTotal** | Toplam vmalloc alanı |
| **HugePages_Total** | Toplam huge page sayısı |
| **HugePages_Free** | Boş huge page sayısı |

> [!tip] MemFree vs MemAvailable
> `MemFree` düşük olması **sorun değildir**. Linux boş RAM'i page cache olarak kullanır.
> **MemAvailable** daha doğru bir metrik — uygulamaların gerçekte kullanabileceği belleği gösterir.
> `MemAvailable` düşükse endişelenin, `MemFree` düşükse normal.

#### /proc/\<pid\>/maps

Process'in sanal adres alanındaki tüm haritalanmış bölgeleri gösterir.

```bash
cat /proc/<pid>/maps

# Örnek çıktı:
# adres araligi         izinler offset  device  inode   dosya yolu
55a3c4400000-55a3c4401000 r--p 00000000 08:01 1234567  /usr/bin/myapp    # ELF header
55a3c4401000-55a3c4405000 r-xp 00001000 08:01 1234567  /usr/bin/myapp    # Text (kod)
55a3c4405000-55a3c4406000 r--p 00005000 08:01 1234567  /usr/bin/myapp    # Read-only data
55a3c4406000-55a3c4407000 rw-p 00006000 08:01 1234567  /usr/bin/myapp    # Data + BSS
55a3c5292000-55a3c52b3000 rw-p 00000000 00:00 0        [heap]
7f2b4c600000-7f2b4c7c0000 r-xp 00000000 08:01 2345678  /lib/x86_64-linux-gnu/libc.so.6
...
7ffc8a39e000-7ffc8a3bf000 rw-p 00000000 00:00 0        [stack]
7ffc8a3d4000-7ffc8a3d8000 r--p 00000000 00:00 0        [vvar]
7ffc8a3d8000-7ffc8a3da000 r-xp 00000000 00:00 0        [vdso]
```

| İzin | Anlam |
|------|-------|
| `r` | Okunabilir |
| `w` | Yazılabilir |
| `x` | Çalıştırılabilir |
| `p` | Private (MAP_PRIVATE — CoW) |
| `s` | Shared (MAP_SHARED) |

#### /proc/\<pid\>/smaps

`maps`'in genişletilmiş versiyonu — her bölge için detaylı bellek kullanımını gösterir.

```bash
cat /proc/<pid>/smaps

# Örnek bolge:
# 55a3c5292000-55a3c52b3000 rw-p 00000000 00:00 0  [heap]
# Size:                132 kB    ← Sanal boyut
# KernelPageSize:        4 kB
# MMUPageSize:           4 kB
# Rss:                  96 kB    ← Fiziksel bellekte olan kisim
# Pss:                  96 kB    ← Proportional (paylaşım dahil)
# Shared_Clean:          0 kB
# Shared_Dirty:          0 kB
# Private_Clean:         0 kB
# Private_Dirty:        96 kB    ← Bu process'e özel dirty sayfalar
# Referenced:           96 kB
# Anonymous:            96 kB    ← Dosya ile iliskilendirilmemis
# Swap:                  0 kB    ← Swap'a giden miktar

# Ozet gormek için (smaps_rollup)
cat /proc/<pid>/smaps_rollup
```

> [!info] RSS vs PSS vs VSS
> - **VSS** (Virtual Set Size): Toplam sanal adres alanı (her zaman en büyük, yanıltıcı)
> - **RSS** (Resident Set Size): Fiziksel bellekteki toplam (paylaşılan sayfalar her process'te sayılır)
> - **PSS** (Proportional Set Size): Paylaşılan sayfalar process sayısına bölünür (en doğru metrik)
> - **USS** (Unique Set Size): Sadece bu process'e özel sayfalar
>
> Örnek: libc.so 10 process tarafından paylaşılıyor, 2 MB
> RSS'te her process için 2 MB, PSS'te her process için 200 KB sayılır.

---

## Pratik Komutlar

#### free — Sistem Bellek Özeti

```bash
free -h
#               total   used   free   shared  buff/cache  available
# Mem:           16G    8.5G   1.2G    512M      6.3G       6.8G
# Swap:           2G    128M   1.9G

# Periyodik izleme
free -h -s 2   # Her 2 saniyede güncelle
```

```
free çıktısı yorumu:

total   = Toplam fiziksel RAM
used    = Kullanilan (process'ler + kernel)
free    = Tamamen bos (düşük olması NORMAL)
shared  = tmpfs + shared memory
buff/cache = Buffer + page cache (gerektiğinde bosalinir)
available  = Uygulamalar için kullanılabilir tahmini miktar

available ≈ free + reclaimable buff/cache
```

#### vmstat — Sanal Bellek İstatistikleri

```bash
vmstat 1 5    # Her 1 saniyede, 5 kez ornekle

# procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
#  r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
#  2  0  12800 120000  45000 650000    0    0    10    25  500 1200 15  3 80  2  0
#  1  0  12800 118000  45000 652000    0    0     0     8  480 1100 12  2 85  1  0
```

| Sütun | Açıklama | Dikkat Edilecek |
|-------|----------|-----------------|
| `r` | CPU bekleyen process sayısı | > CPU sayısı ise CPU doymuş |
| `b` | I/O bekleyen (blocked) process | Yüksekse disk darboğazı |
| `swpd` | Kullanılan swap (KB) | Artıyorsa bellek yetersiz |
| `si` | Swap in (diskten RAM'e, KB/s) | > 0 ise major page fault oluyor |
| `so` | Swap out (RAM'den diske, KB/s) | > 0 ise bellek basıncı var |
| `bi` | Disk block in (KB/s) | Disk okuma aktivitesi |
| `bo` | Disk block out (KB/s) | Disk yazma aktivitesi |
| `us` | User CPU % | Uygulama yükleri |
| `sy` | System (kernel) CPU % | Yüksekse syscall yoğun |
| `wa` | I/O wait CPU % | Yüksekse disk yavaş |

> [!warning] si/so Alarmı
> `si` ve `so` sütunlarında **sürekli sıfırdan büyük değerler** görüyorsanız, sistem aktif olarak swap kullanıyor demektir. Bu ciddi performans düşüşüne (thrashing) yol açar.
> Çözümler:
> - Daha fazla RAM ekle
> - Bellek tüketimi yüksek process'leri bul: `ps aux --sort=-%mem | head`
> - Swappiness'i düşür
> - Cgroup memory limitleri gözden geçir → [[Linux Cgroups#Memory Kontrolü]]

#### pmap — Process Memory Map

```bash
# Process'in bellek haritasi
pmap <pid>
# Adres           Kbytes  RSS    Dirty  Mode  Mapping
# 000055a3c4400000     4     4      0   r---- myapp
# 000055a3c4401000    16    16      0   r-x-- myapp
# 000055a3c5292000   132    96     96   rw---   [ anon ]  ← heap
# 00007f2b4c600000  1856  1200      0   r-x-- libc.so.6
# 00007ffc8a39e000   132    32     32   rw---   [ stack ]
# Total:           12345  4567    234

# Detaylı çıktı
pmap -x <pid>

# Genişletilmiş (RSS, PSS, swap dahil)
pmap -XX <pid>
```

#### valgrind — Bellek Hata Tespiti

```bash
# Memory leak tespiti
valgrind --leak-check=full ./myapp

# Örnek çıktı:
# ==1234== HEAP SUMMARY:
# ==1234==     in use at exit: 1,024 bytes in 1 blocks
# ==1234==   total heap usage: 10 allocs, 9 frees, 2,048 bytes allocated
# ==1234==
# ==1234== 1,024 bytes in 1 blocks are definitely lost in loss record 1 of 1
# ==1234==    at 0x4C2BBAF: malloc (vg_replace_malloc.c:299)
# ==1234==    by 0x401234: process_data (main.c:42)
# ==1234==    by 0x401456: main (main.c:78)

# Geçersiz bellek erişimi tespiti
valgrind --tool=memcheck ./myapp

# ==1234== Invalid read of size 4
# ==1234==    at 0x401234: main (main.c:15)
# ==1234==  Address 0x5205044 is 0 bytes after a block of size 4 alloc'd

# Cache profiling (performans analizi)
valgrind --tool=cachegrind ./myapp

# Detaylı heap profiling
valgrind --tool=massif ./myapp
ms_print massif.out.<pid>
```

> [!tip] valgrind Alternatifleri
> - **AddressSanitizer (ASan)**: Derleme zamanında, valgrind'den ~2-5x hızlı
>   ```bash
>   gcc -fsanitize=address -g -o myapp myapp.c
>   ./myapp   # Hata varsa otomatik raporlar
>   ```
> - **LeakSanitizer (LSan)**: Sadece leak tespiti
>   ```bash
>   gcc -fsanitize=leak -g -o myapp myapp.c
>   ```
> - valgrind runtime overhead: **10-50x yavaşlatır** (production'da kullanılmaz)
> - ASan overhead: **~2x** (CI/CD testlerinde kullanılabilir)
> Daha fazla debugging aracı → [[Linux Debugging Araçları]]

---

## Overcommit ve Memory Accounting

Linux varsayılan olarak **overcommit** yapar — fiziksel bellekten fazla sanal bellek tahsis edilmesine izin verir. Çünkü çoğu program ayırdığı belleğin tamamını kullanmaz.

```bash
# Overcommit politikasi
cat /proc/sys/vm/overcommit_memory

# 0 = Heuristic (varsayilan) — "makul" miktarda overcommit izin verilir
# 1 = Her zaman izin ver (TEHLIKELI — malloc asla başarısız olmaz)
# 2 = Katı — CommitLimit'i asma (swap + RAM * overcommit_ratio)

cat /proc/sys/vm/overcommit_ratio   # Varsayilan: 50 (%)
# overcommit_memory=2 iken:
# CommitLimit = SwapTotal + (PhysicalRAM * overcommit_ratio / 100)

# Mevcut commit durumu
grep -i commit /proc/meminfo
# CommitLimit:    12345678 kB   ← İzin verilen maksimum
# Committed_AS:    8765432 kB   ← Su an tahsis edilen
```

> [!warning] Overcommit = 1 Tehlikesi
> `overcommit_memory=1` ayarında `malloc()` **hiçbir zaman NULL dönmez**.
> Ancak gerçekte bellek tükendiğinde OOM Killer beklenmedik process'leri öldürür.
> Production sistemlerde `0` (heuristic) veya `2` (strict) kullanın.

---

## Özet ve Hızlı Referans

```
Virtual Memory Buyuk Resim:

Process ──→ Sanal Adres ──→ MMU (TLB + Page Table) ──→ Fiziksel Adres
                                    │
                                    ├─ TLB Hit → Hizli erişim
                                    ├─ TLB Miss → Page table walk
                                    ├─ Minor Fault → Sayfa bellekte, tablo güncelle
                                    ├─ Major Fault → Sayfa diskten yükle (yavaş!)
                                    └─ Invalid → SIGSEGV (crash)

Bellek Hiyerarsisi:
CPU Register (< 1ns) → L1 Cache (~1ns) → L2 Cache (~3ns) → L3 Cache (~10ns)
→ RAM (~100ns) → SSD (~100us) → HDD (~10ms)
```

| Kavram | Temel Bilgi |
|--------|------------|
| **Virtual Address Space** | Her process'e özel, izole adres alanı |
| **Page Table** | Sanal → fiziksel adres çevirisi (4 seviye, x86-64) |
| **TLB** | Sayfa çevirimi önbelleği (hardware) |
| **Page Fault** | Minor (bellekte, hızlı) vs Major (diskten, yavaş) |
| **mmap()** | Dosya/anonim belleği adres alanına haritala |
| **CoW** | fork() ile paylaşım, yazma anında kopyalama |
| **Swap** | RAM taştığında disk üzerine sayfa taşıma |
| **OOM Killer** | Bellek tükendiğinde process öldürme mekanizması |
| **ASLR** | Adres rastgeleleştirme (güvenlik) |

| **Buddy System** | Fiziksel sayfa tahsisi (2^n bloklar) |
| **Slab Allocator** | Kernel küçük nesne tahsisi (kmalloc/kfree) |
| **malloc** | User-space tahsis (brk < 128KB, mmap >= 128KB) |

```bash
# Hizli tani komutları
free -h                          # Sistem bellek özeti
vmstat 1                         # Canli swap/io/cpu izleme
pmap -x <pid>                    # Process bellek haritasi
cat /proc/<pid>/smaps_rollup     # Process bellek özeti (PSS dahil)
cat /proc/meminfo                # Detayli sistem bellek bilgisi
cat /proc/buddyinfo              # Buddy system durumu
sudo slabtop                     # Slab allocator izleme
valgrind --leak-check=full ./app # Memory leak tespiti
```
