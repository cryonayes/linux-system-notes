Docker CLI'dan container'ın kernel'de çalışmasına kadar olan **tam zincir**.

---

## Büyük Resim

```
docker run myapp
      │
      ▼
┌─ Docker CLI ─────────────────────────┐
│  Komutu parse eder, API call yapar   │
└──────────────┬───────────────────────┘
               │ REST API (unix socket)
               ▼
┌─ dockerd (Docker Daemon) ────────────┐
│  Image pull, network, volume yönetimi│
│  Container lifecycle                 │
└──────────────┬───────────────────────┘
               │ gRPC
               ▼
┌─ containerd ─────────────────────────┐
│  Container runtime yöneticisi        │
│  Image management, snapshot          │
│  Task/container lifecycle            │
└──────────────┬───────────────────────┘
               │ OCI Runtime Spec
               ▼
┌─ runc ───────────────────────────────┐
│  OCI uyumlu low-level runtime        │
│  Namespace, cgroup, seccomp setup    │
│  Container process'ini başlatır      │
└──────────────┬───────────────────────┘
               │ syscalls
               ▼
┌─ Linux Kernel ───────────────────────┐
│  clone() → namespaces                │
│  cgroup → resource limits            │
│  seccomp → syscall filtering         │
│  pivot_root → filesystem isolation   │
└──────────────────────────────────────┘
```

---

## dockerd (Docker Daemon)

Docker ekosisteminin **merkezi daemon'ı**.

Sorumlulukları:
- Docker CLI'dan gelen API isteklerini karşılar
- Image pull/push/build
- Network yönetimi (bridge, overlay)
- Volume yönetimi
- Container lifecycle (create, start, stop, rm)
- Logging ve monitoring

```bash
# Docker daemon'ın dinlediği socket
ls -la /var/run/docker.sock

# Docker API'sine doğrudan erişim
curl --unix-socket /var/run/docker.sock http://localhost/v1.44/containers/json
```

> [!warning] docker.sock güvenliği
> `/var/run/docker.sock`'a erişim = **root erişimi** demektir.
> Bu socket'i container'a mount etmek = container'a host üzerinde tam yetki vermek.

---

## containerd

**Endüstri standardı** container runtime. Docker'dan bağımsız olarak da çalışabilir (Kubernetes CRI).

