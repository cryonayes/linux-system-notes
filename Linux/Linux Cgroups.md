# Linux Cgroups

**Cgroups (Control Groups)**, Linux kernel'inin process'lere **kaynak limiti** koymasını sağlayan mekanizmadır.

[[Linux Namespaces]] → **ne görüyorsun?** (izolasyon)
Cgroups → **ne kadar kullanabilirsin?** (kaynak kontrolü)

---

## Cgroup Ne Kontrol Eder?

| Kaynak | Açıklama |
|--------|----------|
| **CPU** | Process'in kullanabileceği CPU süresi |
| **Memory** | RAM limiti, swap limiti |
| **I/O** | Disk read/write bandwidth |
| **PIDs** | Maksimum process sayısı |
| **Network** | Paket önceliklendirme (net_cls, net_prio) |

---

## Cgroup v1 vs Cgroup v2

#### Cgroup v1
- Her kaynak (CPU, memory, I/O) **ayrı hiyerarşi** ile yönetilir
- Bir process farklı kaynak controller'ları için farklı cgroup'larda olabilir
- Karmaşık, tutarsız davranışlar mümkün

```
/sys/fs/cgroup/
├── cpu/
│   └── docker/<container-id>/
├── memory/
│   └── docker/<container-id>/
└── blkio/
    └── docker/<container-id>/
```

#### Cgroup v2
- **Tek unified hiyerarşi**
- Bir process tek bir cgroup'a ait
- Daha temiz, tutarlı API
- Pressure Stall Information (PSI) desteği
- eBPF ile entegrasyon

```
/sys/fs/cgroup/
└── system.slice/
    └── docker-<container-id>.scope/
        ├── cpu.max
        ├── memory.max
        ├── memory.current
        └── io.max
```

> [!warning] Uyumluluk
> Docker 20.10+ cgroup v2 destekler. Eski kernel'lerde (< 4.15) sadece v1 bulunur.
> Hangi versiyon aktif: `stat -fc %T /sys/fs/cgroup/`
> `cgroup2fs` → v2, `tmpfs` → v1

---

## Pressure Stall Information (PSI)

PSI, Linux kernel'in **CPU, bellek ve disk I/O baskısı nedeniyle süreçlerin ne kadar beklediğini** ölçen mekanizmasıdır.
## Neden önemli?

- Klasik `cpu%` tek başına darboğazı her zaman göstermez.
- PSI, doğrudan "iş yapamama/bekleme" süresini verir.
- Özellikle container ve multi-tenant sistemlerde gürültülü komşu etkisini yakalamada çok faydalıdır.

## Nereden okunur?

```bash
cat /proc/pressure/cpu
cat /proc/pressure/memory
cat /proc/pressure/io
```

Alanlar:
- `some`: En az bir process beklemiş.
- `full`: Tüm çalışabilir processler beklemiş (kritik).
- `avg10/avg60/avg300`: Son 10/60/300 saniyelik ortalama baskı yüzdesi.
- `total`: Sistem açıldığından beri biriken bekleme süresi (mikrosaniye).

## Kısa örnek yorum

Örnek CPU çıktısı:

```text
some avg10=0.66 avg60=0.45 avg300=0.79 total=...
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
```

Yorum:
- `cpu some` sıfırdan büyük: Hafif CPU beklemesi var.
- `cpu full` sıfır: Toplu/kritik CPU kilitlenmesi yok.
- `memory` ve `io` tarafında `avg* = 0.00`: Anlık baskı görünmüyor.

---

## CPU Kontrolü

#### CPU Shares (göreceli ağırlık)
```bash
docker run --cpu-shares=512 myapp
```
- Default: 1024
- 512 = diğerlerinin yarısı kadar CPU hakkı
- Sadece **contention** durumunda etkili (boş CPU varsa limit yok)

#### CPU Quota (kesin limit)
```bash
docker run --cpus=1.5 myapp
```
- 1.5 CPU core kullanabilir (max)
- Arka planda: `cpu.cfs_quota_us / cpu.cfs_period_us`

```bash
# Manuel eşdeğeri
docker run --cpu-period=100000 --cpu-quota=150000 myapp
# 150000 / 100000 = 1.5 CPU
```

#### Cpuset (belirli core'lara pin)
```bash
docker run --cpuset-cpus="0,2" myapp
```
- Sadece CPU 0 ve CPU 2 üzerinde çalışır
- NUMA-aware uygulamalar için kritik

---

## Memory Kontrolü

#### Hard Limit
```bash
docker run --memory=512m myapp
```
- Container max 512 MB RAM kullanabilir
- Aşarsa → **OOM Killer** devreye girer

#### Soft Limit (reservation)
```bash
docker run --memory=512m --memory-reservation=256m myapp
```
- 256 MB garanti edilir
- 512 MB'a kadar çıkabilir (sistem müsaitse)

#### Swap Limiti
```bash
docker run --memory=512m --memory-swap=1g myapp
```
- 512 MB RAM + 512 MB swap = toplam 1 GB
- `--memory-swap=-1` → sınırsız swap
- `--memory-swap=0` veya belirtilmezse → swap = 2x memory

