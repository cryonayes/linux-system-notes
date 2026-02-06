# Linux Namespaces

Namespace = process'lerin **kernel objelerini farklı görmesini** sağlar.
Aynı kernel, farklı "gerçeklik".

> [!info] Docker ile ilişki
> Docker, container izolasyonunu sağlamak için bu namespace'leri kullanır → [[Docker Temelleri#Container Isolation Nasıl Sağlanır?]]
> Namespace = **ne görüyorsun?**, Cgroup = **ne kadar kullanabilirsin?** → [[Linux Cgroups]]

---

## Namespace Türleri

Linux kernel **8 farklı namespace** destekler:

| Namespace | Flag | İzole Edilen | Kernel Versiyonu |
|-----------|------|-------------|-----------------|
| **PID** | `CLONE_NEWPID` | Process ID ağacı | 2.6.24 (2008) |
| **Network** | `CLONE_NEWNET` | Network stack | 2.6.29 (2009) |
| **Mount** | `CLONE_NEWNS` | Filesystem mount noktaları | 2.4.19 (2002) |
| **UTS** | `CLONE_NEWUTS` | Hostname, domain name | 2.6.19 (2006) |
| **IPC** | `CLONE_NEWIPC` | Shared memory, semaphore, message queue | 2.6.19 (2006) |
| **User** | `CLONE_NEWUSER` | UID/GID mapping | 3.8 (2013) |
| **Cgroup** | `CLONE_NEWCGROUP` | Cgroup root dizini | 4.6 (2016) |
| **Time** | `CLONE_NEWTIME` | Monotonic/boottime clock | 5.6 (2020) |

---

## Namespace Nasıl Oluşturulur?

#### clone() Syscall

Yeni bir process oluştururken **aynı anda** yeni namespace'ler yaratır.
Docker'ın (runc'ın) container oluştururken kullandığı yöntem budur.

```c
// Yeni PID + network + mount namespace ile process oluştur
int flags = CLONE_NEWPID | CLONE_NEWNET | CLONE_NEWNS | SIGCHLD;
pid_t child = clone(child_func, stack + STACK_SIZE, flags, arg);
```

#### unshare() Syscall / Komutu

Mevcut process'i **yeni namespace'lere** taşır. Yeni process oluşturmaz.

```bash
# Yeni PID + mount namespace'de shell başlat
sudo unshare --pid --mount --fork /bin/bash

# Yeni network namespace'de shell başlat
sudo unshare --net /bin/bash

# Tüm namespace'leri izole et
sudo unshare --pid --net --mount --uts --ipc --fork /bin/bash
```

#### setns() Syscall

Mevcut process'i **var olan** bir namespace'e sokar.
`nsenter` komutu ve `docker exec` bu mekanizmayı kullanır.

```c
// Var olan namespace'e gir
int fd = open("/proc/12345/ns/net", O_RDONLY);
setns(fd, CLONE_NEWNET);
```

---

## /proc/\<pid\>/ns/ — Namespace Dosyaları

Her process'in namespace üyelikleri `/proc/<pid>/ns/` altında görülebilir.

```bash
# Process'in namespace'lerini görmek
ls -la /proc/self/ns/
lrwxrwxrwx 1 root root 0 ... cgroup -> cgroup:[4026531835]
lrwxrwxrwx 1 root root 0 ... ipc -> ipc:[4026531839]
lrwxrwxrwx 1 root root 0 ... mnt -> mnt:[4026531841]
lrwxrwxrwx 1 root root 0 ... net -> net:[4026531840]
lrwxrwxrwx 1 root root 0 ... pid -> pid:[4026531836]
lrwxrwxrwx 1 root root 0 ... user -> user:[4026531837]
lrwxrwxrwx 1 root root 0 ... uts -> uts:[4026531838]
```

- Köşeli parantez içindeki numara = **namespace inode numarası**
- Aynı numara → aynı namespace'te
- Farklı numara → farklı namespace'te (izole)

```bash
# Host ve container namespace'lerini karşılaştır
# Host
ls -la /proc/1/ns/pid
# pid:[4026531836]

# Container (host perspektifinden)
CPID=$(docker inspect --format '{{.State.Pid}}' mycontainer)
ls -la /proc/$CPID/ns/pid
# pid:[4026532456]  ← farklı numara = farklı namespace
```

---

## PID Namespace (process izolasyonu)

Her PID namespace kendi **bağımsız PID numaralandırma** sistemine sahiptir.