Sorumlulukları:
- Image pull ve storage (snapshot'lar)
- Container lifecycle yönetimi
- Task execution (runc'ı çağırır)
- gRPC API sunar

```bash
# containerd status
systemctl status containerd

# ctr: containerd CLI aracı
ctr containers list
ctr images list

# nerdctl: Docker-uyumlu containerd CLI
nerdctl run -d --name web nginx
```

#### containerd Mimarisi
```
containerd
├── Content Store    → image layer'larını depolar
├── Snapshotter      → container filesystem (overlay2)
├── Task Service     → container process lifecycle
├── Namespace        → multi-tenant izolasyon
└── Runtime (shim)   → runc ile iletişim
```

#### containerd-shim
Her container için bir **shim process** oluşturulur:

```
containerd → containerd-shim-runc-v2 → container process
```

Neden shim var?
- containerd restart edilse bile **container çalışmaya devam eder**
- Container'ın stdin/stdout/stderr'ini yönetir
- Exit code'u toplar
- Her container bağımsız yaşar

```bash
# Her container için bir shim process görülür
ps aux | grep containerd-shim
```

---

## runc

**OCI Runtime Specification** uyumlu, Go ile yazılmış low-level container runtime.
Container process'ini **gerçekten oluşturan** bileşen.

#### runc Ne Yapar?

`runc create` çağrıldığında sırasıyla:

1. **Namespaces oluşturur** → `clone()` syscall
   ```
   clone(CLONE_NEWPID | CLONE_NEWNET | CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWUSER)
   ```

2. **Cgroups ayarlar** → resource limitleri
   ```
   /sys/fs/cgroup/.../memory.max = 536870912  (512MB)
   /sys/fs/cgroup/.../cpu.max = 150000 100000  (1.5 CPU)
   ```

3. **Root filesystem kurar** → `pivot_root()` syscall
   ```
   pivot_root(new_root, put_old)
   umount(put_old)  # Host FS erişimini tamamen keser
   ```

4. **Seccomp profili uygular** → syscall filtering
   ```
   seccomp(SECCOMP_SET_MODE_FILTER, ...)
   ```

5. **Capabilities ayarlar** → drop/add
   ```
   capset(...)  # Sadece izin verilen capability'ler kalır
   ```

6. **Process'i exec eder** → `execve()`
   ```
   execve("/usr/bin/node", ["node", "server.js"], envp)
   ```

#### runc Doğrudan Kullanımı
```bash
# OCI bundle oluştur
mkdir -p mycontainer/rootfs
docker export $(docker create alpine) | tar -C mycontainer/rootfs -xf -

# OCI config oluştur
cd mycontainer
runc spec

# Container çalıştır
runc run my-container
```

#### config.json (OCI Runtime Spec)
```json
{
  "ociVersion": "1.0.2",
  "process": {
    "terminal": true,
    "user": { "uid": 0, "gid": 0 },
    "args": ["sh"],
    "env": ["PATH=/usr/bin:/bin"],
    "cwd": "/"
  },
  "root": {
    "path": "rootfs",
    "readonly": false
  },
  "linux": {
    "namespaces": [
      { "type": "pid" },
      { "type": "network" },
      { "type": "mount" },
      { "type": "ipc" },
      { "type": "uts" }
    ],
    "resources": {
      "memory": { "limit": 536870912 }
    }
  }
}
```

---

## OCI (Open Container Initiative) Standartları

Container ekosisteminin **açık standartları**. Docker, containerd, Kubernetes hepsi OCI uyumludur.

#### 3 Temel Spec

| Spec | Açıklama |
|------|----------|
| **Runtime Spec** | Container nasıl oluşturulur ve çalıştırılır (`config.json`) |
| **Image Spec** | Image formatı (manifest, layer'lar, config) |
| **Distribution Spec** | Image'lar registry'ler arasında nasıl dağıtılır |

#### Runtime Spec Lifecycle
```
create → created → start → running → kill/stop → stopped → delete
```

#### Image Spec
```
Image Manifest
├── Config (JSON)
│   ├── Architecture
│   ├── OS
│   ├── Entrypoint / CMD
│   └── Environment
└── Layers (tar.gz)
    ├── Layer 1 (base OS)
    ├── Layer 2 (dependencies)
    └── Layer 3 (application)
```

#### Alternatif OCI Runtime'lar

| Runtime | Özellik |
|---------|---------|
| **runc** | Default, Go, referans implementasyon |
| **crun** | C ile yazılmış, daha hızlı startup |
| **youki** | Rust ile yazılmış |
| **gVisor (runsc)** | Google, user-space kernel (extra izolasyon) |
| **Kata Containers** | Micro-VM bazlı (VM seviyesi izolasyon) |

---

## docker exec Nasıl Çalışır?

```bash
docker exec -it mycontainer sh
```

#### Arka Planda Ne Olur?

1. **dockerd** API isteğini alır
2. **containerd**'ye gRPC ile iletir
3. containerd **shim**'e yeni process eklemesini söyler
4. shim, **nsenter** benzeri mekanizma ile mevcut container'ın namespace'lerine girer
5. Yeni process container **içinde** başlatılır

#### nsenter (Manuel)
`nsenter`, çalışan bir process'in namespace'lerine **dışarıdan girmeyi** sağlar.

```bash
# Container'ın PID 1'ini bul (host perspektifinden)
docker inspect --format '{{.State.Pid}}' mycontainer
# 12345

# O process'in namespace'lerine gir
nsenter -t 12345 -m -u -i -n -p -- /bin/sh
```

#### nsenter Parametreleri
| Flag | Namespace |
|------|-----------|
| `-m` | Mount |
| `-u` | UTS (hostname) |
| `-i` | IPC |
| `-n` | Network |
| `-p` | PID |
| `-U` | User |

#### nsenter vs docker exec
- `docker exec` → Docker API üzerinden (normal yol)
- `nsenter` → Doğrudan kernel namespace'lerine giriş (debug / rescue)
- Docker daemon çökse bile `nsenter` ile container'a erişilebilir

---

## Tam Akış: docker run nginx

```
1. docker CLI → "POST /containers/create" → dockerd
2. dockerd → image var mı? yoksa pull et
3. dockerd → containerd'ye "container oluştur" (gRPC)
4. containerd → image layer'larını overlay2 ile birleştir
5. containerd → containerd-shim-runc-v2 başlat
6. shim → runc'ı çağır (OCI bundle + config.json)
7. runc:
   a. clone() → yeni namespace'ler
   b. cgroup ayarla → resource limitleri
   c. pivot_root() → filesystem izolasyonu
   d. seccomp ayarla → syscall filtering
   e. capabilities ayarla → yetki kısıtlama
   f. execve("nginx") → process başlat
8. runc çıkar, shim container'ı yönetmeye devam eder
9. nginx PID 1 olarak container'da çalışır
```
