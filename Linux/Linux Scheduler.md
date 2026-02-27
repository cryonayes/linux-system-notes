Linux kernel'inde **scheduler**, CPU zamanını process'ler arasında **adil ve verimli** bir şekilde paylaştıran alt sistemdir. Birden fazla process'in aynı anda çalışıyormuş gibi görünmesini sağlayan **preemptive multitasking** mekanizmasının kalbidir.

> [!info] İlişkili
> Process durumları ve yaşam döngüsü --> [[Linux Process Management]]
> Container CPU sınırlandırması --> [[Linux Cgroups#CPU Kontrolü]]
> Container izolasyonu --> [[Docker Temelleri]]
> Namespace kavramı --> [[Linux Namespaces]]

---

## Scheduler Nedir?

Modern sistemlerde CPU sayısı, aynı anda çalışmak isteyen process sayısından **çok daha azdır**. Scheduler, hangi process'in ne zaman ve ne kadar süre CPU'da çalışacağını belirler.

```
4 process, 1 CPU:

Zaman -->
 ┌─────┐     ┌─────┐           ┌─────┐
 │  P1 │     │  P1 │           │  P1 │
 ├─────┤     ├─────┤     ┌─────┤─────┤
 │  P2 │     │  P2 │     │  P2 │     │
 ├─────┤─────┤─────┤─────┤─────┤     │
 │  P3 │  P3 │     │  P3 │     │     │
 ├─────┤─────┤─────┤─────┤─────┤─────┤
 │  P4 │  P4 │  P4 │  P4 │  P4 │  P4 │
 └─────┘─────┘─────┘─────┘─────┘─────┘
  t0    t1    t2    t3    t4    t5    t6
```

#### Preemptive Multitasking

Linux **preemptive** bir scheduler kullanır. Yani bir process CPU'yu gönüllü bırakmasa bile kernel onu **zorla** durdurabilir ve başka bir process'e CPU verebilir.

```
Cooperative (eski yöntem):
  Process çalışması bitene kadar bekle --> Bir process takilirsa sistem donar

Preemptive (Linux):
  Timer interrupt --> Kernel devreye girer --> Gerekirse process değiştirilir
  Process takilsa bile kernel müdahale eder
```

**Scheduler'in temel görevleri:**
- Hangi process çalışacak? (picking)
- Ne kadar süre çalışacak? (time slice / quantum)
- Ne zaman başka process'e geçilecek? (preemption)
- Birden fazla CPU varsa hangi CPU'ya atanacak? (load balancing)

---

## CFS (Completely Fair Scheduler)

Linux 2.6.23'ten (2007) itibaren varsayılan scheduler **CFS**'dir. Ingo Molnar tarafından yazılmıştır. Temel felsefesi: **her process'e CPU zamanını adil dağıt**.

#### vruntime Kavramı

CFS her process için bir **virtual runtime (vruntime)** değeri tutar. Bu değer, process'in ne kadar CPU zamanı tükettiğinin **ağırlıklı** ölçümüdür.

```
vruntime = gerçek_çalışma_süresi * (NICE_0_WEIGHT / process_weight)

Dusuk vruntime  = az CPU kullanmis   = öncelik verilir
Yuksek vruntime = çok CPU kullanmis  = bekletilir
```

**Örnek:**
```
Process A (nice 0, weight=1024): 10ms calisti --> vruntime = 10ms
Process B (nice 5, weight=335):  10ms calisti --> vruntime = 10 * (1024/335) = ~30.6ms
Process C (nice -5, weight=3121): 10ms calisti --> vruntime = 10 * (1024/3121) = ~3.3ms

Siradaki calisacak process: en düşük vruntime'a sahip olan --> C
```

> [!tip] Temel Kural
> CFS her zaman **en düşük vruntime** değerine sahip process'i seçer. Yüksek öncelikli process'lerin vruntime'i daha yavaş artar, bu sayede daha fazla CPU zamanı alırlar.

#### Red-Black Tree

CFS, process'leri vruntime değerine göre **red-black tree** (kendini dengeleyen ikili ağaç) yapısında tutar. Bu sayede en düşük vruntime'li process'i bulmak **O(1)** (en sol düğüm), ekleme/çıkarma ise **O(log n)** karmaşıklığındadır.

```
                     vruntime=50 (siyah)
                    /                    \
           vruntime=30 (kirmizi)    vruntime=70 (kirmizi)
           /          \                /          \
     vruntime=20    vruntime=40   vruntime=60   vruntime=80
      (siyah)        (siyah)      (siyah)       (siyah)
         ^
         |
    En sol dugum = siradaki calisacak process
```

#### CFS Kaynak Kodu (Basitleştirilmiş)

```c
// kernel/sched/fair.c - CFS'in temel pick fonksiyonu (kavramsal)

struct sched_entity {
    u64                 vruntime;       // sanal çalışma süresi
    struct rb_node      run_node;       // red-black tree dugumu
    unsigned long       weight;         // nice degerine karşılık gelen ağırlık
    u64                 exec_start;     // son çalışma başlangıç zamani
};

// En düşük vruntime'li entity'yi sec
static struct sched_entity *pick_next_entity(struct cfs_rq *cfs_rq) {
    struct rb_node *left = rb_first_cached(&cfs_rq->tasks_timeline);
    struct sched_entity *se = rb_entry(left, struct sched_entity, run_node);
    return se;
}

// vruntime güncelle
static void update_curr(struct cfs_rq *cfs_rq) {
    struct sched_entity *curr = cfs_rq->curr;
    u64 now = rq_clock_task(rq);
    u64 delta_exec = now - curr->exec_start;

    // Agirlik hesaba katilarak vruntime guncellenir
    curr->vruntime += calc_delta_fair(delta_exec, curr);
    curr->exec_start = now;
}
```

#### Weight / Nice Mapping Tablosu

CFS, nice değerlerini ağırlığa (weight) dönüştürür. Her nice seviyesi yaklaşık **%10 CPU payı farkına** denk gelir.

| Nice | Weight | Oran (nice 0'a göre) |
|------|--------|----------------------|
| -20 | 88761 | ~86.7x |
| -15 | 29154 | ~28.5x |
| -10 | 9548 | ~9.3x |
| -5 | 3121 | ~3.0x |
| 0 | 1024 | 1.0x (referans) |
| 5 | 335 | ~0.33x |
| 10 | 110 | ~0.11x |
| 15 | 36 | ~0.035x |
| 19 | 15 | ~0.015x |

> [!warning] Doğrusal Değil
> Nice değerleri **doğrusal değil, logaritmiktir**. nice 0 ile nice 1 arasındaki fark, nice 18 ile nice 19 arasındaki farkla aynıdır (yaklaşık %10 CPU payı).

---

## Nice Values

Nice değeri bir process'in **kullanıcı alanı önceliğidir**. `-20` (en yüksek öncelik) ile `19` (en düşük öncelik) arasında değişir.

```
Nice Degerleri:
-20 ───────────────── 0 ───────────────── 19
 ^                    ^                   ^
 |                    |                   |
En yüksek öncelik     Normal öncelik      En düşük öncelik
```

#### nice Komutu (Başlangıçta Ayarla)

```bash
# Normal oncelikle çalışır (nice 0)
./heavy_computation

# Dusuk oncelikle başlat (nice 10)
nice -n 10 ./heavy_computation

# Yuksek oncelikle başlat (sadece root)
sudo nice -n -15 ./critical_service

# En düşük oncelikle başlat (arka plan ısı)
nice -n 19 ./backup_script.sh
```

#### renice Komutu (Çalışırken Değiştir)

```bash
# PID ile değiştir
renice -n 5 -p 1234

# Kullanicinin tüm process'lerini değiştir
renice -n 10 -u www-data

# Process grubunu değiştir
renice -n 15 -g 5000

# Root olmadan sadece nice artirabilirsiniz (öncelik düşürme)
renice -n 10 -p 1234     # Normal kullanıcı yapabilir (0 -> 10)
renice -n -5 -p 1234     # Sadece root yapabilir
```

#### Kernel Priority Hesabı

```
Kernel priority = 120 + nice

nice -20  -->  priority 100  (en yüksek)
nice 0    -->  priority 120  (normal)
nice 19   -->  priority 139  (en düşük)

Real-time priority aralık: 0-99 (ayri mekanizma)
Normal priority aralık:  100-139 (nice ile kontrol)
```

```bash
# Process'in nice ve priority degerini gor
ps -eo pid,ni,pri,comm | head -20

# /proc'dan okuma
cat /proc/<pid>/stat | awk '{print "Priority:", $18, "Nice:", $19}'
```

> [!tip] Docker'da Nice
> ```bash
> # Container içinde nice ayarla
> docker run --cap-add=SYS_NICE myapp
> # Bu capability olmadan container içinde renice calistiramzsiniz
> ```

---

## Scheduling Policy'ler

Linux kernel birden fazla scheduling policy destekler. Her biri farklı iş yükleri için optimize edilmiştir.

| Policy | Sınıf | Açıklama | Öncelik | Kullanım Alanı |
|--------|-------|----------|---------|----------------|
| `SCHED_OTHER` | Normal (CFS) | Varsayılan policy, CFS kullanır | nice -20..19 | Genel amaçlı uygulamalar |
| `SCHED_BATCH` | Normal (CFS) | CPU-intensive batch işler | nice -20..19 | Derleme, veri işleme |
| `SCHED_IDLE` | Normal (CFS) | Çok düşük öncelik | - | Sadece sistem boşta iken çalışır |
| `SCHED_FIFO` | Real-time | İlk giren ilk çalışır, preemption yok | 1..99 | Gerçek zamanlı kontrol |
| `SCHED_RR` | Real-time | Round-robin, time slice ile | 1..99 | Gerçek zamanlı, adil dağıtım |
| `SCHED_DEADLINE` | Deadline | EDF (Earliest Deadline First) | - | Periyodik gerçek zamanlı işler |

```
Oncelik Hiyerarsisi:

SCHED_DEADLINE  (en yüksek - her seyi preempt eder)
       |
SCHED_FIFO / SCHED_RR  (real-time, priority 1-99)
       |
SCHED_OTHER / SCHED_BATCH  (normal, CFS, nice -20..19)
       |
SCHED_IDLE  (en düşük - sadece bos CPU'da çalışır)
```

#### SCHED_OTHER (CFS)

```bash
# Varsayilan policy - özel bir sey yapmaya gerek yok
./myapp

# Policy'yi dogrula
chrt -p <pid>
# pid <pid>'s current scheduling policy: SCHED_OTHER
# pid <pid>'s current scheduling priority: 0
```

#### SCHED_BATCH

İnteraktif olmayan, CPU yoğun işler için. CFS kullanır ama scheduler wake-up penaltı uygulamaz.

```bash
# Batch modda başlat
chrt -b 0 ./compile_project.sh

# veya
schedtool -B <pid>
```

#### SCHED_IDLE

Sadece başka hiçbir process CPU istemiyorsa çalışır.

```bash
chrt -i 0 ./background_indexer
```

#### Policy Değiştirme (Programatik)

```c
#include <sched.h>
#include <stdio.h>

int main() {
    struct sched_param param;

    // Mevcut policy'yi oku
    int policy = sched_getscheduler(0);  // 0 = current process
    printf("Mevcut policy: %d\n", policy);

    // SCHED_FIFO'ya geçiş (root gerekli)
    param.sched_priority = 50;
    if (sched_setscheduler(0, SCHED_FIFO, &param) == -1) {
        perror("sched_setscheduler");
        return 1;
    }

    // SCHED_OTHER'a geri don
    param.sched_priority = 0;  // SCHED_OTHER için priority 0 olmali
    sched_setscheduler(0, SCHED_OTHER, &param);

    return 0;
}
```

---

## Context Switch

Context switch, CPU'nun bir process'ten diğerine geçiş yapması işlemidir. Scheduler yeni bir process seçtiğinde, mevcut process'in durumu kaydedilir ve yeni process'in durumu yüklenir.

#### Ne Kaydedilir?

```
Context Switch Sirasinda Kaydedilen/Yuklenen:

Hardware Context (CPU Register'lari):
├── Genel amaçlı register'lar (RAX, RBX, RCX, ... x86-64'te 16 adet)
├── Program Counter (RIP) - siradaki instruction adresi
├── Stack Pointer (RSP) - stack'in basi
├── RFLAGS - CPU flag'leri (carry, zero, sign, overflow)
├── Segment register'lari (CS, DS, SS, ES, FS, GS)
└── FPU/SSE/AVX register'lari (floating point state)

Kernel State:
├── Page table pointer (CR3 register) - sanal bellek mapping
├── Kernel stack pointer
└── Thread-local storage (TLS)

Dolayli Etkiler:
├── TLB flush (Translation Lookaside Buffer temizlenir)
├── CPU cache pollution (L1/L2/L3 cache'ler etkisiz kalir)
└── Branch predictor state kaybolur
```

#### Context Switch Maliyeti

```
Direkt maliyet:   ~1-5 mikrosaniye (register kaydet/yükle)
Dolayli maliyet:  ~5-30+ mikrosaniye (cache miss, TLB miss)

TLB miss maliyeti:
  Sayfa tablosunda yurume (page walk): ~100-200 cycle
  Buyuk sayfalarda (hugepages): daha az TLB miss

Cache miss zincirleme etkisi:
  L1 cache miss:  ~4 cycle
  L2 cache miss:  ~10 cycle
  L3 cache miss:  ~40 cycle
  RAM erişimi:    ~200+ cycle
```

> [!warning] Performans Etkisi
> Çok sık context switch = performans kaybı. Özellikle farklı process'ler arasındaki geçişler pahalıdır (TLB flush gerekir). Aynı process'in thread'leri arasındaki geçişler daha ucuzdur (aynı address space, TLB flush gerekmez).

#### Voluntary vs Involuntary Context Switch

```
Voluntary (Gonullu):
  Process kendisi CPU'yu bırakır
  - I/O beklerken (read, write, recv, ...)
  - sleep(), nanosleep(), usleep()
  - Mutex/semaphore beklerken
  - sched_yield() cagrisi

Involuntary (Zorunlu):
  Kernel zorla process'i durdurur
  - Time slice (quantum) doldu
  - Daha yüksek öncelikli process çalışabilir oldu
  - Timer interrupt tetiklendi
```

```bash
# Process'in context switch istatistikleri
cat /proc/<pid>/status | grep ctxt
# voluntary_ctxt_switches:    1500
# nonvoluntary_ctxt_switches: 230

# Sistem geneli context switch hızı
vmstat 1
# procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
#  r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
#  1  0      0 123456  12345 234567    0    0     0     0  500 1200  5  2 93  0  0
#                                                           ^^  ^^
#                                               interrupts  |   context switches
```

```bash
# perf ile context switch analizi
sudo perf stat -e context-switches,cpu-migrations ./myapp
# Performance counter stats for './myapp':
#     1,234  context-switches
#        12  cpu-migrations
```

---

## CPU Affinity

CPU affinity, bir process'in hangi CPU core'ları üzerinde çalışabileceğini belirler. Varsayılan olarak scheduler process'leri herhangi bir core'a atayabilir.

```
Varsayilan (affinity yok):
  Process --> [CPU0, CPU1, CPU2, CPU3]  (herhangi birinde çalışabilir)

Affinity ayarlanmis:
  Process --> [CPU0, CPU2]  (sadece 0 ve 2 numarali core'larda çalışır)
```

#### taskset Komutu

```bash
# Belirli CPU'larda başlat
taskset -c 0,2 ./myapp          # CPU 0 ve CPU 2
taskset -c 0-3 ./myapp          # CPU 0, 1, 2, 3
taskset 0x5 ./myapp             # Bitmask: 0101 = CPU 0 ve CPU 2

# Calisan process'in affinity'sini gor
taskset -p <pid>
# pid <pid>'s current affinity mask: f    (1111 = tüm CPU'lar)

# Calisan process'in affinity'sini değiştir
taskset -p -c 0,1 <pid>
```

#### sched_setaffinity() — Programatik

```c
#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>

int main() {
    cpu_set_t mask;

    // Mevcut affinity'yi oku
    CPU_ZERO(&mask);
    sched_getaffinity(0, sizeof(mask), &mask);

    printf("Kullanilabilir CPU'lar: ");
    for (int i = 0; i < CPU_SETSIZE; i++) {
        if (CPU_ISSET(i, &mask)) {
            printf("%d ", i);
        }
    }
    printf("\n");

    // Sadece CPU 0 ve CPU 2'yi kullan
    CPU_ZERO(&mask);
    CPU_SET(0, &mask);
    CPU_SET(2, &mask);

    if (sched_setaffinity(0, sizeof(mask), &mask) == -1) {
        perror("sched_setaffinity");
        return 1;
    }

    printf("Affinity ayarlandi: CPU 0 ve CPU 2\n");

    // Yogun işlem (sadece CPU 0 ve 2'de calisacak)
    while (1) { /* ... */ }

    return 0;
}
```

#### NUMA Awareness

**NUMA (Non-Uniform Memory Access)** mimarisinde her CPU soketinin kendi yerel memory'si vardır. Uzak memory'ye erişim daha yavaş olduğu için, process'i **verisine yakın CPU'da** çalıştırmak önemlidir.

```
NUMA Topolojisi:

  ┌─────────────────────┐     ┌─────────────────────┐
  │     NUMA Node 0     │     │     NUMA Node 1     │
  │  ┌───────────────┐  │     │  ┌───────────────┐  │
  │  │ CPU 0 │ CPU 1 │  │     │  │ CPU 2 │ CPU 3 │  │
  │  └───────────────┘  │     │  └───────────────┘  │
  │  ┌───────────────┐  │     │  ┌───────────────┐  │
  │  │  Local Memory │  │←QPI→│  │  Local Memory │  │
  │  │   (hızlı)     │  │     │  │   (hızlı)     │  │
  │  └───────────────┘  │     │  └───────────────┘  │
  └─────────────────────┘     └─────────────────────┘

  CPU 0 --> Node 0 memory: ~80ns (yerel)
  CPU 0 --> Node 1 memory: ~140ns (uzak, QPI üzerinden)
```

```bash
# NUMA topolojisini gor
numactl --hardware
# available: 2 nodes (0-1)
# node 0 cpus: 0 1 2 3
# node 0 size: 16384 MB
# node 1 cpus: 4 5 6 7
# node 1 size: 16384 MB

# Process'i belirli NUMA node'da çalıştır
numactl --cpunodebind=0 --membind=0 ./database_server

# Mevcut NUMA istatistikleri
numastat
numastat -p <pid>
```

> [!tip] NUMA ve Container
> ```bash
> # Docker'da cpuset ile NUMA-aware dağıtım
> docker run --cpuset-cpus="0-3" --cpuset-mems="0" myapp
> # CPU 0-3 ve NUMA node 0 memory'si kullanılır
> ```

---

## Real-Time Scheduling

Real-time scheduling, **deterministik zamanlama** gerektiren uygulamalar içindir. Normal CFS process'lerini **her zaman** preempt eder.

#### SCHED_FIFO vs SCHED_RR

| Özellik | SCHED_FIFO | SCHED_RR |
|---------|-----------|----------|
| Preemption | Sadece daha yüksek priority'den | Aynı priority'de time slice ile |
| Time Slice | Yok (bloke olana kadar çalışır) | Var (varsayılan ~100ms) |
| Aynı priority davranışı | İlk giren çalışır | Round-robin dönüşüm |
| Tehlike | Düşük priority process'ler açlıktan ölür | Daha adil ama hala riskli |

```
SCHED_FIFO (Priority 50):
  P1 ████████████████████████████ (bloke olana kadar çalışır)
  P2 ░░░░░░░░░░░░░░████████████  (P1 bloke olunca çalışır)

SCHED_RR (Priority 50, aynı seviye):
  P1 ████░░░░████░░░░████░░░░
  P2 ░░░░████░░░░████░░░░████    (time slice ile donusumlum)
```

```bash
# SCHED_FIFO ile başlat (root gerekli)
sudo chrt -f 50 ./realtime_app

# SCHED_RR ile başlat
sudo chrt -r 30 ./realtime_app

# Calisan process'in policy'sini değiştir
sudo chrt -f -p 50 <pid>

# RT time slice degerini gor (SCHED_RR için)
cat /proc/sys/kernel/sched_rr_timeslice_ms
# 100
```

#### Priority Inversion Problemi

Priority inversion, yüksek öncelikli bir process'in düşük öncelikli bir process'in tuttuğu kaynak yüzünden **bloke kalmasıdır**.

```
Senaryo: 3 process, 1 mutex

Priority:  Yuksek=H   Orta=M   Dusuk=L

1. L mutex'i alir ve calismaya başlar
2. H çalışabilir olur, L'yi preempt eder
3. H mutex'i ister --> L'de olduğu için bloke olur
4. M çalışabilir olur --> L'den yüksek priority, L'yi preempt eder
5. M çalışıyor, L bekliyor, H bekliyor
   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   H, M'den yüksek öncelikli olduğu halde M yuzunden bekliyor!
   Bu = Priority Inversion

Zamanlama:
  L: ████░░░░░░░░░░░░░░████████  (mutex al ... mutex bırak)
  M: ░░░░░░░░░░████████░░░░░░░░  (H ve L'nin onunde çalışıyor!)
  H: ░░░░████▓▓▓▓▓▓▓▓▓▓▓▓██████  (▓ = bloke, mutex bekliyor)
```

> [!warning] Mars Pathfinder Olayı
> 1997'de Mars Pathfinder uzay aracında priority inversion yüzünden sistem sürekli resetlendi. Çözüm: priority inheritance protokolü uzaktan aktive edildi.

#### Priority Inheritance

Priority inheritance, priority inversion'ı çözen mekanizmadır. Düşük öncelikli process, yüksek öncelikli process'in beklediği kaynağı tutuyorsa, geçici olarak **yüksek önceliğe çıkarılır**.

```
Priority Inheritance ile:

1. L mutex'i alir (priority = L)
2. H mutex'i ister, bloke olur
3. Kernel L'nin priority'sini H'ye yukseltir (geçici)
4. M çalışabilir olur AMA L (simdi H priority'sinde) calismaya devam eder
5. L mutex'i bırakır, priority'si normale döner
6. H mutex'i alir ve çalışır

  L: ████░░░░████████░░░░░░░░░░  (priority H'ye yükselir, mutex bırakır)
  M: ░░░░░░░░░░░░░░░░░░████████  (simdi çalışabilir)
  H: ░░░░████▓▓▓▓▓▓▓▓██████░░░░  (daha kısa bekleme)
```

```c
// Priority inheritance mutex (POSIX)
#include <pthread.h>

pthread_mutex_t mutex;
pthread_mutexattr_t attr;

// Priority inheritance protokolunu aktive et
pthread_mutexattr_init(&attr);
pthread_mutexattr_setprotocol(&attr, PTHREAD_PRIO_INHERIT);
pthread_mutex_init(&mutex, &attr);

// Bu mutex'i kullanan düşük öncelikli thread, yüksek
// öncelikli thread bloke olduğunda otomatik olarak
// önceliği yükseltilir.
```

---

## Deadline Scheduler (SCHED_DEADLINE)

`SCHED_DEADLINE` Linux 3.14'te (2014) eklenmiştir. **Earliest Deadline First (EDF)** algoritmasını kullanır. En yakın deadline'a sahip task öncelikli çalıştırılır.

#### EDF Parametreleri

Her SCHED_DEADLINE task'i üç parametre ile tanımlanır:

```
  runtime    deadline    period
  ├───┤      ├────────┤  ├────────────────────┤
  ┌───┐                  ┌───┐                  ┌───┐
  │RUN│                  │RUN│                  │RUN│
  └───┘                  └───┘                  └───┘
  |<------- period ------>|<------- period ------>|
  |<-- deadline -->|      |<-- deadline -->|

  runtime:  Her periyotta ne kadar CPU zamani gerekli
  deadline: Her periyotta ısı ne zamana kadar bitirmeli
  period:   Periyodun toplam süresi

  Kisitlama: runtime <= deadline <= period
```

```bash
# SCHED_DEADLINE ile başlat
# runtime=5ms, deadline=10ms, period=20ms
sudo chrt -d --sched-runtime 5000000 \
             --sched-deadline 10000000 \
             --sched-period 20000000 \
             0 ./periodic_sensor_reader
```

```c
// Programatik SCHED_DEADLINE ayarlama
#include <sched.h>
#include <linux/sched.h>
#include <sys/syscall.h>
#include <unistd.h>

struct sched_attr {
    uint32_t size;
    uint32_t sched_policy;
    uint64_t sched_flags;
    int32_t  sched_nice;
    uint32_t sched_priority;
    uint64_t sched_runtime;
    uint64_t sched_deadline;
    uint64_t sched_period;
};

int main() {
    struct sched_attr attr = {
        .size = sizeof(attr),
        .sched_policy = SCHED_DEADLINE,
        .sched_runtime  =  5000000,   //  5 ms
        .sched_deadline = 10000000,   // 10 ms
        .sched_period   = 20000000,   // 20 ms
    };

    // sched_setattr syscall (glibc wrapper yok)
    if (syscall(SYS_sched_setattr, 0, &attr, 0) == -1) {
        perror("sched_setattr");
        return 1;
    }

    while (1) {
        // Periyodik is yap (sensor oku, veri isle, vb.)
        do_periodic_work();

        // Bu periyottaki ısı bitirdigini bildir
        sched_yield();
    }
    return 0;
}
```

> [!info] SCHED_DEADLINE Kullanım Alanları
> - Ses/video işleme pipeline'ları
> - Endüstriyel kontrol sistemleri
> - Sensor veri toplama (periyodik okuma)
> - Robotik motor kontrolleri

---

## Container'larda Scheduling

Container'lar doğrudan scheduler policy değiştirmez; bunun yerine **cgroups** üzerinden CPU kaynak kontrolü sağlar. Scheduler, cgroup parametrelerini dikkate alarak CPU dağıtımını yapar.

#### cpu.shares (Göreceli Ağırlık)

```bash
# Container'a CPU ağırlık ata
docker run --cpu-shares=2048 app_critical
docker run --cpu-shares=512  app_background

# Agirlik oranı: 2048 / (2048+512) = %80 CPU (contention varsa)
```

```
Senaryo: 2 container, 1 CPU, tam yükleme

Container A (shares=2048): ████████████████████░░░░░  (~%80 CPU)
Container B (shares=512):  ░░░░░░░░░░░░░░░░░░░█████  (~%20 CPU)

Senaryo: Sadece A çalışıyor (contention yok)
Container A (shares=2048): █████████████████████████  (%100 CPU)
Container B (idle):        ░░░░░░░░░░░░░░░░░░░░░░░░░
```

#### cpu.cfs_quota / cpu.cfs_period (Kesin Limit)

```bash
# 1.5 CPU limit (kesin ust sınır)
docker run --cpus=1.5 myapp

# Arka planda cgroup v1 dosyaları:
# cpu.cfs_period_us = 100000  (100ms)
# cpu.cfs_quota_us  = 150000  (150ms) --> 150/100 = 1.5 CPU

# Manuel ayarlama
docker run --cpu-period=100000 --cpu-quota=50000 myapp
# 50000 / 100000 = 0.5 CPU (yari core)
```

```
cpu.cfs_quota etkisi:

Period = 100ms, Quota = 50ms --> 0.5 CPU

|<--- 100ms period --->|<--- 100ms period --->|
 ██████████░░░░░░░░░░░░ ██████████░░░░░░░░░░░░
 ^-- 50ms calis         ^-- 50ms calis
            ^-- 50ms bekle           ^-- 50ms bekle
```

#### Cgroup v2 CPU Dosyaları

```bash
# Cgroup v2'de CPU kontrolü
cat /sys/fs/cgroup/system.slice/docker-<id>.scope/cpu.max
# 150000 100000  (quota period formatinda)
# "max 100000" = limit yok

cat /sys/fs/cgroup/system.slice/docker-<id>.scope/cpu.weight
# 100  (1-10000 arasi, varsayilan 100)

cat /sys/fs/cgroup/system.slice/docker-<id>.scope/cpu.stat
# usage_usec 12345678
# user_usec 10000000
# system_usec 2345678
# nr_periods 1000
# nr_throttled 50
# throttled_usec 500000
```

> [!tip] Throttle Tespiti
> `nr_throttled` değeri yüksekse container CPU limitine sürekli takılıyor demektir. Bu durumda ya limiti arttırın ya da uygulamayı optimize edin.
> ```bash
> # Container CPU throttle kontrolü
> docker exec <container> cat /sys/fs/cgroup/cpu.stat
> ```

Daha fazla detay için --> [[Linux Cgroups#CPU Kontrolü]]

---

## /proc Dosya Sistemi ile Scheduler Bilgileri

#### /proc/\<pid\>/sched

Process'in scheduler istatistiklerini içerir.

```bash
cat /proc/<pid>/sched
# task_name (pid)
# -----------------------------------------------------------
# se.exec_start                      :     123456789.123456
# se.vruntime                        :       5678901.234567
# se.sum_exec_runtime                :       1234567.890123
# se.nr_migrations                   :               42
# nr_switches                        :             1500
# nr_voluntary_switches              :             1200
# nr_involuntary_switches            :              300
# se.load.weight                     :             1024
# policy                             :                0  (SCHED_OTHER)
# prio                               :              120  (nice 0)
```

| Alan | Açıklama |
|------|----------|
| `se.vruntime` | CFS virtual runtime değeri |
| `se.sum_exec_runtime` | Toplam CPU kullanım süresi (nanosaniye) |
| `nr_switches` | Toplam context switch sayısı |
| `nr_voluntary_switches` | Gönüllü context switch (I/O bekleme vs.) |
| `nr_involuntary_switches` | Zorunlu context switch (preemption) |
| `se.load.weight` | CFS weight değeri (nice'a karşılık) |
| `se.nr_migrations` | CPU'lar arası göç sayısı |
| `policy` | 0=OTHER, 1=FIFO, 2=RR, 6=DEADLINE |

#### /proc/\<pid\>/status

```bash
cat /proc/<pid>/status
# Name:   myapp
# State:  S (sleeping)
# Pid:    1234
# PPid:   1
# Threads:        4
# Cpus_allowed:   f          (bitmask: 1111 = CPU 0-3)
# Cpus_allowed_list:  0-3
# voluntary_ctxt_switches:  1500
# nonvoluntary_ctxt_switches:  230
```

#### /proc/\<pid\>/stat

```bash
# Alan numaralari (bazi önemli olanlar):
# 3  = state
# 14 = utime (user mode ticks)
# 15 = stime (kernel mode ticks)
# 18 = priority
# 19 = nice
# 20 = num_threads
# 39 = processor (son çalıştığı CPU)

cat /proc/<pid>/stat
# 1234 (myapp) S 1 ... 100 20 4 ... 2
```

```bash
# Tum process'lerin scheduler bilgisi (one-liner)
for pid in /proc/[0-9]*/sched; do
    echo "=== $pid ===";
    head -5 "$pid" 2>/dev/null;
    echo;
done
```

---

## Pratik Komutlar ve Araçlar

#### top / htop — Canlı İzleme

```bash
# top ile CPU ve scheduling bilgisi
top
# PR = priority (kernel priority, 120 = nice 0)
# NI = nice değeri
# S  = state (R=running, S=sleeping, D=disk sleep)

# top'ta önemli tuslar:
# P = CPU'ya gore sirala
# M = Memory'ye gore sirala
# 1 = CPU core'lari ayri göster
# f = gorunecek alanları sec (WCHAN, POLICY eklenebilir)

# htop (daha iyi arayuz)
htop
# F2 = Setup (gorunecek sutunlari ayarla)
# F5 = Tree view (process ağacı)
# F6 = Sort
# F9 = Kill (signal gönder)
```

#### chrt — Scheduling Policy Yönetimi

```bash
# Mevcut policy ve priority'yi gor
chrt -p <pid>

# SCHED_FIFO ile başlat
sudo chrt -f 50 ./realtime_app

# SCHED_RR ile başlat
sudo chrt -r 30 ./realtime_app

# SCHED_BATCH ile başlat
chrt -b 0 ./batch_job

# SCHED_IDLE ile başlat
chrt -i 0 ./idle_task

# Calisan process'in policy'sini değiştir
sudo chrt -f -p 80 <pid>

# SCHED_DEADLINE
sudo chrt -d --sched-runtime 5000000 \
             --sched-deadline 10000000 \
             --sched-period 20000000 0 ./app

# Kullanilabilir priority araligini gor
chrt -m
# SCHED_OTHER min/max priority    : 0/0
# SCHED_FIFO min/max priority     : 1/99
# SCHED_RR min/max priority       : 1/99
# SCHED_BATCH min/max priority    : 0/0
# SCHED_IDLE min/max priority     : 0/0
# SCHED_DEADLINE min/max priority : 0/0
```

#### taskset — CPU Affinity

```bash
# CPU affinity ayarla (baslangicta)
taskset -c 0,2 ./myapp

# Calisan process'in affinity'sini gor
taskset -p <pid>

# Calisan process'in affinity'sini değiştir
taskset -p -c 0-3 <pid>
```

#### schedtool

```bash
# Process scheduling bilgisi
schedtool <pid>
# PID 1234: PRIO 0, POLICY N, NICE 0, AFFINITY 0xf

# SCHED_BATCH ayarla
schedtool -B <pid>

# SCHED_FIFO priority 50 ayarla
schedtool -F -p 50 <pid>

# Affinity + policy birlikte
schedtool -F -p 50 -a 0x3 <pid>
# SCHED_FIFO, priority 50, CPU 0 ve 1
```

#### mpstat — CPU Core Bazlı İstatistik

```bash
# Tum CPU core'larinin kullanimi (1 saniye aralikla)
mpstat -P ALL 1

# Örnek çıktı:
# CPU    %usr   %nice   %sys   %iowait  %irq   %soft  %steal  %idle
# all    15.00   0.00   3.00    1.00    0.00    0.50    0.00   80.50
#   0    30.00   0.00   5.00    2.00    0.00    1.00    0.00   62.00
#   1    10.00   0.00   2.00    0.50    0.00    0.00    0.00   87.50
#   2    15.00   0.00   3.00    1.00    0.00    0.50    0.00   80.50
#   3     5.00   0.00   2.00    0.50    0.00    0.50    0.00   92.00

# %nice: nice > 0 olan process'lerin CPU kullanimi
# %steal: hypervisor tarafından "calinan" CPU (VM'lerde önemli)
```

#### vmstat — Context Switch İzleme

```bash
# 1 saniye aralikla sistem istatistikleri
vmstat 1

# Örnek çıktı:
# procs  ----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
#  r  b    swpd   free    buff  cache   si  so    bi    bo   in    cs  us sy id wa
#  2  0       0 512000  64000 256000    0   0     5    10  800  2500  10  3 85  2
#  1  0       0 511000  64000 256000    0   0     0    20  900  3000  15  5 78  2

# r  = runnable process sayisi (run queue'da bekleyen)
# b  = blocked (uninterruptible sleep) process sayisi
# in = interrupt sayisi/saniye
# cs = context switch sayisi/saniye

# r > CPU sayisi ise CPU doygunlugu (saturation) var demektir
```

#### Scheduler Tuning Parametreleri

```bash
# CFS ayar parametreleri
cat /proc/sys/kernel/sched_min_granularity_ns
# 3000000  (3ms - minimum time slice)

cat /proc/sys/kernel/sched_latency_ns
# 24000000  (24ms - hedef scheduling periyodu)

cat /proc/sys/kernel/sched_wakeup_granularity_ns
# 4000000  (4ms - wakeup preemption esigi)

# Real-time bandwidth limiti (RT process'lerin max CPU kullanimi)
cat /proc/sys/kernel/sched_rt_runtime_us
# 950000  (950ms / 1s period = %95 CPU max RT için)

cat /proc/sys/kernel/sched_rt_period_us
# 1000000  (1 saniye)
```

> [!warning] RT Bandwidth Limiti
> Varsayılan olarak RT process'ler CPU'nun en fazla **%95**'ini kullanabilir. Kalan %5 normal process'lerin açlıktan ölmemesi içindir. Bu limiti kaldırmak tehlikelidir:
> ```bash
> # TEHLIKELI: RT limiti kaldir (RT process tüm CPU'yu alabilir)
> echo -1 > /proc/sys/kernel/sched_rt_runtime_us
> ```

---

## Özet Tablosu

| Kavram | Açıklama | Komut/Dosya |
|--------|----------|-------------|
| CFS | Varsayılan adil scheduler | - |
| vruntime | Sanal çalışma süresi | `/proc/<pid>/sched` |
| Nice | Kullanıcı önceliği (-20..19) | `nice`, `renice` |
| Policy | Scheduling algoritması | `chrt` |
| Context Switch | Process değişimi | `vmstat`, `/proc/<pid>/status` |
| CPU Affinity | Core sınırlandırma | `taskset`, `numactl` |
| RT Scheduling | Gerçek zamanlı zamanlama | `chrt -f`, `chrt -r` |
| SCHED_DEADLINE | EDF algoritması | `chrt -d` |
| CPU Shares | Container göreceli ağırlık | `docker --cpu-shares` |
| CPU Quota | Container kesin limit | `docker --cpus` |

```
Karar Agaci: Hangi Policy Kullanmaliyim?

Periyodik gerçek zamanli is mi?
  └─ Evet --> SCHED_DEADLINE
  └─ Hayir
       Gercek zamanli yanit süresi gerekli mi?
         └─ Evet --> Tek task mi?
         │            └─ Evet --> SCHED_FIFO
         │            └─ Hayir --> SCHED_RR
         └─ Hayir
              CPU-intensive batch is mi?
                └─ Evet --> SCHED_BATCH
                └─ Hayir
                     Sadece bos CPU'da mi calismali?
                       └─ Evet --> SCHED_IDLE
                       └─ Hayir --> SCHED_OTHER (varsayilan)
```
