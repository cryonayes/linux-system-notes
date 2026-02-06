# Linux Logging

Linux'ta log sistemi, **kernel**, **daemon'lar** ve **uygulamalar** tarafından üretilen mesajları toplar, depolar ve yönetir.

> [!info] Docker ile ilişki
> Docker kendi log driver'larını kullanır ama temelde aynı mekanizmalara dayanır → [[Docker Temelleri#Container İnceleme]]

---

## Log Mimarisi

```
┌──────────────────────────────────────────────────────┐
│                  Log Üreticileri                     │
│                                                      │
│  Kernel ──→ printk() ──→ /dev/kmsg ──→ dmesg         │
│                              │                       │
│  Daemon'lar ──→ syslog() ────┤                       │
│                              │                       │
│  Uygulamalar ──→ write() ────┤                       │
│                              ▼                       │
│                    ┌──────────────────┐              │
│                    │ journald / syslog│              │
│                    │ (log collector)  │              │
│                    └────────┬─────────┘              │
│                             │                        │
│              ┌──────────────┼──────────────┐         │
│              ▼              ▼              ▼         │
│        /var/log/       journalctl    Remote syslog   │
│        (dosyalar)      (binary db)   (network)       │
└──────────────────────────────────────────────────────┘
```

---

## Kernel Log — dmesg

Kernel **ring buffer**'ına yazılan mesajlar. Boot, hardware, driver, OOM, panic olayları burada.

```bash
# Kernel mesajlarını göster
dmesg

# Son mesajlar (follow)
dmesg -w

# Zaman damgalı
dmesg -T

# Sadece error ve üstü
dmesg --level=err,crit,alert,emerg

# Belirli facility
dmesg --facility=kern

# Ring buffer'ı temizle
dmesg -c   # oku ve temizle (root gerekir)
```

#### Kernel Log Seviyeleri

| Seviye | Numara | Açıklama |
|--------|--------|----------|
| `emerg` | 0 | Sistem kullanılamaz |
| `alert` | 1 | Hemen müdahale gerekli |
| `crit` | 2 | Kritik durum |
| `err` | 3 | Hata |
| `warning` | 4 | Uyarı |
| `notice` | 5 | Normal ama önemli |
| `info` | 6 | Bilgi |
| `debug` | 7 | Debug mesajları |

```bash
# Kernel'de log level ayarı
cat /proc/sys/kernel/printk
# 4    4    1    7
# current  default  minimum  boot-time-default

# OOM Killer olaylarını bul
dmesg | grep -i "oom\|killed process\|out of memory"

# USB/disk olayları
dmesg | grep -i "usb\|sd[a-z]\|nvme"

# Network olayları
dmesg | grep -i "eth\|link\|network"
```

> [!tip] Container'larda dmesg
> Container'lar default olarak dmesg'e **erişemez** (seccomp + /proc/kmsg mask).
> `docker run --privileged` veya `--cap-add=SYSLOG` ile erişilebilir.

---

## syslog

Unix/Linux'un geleneksel log framework'ü. **RFC 5424** standardı.

#### syslog Mesaj Formatı
```
<priority>timestamp hostname app[pid]: message

<34>Jan 12 06:30:00 myhost sshd[3456]: Accepted publickey for user from 10.0.0.1
```

#### Priority = Facility × 8 + Severity

**Facility** (mesaj kaynağı):

| Facility | Numara | Açıklama |
|----------|--------|----------|
| `kern` | 0 | Kernel |
| `user` | 1 | User-level |
| `mail` | 2 | Mail sistemi |
| `daemon` | 3 | System daemon'lar |
| `auth` | 4 | Authentication |
| `syslog` | 5 | Syslog kendisi |
| `cron` | 8 | Cron |
| `local0-7` | 16-23 | Custom kullanım |

#### rsyslog (modern syslog daemon)

