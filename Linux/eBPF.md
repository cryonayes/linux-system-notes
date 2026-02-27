Linux kernel'inde **sandboxed programlar** çalıştırabilen, kernel kaynak kodunu değiştirmeden veya kernel modülü yüklemeden **kernel davranışını programlanabilir** hale getiren devrimsel teknoloji. Networking, observability, security ve tracing alanlarında modern Linux altyapısının temelidir.

> [!info] İlişkili
> Debugging araçları ve strace --> [[Linux Debugging Araçları]]
> Container security --> [[Docker Security]]
> Packet filtering --> [[iptables ve nftables]]
> Namespace izolasyonu --> [[Linux Namespaces]]

---

## eBPF Nedir

**eBPF (extended Berkeley Packet Filter)**, Linux kernel'ine **güvenli**, **verimli** ve **dinamik** şekilde program yüklemenizi sağlayan bir teknolojidir. Kernel'in içinde çalışan mini bir sanal makine (virtual machine) olarak düşünülebilir.

#### Tarihçe: cBPF --> eBPF

| Dönem | Teknoloji | Açıklama |
|-------|-----------|----------|
| 1992 | **cBPF** (classic BPF) | Steven McCanne ve Van Jacobson tarafından yazıldı. Sadece **paket filtreleme** için (tcpdump) |
| 2014 | **eBPF** (extended BPF) | Alexei Starovoitov tarafından Linux 3.18'e eklendi. Genel amaçlı **kernel programmability** |
| 2016+ | **eBPF ekosistemi** | BCC, bpftrace, Cilium, Falco gibi araçlar ortaya çıktı |
| 2020+ | **CO-RE** (Compile Once, Run Everywhere) | BTF ile kernel versiyon bağımsız program taşınabilirliği |

```
cBPF (1992)                          eBPF (2014+)
-----------                          -----------
- 2 register (A, X)                  - 11 register (R0-R10)
- 32-bit                             - 64-bit
- Sadece packet filtering            - Genel amaçlı (network, trace, security)
- Interpreter only                   - JIT compilation
- Sinirli instruction set            - Zengin instruction set + helper functions
- Map yok                            - Map desteği (key-value store)
```

#### Neden eBPF?

Geleneksel yöntemlerle kernel davranışını değiştirmek için **kernel modülü** yazmak gerekir. Bu yaklaşım:

- Kernel panic riski taşır
- Kernel versiyonuna bağımlıdır
- Güvenlik açığı oluşturabilir
- Dağıtımı ve bakımı zordur

eBPF bunların **hepsini** çözer: verifier ile güvenlik sağlanır, JIT ile performans, maps ile veri paylaşımı, helper functions ile kernel API erişimi.

> [!tip] Analoji
> eBPF, kernel için **JavaScript**'in web browser için olduğu şeye benzer. Nasıl JavaScript browser'a programlanabilirlik kazandırdıysa, eBPF de Linux kernel'ine aynı şeyi yapar -- güvenli bir sandbox içinde.

---

## eBPF Mimarisi

```
                    Kullanici Alani (User Space)
    ┌──────────────────────────────────────────────────┐
    │                                                  │
    │   bpftrace / BCC / libbpf / cilium / falco       │
    │         │                     ▲                  │
    │         │ bpf() syscall       │ Map okuma/yazma  │
    │         ▼                     │                  │
    ├──────────────────────────────────────────────────┤
    │                Kernel Alani (Kernel Space)       │
    │                                                  │
    │   ┌─────────────┐    ┌──────────────────────┐    │
    │   │  eBPF       │    │   eBPF Maps          │    │
    │   │  Bytecode   │    │   (Hash, Array,      │    │
    │   │             │    │    Ring Buffer, ...) │    │
    │   └──────┬──────┘    └──────────▲───────────┘    │
    │          │                      │                │
    │          ▼                      │                │
    │   ┌─────────────┐               │                │
    │   │  Verifier   │   güvenlik    │                │
    │   │  (statik    │   kontrolü    │                │
    │   │   analiz)   │               │                │
    │   └──────┬──────┘               │                │
    │          │ onay                 │                │
    │          ▼                      │                │
    │   ┌─────────────┐               │                │
    │   │  JIT        │               │                │
    │   │  Compiler   │   native      │                │
    │   │  (x86/ARM)  │   kod         │                │
    │   └──────┬──────┘               │                │
    │          │                      │                │
    │          ▼                      │                │
    │   ┌─────────────────────────────────────────┐    │
    │   │        Hook Noktalari                   │    │
    │   │  kprobe │ tracepoint │ XDP │ cgroup ... │    │
    │   │         │            │     │            │    │
    │   │  ┌──────┴──────┐     │     │            │    │
    │   │  │ Helper      │◄────┘     │            │    │
    │   │  │ Functions   │◄──────────┘            │    │
    │   │  └─────────────┘                        │    │
    │   └─────────────────────────────────────────┘    │
    └──────────────────────────────────────────────────┘
```

#### Temel Bileşenler

**1. Verifier (Doğrulayıcı)**

eBPF programını kernel'e yüklemeden önce **statik analiz** yapar. Programın güvenli olduğunu garanti eder.

Verifier'in kontrol ettikleri:

| Kontrol | Açıklama |
|---------|----------|
| **Sonlanma garantisi** | Program sonsuza kadar çalışamaz (loop limiti, max instruction sayısı) |
| **Memory güvenliği** | Out-of-bounds erişim yok, NULL pointer dereference yok |
| **Register durumu** | Her instruction'da register durumu takip edilir |
| **Stack sınırı** | Maksimum 512 byte stack |
| **Helper çağrı kontrolü** | Sadece izin verilen helper function'lar çağırılabilir |
| **Program boyutu** | Kernel 5.2 öncesi 4096 instruction, sonrası 1 milyon |

```bash
# Verifier çıktısı örneği (hata durumu)
$ bpftool prog load bad_prog.o /sys/fs/bpf/bad
libbpf: prog 'bad_func': BPF program load failed: Permission denied
libbpf: prog 'bad_func': -- BEGIN PROG LOAD LOG --
0: (79) r1 = *(u64 *)(r10 -8)
1: (b7) r0 = 0
; out of bounds memory access
R1 invalid mem access 'inv'
-- END PROG LOAD LOG --
```

**2. JIT Compiler**

Verifier'dan geçen eBPF bytecode, **native makine koduna** (x86, ARM64, vs.) derlenir. Bu sayede eBPF programları neredeyse **native hızda** çalışır.

```bash
# JIT durumunu kontrol et
cat /proc/sys/net/core/bpf_jit_enable
# 0 = kapali (interpreter)
# 1 = açık (default)
# 2 = açık + debug (GDB ile debug edilebilir)

# JIT'i aktif et
echo 1 > /proc/sys/net/core/bpf_jit_enable
```

**3. Helper Functions**

eBPF programları doğrudan kernel fonksiyonlarını çağıramazlar. Bunun yerine kernel'in sunduğu **helper function'lar** kullanılır.

