# Docker Storage ve Volumes

Container'lar **stateless** çalışır — container silindiğinde içindeki veriler kaybolur.
Kalıcı veri için Docker **3 storage mekanizması** sunar.

> [!info] İlişkili
> Container'ın yazılabilir katmanı (Union FS) hakkında → [[Docker Temelleri#Union File System (AUFS / OverlayFS)]]

---

## 3 Storage Tipi

```
Host filesystem
│
├── Bind Mount ──→ Host'taki belirli bir dizin doğrudan mount edilir
│                  /home/user/data → /app/data
│
├── Volume ──────→ Docker yönetiminde, /var/lib/docker/volumes/ altında
│                  my-vol → /app/data
│
└── tmpfs ───────→ Sadece RAM'de yaşar, diske yazılmaz
                   tmpfs → /app/temp
```

| Özellik | Bind Mount | Volume | tmpfs |
|---------|-----------|--------|-------|
| Konum | Host path (siz seçersiniz) | Docker yönetir | RAM |
| Portabilite | Host'a bağımlı | Taşınabilir | Yok |
| Docker CLI ile yönetim | Hayır | Evet (`docker volume`) | Hayır |
| Performans | Host FS'ye bağlı | Host FS'ye bağlı | Çok hızlı |
| Persistence | Evet | Evet | **Hayır** |
| Güvenlik | Host FS'ye erişim riski | İzole | En güvenli |

---

## Bind Mount

Host'taki bir dizini **doğrudan** container'a mount eder.

```bash
# -v (eski syntax)
docker run -v /host/path:/container/path myapp

# --mount (yeni, daha explicit syntax)
docker run --mount type=bind,source=/host/path,target=/container/path myapp

# Read-only bind mount
docker run -v /host/path:/container/path:ro myapp
docker run --mount type=bind,source=/host/path,target=/container/path,readonly myapp
```

#### Ne Zaman Kullanılır?
- Development: kaynak kodun hot-reload ile container'da çalışması
- Config dosyaları mount etme (`nginx.conf`, `my.cnf`)
- Host log dizinine yazma

#### Riskler
- Container host filesystem'e **doğrudan erişir**
- Yanlış path mount edilirse host dosyaları bozulabilir
- Host path yoksa Docker **otomatik oluşturmaz** (hata verir, `--mount` ile)

> [!warning] -v vs --mount farkı
> `-v /nonexistent:/data` → host'ta `/nonexistent` dizinini **otomatik oluşturur**
> `--mount type=bind,source=/nonexistent,target=/data` → **hata verir** (daha güvenli)

---

## Volume (Docker Managed)

Docker'ın kendi yönettiği storage alanı. Veriler `/var/lib/docker/volumes/` altında tutulur.

```bash
# Volume oluştur
docker volume create my-data

# Container'a bağla
docker run -v my-data:/app/data myapp
docker run --mount type=volume,source=my-data,target=/app/data myapp

# Anonim volume (isim Docker tarafından atanır)
docker run -v /app/data myapp
```

#### Volume Lifecycle
```bash
# Tüm volume'ları listele
docker volume ls

# Volume detayı
docker volume inspect my-data
# {
#     "Driver": "local",
#     "Mountpoint": "/var/lib/docker/volumes/my-data/_data",
#     "Name": "my-data",
#     "Scope": "local"
# }

# Volume sil (container kullanmıyorsa)
docker volume rm my-data

# Kullanılmayan tüm volume'ları temizle
docker volume prune
```

> [!warning] Dikkat
> `docker rm <container>` volume'u **silmez**.
> `docker rm -v <container>` anonim volume'ları **siler**.
> Named volume'lar ancak `docker volume rm` ile silinir.

#### Volume'un Avantajları
- **Backup/restore** kolaylığı
- Docker CLI ile yönetim
- Linux ve Windows'ta çalışır
- Birden fazla container arasında **paylaşılabilir**
- Volume driver'lar ile **remote storage** desteği

---

## tmpfs Mount

Veri sadece **RAM'de** tutulur. Container durduğunda **her şey silinir**.

```bash
docker run --tmpfs /app/temp myapp

# Boyut ve permission kontrolü ile
docker run --mount type=tmpfs,target=/app/temp,tmpfs-size=100m,tmpfs-mode=1777 myapp
```

#### Ne Zaman Kullanılır?
- Geçici dosyalar (session data, cache)
- Hassas veriler (secret'lar, token'lar) — diske yazılmamalı
- Yüksek I/O gerektiren geçici işlemler

---

## Volume Driver'lar

Default `local` driver dışında remote/cloud storage kullanılabilir.

```bash
# NFS volume
docker volume create --driver local \
  --opt type=nfs \
  --opt o=addr=192.168.1.100,rw \
  --opt device=:/shared/data \
  nfs-data

# SSHFS (plugin gerekir)
docker plugin install vieux/sshfs
docker volume create -d vieux/sshfs \
  -o sshcmd=user@host:/path \
  -o password=secret \
  ssh-data
```

Yaygın volume driver'lar:
- **local** → host filesystem (default)
- **nfs** → NFS share mount
- **sshfs** → SSH üzerinden remote mount
- **rexray** → AWS EBS, Azure Disk, GCE PD
- **convoy** → snapshot, backup destekli

---

## Data Persistence Stratejileri

#### Database Container'ları
```bash
# PostgreSQL data kalıcılığı
docker run -d \
  --name postgres \
  -v pg-data:/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD=secret \
  postgres:16

# Container silinse bile data kalır
docker rm -f postgres

# Yeni container aynı volume ile başlatılır
docker run -d \
  --name postgres-new \
  -v pg-data:/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD=secret \
  postgres:16
```

#### Volume Backup
```bash
# Volume'u tar ile backup al
docker run --rm \
  -v pg-data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/pg-backup.tar.gz -C /data .

# Restore
docker run --rm \
  -v pg-data:/data \
  -v $(pwd):/backup \
  alpine sh -c "cd /data && tar xzf /backup/pg-backup.tar.gz"
```

#### Volume Paylaşımı
```bash
# İki container aynı volume'u kullanır
docker run -d --name writer -v shared-data:/data alpine sh -c "while true; do date >> /data/log.txt; sleep 1; done"
docker run -d --name reader -v shared-data:/data:ro alpine tail -f /data/log.txt
```

> [!tip] Best Practice
> - Production'da her zaman **named volume** kullan (anonim değil)
> - Database volume'larını düzenli **backup** al
> - Sensitive data için **tmpfs** tercih et
> - Volume'ları gereksiz yere paylaşma (**least privilege**)
