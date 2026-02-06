# Docker Security

Docker container'ları **izole** çalışır ama default konfigürasyon her zaman **yeterli güvenlik** sağlamaz.
Katmanlı savunma (defense in depth) yaklaşımı uygulanmalıdır.

> [!info] İlişkili Notlar
> - Namespace izolasyonu → [[Linux Namespaces]]
> - Kaynak limitleri → [[Linux Cgroups]]
> - Non-root image → [[Dockerfile Best Practices#Non-Root User]]

---

## Attack Surface Özeti

```
Dış Dünya
    │
    ▼
┌─ Host Kernel ─────────────────────────────┐
│                                           │
│  ┌─ Container ──────────────────────┐     │
│  │  Uygulama                        │     │
│  │  ├─ Syscall'lar ← Seccomp        │     │
│  │  ├─ Dosya erişimi ← AppArmor     │     │
│  │  ├─ Yetkiler ← Capabilities      │     │
│  │  ├─ User ← User Namespace        │     │
│  │  └─ Network ← iptables           │     │
│  └──────────────────────────────────┘     │
│                                           │
└───────────────────────────────────────────┘
```

---

## Linux Capabilities

Geleneksel Linux: ya **root** (tüm yetkiler) ya **normal user** (sınırlı).
Capabilities bu ikiliği parçalar: root yetkilerini **granüler parçalara** böler.

#### Docker Default Capabilities
Docker container'lara **sınırlı** bir capability seti verir:

```
CHOWN, DAC_OVERRIDE, FSETID, FOWNER, MKNOD, NET_RAW,
SETGID, SETUID, SETFCAP, SETPCAP, NET_BIND_SERVICE,
SYS_CHROOT, KILL, AUDIT_WRITE
```

Verilmeyen (tehlikeli) capability'ler:
- `SYS_ADMIN` → mount, namespace ops (container escape riski)
- `NET_ADMIN` → network konfigürasyonu
- `SYS_PTRACE` → process debugging
- `SYS_MODULE` → kernel modül yükleme

#### Capability Yönetimi
```bash
# Tüm capability'leri kaldır, sadece gerekenleri ekle
docker run --cap-drop=ALL --cap-add=NET_BIND_SERVICE myapp

# Belirli capability kaldır
docker run --cap-drop=NET_RAW myapp

# Tehlikeli: tüm capability'leri ver (asla production'da kullanma)
docker run --privileged myapp
```

#### Capability Listesini Kontrol
```bash
# Container içinde mevcut capability'leri görmek
docker exec <container> cat /proc/1/status | grep Cap

# Decode etmek
capsh --decode=00000000a80425fb
```

> [!warning] --privileged Flag
> `--privileged` container'a **tüm** host capability'lerini verir + tüm device'lara erişim sağlar.
> Container neredeyse host'un kendisi kadar yetkili olur. **Asla production'da kullanma.**

---

## Seccomp (Secure Computing Mode)

**Syscall filtering** mekanizması. Container'ın hangi kernel syscall'larını yapabileceğini kontrol eder.

#### Docker Default Seccomp Profile
Docker ~44 tehlikeli syscall'ı **varsayılan olarak engeller**:

- `reboot` → host'u yeniden başlatma
- `mount` → filesystem mount
- `swapon/swapoff` → swap yönetimi
- `init_module` → kernel modül yükleme
- `ptrace` → process debugging (bazı modlarda)
- `clock_settime` → sistem saatini değiştirme

#### Custom Seccomp Profile
```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": ["SCMP_ARCH_X86_64"],
  "syscalls": [
    {
      "names": ["read", "write", "open", "close", "stat", "fstat",
                "mmap", "mprotect", "brk", "exit_group", "futex"],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

```bash
# Custom profil ile çalıştır
docker run --security-opt seccomp=./my-profile.json myapp

# Seccomp'u devre dışı bırak (tehlikeli!)
docker run --security-opt seccomp=unconfined myapp
```

> [!tip] Profil Oluşturma
> 1. Uygulamayı `strace` ile çalıştırarak kullandığı syscall'ları tespit et
> 2. Sadece gerekli syscall'lara izin veren whitelist profili oluştur
> 3. Test et, eksik syscall varsa ekle

---

## AppArmor

**Mandatory Access Control (MAC)** sistemi. Process'lerin dosya, network ve capability erişimlerini profil bazlı kısıtlar.

#### Docker Default AppArmor Profile (`docker-default`)
```
# Engellenenler:
- /proc/{kcore,kmem,mem} yazma (kernel memory)
- /sys/ altına yazma (kernel parametreleri)
- mount syscall
- ptrace (diğer container process'lere)
```

#### Custom AppArmor Profile
```
#include <tunables/global>

profile docker-myapp flags=(attach_disconnected) {
  #include <abstractions/base>

  # Sadece /app altında okuma/yazma
  /app/** rw,

  # Network erişimi
  network inet stream,
  network inet dgram,

  # /tmp yazma
  /tmp/** rw,

  # Diğer her şey engellenir
  deny /etc/shadow r,
  deny /proc/*/mem rw,
}
```

```bash
# Custom profil ile çalıştır
docker run --security-opt apparmor=docker-myapp myapp

# AppArmor'u devre dışı bırak
docker run --security-opt apparmor=unconfined myapp
```

---

## SELinux

**Security-Enhanced Linux** — Red Hat/CentOS tabanlı sistemlerde AppArmor yerine kullanılır.
Label-based access control sağlar.

```bash
# SELinux context ile çalıştır
docker run --security-opt label=type:svirt_apache_net_t myapp

# SELinux'u devre dışı bırak
docker run --security-opt label=disable myapp

# Volume mount'larda SELinux label
docker run -v /host/data:/data:Z myapp   # :Z = private label
docker run -v /host/data:/data:z myapp   # :z = shared label
```

---

## Read-Only Filesystem

Container'ın root filesystem'ini **salt okunur** yapar.

```bash
docker run --read-only myapp
```

Ama çoğu uygulama geçici dosya yazar. Çözüm:

```bash
# Read-only root + yazılabilir tmpfs
docker run --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=100m \
  --tmpfs /var/run:rw,noexec,nosuid \
  myapp
```

#### Docker Compose'da
```yaml
services:
  api:
    image: myapp
    read_only: true
    tmpfs:
      - /tmp:size=100m
      - /var/run
```

> [!tip] Neden Önemli?
> - Exploit sonrası dosya yazma engellenir (webshell, backdoor)
> - Container içine malware yerleştirilemez
> - Immutable infrastructure prensibi

---

## Rootless Docker

Docker daemon'ı **root yetkisi olmadan** çalıştırır.

#### Normal Docker
```
docker CLI → dockerd (root) → containerd (root) → runc (root) → container
```

#### Rootless Docker
```
docker CLI → dockerd (user) → containerd (user) → runc (user) → container
```

#### Kurulum
```bash
# Rootless Docker kurulumu
dockerd-rootless-setuptool.sh install

# Kullanım
export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock
docker run hello-world
```

#### Kısıtlamalar
- Privileged port'lar (< 1024) bind edilemez (kernel parametresi ile açılabilir)
- Bazı storage driver'lar çalışmaz
- AppArmor/SELinux profilleri farklı davranabilir
- `--net=host` çalışmaz

> [!info] Ne Zaman Kullanılır?
> - Shared host ortamları (CI/CD runner, multi-tenant)
> - Root daemon'ı çalıştırmak istenmeyen güvenlik-kritik sistemler
> - Container-in-container senaryoları

---

## Docker Content Trust (Image İmzalama)

Image'ların **doğrulanmış kaynaktan** geldiğini garanti eder.

```bash
# Content Trust'ı aktifleştir
export DOCKER_CONTENT_TRUST=1

# İmzalı image push
docker push myrepo/myapp:latest   # Otomatik imzalanır

# İmzasız image pull edilemez (trust aktifken)
docker pull suspicious-image      # Hata verir
```

---

## Security Checklist

- [ ] Non-root user kullan (`USER` directive)
- [ ] Minimal base image (`alpine`, `distroless`, `scratch`)
- [ ] `--cap-drop=ALL` + sadece gerekli capability'leri ekle
- [ ] Read-only filesystem (`--read-only` + `tmpfs`)
- [ ] Seccomp profili uygula (en azından default)
- [ ] Resource limitleri koy (`--memory`, `--cpus`, `--pids-limit`)
- [ ] `--privileged` **asla** kullanma
- [ ] Image'ları vulnerability scanner ile tara (`trivy`, `grype`)
- [ ] Docker Content Trust aktifleştir
- [ ] Sensitive veri image'a gömme (secret management kullan)
- [ ] Network izolasyonu uygula (gereksiz port expose etme)
- [ ] Docker daemon socket'ini container'a mount etme (`/var/run/docker.sock`)