| Helper | Açıklama |
|--------|----------|
| `bpf_map_lookup_elem()` | Map'ten değer oku |
| `bpf_map_update_elem()` | Map'e değer yaz |
| `bpf_map_delete_elem()` | Map'ten değer sil |
| `bpf_probe_read()` | Kernel memory'den güvenli okuma |
| `bpf_probe_read_user()` | User-space memory'den okuma |
| `bpf_ktime_get_ns()` | Nanosaniye cinsinden zaman |
| `bpf_get_current_pid_tgid()` | Mevcut PID/TGID |
| `bpf_get_current_comm()` | Mevcut process ismi |
| `bpf_trace_printk()` | Debug çıktısı (/sys/kernel/debug/tracing/trace_pipe) |
| `bpf_redirect()` | Paketi başka interface'e yönlendir |
| `bpf_perf_event_output()` | User-space'e event gönder |
| `bpf_ringbuf_output()` | Ring buffer'a veri yaz |

**4. eBPF Maps**

Kernel ve user-space arasında **veri paylaşımı** için kullanılan key-value veri yapıları. Ayrıntılı açıklama aşağıda.

---

## eBPF Program Türleri

eBPF programları farklı **hook noktalarında** çalışır. Her program türü belirli bir amaca hizmet eder.

```
                Kernel Katmanlari ve eBPF Hook Noktalari

  ┌─────────────────────────────────────────────────────────────┐
  │ User Space Application                                      │
  │    │              ▲                                         │
  │    │ syscall      │ return                                  │
  │    ▼              │                                         │
  ├────────── uprobe ─┼──────── uretprobe ──────────────────────┤
  │                   │                                         │
  │ ┌─────────────────┼──────────────────────────────────────┐  │
  │ │  System Call Layer      tracepoint:raw_syscalls        │  │
  │ └─────────────────┼──────────────────────────────────────┘  │
  │                   │                                         │
  │ ┌─────────────────┼──────────────────────────────────────┐  │
  │ │  VFS / Scheduler / Memory        kprobe, tracepoint    │  │
  │ └─────────────────┼──────────────────────────────────────┘  │
  │                   │                                         │
  │ ┌─────────────────┼──────────────────────────────────────┐  │
  │ │  Network Stack (TCP/IP)          socket filter, cgroup │  │
  │ └─────────────────┼──────────────────────────────────────┘  │
  │                   │                                         │
  │ ┌─────────────────┼──────────────────────────────────────┐  │
  │ │  Network Driver (NIC)            XDP                   │  │
  │ └─────────────────┼──────────────────────────────────────┘  │
  │                   │                                         │
  └───────────────────┼─────────────────────────────────────────┘
                      ▼
                   Network
```

#### Program Türü Tablosu

| Tür | Hook Noktası | Kullanım Alanı | Örnek |
|-----|-------------|----------------|-------|
| **kprobe / kretprobe** | Herhangi bir kernel fonksiyonu | Fonksiyon giriş/çıkışını izleme | `do_sys_openat2` izleme |
| **uprobe / uretprobe** | Herhangi bir user-space fonksiyonu | Uygulama fonksiyonlarını izleme | `malloc()` çağrısı izleme |
| **tracepoint** | Kernel'deki sabit tracepoint'ler | Kararlı API ile kernel event izleme | `sched:sched_switch` |
| **raw_tracepoint** | Ham tracepoint verisi | Düşük overhead tracing | Syscall izleme |
| **XDP** | NIC driver seviyesi | Ultra hızlı paket işleme | DDoS mitigation, load balancing |
| **tc** (traffic control) | Network stack qdisc katmanı | Paket manipülasyonu | Bandwidth sınırlandırma |
| **cgroup** | Cgroup hook'ları | Container/process grubu kontrolü | Network erişim kontrolü |
| **socket filter** | Socket katmanı | Paket filtreleme | tcpdump benzeri yakalama |
| **LSM** (Linux Security Module) | Security hook'ları | Güvenlik politikası uygulama | Dosya erişim kontrolü |
| **perf_event** | Hardware/software event'ler | CPU profiling | Stack sampling |
| **fentry / fexit** | Kernel fonksiyon giriş/çıkış | kprobe'dan daha hızlı tracing | Düşük overhead fonksiyon izleme |
| **struct_ops** | Kernel struct operations | Kernel davranışını değiştirme | TCP congestion control |

#### kprobe Örneği (C ile)

```c
// kprobe_example.bpf.c
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

// Her dosya acildiginda tetiklenir
SEC("kprobe/do_sys_openat2")
int BPF_KPROBE(trace_open, int dfd, const char *filename)
{
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    char comm[16];
    bpf_get_current_comm(&comm, sizeof(comm));

    bpf_printk("PID %d (%s) dosya aciyor: %s\n", pid, comm, filename);
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
```

#### uprobe Örneği (bpftrace ile)

```bash
# User-space'deki malloc() cagrilarini izle
bpftrace -e 'uprobe:/lib/x86_64-linux-gnu/libc.so.6:malloc {
    printf("PID %d (%s) malloc(%d)\n", pid, comm, arg0);
}'
```

#### LSM Örneği

```c
// lsm_example.bpf.c
SEC("lsm/file_open")
int BPF_PROG(restrict_file_open, struct file *file, int ret)
{
    // /etc/shadow erisimini logla
    // LSM hook'lari security policy uygulamak için kullanılır
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    bpf_printk("LSM: PID %d dosya aciyor\n", pid);
    return 0;  // 0 = izin ver, negatif = engelle
}
```

---

## eBPF Maps

Maps, eBPF programları ile user-space arasında **veri paylaşımı** sağlayan key-value veri yapılarıdır. Aynı zamanda eBPF programları arasında da veri paylaşımında kullanılır.

```
  User Space                        Kernel Space
  ┌──────────────────┐             ┌────────────────────┐
  │  bpftrace / BCC  │             │  eBPF Program      │
  │                  │  bpf()      │                    │
  │  map_lookup() ───┼─────────────┼──► map veri okuma  │
  │  map_update() ───┼─────────────┼──► map veri yazma  │
  │  map_delete() ───┼─────────────┼──► map veri silme  │
  │                  │  syscall    │                    │
  └──────────────────┘             └────────────────────┘
                         │
                    ┌────┴────────────┐
                    │  eBPF           │
                    │  Map            │
                    │ (kernel memory) │
                    └─────────────────┘
```

#### Map Türleri