```bash
# rsyslog config
cat /etc/rsyslog.conf

# Kural formatı: facility.severity  destination
auth.*                  /var/log/auth.log       # Tüm auth logları
kern.*                  /var/log/kern.log       # Kernel logları
*.emerg                 :omusrmsg:*             # Emergency → tüm kullanıcılara
mail.*                  -/var/log/mail.log      # - = async yazma
*.* @@remote-server:514                         # Tüm logları remote'a gönder (TCP)
*.* @remote-server:514                          # UDP ile gönder

# Log rotasyonu
cat /etc/logrotate.d/rsyslog
```

#### syslog() API
```c
#include <syslog.h>

// Syslog bağlantısı aç
openlog("myapp", LOG_PID | LOG_CONS, LOG_DAEMON);

// Log mesajı gönder
syslog(LOG_INFO, "Uygulama başlatıldı");
syslog(LOG_ERR, "Bağlantı hatası: %s", strerror(errno));
syslog(LOG_WARNING, "Disk kullanımı: %d%%", usage);

// Kapat
closelog();
```

---

## systemd-journald

systemd tabanlı sistemlerde **binary formatta** log toplayan modern log sistemi.

#### journalctl Temel Kullanım

```bash
# Tüm logları göster
journalctl

# Son loglar (follow)
journalctl -f

# Son N satır
journalctl -n 50

# Bu boot'un logları
journalctl -b

# Önceki boot
journalctl -b -1

# Zaman aralığı
journalctl --since "2024-01-01 00:00:00" --until "2024-01-01 23:59:59"
journalctl --since "1 hour ago"
journalctl --since today
```

#### Filtreleme

```bash
# Unit bazında
journalctl -u sshd
journalctl -u nginx.service
journalctl -u docker.service

# Priority bazında
journalctl -p err                  # error ve üstü
journalctl -p warning..err         # warning ile error arası

# PID bazında
journalctl _PID=1234

# Binary bazında
journalctl /usr/sbin/sshd

# Kernel mesajları
journalctl -k                     # = dmesg

# Birden fazla filtre (AND)
journalctl -u sshd -p err --since today

# JSON formatında çıktı
journalctl -o json-pretty -n 5

# Disk kullanımı
journalctl --disk-usage

# Eski logları temizle
journalctl --vacuum-size=500M     # 500MB'a küçült
journalctl --vacuum-time=7d       # 7 günden eski sil
```

#### journald Konfigürasyonu

```bash
# /etc/systemd/journald.conf
[Journal]
Storage=persistent        # persistent | volatile | auto | none
Compress=yes
SystemMaxUse=500M         # Max disk kullanımı
SystemMaxFileSize=50M     # Tek dosya max boyut
MaxRetentionSec=1month    # Max saklama süresi
ForwardToSyslog=yes       # rsyslog'a da gönder
MaxLevelStore=debug       # Depolama seviyesi
```

---

## /var/log Dosyaları

```bash
/var/log/
├── syslog          # Genel sistem logları (Debian/Ubuntu)
├── messages        # Genel sistem logları (RHEL/CentOS)
├── auth.log        # Authentication (login, sudo, ssh)
├── kern.log        # Kernel mesajları
├── dmesg           # Boot sırasındaki kernel logları
├── dpkg.log        # Paket yönetimi (Debian)
├── yum.log         # Paket yönetimi (RHEL)
├── cron.log        # Cron job logları
├── mail.log        # Mail sistemi
├── nginx/          # Nginx access/error logları
│   ├── access.log
│   └── error.log
├── mysql/          # MySQL logları
├── journal/        # systemd-journald binary logları
├── faillog         # Başarısız login denemeleri
├── lastlog         # Son login bilgileri
├── wtmp            # Login geçmişi (binary, `last` ile oku)
├── btmp            # Başarısız login geçmişi (`lastb` ile oku)
└── audit/          # SELinux / auditd logları
    └── audit.log
```

```bash
# Authentication logları
tail -f /var/log/auth.log
# Jan 12 06:30:00 myhost sshd[3456]: Failed password for root from 10.0.0.1 port 42356 ssh2

# Login geçmişi
last                    # Başarılı loginler
lastb                   # Başarısız loginler
who                     # Şu an logged in kullanıcılar
w                       # Kullanıcılar + ne yapıyorlar
```