#### Container İçinden
```
[Hunting] ~ $ ps aux
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  0.0  0.0  11660  7588 pts/0    Ss+  Feb04   0:00 sshd: /usr/sbin/sshd -D
hunter     132  0.9  0.0   8304  5364 pts/1    Ss   11:40   0:00 zsh
```

#### Host'tan Aynı Container
```bash
# Container'ın PID 1'inin host'taki gerçek PID'si
docker inspect --format '{{.State.Pid}}' mycontainer
# 28451

ps aux | grep 28451
# root 28451 0.0 0.0 11660 7588 ? Ss Feb04 0:00 sshd: /usr/sbin/sshd -D
```

```
Host PID namespace
├── PID 1 (systemd/init)
├── PID 1234 (dockerd)
├── PID 28451 (container'ın "PID 1"i)  ← host'ta farklı PID
│   └── Container PID namespace
│       ├── PID 1 (sshd)              ← container'da PID 1
│       └── PID 132 (zsh)
└── ...
```

#### PID 1'in Önemi
Container'da PID 1 olan process **init process** rolünü üstlenir:
- **Orphan process'leri** toplar (reaping)
- **Signal**'leri alır (`docker stop` → SIGTERM → PID 1'e gider)
- PID 1 ölürse → **container durur**

> [!warning] Signal Handling
> `docker stop` komutu PID 1'e `SIGTERM` gönderir, 10 saniye bekler, sonra `SIGKILL`.
> Shell form (`CMD node server.js`) kullanırsan PID 1 = `/bin/sh`, signal uygulamana ulaşmaz.
> Exec form (`CMD ["node", "server.js"]`) kullanırsan PID 1 = `node`, signal doğru yere gider.
> Detay → [[Dockerfile Best Practices#Shell Form vs Exec Form]]

#### Nested PID Namespaces
PID namespace'ler **iç içe** olabilir. Üst namespace alt namespace'in process'lerini görebilir, ama tersi mümkün değildir.

```
Host (tüm PID'leri görür)
└── Container A (sadece kendi PID'lerini görür)
    └── Nested Container (sadece kendi PID'lerini görür)
```

---

## Network Namespace (netns)

Her container, kendi **network namespace**'ine sahiptir, process'lerin **network stack'ini tamamen izole eder**.

```
Container
 └─ network namespace
     ├─ eth0 (container interface)
     ├─ lo (loopback, 127.0.0.1)
     ├─ routing table
     ├─ ARP table
     └─ iptables (ns scoped)
```

İzole edilenler:
- Network interface'ler (`eth0`, `lo`, veth, vs)
- IP adresleri
- Routing table
- ARP / NDP cache
- Netfilter (iptables/nftables – namespace scoped kısımlar)
- Socket'ler (bind edilen portlar)

> [!tip] Detaylı bilgi
> Docker'ın network namespace'lerini nasıl kullandığı → [[Docker Networking]]

#### Manuel Network Namespace Oluşturma

```bash
# Yeni network namespace oluştur
ip netns add myns

# Namespace'leri listele
ip netns list

# Namespace içinde komut çalıştır
ip netns exec myns ip addr show
# Sadece "lo" interface görünür (DOWN durumda)

# Loopback'i aktifleştir
ip netns exec myns ip link set lo up
```

#### veth Pair ile İki Namespace'i Bağlama

```bash
# veth pair oluştur (sanal kablo)
ip link add veth-host type veth peer name veth-ns

# Bir ucunu namespace'e taşı
ip link set veth-ns netns myns

# Host tarafına IP ver
ip addr add 10.0.0.1/24 dev veth-host
ip link set veth-host up

# Namespace tarafına IP ver
ip netns exec myns ip addr add 10.0.0.2/24 dev veth-ns
ip netns exec myns ip link set veth-ns up

# Test
ping 10.0.0.2          # Host → namespace
ip netns exec myns ping 10.0.0.1  # Namespace → host
```

Bu tam olarak Docker'ın her container için yaptığı şeydir:
`veth pair` → bir uç container'da (`eth0`), diğer uç `docker0` bridge'inde.

---

## Mount Namespace (filesystem izolasyonu)

Her container **kendi mount table'ına** sahiptir. Container, host'un filesystem'ini göremez.

Ne İzole Edilir:
- Mount point'ler (`/`, `/proc`, `/sys`, `/dev`, `/tmp`, vs)
- Mount flag'leri (`ro`, `rw`, `noexec`, `nosuid`)
- Bind mount'lar
- tmpfs instance'ları

#### pivot_root vs chroot

| Özellik | chroot | pivot_root |
|---------|--------|------------|
| Mekanizma | Root dizinini değiştirir | Root filesystem'i swap eder |
| Eski root'a erişim | **Mümkün** (escape edilebilir) | **Engellenir** (unmount edilir) |
| Güvenlik | Zayıf | Güçlü |
| Docker | Kullanmaz | **Kullanır** |

```bash
# chroot: process'in gördüğü "/" dizinini değiştirir
# Ama process hala eski root'a dönebilir (güvensiz)
chroot /new/root /bin/sh

# pivot_root: eski root'u tamamen değiştirir ve unmount edebilir
# Docker/runc bunu kullanır → container host FS'ye erişemez
pivot_root new_root put_old
umount put_old
```

#### /proc, /sys, /tmp Neden Ayrı?

##### `/proc`
- Process ve kernel bilgisi (pseudo-filesystem)
- PID namespace ile **bağlantılı**
- Container'da sadece kendi process'lerini görür
- Docker bazı dosyaları **mask'ler**: `/proc/kcore`, `/proc/keys`, `/proc/sysrq-trigger`

##### `/sys`
- Kernel object'leri, device bilgileri
- Çoğu **read-only** bind mount edilir
- Host hardware'e erişim engellenir

##### `/tmp`
- Genelde `tmpfs` olarak mount edilir
- Namespace başına ayrı instance
- Container restart → data silinir

#### Mount Propagation

Mount namespace'ler arasında mount event'lerinin nasıl yayıldığını kontrol eder:

| Tip | Davranış |
|-----|----------|
| **private** | İzole, hiçbir yayılım yok (Docker default) |
| **shared** | Mount event'leri her iki yöne yayılır |
| **slave** | Sadece üst namespace'ten alt'a yayılır |
| **unbindable** | Bind mount edilemez |

```bash
# Docker'da mount propagation ayarı
docker run -v /host/path:/container/path:shared myapp
docker run -v /host/path:/container/path:slave myapp
```

---

## UTS Namespace (hostname)

UTS (UNIX Time-Sharing) Namespace, bir process grubunun **hostname** ve **domainname** bilgisinin host'tan izole edilmesini sağlar.

Docker her container'a **otomatik** ayrı hostname atar (container ID'nin ilk 12 karakteri).

Docker container
```bash
[Hunting] ~ $ hostname
hunting

# veya Docker'ın atadığı default
$ hostname
a1b2c3d4e5f6
```

Host
```bash
➜  ~ hostname
Ayberks-MacBook-Pro.local
```

#### Hostname Ayarlama
```bash
# Container'a özel hostname ver
docker run --hostname myserver myapp

# Container içinde hostname değiştirmek mümkün (UTS namespace izole)
docker exec mycontainer hostname newname
# Host'un hostname'i etkilenmez
```

#### sethostname() Syscall
```c
// UTS namespace'in arkasındaki syscall
sethostname("mycontainer", 13);

// Sadece kendi UTS namespace'ini etkiler
// Diğer namespace'ler (host dahil) etkilenmez
```

---

## IPC Namespace

IPC (Inter-Process Communication) namespace, process'ler arası iletişim mekanizmalarını izole eder.

> [!tip] Detaylı bilgi
> IPC mekanizmalarının (shared memory, semaphore, message queue) detayları için → [[Linux IPC Mekanizmaları]]

İzole edilen mekanizmalar:
- Shared memory segments
- Semaphore sets
- Message queues
- POSIX message queues

Container'lar:
- Birbirinin shared memory'sini göremez
- DB + app ayrı container ise önemli
- Her container kendi IPC ID table'ına sahip

***IPC Namespace Ne Zaman Kullanılır?***
- Aynı host'ta çalışan ama **birbirini kesinlikle görmemesi gereken** process'ler
- Multi-tenant sistemler
- Aynı image'den çok sayıda container
- Exploit impact surface'i küçültme

***IPC Namespace Nasıl Çalışır?***
Her IPC namespace:
- Kendi IPC ID table'ına sahiptir
- Kernel object ID'ler **namespace'e özeldir**
- Aynı key → farklı namespace → **farklı object**

Birbirini **asla göremez**.

***İki Container IPC Olarak Bağlanabilir mi?***

Evet, ama dikkatli kullanılmalı.

Yöntem: `--ipc=container:<id>`

Container B, Container A'nın IPC namespace'ini kullanır.

```bash
# Container A'yı başlat
docker run -d --name a myapp

# Container B, A'nın IPC namespace'ini paylaşır
docker run -d --ipc=container:a --name b myapp2
```

Sonuç:
- Aynı shared memory
- Aynı semaphore
- Aynı message queue

Mantıklı Senaryolar:
- Çok düşük latency (nanosecond seviyeleri)
- Lock-free ring buffer
- Same-node worker pool

> [!warning] Güvenlik
> IPC paylaşımı izolasyonu kırar. Sadece **güvenilen** container'lar arasında kullanılmalı.

---

## User Namespace

Container içindeki UID/GID'leri host'taki farklı UID/GID'lere **eşler** (mapping).

Container içinde:
```
root (uid 0)
```

Host'ta:
```
uid 100000+
```

Bu ne demek?
- Container'da root → host'ta **normal unprivileged user**
- Kernel privilege escalation engellenir
- Container escape olsa bile host'ta sınırlı yetki

User namespace = container security için olmazsa olmaz

#### UID/GID Mapping

```
Container UID 0  → Host UID 100000
Container UID 1  → Host UID 100001
...
Container UID 65535 → Host UID 165535
```

```bash
# Mapping'i görmek
cat /proc/<container-pid>/uid_map
#          0     100000      65536
#   ns_start  host_start    range

cat /proc/<container-pid>/gid_map
#          0     100000      65536
```

#### Ne sağlar?

User Namespace, process'lerin:
- **UID / GID** algısını
- **Capabilities** kapsamını
- **Privilege** seviyesini

host'tan izole etmesini sağlar.

Container içindeki `root` != host'taki `root`

#### Capabilities ve User Namespace

User namespace içinde **root olan** process (uid 0):
- **Kendi namespace'i içinde** tüm capability'lere sahip
- **Host namespace'inde** hiçbir capability'ye sahip değil

```bash
# Container'da root olarak
id          # uid=0(root) gid=0(root)
cat /proc/1/status | grep Cap
# CapEff: 000001ffffffffff  (tüm capability'ler - namespace içinde)

# Ama host'ta bu process:
# uid=100000 (unprivileged)
# Hiçbir host capability'si yok
```

> [!tip] Rootless Docker
> User namespace'in en önemli kullanımı **Rootless Docker**'dır.
> Docker daemon bile root olmadan çalışır → [[Docker Security#Rootless Docker]]

---

## Cgroup Namespace

Process'in gördüğü **cgroup hiyerarşisini** izole eder. Container kendi cgroup root'unu `/` olarak görür.

#### Cgroup Namespace Olmadan
```bash
# Container kendi cgroup path'ini tam olarak görür
cat /proc/self/cgroup
# 0::/system.slice/docker-abc123.scope   ← host bilgisi sızar
```

#### Cgroup Namespace İle
```bash
# Container sadece kendi root'unu görür
cat /proc/self/cgroup
# 0::/   ← izole, host path gizli
```

Neden önemli:
- Host'un cgroup yapısı hakkında bilgi sızmasını önler
- Container'ın kendini host'ta nerede olduğunu bilmesini engeller
- Security hardening

---

## Time Namespace (Linux 5.6+)

Container'ın gördüğü **monotonic clock** ve **boottime clock** değerlerini izole eder.

```bash
# Container farklı bir "uptime" görebilir
# Container migration / checkpoint-restore senaryoları için
```

> [!info] Not
> Docker henüz time namespace'i **varsayılan olarak kullanmaz**.
> Ama CRIU (Checkpoint/Restore In Userspace) ile container migration senaryolarında kritiktir.

---

## Namespace İşlemleri Özet

```bash
# Process'in namespace'lerini görmek
ls -la /proc/<pid>/ns/

# Mevcut process'ten yeni namespace oluştur
unshare --pid --mount --fork /bin/bash

# Var olan namespace'e girmek
nsenter -t <pid> -m -u -i -n -p -- /bin/sh

# Network namespace yönetimi
ip netns add myns
ip netns list
ip netns exec myns <command>
ip netns del myns

# Tüm namespace'leri listele (util-linux)
lsns
lsns -t pid    # Sadece PID namespace'leri
lsns -t net    # Sadece network namespace'leri
```
