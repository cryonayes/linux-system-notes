# Docker Temelleri

**Docker**, uygulamaları **izole**, **taşınabilir** ve **tekrar üretilebilir** şekilde çalıştırmak için kullanılan bir **container platformudur**.

Docker şunları paketler:
- Uygulama kodu
- Runtime (Node, Java, Python vs.)
- Sistem kütüphaneleri
- Environment değişkenleri
- Konfigürasyon

Ama **kernel'i paketlemez**.

> [!info] İlişkili Notlar
> - Tam runtime zinciri → [[Container Runtime]]
> - Network katmanı → [[Docker Networking]]
> - Veri kalıcılığı → [[Docker Storage ve Volumes]]

---

## Docker Mimarisi

```
docker CLI ──→ dockerd (daemon) ──→ containerd ──→ runc ──→ kernel
  (client)      (REST API)          (gRPC)        (OCI)    (syscalls)
```

| Bileşen | Rol |
|---------|-----|
| **docker CLI** | Kullanıcı komutları (`docker run`, `docker build`) |
| **dockerd** | API server, image/network/volume yönetimi |
| **containerd** | Container lifecycle, image storage |
| **runc** | Low-level runtime, namespace/cgroup oluşturur |
| **kernel** | `clone()`, `cgroup`, `seccomp`, `pivot_root` |

> [!tip] Detaylı bilgi
> Her bileşenin detaylı açıklaması için → [[Container Runtime]]

---

## VM vs Docker

```
Virtual Machine                    Docker Container
┌─────────────────────┐           ┌──────────────────────┐
│  App A   │  App B   │           │  App A   │  App B    │
├──────────┼──────────┤           ├──────────┼───────────┤
│ Bins/Libs│ Bins/Libs│           │ Bins/Libs│ Bins/Libs │
├──────────┼──────────┤           ├──────────┴───────────┤
│ Guest OS │ Guest OS │           │    Docker Engine     │
├──────────┴──────────┤           ├──────────────────────┤
│     Hypervisor      │           │       Host OS        │
├─────────────────────┤           ├──────────────────────┤
│     Host OS         │           │      Hardware        │
├─────────────────────┤           └──────────────────────┘
│     Hardware        │
└─────────────────────┘
```

#### Virtual Machine