---

## Log Rotation (logrotate)

Log dosyalarının **büyümesini** kontrol eder: sıkıştırma, silme, rotasyon.

```bash
# Global config
cat /etc/logrotate.conf

# Per-application config
cat /etc/logrotate.d/nginx
```

```
# /etc/logrotate.d/myapp
/var/log/myapp/*.log {
    daily              # Günlük rotasyon
    rotate 14          # 14 dosya sakla
    compress           # Eski logları gzip
    delaycompress      # Bir öncekini sıkıştırma (hala yazılıyor olabilir)
    missingok          # Dosya yoksa hata verme
    notifempty         # Boş dosyayı rotate etme
    create 0644 www-data www-data   # Yeni dosya permission
    sharedscripts      # Script'leri bir kez çalıştır
    postrotate
        systemctl reload nginx > /dev/null 2>&1 || true
    endscript
}
```

```bash
# Manuel rotasyon testi
logrotate -d /etc/logrotate.d/nginx   # Dry-run
logrotate -f /etc/logrotate.d/nginx   # Zorla çalıştır
```

---

## Docker Log Sistemi

Docker container log'larını **log driver** üzerinden yönetir.

```bash
# Container logları
docker logs mycontainer
docker logs -f --tail 100 mycontainer           # Follow + son 100
docker logs --since 1h mycontainer              # Son 1 saat
docker logs --since 2024-01-01T00:00:00 mycontainer
```

#### Log Driver'lar

| Driver | Açıklama |
|--------|----------|
| `json-file` | **Default**, JSON formatında dosya |
| `local` | Optimize edilmiş binary format |
| `syslog` | syslog daemon'a gönderir |
| `journald` | systemd-journald'a gönderir |
| `fluentd` | Fluentd'ye gönderir |
| `gelf` | Graylog GELF formatında |
| `awslogs` | AWS CloudWatch |
| `none` | Log yok |

```bash
# Container bazında driver
docker run --log-driver=syslog --log-opt syslog-address=udp://logserver:514 myapp

# Log boyut limiti (json-file driver)
docker run --log-opt max-size=10m --log-opt max-file=3 myapp
```

```json
// /etc/docker/daemon.json (global ayar)
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

> [!warning] Disk Tüketimi
> Default `json-file` driver'da log limiti **yoktur**.
> Container çok log üretirse host diski dolabilir.
> Production'da mutlaka `max-size` ve `max-file` ayarla.

#### Container Log'ları Nerede?
```bash
# json-file driver (default)
/var/lib/docker/containers/<container-id>/<container-id>-json.log

# Docker logs aslında bu dosyayı okur
# stdout → log dosyasına yazılır
# stderr → log dosyasına yazılır (stream="stderr" ile işaretlenir)
```

---

## Audit Sistemi (auditd)

Kernel seviyesinde **detaylı izleme**. Syscall, dosya erişimi, kullanıcı aktivitesi loglanır.

```bash
# auditd durumu
auditctl -s

# Aktif kuralları göster
auditctl -l

# Dosya izleme kuralı ekle
auditctl -w /etc/passwd -p rwa -k passwd_changes
# -w: izlenecek dosya
# -p: permission (r=read, w=write, a=attribute, x=execute)
# -k: arama anahtarı

# Syscall izleme
auditctl -a always,exit -F arch=b64 -S execve -k commands
# Her execve syscall'ı logla

# Audit log'larını ara
ausearch -k passwd_changes
ausearch -k commands --start today

# Audit raporu
aureport --summary
aureport --auth         # Authentication olayları
aureport --login        # Login olayları
aureport --file         # Dosya erişimleri
```

> [!tip] Container Security
> `auditd` container'ların syscall'larını da loglayabilir.
> Container escape denemelerini, şüpheli `execve` çağrılarını tespit etmek için kritik.