| Map Türü | Açıklama | Kullanım |
|----------|----------|----------|
| **BPF_MAP_TYPE_HASH** | Hash table (key-value) | Genel amaçlı sayaç, lookup |
| **BPF_MAP_TYPE_ARRAY** | Sabit boyutlu array (index = key) | Index bazlı hızlı erişim |
| **BPF_MAP_TYPE_PERCPU_HASH** | Her CPU için ayrı hash | Lock-free sayaç, yüksek performans |
| **BPF_MAP_TYPE_PERCPU_ARRAY** | Her CPU için ayrı array | Per-CPU istatistik |
| **BPF_MAP_TYPE_RINGBUF** | Tek ring buffer (tüm CPU'lar paylaşılır) | Event streaming, modern tercih |
| **BPF_MAP_TYPE_PERF_EVENT_ARRAY** | Per-CPU ring buffer | Eski stil event streaming |
| **BPF_MAP_TYPE_LRU_HASH** | LRU eviction ile hash | Sınırlı bellek, otomatik temizlik |
| **BPF_MAP_TYPE_LPM_TRIE** | Longest prefix match | IP routing, CIDR eşleştirme |
| **BPF_MAP_TYPE_STACK_TRACE** | Stack trace depolama | Profiling, flame graph |
| **BPF_MAP_TYPE_PROG_ARRAY** | Program array (tail call) | eBPF programları arası atlama |
| **BPF_MAP_TYPE_CGROUP_STORAGE** | Cgroup bazlı depolama | Container bazlı istatistik |

#### Hash Map Örneği (C)

```c
// map tanımlama
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, u32);        // PID
    __type(value, u64);      // syscall sayisi
} syscall_count SEC(".maps");

SEC("tracepoint/raw_syscalls/sys_enter")
int count_syscalls(struct trace_event_raw_sys_enter *ctx)
{
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u64 *count = bpf_map_lookup_elem(&syscall_count, &pid);

    if (count) {
        __sync_fetch_and_add(count, 1);
    } else {
        u64 init_val = 1;
        bpf_map_update_elem(&syscall_count, &pid, &init_val, BPF_ANY);
    }
    return 0;
}
```

#### Ring Buffer Örneği

```c
// Ring buffer -- modern ve tercih edilen yöntem
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);  // 256 KB
} events SEC(".maps");

struct event {
    u32 pid;
    u32 uid;
    char comm[16];
    char filename[256];
};

SEC("tracepoint/syscalls/sys_enter_openat")
int trace_openat(struct trace_event_raw_sys_enter *ctx)
{
    struct event *e;

    // Ring buffer'dan alan ayir
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;

    e->pid = bpf_get_current_pid_tgid() >> 32;
    e->uid = bpf_get_current_uid_gid() & 0xFFFFFFFF;
    bpf_get_current_comm(&e->comm, sizeof(e->comm));
    bpf_probe_read_user_str(&e->filename, sizeof(e->filename),
                            (void *)ctx->args[1]);

    // Event'i gönder
    bpf_ringbuf_submit(e, 0);
    return 0;
}
```

#### Per-CPU Map Avantajı

```
Normal Hash Map:              Per-CPU Hash Map:
┌───────────────┐             ┌─── CPU 0 ──────┐
│  key │ value  │             │  key │ value   │
│  A   │  100   │  <-- lock   ├─── CPU 1 ──────┤
│  B   │  200   │  gerekli    │  key │ value   │
└───────────────┘             ├─── CPU 2 ──────┤
                              │  key │ value   │
Cok CPU'da yavaş              └────────────────┘
(lock contention)             Lock-free, çok hızlı
                              User-space'de toplanir
```

> [!warning] Map Boyut Limiti
> Map'ler kernel memory kullanır. Çok büyük map'ler sistem belleğini tüketebilir.
> `max_entries` değerini ihtiyaca göre ayarla. `BPF_MAP_TYPE_LRU_HASH` kullanarak
> otomatik eski kayıt temizliği yapabilirsin.

---

## bpftrace

**bpftrace**, eBPF için **yüksek seviyeli tracing dili**dir. Tek satırlık (one-liner) komutlarla güçlü kernel analizi yapılabilir. AWK'nin eBPF versiyonu olarak düşünülebilir.

```bash
# bpftrace kurulumu
apt-get install bpftrace        # Debian/Ubuntu
dnf install bpftrace            # Fedora
```

#### bpftrace Yapısı

```
bpftrace -e 'probe:filter /kosul/ { aksiyon }'
              │       │      │         │
              │       │      │         └─ Calistirilacak kod
              │       │      └─ Opsiyonel filtre
              │       └─ Probe parametresi
              └─ Probe türü (kprobe, tracepoint, ...)
```

#### Syscall Tracing

```bash
# Hangi process hangi syscall yapiyor?
bpftrace -e 'tracepoint:raw_syscalls:sys_enter {
    @syscalls[comm, args[1]] = count();
}'

# Belirli bir process'in syscall'larini izle
bpftrace -e 'tracepoint:raw_syscalls:sys_enter /comm == "nginx"/ {
    @[probe] = count();
}'

# openat syscall'larini izle (hangi dosyalar aciliyor)
bpftrace -e 'tracepoint:syscalls:sys_enter_openat {
    printf("%-6d %-16s %s\n", pid, comm, str(args->filename));
}'

# Syscall hata donusleri
bpftrace -e 'tracepoint:raw_syscalls:sys_exit /args->ret < 0/ {
    @errors[comm, args->ret] = count();
}'
```

#### Latency Ölçümü

```bash
# read() syscall süresi (latency histogram)
bpftrace -e 'tracepoint:syscalls:sys_enter_read {
    @start[tid] = nsecs;
}
tracepoint:syscalls:sys_exit_read /@start[tid]/ {
    @usecs = hist((nsecs - @start[tid]) / 1000);
    delete(@start[tid]);
}'

# Fonksiyon çalışma süresi
bpftrace -e 'kprobe:vfs_read { @start[tid] = nsecs; }
kretprobe:vfs_read /@start[tid]/ {
    @ns = hist(nsecs - @start[tid]);
    delete(@start[tid]);
}'
```

#### Disk I/O İzleme

```bash
# Block I/O istekleri (boyut dagilimi)
bpftrace -e 'tracepoint:block:block_rq_issue {
    @bytes = hist(args->bytes);
}'

# Disk I/O latency (ms cinsinden)
bpftrace -e 'tracepoint:block:block_rq_issue {
    @start[args->dev, args->sector] = nsecs;
}
tracepoint:block:block_rq_complete /@start[args->dev, args->sector]/ {
    @ms = hist((nsecs - @start[args->dev, args->sector]) / 1000000);
    delete(@start[args->dev, args->sector]);
}'

# Hangi process disk I/O yapiyor?
bpftrace -e 'tracepoint:block:block_rq_issue {
    @io_by_process[comm] = sum(args->bytes);
}'
```

#### Network İzleme

```bash
# TCP bağlantı kurulumlari
bpftrace -e 'kprobe:tcp_v4_connect {
    printf("%-6d %-16s TCP connect\n", pid, comm);
}'

# TCP accept (gelen bağlantı)
bpftrace -e 'kretprobe:inet_csk_accept {
    printf("%-6d %-16s TCP accept\n", pid, comm);
}'

# DNS sorgularini izle (UDP port 53)
bpftrace -e 'kprobe:udp_sendmsg /comm == "dig" || comm == "nslookup"/ {
    printf("%-6d %-16s DNS query\n", pid, comm);
}'

# Gonderilen/alinan byte sayisi (process bazinda)
bpftrace -e 'kprobe:tcp_sendmsg {
    @sent[comm] = sum(arg2);
}
kprobe:tcp_recvmsg {
    @recv[comm] = sum(arg2);
}'
```

#### Process İzleme

```bash
# Yeni process'leri izle (exec)
bpftrace -e 'tracepoint:syscalls:sys_enter_execve {
    printf("%-6d %-6d %s ", pid, uid, str(args->filename));
    join(args->argv);
}'

# Process oluşturma (fork)
bpftrace -e 'tracepoint:sched:sched_process_fork {
    printf("%-6d %-16s --> child PID %d\n",
           args->parent_pid, comm, args->child_pid);
}'

# Context switch izleme
bpftrace -e 'tracepoint:sched:sched_switch {
    @[args->prev_comm] = count();
}'
```

#### Diğer Faydalı One-Liner'lar

```bash
# Kernel stack trace (nerede zaman harcaniyor)
bpftrace -e 'profile:hz:99 { @[kstack] = count(); }'

# User-space stack trace
bpftrace -e 'profile:hz:99 /comm == "myapp"/ { @[ustack] = count(); }'

# Cache miss izleme
bpftrace -e 'hardware:cache-misses:1000 { @[comm] = count(); }'

# Sayfa hatasi (page fault) izleme
bpftrace -e 'software:page-faults:1 { @[comm] = count(); }'

# Timer/interval ile periyodik ölçüm
bpftrace -e 'interval:s:1 { printf("uptime: %d\n", elapsed / 1000000000); }'
```

> [!tip] bpftrace Çıktı Formatları
> `count()` -- sayı, `sum()` -- toplam, `avg()` -- ortalama,
> `min()` / `max()` -- minimum/maksimum, `hist()` -- log2 histogram,
> `lhist()` -- lineer histogram, `stats()` -- sayı+ortalama+toplam

---

## BCC (BPF Compiler Collection) Tools

**BCC**, eBPF programları yazmak ve çalıştırmak için Python/Lua frontend'i sağlayan bir toolkit'tir. İçinde **production-ready** araçlar bulunur.

```bash
# BCC kurulumu
apt-get install bpfcc-tools linux-headers-$(uname -r)   # Debian/Ubuntu
dnf install bcc-tools                                     # Fedora
```

#### Temel BCC Araçları

```
Performance Analiz Araci Haritasi (Brendan Gregg):

                    Applications
                    ┌────────────┐
                    │ execsnoop  │  -- yeni process'ler
                    │ opensnoop  │  -- dosya acma
                    │ funccount  │  -- fonksiyon sayma
                    │ trace      │  -- özel tracing
                    ├────────────┤
                    │  tcplife   │  -- TCP bağlantı omru
                    │ tcpconnect │  -- TCP connect
                    │ tcpaccept  │  -- TCP accept
     Syscalls       │ tcpretrans │  -- TCP retransmit
    ┌───────────────┼────────────┤
    │ syscount      │ runqlat    │  -- scheduler latency
    │ argdist       │ cpudist    │  -- CPU kullanım dagilimi
    │ biotop        │ softirqs   │  -- soft interrupt
    ├───────────────┼────────────┤
    │ biolatency    │ hardirqs   │  -- hard interrupt
    │ biosnoop      │ cachestat  │  -- page cache hit/miss
    │ ext4slower    │ llcstat    │  -- LLC cache
    └───────────────┴────────────┘
     Block I/O       CPU / Memory
```

#### execsnoop -- Yeni Process İzleme

```bash
# Tum exec() cagrilarini izle
execsnoop

# Cikti:
# PCOMM   PID    PPID   RET ARGS
# bash    18171  18170    0 /bin/bash
# ls      18172  18171    0 /bin/ls --color=auto
# grep    18173  18171    0 /bin/grep foo

# Timestamp ile
execsnoop -T

# Belirli kullanıcı
execsnoop --uid 1000
```

**Kullanım:** Kısa ömürlü process'leri yakalamak, cron job'ları izlemek, güvenlik denetimi.

#### opensnoop -- Dosya Erişim İzleme

```bash
# Tum dosya acma işlemlerini izle
opensnoop

# Cikti:
# PID    COMM        FD   ERR PATH
# 1234   nginx        7     0 /var/log/nginx/access.log
# 5678   python3      3     0 /etc/config.yaml
# 9012   bash        -1     2 /nonexistent (ENOENT)

# Sadece başarısız açma girişimleri
opensnoop -x

# Belirli PID
opensnoop -p 1234

# Belirli dosya yolu içeren
opensnoop -f /etc/passwd
```

**Kullanım:** Uygulamanın hangi dosyalara eriştiği, permission hataları, eksik config dosyaları.

#### tcplife -- TCP Bağlantı Ömrü

```bash
# TCP bağlantılarının ömrünü izle
tcplife

# Cikti:
# PID   COMM       LADDR           LPORT RADDR           RPORT  TX_KB  RX_KB MS
# 1234  curl       10.0.0.1        45678 93.184.216.34   443       1      12  150
# 5678  nginx      10.0.0.1        80    192.168.1.100   52341     45     2   30021

# Sadece 1 saniyeden uzun bağlantılar
tcplife -D 1000
```

**Kullanım:** Yavaş bağlantılar, çok veri transfer eden bağlantılar, bağlantı süresi analizi.

#### biolatency -- Block I/O Latency

```bash
# Disk I/O latency histogram
biolatency

# Cikti:
#      usecs     : count   distribution
#        0 -> 1  : 0      |                    |
#        2 -> 3  : 0      |                    |
#        4 -> 7  : 15     |**                  |
#        8 -> 15 : 342    |********************|
#       16 -> 31 : 256    |***************     |
#       32 -> 63 : 48     |***                 |
#       64 -> 127: 12     |*                   |
#      128 -> 255: 3      |                    |

# Disk bazinda
biolatency -D

# Milisaniye cinsinden
biolatency -m
```

**Kullanım:** Disk performans analizi, yavaş I/O tespiti, SSD vs HDD karşılaştırması.

#### runqlat -- Scheduler Run Queue Latency

```bash
# CPU run queue bekleme süresi
runqlat

# Cikti:
#      usecs     : count   distribution
#        0 -> 1  : 1523   |********************|
#        2 -> 3  : 890    |************        |
#        4 -> 7  : 234    |***                 |
#        8 -> 15 : 56     |*                   |
#       16 -> 31 : 12     |                    |
#       32 -> 63 : 3      |                    |

# PID bazinda
runqlat -P

# Milisaniye cinsinden
runqlat -m
```

**Kullanım:** CPU doygunluğu tespiti. Yüksek kuyruk süresi = CPU yetersiz veya yanlış scheduling.

#### funccount -- Fonksiyon Sayma

```bash
# Kernel fonksiyon cagrisi sayma
funccount 'vfs_*'

# Cikti:
# FUNC                  COUNT
# vfs_read              15234
# vfs_write              8921
# vfs_open               4567
# vfs_stat               2345

# Belirli bir fonksiyon
funccount 'tcp_sendmsg'

# User-space fonksiyon
funccount 'c:malloc'

# Periyodik çıktı (5 saniyede bir)
funccount -i 5 'vfs_*'
```

#### trace -- Özel Tracing

```bash
# Kernel fonksiyon argümanları
trace 'do_sys_openat2 "%s", arg2'

# Return değerini göster
trace 'r::do_sys_openat2 "ret=%d", retval'

# User-space fonksiyon
trace 'c:open "%s", arg1'

# Koşullu trace
trace 'do_sys_openat2 (arg2 != 0) "%s", arg2'
```

#### Diğer Önemli BCC Araçları

```bash
# TCP retransmit izleme
tcpretrans
# Cikti: hangi baglantilar paket kaybediyor

# TCP connect izleme (giden baglantilar)
tcpconnect
# Cikti: hangi process nereye baglanmaya çalışıyor

# Sayfa cache istatistikleri
cachestat 1
# Cikti: HITS  MISSES  DIRTIES  HITRATIO  BUFFERS_MB
#         1234   56      12      95.67%    128

# Yavas ext4 işlemleri (10ms üstü)
ext4slower 10

# Syscall sayma
syscount -p 1234

# Memory allocation izleme
memleak -p 1234
```

---

## XDP (eXpress Data Path)

**XDP**, NIC driver seviyesinde paket işleme sağlayan eBPF program türüdür. Paketler **kernel network stack'ine girmeden önce** işlenebilir, bu da **muazzam performans** sağlar.

```
Geleneksel Paket Yolu:            XDP Paket Yolu:

NIC                                NIC
 │                                  │
 ▼                                  ▼
Driver                             Driver
 │                                  │
 ▼                                  ▼
sk_buff olustur                    ┌─────────┐
 │                                 │  XDP    │──► XDP_DROP (at)
 ▼                                 │ Program │──► XDP_TX (geri gönder)
TC (traffic control)               │         │──► XDP_REDIRECT (başka if)
 │                                 └────┬────┘
 ▼                                      │ XDP_PASS
Netfilter                               ▼
 │                                 sk_buff olustur (normal akis)
 ▼                                      │
Socket                                  ▼
 │                                 ...normal akis...
 ▼
Application

Avantaj: sk_buff allocation yok = çok düşük overhead
```

#### XDP Aksiyonları

| Aksiyon | Açıklama | Kullanım |
|---------|----------|----------|
| `XDP_PASS` | Paketi normal stack'e ilet | Normal işlem |
| `XDP_DROP` | Paketi at (en hızlı drop) | DDoS mitigation, firewall |
| `XDP_TX` | Paketi aynı interface'den geri gönder | SYN cookie, load balancer |
| `XDP_REDIRECT` | Paketi başka interface'e yönlendir | Load balancing, forwarding |
| `XDP_ABORTED` | Hata, paketi at + trace_xdp_exception | Debug |

#### XDP Program Örneği -- Basit Firewall

```c
// xdp_firewall.bpf.c
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <bpf/bpf_helpers.h>

// Engellenen IP'ler için map
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10000);
    __type(key, __u32);      // IPv4 adres
    __type(value, __u64);    // drop sayaci
} blocked_ips SEC(".maps");

SEC("xdp")
int xdp_firewall(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // Ethernet header kontrolü
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    // Sadece IPv4
    if (eth->h_proto != __constant_htons(ETH_P_IP))
        return XDP_PASS;

    // IP header kontrolü
    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;

    // Source IP engelleme listesinde mi?
    __u32 src_ip = ip->saddr;
    __u64 *counter = bpf_map_lookup_elem(&blocked_ips, &src_ip);

    if (counter) {
        // Engellenen IP -- paketi at ve sayaci artir
        __sync_fetch_and_add(counter, 1);
        return XDP_DROP;
    }

    return XDP_PASS;
}

char LICENSE[] SEC("license") = "GPL";
```

#### XDP Yükleme ve Yönetim

```bash
# XDP programını interface'e yükle
ip link set dev eth0 xdp obj xdp_firewall.o sec xdp

# XDP modları
ip link set dev eth0 xdp obj prog.o          # Native (driver desteği gerekli)
ip link set dev eth0 xdpgeneric obj prog.o   # Generic (tüm driver'lar, yavaş)
ip link set dev eth0 xdpoffload obj prog.o   # Offload (NIC hardware, en hızlı)

# XDP programını kaldır
ip link set dev eth0 xdp off

# Yüklenen programı kontrol et
ip link show dev eth0
bpftool prog show
bpftool map show
```

#### XDP ile DDoS Mitigation

```c
// SYN flood koruması -- rate limiting
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 100000);
    __type(key, __u32);          // source IP
    __type(value, struct rate_info);
} rate_limit SEC(".maps");

struct rate_info {
    __u64 last_seen;   // son paket zamani
    __u32 count;       // pencere icindeki paket sayisi
};

SEC("xdp")
int xdp_ddos_mitigate(struct xdp_md *ctx)
{
    // ... header parsing ...

    struct rate_info *info = bpf_map_lookup_elem(&rate_limit, &src_ip);
    __u64 now = bpf_ktime_get_ns();

    if (info) {
        // 1 saniye pencere içinde 100'den fazla SYN paketi = drop
        if ((now - info->last_seen) < 1000000000) {  // 1 saniye
            if (info->count > 100) {
                return XDP_DROP;
            }
            info->count++;
        } else {
            info->last_seen = now;
            info->count = 1;
        }
    } else {
        struct rate_info new_info = { .last_seen = now, .count = 1 };
        bpf_map_update_elem(&rate_limit, &src_ip, &new_info, BPF_ANY);
    }

    return XDP_PASS;
}
```

#### XDP Performans Karşılaştırması

| Yöntem | Paket/saniye (drop) | CPU Kullanımı |
|--------|---------------------|---------------|
| iptables DROP | ~2-3 Mpps | Yüksek |
| nftables DROP | ~3-4 Mpps | Orta-yüksek |
| XDP_DROP (generic) | ~5 Mpps | Orta |
| XDP_DROP (native) | ~24 Mpps | Düşük |
| XDP_DROP (offload) | ~40+ Mpps | Sıfıra yakın |

> [!tip] XDP Kullanım Alanları
> - **DDoS mitigation**: Saldırı paketlerini kernel stack'e girmeden at
> - **Load balancing**: Facebook'un Katran, Cloudflare'in Unimog projesi
> - **Monitoring**: Paket sayma, flow tracking
> - **NAT**: Yüksek performanslı adres dönüşümü

---

## eBPF ve Security

eBPF, Linux güvenliğinde iki farklı rolde kullanılır: **güvenlik mekanizması olarak** (seccomp-BPF) ve **güvenlik izleme aracı olarak** (runtime security).

#### seccomp-BPF

**seccomp-BPF**, process'lerin kullanabileceği syscall'ları **filtrelemek** için cBPF/eBPF kullanır. Docker ve container runtime'ların temel güvenlik mekanizmasıdır.

```c
// seccomp-BPF ile syscall filtreleme örneği
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <linux/audit.h>
#include <sys/prctl.h>

// BPF filtresi: write() dışında tüm syscall'lari engelle
struct sock_filter filter[] = {
    // Syscall numarasini yükle
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             offsetof(struct seccomp_data, nr)),

    // write (1) ise izin ver
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_write, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),

    // exit_group (231) ise izin ver
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_exit_group, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),

    // Digerleri: KILL
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL),
};

struct sock_fprog prog = {
    .len = sizeof(filter) / sizeof(filter[0]),
    .filter = filter,
};

// seccomp filtresini aktif et
prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog);
```

```bash
# Docker default seccomp profili
docker run --security-opt seccomp=/path/to/profile.json myapp

# Seccomp'u devre dışı bırak (tehlikeli!)
docker run --security-opt seccomp=unconfined myapp
```

#### Falco -- Runtime Security

**Falco** (Sysdig/CNCF), eBPF tabanlı runtime security monitoring aracıdır. Kernel seviyesinde şüphe çekici aktiviteleri tespit eder.

```yaml
# Falco kural örneği
- rule: Terminal shell in container
  desc: Container içinde shell acildigini tespit et
  condition: >
    spawned_process and
    container and
    shell_procs and
    proc.tty != 0
  output: >
    Shell baslatildi (user=%user.name container=%container.name
    shell=%proc.name parent=%proc.pname cmdline=%proc.cmdline)
  priority: WARNING

- rule: Write below /etc
  desc: /etc altina yazma tespit et
  condition: >
    write and
    fd.directory = /etc and
    container
  output: >
    /etc altina yazıldı (file=%fd.name container=%container.name
    command=%proc.cmdline)
  priority: ERROR
```

```bash
# Falco kurulumu (Helm ile Kubernetes)
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco \
  --set driver.kind=ebpf \
  --set falcosidekick.enabled=true

# Falco çıktısı
# 17:23:45.123456 Warning Shell baslatildi
#   (user=root container=nginx shell=bash parent=runc cmdline=bash)
```

#### eBPF Tabanlı Security Araçları

| Araç | Amaç | Yöntem |
|------|------|--------|
| **Falco** | Runtime threat detection | Syscall izleme, kural tabanlı alarm |
| **Tetragon** (Cilium) | Runtime enforcement | Kernel seviyesinde aksiyon (SIGKILL) |
| **KubeArmor** | Container security | LSM + eBPF |
| **Tracee** (Aqua) | Runtime security + forensics | Event-driven security |
| **seccomp-BPF** | Syscall filtreleme | Process bazında izin/engelleme |

```bash
# Tetragon ile process izleme + engelleme
# /tmp altında çalıştırılan binary'leri otomatik sonlandır
kubectl apply -f - <<EOF
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: block-tmp-exec
spec:
  kprobes:
  - call: "security_bprm_check"
    syscall: false
    args:
    - index: 0
      type: "linux_binprm"
    selectors:
    - matchArgs:
      - index: 0
        operator: "Prefix"
        values:
        - "/tmp/"
      matchActions:
      - action: Sigkill
EOF
```

> [!warning] eBPF Güvenlik Gereksinimleri
> eBPF programları yüklemek **CAP_BPF** (veya **CAP_SYS_ADMIN**) yetkisi gerektirir.
> Unprivileged eBPF varsayılan olarak devre dışıdır:
> ```bash
> cat /proc/sys/kernel/unprivileged_bpf_disabled
> # 1 = devre dışı (güvenli default)
> # 0 = herkes yükleme yapabilir (tehlikeli)
> ```

---

## eBPF ve Networking

eBPF, modern cloud-native networking'in temelini oluşturur. Özellikle **Cilium** projesi, Kubernetes networking'i tamamen eBPF üzerine inşa etmiştir.

#### Cilium

**Cilium**, eBPF tabanlı Kubernetes CNI (Container Network Interface) plugin'idir. Geleneksel iptables tabanli networking'i tamamen eBPF ile değiştirir.

```
Geleneksel kube-proxy:              Cilium (eBPF):

Pod A                                Pod A
  │                                    │
  ▼                                    ▼
veth                                 veth
  │                                    │
  ▼                                    ▼
bridge                                ┌──────────┐
  │                                   │  eBPF    │
  ▼                                   │  (tc/XDP)│
iptables (DNAT)                       └────┬─────┘
  │  binlerce kural                        │ doğrudan yönlendirme
  │  linear scan                           │ O(1) map lookup
  ▼                                        ▼
routing                               Pod B / External
  │
  ▼
veth
  │
  ▼
Pod B
```

#### kube-proxy Replacement

```bash
# Cilium'u kube-proxy olmadan kur
helm install cilium cilium/cilium \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=API_SERVER_IP \
  --set k8sServicePort=6443

# Cilium durumunu kontrol et
cilium status
cilium connectivity test

# Service haritasini gor
cilium service list
# ID  Frontend          Backend
# 1   10.96.0.1:443     192.168.1.10:6443
# 2   10.96.0.10:53     192.168.1.20:53, 192.168.1.21:53
```

#### kube-proxy vs Cilium Karşılaştırması

| Özellik | kube-proxy (iptables) | kube-proxy (IPVS) | Cilium (eBPF) |
|---------|----------------------|-------------------|---------------|
| Service ölçekleme | O(n) kural | O(1) hash | O(1) map lookup |
| 1000 service | ~20000 kural | ~1000 ipvs rule | ~1000 map entry |
| Kural güncelleme | Tüm kuralları yeniden yaz | Incremental | Incremental |
| Network policy | Ek iptables kuralları | Ek iptables | Aynı eBPF program |
| Observability | Sınırlı | Sınırlı | Hubble ile zengin |
| DSR (Direct Server Return) | Yok | Sınırlı | Tam destek |
| Session affinity | iptables ile | IPVS ile | eBPF map ile |

#### Cilium Network Policy

```yaml
# L3/L4 + L7 network policy (HTTP bazli)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-access
spec:
  endpointSelector:
    matchLabels:
      app: api-server
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http:
        - method: "GET"
          path: "/api/v1/.*"
        - method: "POST"
          path: "/api/v1/orders"
```

#### Service Mesh (Sidecar-free)

```
Geleneksel Service Mesh:            Cilium Service Mesh:
(Istio/Linkerd)                     (Sidecar-free)

Pod                                  Pod
┌──────────────────┐                ┌──────────────────┐
│  ┌─────────────┐ │                │  ┌─────────────┐ │
│  │ Application │ │                │  │ Application │ │
│  └──────┬──────┘ │                │  └──────┬──────┘ │
│         │        │                │         │        │
│  ┌──────┴──────┐ │                └─────────┼────────┘
│  │ Sidecar     │ │                          │
│  │ Proxy       │ │                    ┌─────┴─────┐
│  │ (Envoy)     │ │                    │ eBPF      │  <-- kernel
│  └─────────────┘ │                    │ (L3/L4/L7)│     seviyesinde
└──────────────────┘                    └───────────┘

Her pod'da ekstra container        Sidecar yok
RAM + CPU tuketimi yüksek          Kernel seviyesinde işlem
Latency eklenir                    Minimal latency
```

#### Hubble -- eBPF Tabanlı Observability

```bash
# Hubble ile network akislarini izle
hubble observe --namespace default

# Cikti:
# TIMESTAMP  SOURCE             DESTINATION        TYPE    VERDICT
# 12:34:56   default/frontend   default/api        L7/HTTP FORWARDED
# 12:34:57   default/api        default/db         L4/TCP  FORWARDED
# 12:34:58   default/api        kube-system/dns    L4/UDP  FORWARDED

# HTTP bazli filtreleme
hubble observe --protocol http --http-status 500

# DNS sorgularini izle
hubble observe --protocol dns

# Hubble UI (web arayuzu)
cilium hubble ui
```

---

## eBPF ve Observability

eBPF, geleneksel monitoring araçlarının ulaşamadığı **kernel seviyesinde** observability sağlar: continuous profiling, distributed tracing ve detayli metrik toplama.

#### Continuous Profiling

```bash
# CPU profiling (flame graph oluşturma)
# bpftrace ile profiling
bpftrace -e 'profile:hz:99 /comm == "myapp"/ {
    @[ustack(perf), comm] = count();
}' > profile_data.txt

# perf + eBPF ile profiling
perf record -F 99 -g -p $(pidof myapp) -- sleep 30
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg
```

#### Off-CPU Analizi

```bash
# Process nerede beklede (I/O, lock, sleep)?
bpftrace -e '
tracepoint:sched:sched_switch {
    if (args->prev_state == 1) {  // TASK_INTERRUPTIBLE
        @start[args->prev_pid] = nsecs;
    }
}
tracepoint:sched:sched_switch {
    if (@start[args->next_pid]) {
        @off_cpu_us[args->next_comm] =
            hist((nsecs - @start[args->next_pid]) / 1000);
        delete(@start[args->next_pid]);
    }
}'
```

#### Profiling Araçları Karşılaştırması

| Araç | Yöntem | Overhead | Kullanım |
|------|--------|----------|----------|
| **Pyroscope** | eBPF continuous profiling | ~1% CPU | Production profiling |
| **Parca** | eBPF profiling (Polar Signals) | ~1% CPU | Flame graph, diff |
| **perf** | Sampling + eBPF | Düşük | CPU profiling |
| **bpftrace** | eBPF tracing | Düşük | Adhoc analiz |
| **gprof** | Instrumentation | Yüksek | Development |
| **Valgrind** | Emulation | 10-50x yavaş | Development |

#### Distributed Tracing Entegrasyonu

eBPF, uygulama kodunu değiştirmeden **otomatik** distributed tracing yapabilir. TCP/HTTP header'larından trace context'i çıkarılır.

```bash
# Pixie (eBPF ile otomatik tracing)
# Uygulama kodunda HICBIR değişiklik gerekmez
px run service:service_stats

# Cikti:
# SERVICE      REQUESTS  ERRORS  LATENCY_P50  LATENCY_P99
# frontend     12345     23      12ms         150ms
# api-server   8901      5       8ms          95ms
# db-service   4567      1       2ms          25ms
```

---

## strace vs bpftrace Performans Karşılaştırması

strace ve bpftrace aynı işi (syscall tracing) yapar ama temelden farklı mekanizmalar kullanır.

#### Mekanizma Farkı

```
strace (ptrace):                    bpftrace (eBPF):

  Traced Process                      Traced Process
       │                                   │
       │ her syscall'da                    │ eBPF program
       │ 2x context switch                 │ in-kernel çalışır
       ▼                                   ▼
  ┌─────────┐                         ┌──────────────┐
  │ SIGSTOP │ process durur           │ eBPF handler │ process DURMAZ
  └────┬────┘                         │ (JIT native) │
       │                              └──────┬───────┘
       ▼                                     │
  ┌─────────┐                                │ map güncelle
  │ strace  │ user-space                     │ veya event gönder
  │ process │ okur                           │
  └────┬────┘                                ▼
       │                              ┌──────────────┐
       ▼                              │ User-space   │
  ┌─────────┐                         │ (bpftrace)   │
  │ SIGCONT │ process devam eder      │ map okur     │
  └─────────┘                         └──────────────┘

Her syscall: 2 context switch        Her syscall: 0 context switch
+ 2 signal + ptrace overhead         + JIT native kod
= ciddi yavaşlık                     = minimal overhead
```

#### Performans Karşılaştırması

| Metrik | strace | bpftrace |
|--------|--------|----------|
| **Mekanizma** | ptrace (process durdurma) | eBPF (in-kernel) |
| **Overhead** | %100-500x yavaşlatma | <%5 yavaşlatma |
| **Context switch** | Her syscall için 2x | Yok |
| **Process durdurma** | Evet (SIGSTOP/SIGCONT) | Hayır |
| **Production kullanımı** | Kısa süreli debug için | Sürekli monitoring için güvenli |
| **Çoklu process** | Her biri için ayrı ptrace | Tek program tüm system |
| **Filtreleme** | User-space (sonradan) | Kernel-space (kaynakta) |
| **Veri toplama** | Tek tek event yazımı | Map'lerle aggregation |

#### Pratik Karşılaştırma

```bash
# strace ile syscall sayma (yavaş)
time strace -c -p $(pidof nginx) -e trace=read,write -- sleep 10
# real    0m10.5s (nginx ciddi yavaslar)

# bpftrace ile syscall sayma (hızlı)
time bpftrace -e '
tracepoint:syscalls:sys_enter_read,
tracepoint:syscalls:sys_enter_write /comm == "nginx"/ {
    @[probe] = count();
}' -d 10
# real    0m10.0s (nginx etkilenmez)
```

```bash
# Karsilastirma: 10000 syscall yapan programda

# strace
time strace -c ./test_program
# real    0m2.34s   (strace ile)
# normal: 0m0.12s   (strace'siz)
# Yavaslatma: ~20x

# bpftrace
time bpftrace -e 'tracepoint:raw_syscalls:sys_enter /pid == PIDOF/ {
    @cnt = count();
}' &
time ./test_program
# real    0m0.13s   (bpftrace ile)
# Yavaslatma: ~%8
```

> [!tip] Ne Zaman Hangisi?
> - **strace**: Geliştirme ortamında hızlı debug, tek process analizi, basit sorun tespit
> - **bpftrace**: Production'da tracing, çoklu process izleme, performans analizi, sürekli monitoring

---

## Pratik eBPF / bpftrace Örnekleri

#### Örnek 1: Yavaş Syscall Tespit

```bash
#!/usr/bin/env bpftrace
// yavaş_syscall.bt -- 1ms'den uzun suren syscall'lari yakala

tracepoint:raw_syscalls:sys_enter {
    @start[tid] = nsecs;
}

tracepoint:raw_syscalls:sys_exit /@start[tid]/ {
    $duration_ms = (nsecs - @start[tid]) / 1000000;

    if ($duration_ms > 1) {
        printf("%-8d %-16s syscall=%-4d süre=%dms\n",
               pid, comm, @start[tid] != 0 ? args->id : 0, $duration_ms);
    }

    delete(@start[tid]);
}
```

#### Örnek 2: Container İçinde Çalıştırılan Komutlar

```bash
#!/usr/bin/env bpftrace
// container_exec.bt -- container içinde exec edilen komutları izle

tracepoint:syscalls:sys_enter_execve {
    // cgroup id ile container tespiti
    $cgid = cgroup;
    if ($cgid > 1) {  // host değil
        printf("%-8d %-8d %-16s ", pid, uid, comm);
        join(args->argv);
    }
}
```

#### Örnek 3: TCP Retransmit Analizi

```bash
#!/usr/bin/env bpftrace
// tcp_retransmit.bt -- TCP retransmit event'lerini izle

tracepoint:tcp:tcp_retransmit_skb {
    printf("%-20s ", strftime("%H:%M:%S.%f", nsecs));
    printf("%-6d %-16s ", pid, comm);
    printf("%s:%d -> %s:%d state=%d\n",
           ntop(args->saddr), args->sport,
           ntop(args->daddr), args->dport,
           args->state);
}

interval:s:10 {
    printf("\n--- Son 10 saniye: %d retransmit ---\n", @total);
    @total = 0;
}

tracepoint:tcp:tcp_retransmit_skb {
    @total++;
    @by_dest[ntop(args->daddr)] = count();
}
```

#### Örnek 4: Dosya Sistemi Latency Haritası

```bash
#!/usr/bin/env bpftrace
// fs_latency.bt -- dosya sistemi operasyon sureleri

kprobe:vfs_read   { @start[tid] = nsecs; @op[tid] = "read"; }
kprobe:vfs_write  { @start[tid] = nsecs; @op[tid] = "write"; }
kprobe:vfs_fsync  { @start[tid] = nsecs; @op[tid] = "fsync"; }
kprobe:vfs_open   { @start[tid] = nsecs; @op[tid] = "open"; }

kretprobe:vfs_read,
kretprobe:vfs_write,
kretprobe:vfs_fsync,
kretprobe:vfs_open /@start[tid]/ {
    $us = (nsecs - @start[tid]) / 1000;

    @latency_us[@op[tid]] = hist($us);

    if ($us > 10000) {  // 10ms üstü
        printf("YAVAS: %-8d %-16s %-6s %d us\n",
               pid, comm, @op[tid], $us);
    }

    delete(@start[tid]);
    delete(@op[tid]);
}
```

#### Örnek 5: Memory Allocation Profiling

```bash
#!/usr/bin/env bpftrace
// malloc_profile.bt -- malloc/free dengesizligi tespit

uprobe:/lib/x86_64-linux-gnu/libc.so.6:malloc {
    @malloc_size[comm] = hist(arg0);
    @malloc_count[comm] = count();
}

uprobe:/lib/x86_64-linux-gnu/libc.so.6:free {
    @free_count[comm] = count();
}

interval:s:10 {
    printf("\n=== Memory Allocation Raporu ===\n");
    print(@malloc_count);
    print(@free_count);
    // malloc_count >> free_count ise -> olasi memory leak
}
```

#### Örnek 6: Network Baglanti Haritasi

```bash
#!/usr/bin/env bpftrace
// net_map.bt -- aktif network baglantilarini izle

kprobe:tcp_v4_connect {
    @connecting[pid, comm] = count();
}

kretprobe:tcp_v4_connect /retval == 0/ {
    @connected[comm] = count();
}

kretprobe:tcp_v4_connect /retval != 0/ {
    @connect_failed[comm, retval] = count();
}

kprobe:tcp_close {
    @closed[comm] = count();
}

interval:s:30 {
    printf("\n=== TCP Baglanti Ozeti (son 30s) ===\n");
    print(@connected);
    print(@connect_failed);
    print(@closed);
    clear(@connected);
    clear(@connect_failed);
    clear(@closed);
}
```

---

## eBPF Gelistirme Araçları ve Ekosistem

| Arac | Tur | Açıklama |
|------|-----|----------|
| **bpftrace** | Yuksek seviye dil | AWK benzeri one-liner tracing |
| **BCC** | Python/Lua framework | Hazir araclar + özel program yazma |
| **libbpf** | C kutuphanesi | CO-RE destekli, en düşük seviye |
| **libbpf-rs** | Rust kutuphanesi | Rust ile eBPF geliştirme |
| **cilium/ebpf** | Go kutuphanesi | Go ile eBPF program yükleme |
| **bpftool** | CLI aracı | eBPF programlari ve map'leri yonetme |
| **BTF** | Binary format | Kernel veri yapı bilgisi (CO-RE için) |

#### bpftool Kullanimi

```bash
# Yuklenen eBPF programlari listele
bpftool prog list
# 12: kprobe  tag abc123  gpl
#     loaded_at 2024-01-15T10:30:00
#     uid 0
#     xlated 456B  jited 789B  memlock 4096B

# Program detayi
bpftool prog show id 12

# Map listele
bpftool map list
# 5: hash  name syscall_count  flags 0x0
#     key 4B  value 8B  max_entries 1024  memlock 82944B

# Map içeriğini oku
bpftool map dump id 5

# BTF bilgisi
bpftool btf show
bpftool btf dump id 1

# Feature kontrol
bpftool feature probe kernel
```

#### Gereksinimler ve Kurulum

```bash
# Kernel versiyonu kontrol (minimum 4.18, ideal 5.8+)
uname -r

# BTF desteği kontrol (CO-RE için gerekli)
ls /sys/kernel/btf/vmlinux

# Gerekli kernel config
# CONFIG_BPF=y
# CONFIG_BPF_SYSCALL=y
# CONFIG_BPF_JIT=y
# CONFIG_HAVE_EBPF_JIT=y
# CONFIG_BPF_EVENTS=y
# CONFIG_DEBUG_INFO_BTF=y  (CO-RE için)

# Kurulum (Ubuntu/Debian)
apt-get install -y \
    bpftrace \
    bpfcc-tools \
    libbpf-dev \
    linux-headers-$(uname -r) \
    linux-tools-$(uname -r)

# Kurulum (Fedora)
dnf install -y \
    bpftrace \
    bcc-tools \
    libbpf-devel \
    kernel-headers \
    kernel-devel
```

> [!info] Kernel Versiyon ve eBPF Ozellikleri
> | Kernel | Özellik |
> |--------|---------|
> | 3.18 | eBPF ilk eklendi |
> | 4.1 | kprobe programlari |
> | 4.8 | XDP |
> | 4.10 | cgroup eBPF |
> | 4.18 | BTF (BPF Type Format) |
> | 5.2 | 1M instruction limiti (eskisi 4096) |
> | 5.3 | Bounded loops |
> | 5.5 | LSM programlari |
> | 5.7 | Ring buffer map |
> | 5.8 | fentry/fexit (daha hızlı kprobe alternatifi) |
> | 5.10 | BPF iterator, task-local storage |
> | 5.15 | BPF timer |

---

## Ozet

```
eBPF Kullanim Alanlari:

┌─────────────────────────────────────────────────────────┐
│                        eBPF                             │
├──────────────┬──────────────┬──────────────┬────────────┤
│  Networking  │ Observability│   Security   │  Tracing   │
├──────────────┼──────────────┼──────────────┼────────────┤
│ Cilium       │ Profiling    │ Falco        │ bpftrace   │
│ XDP          │ Flame graphs │ Tetragon     │ BCC tools  │
│ Load balance │ Metrics      │ seccomp-BPF  │ perf       │
│ Service mesh │ Hubble       │ KubeArmor    │ ftrace     │
│ kube-proxy   │ Pixie        │ Tracee       │ funccount  │
│ replacement  │ Pyroscope    │ LSM hooks    │ trace      │
└──────────────┴──────────────┴──────────────┴────────────┘
```

**Temel Cikarilar:**

- eBPF, kernel'i yeniden derlemeden veya modül yüklemeden **kernel davranışını programlama** imkani verir
- **Verifier** güvenlik sağlar, **JIT** performans sağlar, **maps** veri paylaşımı sağlar
- **bpftrace** hızlı analiz için, **BCC** hazir araclar için, **libbpf** production programlar için kullanılır
- **XDP** ile saniyede milyonlarca paket islenebilir (DDoS koruması, load balancing)
- **Cilium** Kubernetes networking'i eBPF ile yeniden tanimlar (kube-proxy replacement, L7 policy, service mesh)
- strace'e gore **100x daha az overhead** ile production'da guvenle kullanılabilir
- Modern Linux altyapısında eBPF: networking (Cilium), security (Falco/Tetragon), observability (Hubble/Pixie) olarak **her yerde**