- Hypervisor (VirtualBox, VMware, KVM)
- Her VM kendi OS kernel'ine sahip
- Ağır boyut (GB'lar)
- Yavaş açılır (dakikalar)
- Tam hardware emülasyonu

#### Docker (Container)
- Host OS kernel'ini paylaşır
- Sadece user-space izole edilir
- Hafif (MB'lar)
- Saniyeler içinde ayağa kalkar
- Kernel seviyesinde izolasyon (namespace + cgroup)

| Özellik | VM | Container |
|---------|-----|-----------|
| Boot süresi | Dakikalar | Milisaniyeler |
| Boyut | GB'lar | MB'lar |
| Kernel | Ayrı (guest) | Paylaşımlı (host) |
| İzolasyon | Donanım seviyesi | OS seviyesi (namespace) |
| Performans | Overhead var (hypervisor) | Native'e yakın |
| Density | Host başına 10-20 VM | Host başına 100+ container |

Container'lar host'un kernelini kullanır, VM ise sıfırdan tüm sistemi kendi kernel'i ile birlikte kaldırır. Bu nedenle daha yavaş ve boyut anlamında büyüktür.

> [!tip] Ne zaman VM, ne zaman Container?
> - **VM**: Farklı OS gerektiğinde (Windows üzerinde Linux), tam izolasyon şart olduğunda
> - **Container**: Aynı OS üzerinde microservice, hızlı deploy, CI/CD pipeline

---

## Docker Image Nasıl Çalışır?

Docker image **katmanlardan (layers)** oluşur. Her image bir **manifest** + **config** + **layer'lar** bütünüdür.

```
Image = Uygulamanın çalıştırılabilir paketi (read-only template)
Container = Image'ın çalışan instance'ı (read-write layer eklenir)
```

Örnek Dockerfile:
```dockerfile
FROM node:20          # Layer 1: Base image (Debian + Node.js)
WORKDIR /app          # Layer 2: Metadata (working directory)
COPY package.json .   # Layer 3: package.json dosyası
RUN npm install       # Layer 4: node_modules
COPY . .              # Layer 5: Uygulama kodu
CMD ["node", "server.js"]  # Metadata (çalıştırılacak komut)
```

Her `RUN`, `COPY`, `ADD` komutu:
- Yeni bir **read-only layer** üretir
- Öncekine eklenir
- **Cache'lenir** (değişmezse yeniden build edilmez)

> [!tip] Layer Cache
> Bir layer değişirse, ondan sonraki **tüm layer'lar invalidate** olur.
> Bu yüzden seyrek değişen dosyalar (package.json) üste, sık değişenler (kaynak kod) alta yazılır.
> Detaylar → [[Dockerfile Best Practices#Layer Cache Optimizasyonu]]

#### Image Layer'larını İnceleme
```bash
# Image'ın layer'larını ve boyutlarını görmek
docker history nginx:alpine

IMAGE          CREATED       CREATED BY                                      SIZE
a8758716bb6a   2 weeks ago   CMD ["nginx" "-g" "daemon off;"]                0B
<missing>      2 weeks ago   STOPSIGNAL SIGQUIT                              0B
<missing>      2 weeks ago   EXPOSE map[80/tcp:{}]                           0B
<missing>      2 weeks ago   ENTRYPOINT ["/docker-entrypoint.sh"]            0B
<missing>      2 weeks ago   COPY 30-tune-worker-processes.sh ... (truncated) 4.62kB
<missing>      2 weeks ago   COPY 20-envsubst-on-templates.sh ... (truncated) 3.02kB
<missing>      2 weeks ago   RUN /bin/sh -c set -x ...                       62.1MB
<missing>      2 weeks ago   /bin/sh -c #(nop) ADD file:...                  7.67MB
```

```bash
# Image detaylı bilgi (config, layer digest'leri)
docker inspect nginx:alpine

# Image disk kullanımı
docker system df
docker image ls
```

---

## Docker Registry

Image'lar **registry** adı verilen depolardan indirilir ve paylaşılır.

```
docker pull nginx         →  Docker Hub (default registry)
docker pull ghcr.io/user/app  →  GitHub Container Registry
docker pull 123456.dkr.ecr.eu-west-1.amazonaws.com/myapp  →  AWS ECR
```

#### Image Tag Yapısı
```
registry/repository:tag

docker.io/library/nginx:1.25-alpine
────────  ───────  ────  ──────────
registry  repo     image  tag

# Tag belirtilmezse "latest" kullanılır (tehlikeli!)
docker pull nginx         # = docker pull docker.io/library/nginx:latest
```

> [!warning] :latest Tag
> `latest` her zaman en güncel sürüm anlamına **gelmez**.
> Sadece tag verilmediğinde kullanılan default isimdir.
> Production'da **her zaman explicit tag** kullan: `nginx:1.25.4-alpine`

#### Image Push
```bash
# Image'ı tag'le
docker tag myapp:latest myregistry.com/myapp:1.0.0

# Registry'e giriş yap
docker login myregistry.com

# Push et
docker push myregistry.com/myapp:1.0.0
```

---

## Union File System (OverlayFS)

Docker, image layer'larını **Union File System** ile birleştirir. Modern Docker'da **OverlayFS** (overlay2) kullanılır.

```
┌──────────────────────────────────┐
│   Container Layer (read-write)   │  ← Container'a özel değişiklikler
├──────────────────────────────────┤
│   Layer 5: COPY . .              │  ← read-only
├──────────────────────────────────┤
│   Layer 4: RUN npm install       │  ← read-only
├──────────────────────────────────┤
│   Layer 3: COPY package.json .   │  ← read-only
├──────────────────────────────────┤
│   Layer 2: WORKDIR /app          │  ← read-only
├──────────────────────────────────┤
│   Layer 1: FROM node:20          │  ← read-only (base image)
└──────────────────────────────────┘
```

#### OverlayFS Yapısı
```
overlay2/
├── lowerdir   → image layer'ları (read-only, üst üste merged)
├── upperdir   → container layer (read-write, değişiklikler buraya yazılır)
├── workdir    → OverlayFS internal (atomic operations)
└── merged     → birleşik görünüm (container'ın gördüğü filesystem)
```

```bash
# Container'ın overlay mount bilgisini görmek
docker inspect <container> --format '{{.GraphDriver.Data}}'

# Host'ta overlay2 dizinleri
ls /var/lib/docker/overlay2/
```

#### Copy-on-Write (CoW)

Container içinde bir dosya **okunurken**:
- Dosya image layer'larından (lowerdir) okunur
- Kopyalama yapılmaz, performans kaybı yok

Container içinde bir dosya **yazılırken/değiştirilirken**:
1. Dosya lowerdir'den upperdir'e **kopyalanır** (copy-up)
2. Değişiklik upperdir'deki kopya üzerinde yapılır
3. Orijinal (lowerdir) dosya **değişmez**

Container içinde bir dosya **silinirken**:
- Dosya gerçekten silinmez
- upperdir'de bir **whiteout dosyası** oluşturulur
- merged görünümde dosya gizlenir

> [!warning] CoW Performans Etkisi
> İlk yazma işlemi yavaş olabilir (copy-up). Büyük dosyalar (DB data file gibi) için
> Union FS yerine [[Docker Storage ve Volumes|volume]] kullanılmalı.

Container silinirse:
**Upperdir (read-write layer) tamamen silinir → Her şey gider**

Bu yüzden: "Container stateless'tır, state için volume kullan"

---

## Container Lifecycle

```
Image ──create──→ Created ──start──→ Running ──stop──→ Stopped ──rm──→ Silindi
                     │                  │                  │
                     │                  ├──pause──→ Paused │
                     │                  │                  │
                     │                  ├──kill───→ Stopped│
                     │                  │                  │
                     │                  └──restart─────────┘
                     │
                     └──rm──→ Silindi
```

#### Lifecycle Komutları
```bash
# Image'dan container oluştur (başlatmaz)
docker create --name myapp nginx

# Container'ı başlat
docker start myapp

# Oluştur + başlat (kısa yol)
docker run -d --name myapp nginx

# Durdur (SIGTERM → 10s → SIGKILL)
docker stop myapp

# Hemen öldür (SIGKILL)
docker kill myapp

# Restart
docker restart myapp

# Pause (SIGSTOP — process freeze)
docker pause myapp
docker unpause myapp

# Sil (durdurulmuş olmalı)
docker rm myapp

# Zorla sil (çalışıyor olsa bile)
docker rm -f myapp
```

#### Container İnceleme
```bash
# Çalışan container'lar
docker ps

# Tüm container'lar (durmuş dahil)
docker ps -a

# Container detayları (IP, mount, env, state)
docker inspect myapp

# Canlı resource kullanımı
docker stats

# Container logları
docker logs myapp
docker logs -f --tail 100 myapp    # Son 100 satır + follow

# Container içinde komut çalıştır
docker exec -it myapp sh
docker exec myapp cat /etc/hostname
```

---

## Container Isolation Nasıl Sağlanır?

Docker linux kernel feature'larını kullanarak container'lar arası izolasyon sağlar.

```
┌───────────────────────────────────────────┐
│           Container                       │
│  ┌─────────────────────────────┐          │
│  │  Process (uygulama)         │          │
│  └──────────┬──────────────────┘          │
│             │                             │
│  Namespaces │ "Ne görüyorsun?"            │
│  ├─ pid     │ Kendi PID ağacı             │
│  ├─ net     │ Kendi network stack         │
│  ├─ mnt     │ Kendi filesystem            │
│  ├─ uts     │ Kendi hostname              │
│  ├─ ipc     │ Kendi shared memory         │
│  └─ user    │ Kendi UID/GID               │
│             │                             │
│  Cgroups    │ "Ne kadar kullanabilirsin?" │
│  ├─ cpu     │ CPU limiti                  │
│  ├─ memory  │ RAM limiti                  │
│  ├─ io      │ Disk I/O limiti             │
│  └─ pids    │ Process sayısı limiti       │
│             │                             │
│  Security   │ "Ne yapabilirsin?"          │
│  ├─ seccomp │ Syscall filtering           │
│  ├─ apparmor│ Dosya/network erişim        │
│  └─ caps    │ Granüler yetkiler           │
└───────────────────────────────────────────┘
```

#### Namespaces (izolasyon)
- `pid` → process izolasyonu
- `net` → network izolasyonu
- `mnt` → filesystem
- `uts` → hostname
- `ipc` → shared memory
- `user` → UID/GID mapping

> [!tip] Detaylı bilgi
> Namespace'lerin her birinin detaylı açıklaması için → [[Linux Namespaces]]

#### Cgroups (kaynak kontrolü)
- CPU limiti
- RAM limiti
- I/O limiti
- Process sayısı limiti

> [!tip] Detaylı bilgi
> Cgroups mekanizmasının detayları için → [[Linux Cgroups]]

#### Security
- Seccomp profilleri
- AppArmor / SELinux
- Linux Capabilities

> [!tip] Detaylı bilgi
> Container security katmanları için → [[Docker Security]]

---

## Temel Docker Komutları Özet

```bash
# Image
docker pull nginx:alpine       # Image indir
docker build -t myapp:1.0 .    # Dockerfile'dan image oluştur
docker image ls                # Image'ları listele
docker image rm nginx:alpine   # Image sil
docker image prune             # Kullanılmayan image'ları sil

# Container
docker run -d -p 8080:80 --name web nginx    # Oluştur + başlat
docker stop web                               # Durdur
docker start web                              # Tekrar başlat
docker rm web                                 # Sil
docker logs -f web                            # Log takip
docker exec -it web sh                        # Shell aç

# Sistem
docker system df               # Disk kullanımı
docker system prune -a         # Tüm kullanılmayan kaynakları temizle
docker info                    # Docker daemon bilgisi
docker version                 # Versiyon bilgisi
```