#### Memory Kullanımını İzleme
```bash
# Container memory stats
docker stats <container>

# Cgroup dosyasından direkt okuma (v2)
cat /sys/fs/cgroup/system.slice/docker-<id>.scope/memory.current
cat /sys/fs/cgroup/system.slice/docker-<id>.scope/memory.max
```

---

## OOM Killer (Out of Memory Killer)

Container memory limitini aştığında kernel **OOM Killer**'ı tetikler.

#### Ne olur?
1. Container process memory limit'e ulaşır
2. Kernel `oom_score` hesaplar
3. En yüksek score'lu process **SIGKILL** alır
4. Container restart policy'ye göre davranır

#### OOM Score
```bash
# Process'in OOM score'u
cat /proc/<pid>/oom_score

# OOM score adjustment (-1000 ile 1000 arası)
cat /proc/<pid>/oom_score_adj
```

- `-1000` → OOM'dan muaf (kritik system process'ler)
- `0` → normal
- `1000` → ilk öldürülecek

#### Docker'da OOM Kontrolü
```bash
# OOM Killer'ı devre dışı bırak (tehlikeli!)
docker run --oom-kill-disable --memory=512m myapp

# OOM score ayarla
docker run --oom-score-adj=500 myapp
```

> [!warning] Dikkat
> `--oom-kill-disable` kullanırken **mutlaka** `--memory` limiti de ver.
> Yoksa container tüm host memory'sini tüketebilir ve **host OOM** olur.

#### OOM Olaylarını İzleme
```bash
# Docker event'lerinden
docker events --filter event=oom

# Kernel log'dan
dmesg | grep -i "oom\|killed"
```

---
## OOM Score Mekanizması

Linux'ta bellek tükendiğinde (OOM: Out Of Memory), kernel hangi süreci sonlandıracağına bir puanlama ile karar verir.

## `oom_score` nedir?

`/proc/<pid>/oom_score`, ilgili sürecin OOM sırasında öldürülme adaylığı puanını gösterir.

- Aralık pratikte `0` ile `1000` arasındadır.
- Puan yükseldikçe OOM anında sonlandırılma olasılığı artar.

Örnek:

```bash
cat /proc/1234/oom_score
```

Not: `cat /proc/self/oom_score` komutu, shell yerine çoğu zaman `cat` sürecinin puanını gösterir. Shell için `$$` kullan:

```bash
cat /proc/$$/oom_score
```

## `oom_score_adj` nedir?

`/proc/<pid>/oom_score_adj`, kernelin hesapladığı puana manuel bir etki (bias) uygular.

- Aralık: `-1000` ile `+1000`
- `-1000`: Neredeyse hiç öldürme
- `0`: Varsayılan
- `+1000`: Çok güçlü şekilde öldürme adayı yap

Örnek görüntüleme:

```bash
cat /proc/1234/oom_score_adj
```

Örnek değiştirme:

```bash
echo 500 | sudo tee /proc/1234/oom_score_adj
```

## Pratik kullanım

- Kritik servisler için daha düşük değerler (ör. `-500`, `-900`)
- Worker/batch süreçleri için daha yüksek değerler (ör. `+200`, `+500`)

## Dikkat edilmesi gerekenler

- Çok fazla süreci negatif değerlere çekmek, OOM anında kernelin seçeneklerini azaltır.
- Ayarları servis yöneticisinden yapmak daha sürdürülebilirdir. Örneğin systemd:

```ini
[Service]
OOMScoreAdjust=-500
```

Bu şekilde süreç her yeniden başladığında ayar korunur.


---

## I/O Kontrolü

```bash
# Read/write bandwidth limiti
docker run --device-read-bps /dev/sda:10mb \
           --device-write-bps /dev/sda:5mb myapp

# IOPS limiti
docker run --device-read-iops /dev/sda:1000 \
           --device-write-iops /dev/sda:500 myapp
```

> [!info] Not
> I/O limitleri **direct I/O** için çalışır. Buffered I/O (page cache) üzerinden yapılan yazımlar limiti atlayabilir. Cgroup v2'de `io.max` ile daha tutarlı kontrol sağlanır.

---

## PID Limiti

```bash
docker run --pids-limit=100 myapp
```

- Container içinde max 100 process olabilir
- Fork bomb koruması sağlar

```bash
# Fork bomb örneği (PID limit olmadan host'u çökertir)
:(){ :|:& };:
```

> [!tip] Best Practice
> Production container'larında **her zaman** `--pids-limit` kullanılmalı.

---

## Cgroup Dosya Sistemi Yapısı (v2)

```
/sys/fs/cgroup/system.slice/docker-<container-id>.scope/
├── cgroup.controllers      # Aktif controller'lar
├── cgroup.procs            # Bu cgroup'taki PID'ler
├── cpu.max                 # CPU quota (quota period)
├── cpu.stat                # CPU kullanım istatistikleri
├── memory.current          # Şu anki memory kullanımı
├── memory.max              # Memory hard limit
├── memory.high             # Memory soft limit (throttle)
├── memory.swap.current     # Swap kullanımı
├── memory.swap.max         # Swap limiti
├── io.max                  # I/O bandwidth limiti
├── io.stat                 # I/O istatistikleri
└── pids.max                # Max process sayısı
```
