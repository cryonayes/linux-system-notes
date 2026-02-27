Linux'ta **systemd**, modern init sistemidir. PID 1 olarak çalışır, servisleri, soketleri, zamanlayıcıları ve sistem durumlarını yönetir.

> [!info] İlişkili Notlar
> Süreçler ve PID 1 davranışı --> [[Linux Process Management]]
> Kaynak kontrolü (cgroups) --> [[Linux Cgroups]]
> Log sistemi (journald) --> [[Linux Logging]]
> Container'larda init --> [[Docker Temelleri]]
> Boot süreci --> [[Linux Boot Process]]

---

## systemd Nedir?

systemd, Linux sistemlerinde **PID 1** olarak çalışan init sistemi ve servis yöneticisidir. Lennart Poettering ve Kay Sievers tarafından geliştirilmiştir. Sadece bir init sistemi değil, aynı zamanda:

- **Servis yöneticisi** (service manager)
- **Log yöneticisi** (journald)
- **Ağ yapılandırması** (networkd)
- **DNS çözümleyici** (resolved)
- **Login yöneticisi** (logind)
- **Zaman eşitleme** (timesyncd)

```
Sistem Açılışı (Boot):

BIOS/UEFI
    |
    v
Bootloader (GRUB)
    |
    v
Kernel yuklemesi
    |
    v
PID 1 --> systemd
    |
    v
default.target (örneğin multi-user.target)
    |
    v
Bagimliliklara gore unit'ler paralel başlatılır
```

### SysVinit vs systemd Karşılaştırması

| Özellik | SysVinit | systemd |
|---------|----------|---------|
| **Başlatma** | Sırayla (sequential) | Paralel (parallel) |
| **Yapılandırma** | Shell script'ler (`/etc/init.d/`) | Unit dosyaları (`.service`) |
| **Bağımlılık** | Basit sıralama (S01, S02...) | Açık bağımlılık tanımları (Requires, After) |
| **Servis izleme** | Yok (PID dosyası ile) | Otomatik (cgroup tabanlı) |
| **Boot hızı** | Yavaş | Hızlı (paralel + on-demand) |
| **Log** | Metin dosyaları (`/var/log/`) | Yapılandırılmış journal (binary) |
| **Socket activation** | Yok | Var (inetd tarzı) |
| **Cgroup entegrasyonu** | Yok | Yerleşik |
| **Kaynak kontrolü** | Manuel | Yerleşik (MemoryMax, CPUQuota) |

> [!tip] Neden systemd?
> SysVinit'te servisler sırayla başlatılır ve birbirini bekler. systemd ise bağımlılıkları çözümleyerek paralel başlatma yapar, boot süresini önemli ölçüde kısaltır.

---

## Unit Türleri

systemd her şeyi **unit** olarak yönetir. Her unit bir yapılandırma dosyasıdır.

| Unit Türü | Uzantı | Açıklama | Örnek |
|-----------|--------|----------|-------|
| **Service** | `.service` | Daemon/servis yönetimi | `nginx.service` |
| **Socket** | `.socket` | Soket dinleme, socket activation | `sshd.socket` |
| **Timer** | `.timer` | Zamanlanmış görevler (cron alternatifi) | `backup.timer` |
| **Mount** | `.mount` | Dosya sistemi bağlama (`/etc/fstab` alternatifi) | `home.mount` |
| **Automount** | `.automount` | Otomatik mount (ilk erişimde) | `nas.automount` |
| **Path** | `.path` | Dosya/dizin değişikliğinde tetikleme | `config.path` |
| **Target** | `.target` | Unit gruplama (runlevel karşılığı) | `multi-user.target` |
| **Slice** | `.slice` | Kaynak kontrolü grubu (cgroup hiyerarşisi) | `user.slice` |
| **Scope** | `.scope` | Harici process grupları (runtime) | `session-1.scope` |
| **Swap** | `.swap` | Swap alanı yönetimi | `dev-sda2.swap` |
| **Device** | `.device` | udev device yönetimi | `sys-subsystem-net-...` |

```
Unit Dosyalarinin Konumlari (öncelik sirasina gore):

/etc/systemd/system/       # Yonetici tarafından oluşturulan (en yüksek öncelik)
/run/systemd/system/       # Runtime (geçici)
/usr/lib/systemd/system/   # Paket yöneticisi tarafından yuklenen
```

> [!warning] Öncelik Sırası
> `/etc/systemd/system/` altındaki unit dosyaları her zaman `/usr/lib/systemd/system/` altındakileri ezer. Bir servisi özelleştirmek için `systemctl edit` kullanın, doğrudan paket dosyasını değiştirmeyin.

---

## Service Unit Dosyası Yazma

Bir service unit dosyası üç ana bölümden oluşur: `[Unit]`, `[Service]` ve `[Install]`.

### [Unit] Bölümü

Genel tanımlama ve bağımlılıklar:

```ini
[Unit]
Description=My Application Server
Documentation=https://example.com/docs
After=network.target postgresql.service
Requires=postgresql.service
Wants=redis.service
```

| Direktif | Açıklama |
|----------|----------|
| `Description` | Unit'in kısa açıklaması |
| `Documentation` | Dokümantasyon URL'leri |
| `After` | Bu unit'ten **sonra** başla (sıralama) |
| `Before` | Bu unit'ten **önce** başla (sıralama) |
| `Requires` | Zorunlu bağımlılık (başarısız olursa bu da durur) |
| `Wants` | İsteğe bağlı bağımlılık (başarısız olsa da devam eder) |
| `Conflicts` | Aynı anda çalışamaz |
| `BindsTo` | Requires gibi ama bağımlılık durduğundan da durur |

### [Service] Bölümü

Servisin nasıl çalışacağını tanımlar:

```ini
[Service]
Type=simple
User=appuser
Group=appgroup
WorkingDirectory=/opt/myapp
Environment=NODE_ENV=production
EnvironmentFile=/etc/myapp/env
ExecStartPre=/usr/bin/myapp-check
ExecStart=/usr/bin/myapp --config /etc/myapp/config.yaml
ExecStartPost=/usr/bin/myapp-notify started
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/usr/bin/myapp-shutdown
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=myapp
```

### [Install] Bölümü

`systemctl enable/disable` davranışını belirler:

```ini
[Install]
WantedBy=multi-user.target
Alias=myapp.service
Also=myapp-worker.service
```

| Direktif | Açıklama |
|----------|----------|
| `WantedBy` | Hangi target aktifken bu servis etkinleştirilsin |
| `RequiredBy` | Hangi target bu servisi zorunlu kılsın |
| `Alias` | Alternatif isim |
| `Also` | Bu unit enable edilince bunlar da enable edilir |

### Tam Örnek: Node.js Uygulama Servisi

```ini
# /etc/systemd/system/nodeapp.service
[Unit]
Description=Node.js Web Application
Documentation=https://github.com/myorg/nodeapp
After=network.target mongodb.service
Wants=mongodb.service

[Service]
Type=simple
User=nodeapp
Group=nodeapp
WorkingDirectory=/opt/nodeapp
Environment=NODE_ENV=production
Environment=PORT=3000
ExecStart=/usr/bin/node /opt/nodeapp/server.js
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
TimeoutStartSec=30
TimeoutStopSec=30

# Guvenlik
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/nodeapp/data
PrivateTmp=true

# Kaynak limitleri
MemoryMax=512M
CPUQuota=80%

# Log
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nodeapp

[Install]
WantedBy=multi-user.target
```

```bash
# Unit dosyasini yükle ve başlat
sudo systemctl daemon-reload
sudo systemctl enable --now nodeapp.service
sudo systemctl status nodeapp.service
```

---

## Service Türleri (Type=)

`Type=` direktifi, systemd'nin servisi nasıl başlatacağını ve "hazır" kabul edeceğini belirler.

| Type | Davranış | Kullanım Alanı | Örnek |
|------|----------|----------------|-------|
| `simple` | ExecStart process'i **ana process**. Fork yapmaz. systemd hemen "başlatıldı" kabul eder | Foreground çalışan modern daemon'lar | Node.js, Go uygulamaları |
| `forking` | ExecStart fork yapar, parent çıkıyor, child arka planda çalışmaya devam eder. `PIDFile` gerekebilir | Geleneksel Unix daemon'ları | Apache httpd, nginx (eski tarz) |
| `oneshot` | Process çalışır ve çıkar. systemd çıkana kadar "başlatılıyor" sayar. `RemainAfterExit=yes` ile "aktif" kalabilir | Tek seferlik işlemler, script'ler | Firewall kuralları, sistem hazırlığı |
| `notify` | `simple` gibi ama process `sd_notify()` ile "hazırım" sinyali gönderir | Hazırlık süreci olan daemon'lar | systemd-networkd, PostgreSQL |
| `dbus` | Process D-Bus'a kayıt olunca "hazır" kabul edilir. `BusName` gerekir | D-Bus servisleri | NetworkManager, PulseAudio |
| `idle` | `simple` gibi ama tüm işler bitene kadar çalışmayı erteler. Konsol çıktısını düzenleme amaçlı | Boot sonu bilgi mesajları | getty, konsol mesajları |

```ini
# forking örneği (geleneksel daemon)
[Service]
Type=forking
PIDFile=/run/mydaemon.pid
ExecStart=/usr/sbin/mydaemon --daemon
```

```ini
# oneshot örneği (bir kere calis ve cik)
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/firewall-setup.sh
ExecStop=/usr/local/bin/firewall-teardown.sh
```

```ini
# notify örneği (hazir sinyali gönder)
[Service]
Type=notify
ExecStart=/usr/sbin/mynotifyd
NotifyAccess=main
```

> [!tip] Doğru Type Seçimi
> Eğer uygulamanız fork yapıp arka plana geçiyorsa `forking`, foreground çalışıyorsa `simple`, başlaması zaman alıyorsa ve `sd_notify()` kullanıyorsa `notify` seçin. Çoğu modern uygulama için `simple` yeterlidir.

---

## Exec Direktifleri

Servisin yaşam döngüsü boyunca çalışan komutlar:

```
Baslatma Sureci:

ExecStartPre  -->  ExecStart  -->  ExecStartPost
     |                 |                  |
  On hazirlik    Ana process      Baslatma sonrasi
  (kontroller)   (daemon)        (bildirimler)

Yeniden Yukleme:
ExecReload  -->  ana process'e sinyal gönderir (genellikle HUP)

Durdurma Sureci:
ExecStop  -->  ExecStopPost
     |              |
  Duzenli       Temizlik
  kapatma       işlemleri
```

| Direktif | Çalışma Zamanı | Açıklama |
|----------|----------------|----------|
| `ExecStartPre` | Başlatma öncesi | Ön kontrol, dizin oluşturma, config doğrulama |
| `ExecStart` | Ana başlatma | Servisin kendisi (sadece bir tane olabilir, Type=oneshot hariç) |
| `ExecStartPost` | Başlatma sonrası | Bildirim gönderme, sağlık kontrolü |
| `ExecReload` | Yeniden yükleme | Config yeniden yükleme (genellikle HUP sinyali) |
| `ExecStop` | Durdurma | Düzenli kapatma komutu |
| `ExecStopPost` | Durdurma sonrasi | Temizlik (başarısız durumda da çalışır) |

```ini
[Service]
Type=forking

# Baslatma oncesi: config dogrula ve dizin olustur
ExecStartPre=/usr/bin/myapp --validate-config
ExecStartPre=/bin/mkdir -p /run/myapp

# Ana başlatma
ExecStart=/usr/bin/myapp --daemon --pidfile /run/myapp/myapp.pid

# Baslatma sonrasi: sagllik kontrolü
ExecStartPost=/usr/bin/curl -sf http://localhost:8080/health

# Config yeniden yükleme
ExecReload=/bin/kill -HUP $MAINPID

# Duzenli kapatma
ExecStop=/usr/bin/myapp --shutdown

# Temizlik (her durumda çalışır)
ExecStopPost=/bin/rm -f /run/myapp/myapp.pid

PIDFile=/run/myapp/myapp.pid
```

> [!warning] ExecStartPre Başarısızlığı
> `ExecStartPre` komutlarından biri başarısız olursa (`exit code != 0`), `ExecStart` çalışmaz ve servis başlatma hatası verir. Başarısız olabilecek ön kontroller için komutun başına `-` koyarak hatayı yoksayabilirsiniz: `ExecStartPre=-/usr/bin/optional-check`

---

## Restart Policy

systemd, servislerin beklenmedik durumlarda nasıl yeniden başlatılacağını kontrol eder.

| Direktif | Açıklama |
|----------|----------|
| `Restart=no` | Yeniden başlatma (varsayılan) |
| `Restart=always` | Her durumda yeniden başlat (baskısı ile durdurulsa bile) |
| `Restart=on-success` | Sadece başarılı çıkışta (exit code 0) |
| `Restart=on-failure` | Başarısız çıkış, sinyal, timeout durumlarında |
| `Restart=on-abnormal` | Sinyal, timeout, watchdog durumlarında |
| `Restart=on-watchdog` | Sadece watchdog timeout durumunda |
| `Restart=on-abort` | Sadece yakalanmayan sinyal durumunda |
| `RestartSec=` | Yeniden başlatma öncesi bekleme süresi (saniye) |
| `StartLimitIntervalSec=` | Rate limiting penceresi |
| `StartLimitBurst=` | Pencere içinde max deneme |

```ini
[Service]
# Basarisizlikta 10 saniye sonra yeniden başlat
Restart=on-failure
RestartSec=10

# 5 dakikada en fazla 3 deneme
StartLimitIntervalSec=300
StartLimitBurst=3
```

```ini
# Tam restart policy örneği: her kosulda yeniden başlat
[Service]
Type=simple
ExecStart=/usr/bin/critical-app
Restart=always
RestartSec=5

# Basarisiz çıkış kodlarini "başarılı" kabul etme
RestartPreventExitStatus=SIGTERM
# Basarili çıkış kodlarini "başarısız" kabul et (restart tetikle)
RestartForceExitStatus=1 6 SIGABRT
```

```
Restart davranışı tablosu:

Cikis Durumu          | always | on-success | on-failure | on-abnormal | on-abort | on-watchdog
---------------------|--------|------------|------------|-------------|----------|------------
Clean exit (code 0)  |  Evet  |    Evet    |   Hayir    |    Hayir    |  Hayir   |    Hayir
Non-zero exit        |  Evet  |   Hayir    |    Evet    |    Hayir    |  Hayir   |    Hayir
Signal (SIGSEGV vb.) |  Evet  |   Hayir    |    Evet    |     Evet    |   Evet   |    Hayir
Timeout              |  Evet  |   Hayir    |    Evet    |     Evet    |  Hayir   |    Hayir
Watchdog timeout     |  Evet  |   Hayir    |    Evet    |     Evet    |  Hayir   |     Evet
```

---

## systemctl Komutları

`systemctl`, systemd ile etkileşim için ana komut satırı aracıdır.

### Servis Yönetimi

```bash
# Servisi başlat / durdur / yeniden başlat
sudo systemctl start nginx.service
sudo systemctl stop nginx.service
sudo systemctl restart nginx.service

# Config yeniden yükle (servisi durdurmadan)
sudo systemctl reload nginx.service

# Yeniden başlat veya reload (destekliyorsa reload, yoksa restart)
sudo systemctl reload-or-restart nginx.service

# Boot'ta otomatik baslatmayi etkinlestir / devre dışı bırak
sudo systemctl enable nginx.service
sudo systemctl disable nginx.service

# Hem enable hem start (tek komut)
sudo systemctl enable --now nginx.service

# Servis durumunu gor
systemctl status nginx.service
```

### Durum Sorgulama

```bash
# Aktif mi?
systemctl is-active nginx.service
# Ciktisi: active / inactive / failed

# Enable edilmiş mi?
systemctl is-enabled nginx.service
# Ciktisi: enabled / disabled / masked / static

# Basarisiz mi?
systemctl is-failed nginx.service
```

### Maskeleme (Mask)

```bash
# Servisi maskele (hicbir şekilde baslatilamaz)
sudo systemctl mask nginx.service
# /dev/null'a symlink oluşturur

# Maskeyi kaldir
sudo systemctl unmask nginx.service
```

> [!warning] mask vs disable
> `disable` boot'ta otomatik başlatmayı kapatır ama elle başlatılabilir. `mask` ise servisin **hiçbir şekilde** başlatılmasını engeller. Tehlikeli bir servisi tamamen engellemek için `mask` kullanın.

### Unit Listeleme

```bash
# Tum aktif unit'leri listele
systemctl list-units

# Sadece servisler
systemctl list-units --type=service

# Basarisiz olanlar
systemctl list-units --state=failed

# Tum yüklü unit dosyalarını listele (enable/disable durumu ile)
systemctl list-unit-files

# Sadece timer unit dosyaları
systemctl list-unit-files --type=timer

# Tum aktif timer'lari ve bir sonraki tetiklenme zamanini göster
systemctl list-timers --all
```

### daemon-reload

```bash
# Unit dosyalarını yeniden yükle (dosya degistirdikten sonra ZORUNLU)
sudo systemctl daemon-reload
```

> [!warning] daemon-reload Unutmayın
> Unit dosyasını düzenledikten sonra `daemon-reload` çalıştırmazsanız, systemd eski yapılandırmayı kullanmaya devam eder. Bu en sık yapılan hatalardan biridir.

### Diğer Faydalı Komutlar

```bash
# Bir unit'in tüm özelliklerini göster
systemctl show nginx.service

# Belirli bir özelliği gor
systemctl show nginx.service -p MainPID

# Unit dosyasinin içeriğini göster
systemctl cat nginx.service

# Unit dosyasini düzenle (override oluşturur)
sudo systemctl edit nginx.service
# /etc/systemd/system/nginx.service.d/override.conf oluşturur

# Tam dosyayi düzenle (override değil)
sudo systemctl edit --full nginx.service

# Bagimliliklari göster
systemctl list-dependencies nginx.service

# Tersine bagimliliklar (buna kim bagimli?)
systemctl list-dependencies --reverse nginx.service
```

---

## Target'lar

Target'lar, unit'leri mantıksal gruplara ayırmak için kullanılır. SysVinit'teki **runlevel** kavramının karşılığıdır.

| Target | Eski Runlevel | Açıklama |
|--------|---------------|----------|
| `poweroff.target` | 0 | Sistemi kapat |
| `rescue.target` | 1 | Tek kullanıcı modu (root shell) |
| `multi-user.target` | 3 | Çok kullanıcılı, grafik arayüz yok |
| `graphical.target` | 5 | Çok kullanıcılı, grafik arayüz var |
| `reboot.target` | 6 | Sistemi yeniden başlat |
| `emergency.target` | - | Acil durum (minimal root shell) |
| `default.target` | - | Varsayılan hedef (genellikle `multi-user` veya `graphical`) |

```bash
# Varsayilan target'i gor
systemctl get-default
# Ciktisi: multi-user.target veya graphical.target

# Varsayilan target'i değiştir
sudo systemctl set-default multi-user.target

# Baska bir target'a gec (isolate)
sudo systemctl isolate rescue.target

# Rescue mode'a gec
sudo systemctl rescue

# Emergency mode'a gec
sudo systemctl emergency
```

```
Target Hiyerarsisi:

graphical.target
    |
    +-- multi-user.target
    |       |
    |       +-- basic.target
    |       |       |
    |       |       +-- sysinit.target
    |       |       |       |
    |       |       |       +-- local-fs.target
    |       |       |       +-- swap.target
    |       |       |
    |       |       +-- sockets.target
    |       |       +-- timers.target
    |       |       +-- paths.target
    |       |
    |       +-- getty.target (konsol login)
    |       +-- sshd.service
    |       +-- nginx.service
    |       +-- ... (diger servisler)
    |
    +-- display-manager.service (GDM, LightDM vb.)
```

> [!tip] isolate ile Target Değiştirme
> `systemctl isolate` komutu, hedef target'a ait olmayan tüm unit'leri durdurur ve hedefteki unit'leri başlatır. SysVinit'teki `init 3` veya `init 5` komutlarına benzer.

---

## Socket Activation

Socket activation, bir servisin sadece **ilk bağlantı geldiğinde** başlatılmasını sağlar. inetd/xinetd mantığı ile çalışır.

### Çalışma Prensibi

```
1. systemd socket'i dinler (örneğin port 80)
2. İstemci bağlantısı gelir
3. systemd ilgili servisi başlatır
4. Socket file descriptor'larini servise aktarir
5. Servis isteği isler

Avantajlari:
- Kullanilmayan servisler kaynak tuketmez
- Boot hızı artar (servisler lazy başlatılır)
- Servis restart sirasinda bağlantı kaybi olmaz
  (socket systemd'de kalir, buffer'lanir)
```

### Socket Unit Örneği

```ini
# /etc/systemd/system/myapp.socket
[Unit]
Description=My Application Socket

[Socket]
ListenStream=8080
# veya Unix socket:
# ListenStream=/run/myapp.sock
Accept=no
# Accept=no: tek bir servis instance'i tüm bağlantıları isler
# Accept=yes: her bağlantı için yeni bir servis instance'i

[Install]
WantedBy=sockets.target
```

```ini
# /etc/systemd/system/myapp.service
[Unit]
Description=My Application
Requires=myapp.socket

[Service]
Type=simple
ExecStart=/usr/bin/myapp
# Socket'ten gelen fd'leri al
# sd_listen_fds() veya dosya descriptor 3+ kullanılır

[Install]
WantedBy=multi-user.target
```

### Accept=yes vs Accept=no

| Özellik | Accept=no | Accept=yes |
|---------|-----------|------------|
| Instance sayısı | Tek servis tüm bağlantıları işler | Her bağlantı için yeni instance |
| Servis ismi | `myapp.service` | `myapp@<conn>.service` (template) |
| Performans | Daha iyi (tek process) | Her bağlantı için fork |
| Kullanım | Web sunucuları, DB'ler | Basit protokoller, debug |

```bash
# Socket'i etkinlestir (servisi değil!)
sudo systemctl enable --now myapp.socket

# Socket durumunu kontrol et
systemctl status myapp.socket

# Dinlenen soketleri listele
systemctl list-sockets
```

> [!info] SSH için Socket Activation
> OpenSSH sunucusu socket activation ile çalışabilir. Sunucu sadece SSH bağlantısı geldiğinde başlar:
> `systemctl enable --now sshd.socket` (sshd.service yerine)

---

## Timer'lar (cron Alternatifi)

systemd timer'ları, cron'un modern alternatifidir. Daha esnek, loglama entegre ve bağımlılık yönetimi vardır.

### cron vs systemd Timer

| Özellik | cron | systemd Timer |
|---------|------|---------------|
| Yapılandırma | `/etc/crontab`, crontab dosyaları | `.timer` + `.service` unit dosyaları |
| Loglama | `syslog` / mail | `journalctl` ile entegre |
| Bağımlılık | Yok | systemd bağımlılıkları |
| Kaçırılan görev | Kaybolur | `Persistent=true` ile yakalanır |
| Monotonic timer | Yok | `OnBootSec`, `OnUnitActiveSec` |
| Kaynak kontrolü | Yok | cgroups ile entegre |
| Hassasiyet | Dakika | Mikrosaniye |

### Timer Türleri

**Monotonic Timer** (göstergeye bağlı):

```ini
[Timer]
# Boot'tan 15 dakika sonra
OnBootSec=15min

# Timer aktif olduktan 1 saat sonra
OnActiveSec=1h

# Servis son calismasindan 30 dakika sonra tekrarla
OnUnitActiveSec=30min

# systemd baslatilasindan 10 dakika sonra
OnStartupSec=10min
```

**Takvim Tabanlı Timer** (cron tarzı):

```ini
[Timer]
# Her gun gece yarisi
OnCalendar=daily
# Asil format: OnCalendar=*-*-* 00:00:00

# Her saat
OnCalendar=hourly

# Her pazartesi saat 09:00
OnCalendar=Mon *-*-* 09:00:00

# Her ayin 1'i saat 03:00
OnCalendar=*-*-01 03:00:00

# Her 15 dakikada bir
OnCalendar=*:0/15

# Haftaici her gun 08:00-18:00 arasi her saat
OnCalendar=Mon..Fri *-*-* 08..18:00:00
```

### Tam Timer + Service Örneği

```ini
# /etc/systemd/system/backup.timer
[Unit]
Description=Daily Backup Timer

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
# Persistent=true: sistem kapali iken kacirilan görevleri
# sistem acildiginda çalıştırır
RandomizedDelaySec=900
# 0-15 dakika arasi rastgele gecikme (herd etkisini onler)
AccuracySec=60
# 1 dakika hassasiyet (varsayilan 1 dakika)

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/backup.service
[Unit]
Description=Daily Backup Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=backup
ExecStart=/usr/local/bin/backup.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=daily-backup

# Kaynak limitleri
MemoryMax=1G
CPUQuota=50%
IOWeight=100
Nice=10
```

```bash
# Timer'i etkinlestir
sudo systemctl enable --now backup.timer

# Tum timer'lari listele (bir sonraki çalışma zamani ile)
systemctl list-timers --all

# Timer'i elle tetikle (test için)
sudo systemctl start backup.service

# Timer loglarini incele
journalctl -u backup.service --since today

# OnCalendar ifadesini test et
systemd-analyze calendar "Mon..Fri *-*-* 09:00:00"
systemd-analyze calendar "daily"
systemd-analyze calendar "*:0/15"
```

> [!tip] Persistent Timer'lar
> `Persistent=true` ayarı ile timer, sistem kapalı iken kaçırılan görevleri sonraki açılışta çalıştırır. Bu özellik özellikle laptop ve periyodik kapatılan sunucular için çok faydalıdır.

---

## Path Unit'leri

Path unit'leri, belirli dosya veya dizin değişikliklerinde bir servisi tetikler. inotify mekanizmasını kullanır.

### İzlenebilen Değişiklikler

| Direktif | Açıklama |
|----------|----------|
| `PathExists=` | Belirtilen yol var olunca tetikle |
| `PathExistsGlob=` | Glob desenine uyan yol var olunca tetikle |
| `PathChanged=` | Dosya değiştiğinde tetikle (yazma sonrası dosya kapatılınca) |
| `PathModified=` | Dosya yazıldığında tetikle (her yazma işleminde) |
| `DirectoryNotEmpty=` | Dizin boş değilse tetikle |

### Tam Path Unit Örneği

```ini
# /etc/systemd/system/config-watcher.path
[Unit]
Description=Watch Configuration Directory

[Path]
PathChanged=/etc/myapp/config.yaml
PathChanged=/etc/myapp/rules.d/
DirectoryNotEmpty=/var/spool/myapp/incoming/
MakeDirectory=yes
Unit=config-reload.service

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/config-reload.service
[Unit]
Description=Reload Application Config

[Service]
Type=oneshot
ExecStart=/usr/bin/myapp-reload
StandardOutput=journal
SyslogIdentifier=config-reload
```

```bash
# Path unit'ini etkinlestir
sudo systemctl enable --now config-watcher.path

# Durumunu kontrol et
systemctl status config-watcher.path
```

### Pratik Örnek: Upload Dizini İzleme

```ini
# /etc/systemd/system/process-uploads.path
[Unit]
Description=Watch Upload Directory

[Path]
DirectoryNotEmpty=/var/uploads/incoming
MakeDirectory=yes

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/process-uploads.service
[Unit]
Description=Process Uploaded Files

[Service]
Type=oneshot
ExecStart=/usr/local/bin/process-uploads.sh
```

---

## Resource Control (Kaynak Kontrolü)

systemd, **cgroups** ile entegre çalışarak servislere kaynak limiti koyar. Bu özellik [[Linux Cgroups]] altyapısını kullanır.

### CPU Kontrolü

```ini
[Service]
# CPU paylaşım ağırlığı (varsayilan: 100, aralık: 1-10000)
CPUWeight=50

# Kesin CPU limiti (yüzde, 100% = 1 core)
CPUQuota=200%
# 2 core'a kadar kullanabilir

# Belirli CPU core'larina sabitle
CPUAffinity=0 1
# Sadece CPU 0 ve 1 kullanılır
```

### Bellek Kontrolü

```ini
[Service]
# Kesin bellek limiti (asilirsa OOM killer devreye girer)
MemoryMax=1G

# Yuksek bellek kullanım uyarisi (soft limit)
MemoryHigh=800M

# Minimum garantili bellek
MemoryMin=256M

# Swap limiti
MemorySwapMax=512M
```

### I/O Kontrolü

```ini
[Service]
# I/O ağırlığı (varsayilan: 100, aralık: 1-10000)
IOWeight=50

# Belirli cihaz için bant genisligi limiti
IOReadBandwidthMax=/dev/sda 50M
IOWriteBandwidthMax=/dev/sda 30M

# IOPS limiti
IOReadIOPSMax=/dev/sda 1000
IOWriteIOPSMax=/dev/sda 500
```

### Diğer Kaynak Limitleri

```ini
[Service]
# Maksimum process/thread sayisi
TasksMax=100

# Dosya boyutu limiti
LimitFSIZE=500M

# Acik dosya limiti
LimitNOFILE=65536

# Core dump boyutu (0 = devre dışı)
LimitCORE=0
```

### systemd-cgtop ile İzleme

```bash
# Cgroup bazinda kaynak kullanımını canli izle (top benzeri)
systemd-cgtop

# Belirli bir servisin cgroup bilgilerini göster
systemctl show nginx.service -p MemoryCurrent -p CPUUsageNSec

# Slice bazinda kaynak kullanımını gor
systemd-cgtop -m
```

```bash
# Calisma zamaninda kaynak limiti değiştir (geçici)
sudo systemctl set-property nginx.service MemoryMax=2G
sudo systemctl set-property nginx.service CPUQuota=150%

# Kalici değişiklik (override dosyasi oluşturur)
sudo systemctl set-property nginx.service MemoryMax=2G --runtime=false
```

> [!info] Cgroup v2 Gerekliliği
> Bazı kaynak kontrol özellikleri (özellikle I/O limitleri ve MemoryMin) sadece **cgroup v2** ile çalışır. Sistem hangi cgroup versiyonunu kullandığını kontrol etmek için: `stat -fc %T /sys/fs/cgroup/`

---

## Journal Entegrasyonu

systemd servisleri varsayılan olarak çıktılarını **journald**'ye gönderir. Detaylı bilgi için: [[Linux Logging]]

### Servis İçinden Log Yapılandırması

```ini
[Service]
# Standart ciktiyi journal'a yönlendir
StandardOutput=journal
StandardError=journal

# Log'larda gorunecek isim
SyslogIdentifier=myapp

# Log seviyesini filtrele
SyslogLevel=info

# Log facility
SyslogFacility=daemon
```

### StandardOutput/StandardError Seçenekleri

| Değer | Açıklama |
|-------|----------|
| `inherit` | systemd'nin çıktısını devral |
| `null` | `/dev/null`'a gönder (yok say) |
| `journal` | Sadece journal'a yaz |
| `journal+console` | Hem journal hem konsola yaz |
| `kmsg` | Kernel mesaj buffer'ına yaz |
| `syslog` | Syslog daemon'a gönder |
| `file:/path` | Belirtilen dosyaya yaz |
| `append:/path` | Belirtilen dosyaya ekle (mevcut içeriği korur) |

```bash
# Belirli servisin loglarini gor
journalctl -u nginx.service

# Canli takip
journalctl -u nginx.service -f

# Son 50 satır
journalctl -u nginx.service -n 50

# Bugunun loglari
journalctl -u nginx.service --since today

# Zaman araliginda
journalctl -u nginx.service --since "2024-01-01 00:00" --until "2024-01-02 00:00"

# Sadece hatalar
journalctl -u nginx.service -p err

# JSON formatinda çıktı
journalctl -u nginx.service -o json-pretty

# Birden fazla servisin loglarini birlikte gor
journalctl -u nginx.service -u php-fpm.service
```

---

## Dependency (Bağımlılık) Yönetimi

systemd, unit'ler arasında karmaşık bağımlılık ilişkileri tanımlamayı destekler.

### Sıralama Direktifleri (Ordering)

```ini
[Unit]
# Bu unit, network.target'tan SONRA baslasin
After=network.target

# Bu unit, cleanup.service'den ONCE baslasin
Before=cleanup.service
```

> [!warning] After/Before vs Requires/Wants
> `After` ve `Before` sadece **başlatma sirasini** belirler, bagimliligi olusturmaz. `Requires` ve `Wants` ise bagimliligi tanimlar ama sirayi belirlemez. Cogu durumda ikisini birlikte kullanmaniz gerekir.

### Bagimlilik Direktifleri (Dependency)

| Direktif | Davranış | Bagimlilik Basarisiz Olursa |
|----------|----------|----------------------------|
| `Requires` | Zorunlu bağımlılık, birlikte başlatılır | Bu unit de başarısız olur |
| `Wants` | Istege bağlı bağımlılık, birlikte başlatılır | Bu unit'i etkilemez |
| `BindsTo` | `Requires` gibi + bağımlılık durursa bu da durur | Bu unit de durur |
| `Requisite` | Zaten aktif olmali (baslatilmaz) | Bu unit baslamaz |
| `PartOf` | Bagimlilik restart/stop edilirse bu da restart/stop edilir | - |
| `Conflicts` | Birlikte calisamaz | Diger durdurulur |

```ini
# Örnek: web uygulaması bağımlılıkları
[Unit]
Description=Web Application
# Zorunlu: veritabanı olmadan calisamaz
Requires=postgresql.service
# Istege bağlı: redis olsa iyi olur ama zorunlu değil
Wants=redis.service
# Siralama: ikisinden sonra basla
After=postgresql.service redis.service network-online.target
# Cakisma: apache ile aynı anda calismamali
Conflicts=apache2.service
```

```ini
# BindsTo örneği: VPN'e bağlı servis
[Unit]
Description=VPN-dependent Service
BindsTo=openvpn.service
After=openvpn.service
# openvpn durursa bu servis de otomatik durur
```

```bash
# Bagimliliklari ağaç olarak göster
systemctl list-dependencies nginx.service

# Tersine bagimliliklar
systemctl list-dependencies --reverse nginx.service

# Tum bağımlılık agacini göster (recursive)
systemctl list-dependencies --all nginx.service
```

---

## Container'da systemd

Container'larda systemd çalıştırmak **sorunlu** bir konudur cunku systemd PID 1 olarak çalışmayı ve bazi kernel ozelliklerine erismesi gerektiğini varsayar.

### Neden Sorunlu?

```
Container'da systemd sorunları:

1. PID 1 beklentisi:
   - systemd PID 1 olmak ister
   - Container'da genellikle uygulama PID 1'dir

2. Cgroup erişimi:
   - systemd cgroup dosya sistemine yazma erişimi ister
   - Container'lar genellikle read-only cgroup'a sahip

3. /sys/fs/cgroup mount'u:
   - systemd kendi cgroup hiyerarsisini oluşturmak ister
   - Container izolasyonu bunu engelleyebilir

4. tmpfs gereksinimleri:
   - /run, /tmp gibi dizinlerde tmpfs bekler

5. DBus/journald:
   - Tam systemd için bu alt servisler de gerekir
```

### Docker --init Alternatifi

Docker container'larinda PID 1 sorunlarını çözmek için `--init` flagi kullanılabilir. Bu, `tini` adlı hafif bir init process'i PID 1 olarak çalıştırır.

```bash
# tini ile container çalıştır (onerilen yaklaşım)
docker run --init myapp

# tini sadece sinyal iletimi ve zombie reaping yapar
# systemd'nin tamamindan çok daha hafif
```

```
docker run --init ile:

PID 1: tini (sinyal iletimi + zombie reaping)
PID 2: uygulamaniz

docker run (--init olmadan):

PID 1: uygulamaniz (sinyal yönetimi eksik olabilir)
```

### Docker ile systemd (zorlanarak)

```dockerfile
# Onerilmez ama mumkun
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y systemd
CMD ["/sbin/init"]
```

```bash
# Gerekli izinler
docker run -d \
  --privileged \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --cgroupns=host \
  --tmpfs /run \
  --tmpfs /run/lock \
  my-systemd-image
```

> [!warning] Docker'da systemd
> Docker container'larinda systemd çalıştırmak **anti-pattern** kabul edilir. Container felsefesi tek bir süreç calistirmayi benimser. Eger birden fazla servis gerekiyorsa Docker Compose veya Kubernetes kullanin.

### Podman ile systemd

Podman, systemd container'lari için çok daha iyi destek sunar:

```bash
# Podman otomatik olarak systemd'yi algılar ve gerekli ayarlari yapar
podman run -d \
  --name my-systemd-container \
  my-systemd-image \
  /sbin/init

# Podman ile systemd avantajlari:
# - Root'suz (rootless) calismaya uygun
# - Cgroup v2 ile dogal entegrasyon
# - --privileged gerekmiyor (çoğu durumda)
# - Otomatik tmpfs mount'lari
```

```bash
# Podman ile systemd servisini host systemd'den yonetme
# Container'i bir systemd servisi olarak olustur
podman generate systemd --new --name my-container > \
  /etc/systemd/system/container-myapp.service

sudo systemctl enable --now container-myapp.service
```

---

## Troubleshooting (Sorun Giderme)

### Basarisiz Servisleri Bulma

```bash
# Basarisiz unit'leri listele
systemctl --failed
# veya
systemctl list-units --state=failed

# Belirli servisin durumunu incele
systemctl status nginx.service
# Cikti: loaded, active/inactive/failed, son log satırları, PID, bellek

# Detayli servis bilgisi
systemctl show nginx.service
```

### Journal ile Log Analizi

```bash
# Servis loglarini incele
journalctl -u nginx.service

# Son boot'tan itibaren
journalctl -u nginx.service -b

# Sadece hatalar ve ustunu göster
journalctl -u nginx.service -p err

# Servisin son başarısız calismasinin loglarini gor
journalctl -u nginx.service --since "1 hour ago"

# Tum kernel mesajları
journalctl -k

# Disk kullanimi
journalctl --disk-usage
```

### Boot Suresi Analizi

```bash
# Toplam boot suresini göster
systemd-analyze

# Her unit'in ne kadar surde basladigini göster (en yavaş en ustte)
systemd-analyze blame

# Kritik zincir (boot'u en çok yavalatan bağımlılık zinciri)
systemd-analyze critical-chain

# Belirli bir unit'in kritik zinciri
systemd-analyze critical-chain nginx.service

# SVG formatinda boot grafigi olustur
systemd-analyze plot > boot-analysis.svg

# Unit dosyasini dogrula (syntax kontrolü)
systemd-analyze verify /etc/systemd/system/myapp.service

# Guvenlik puanlama (unit dosyasinin ne kadar güvenli olduğu)
systemd-analyze security nginx.service
```

### Yayginn Sorunlar ve Cozumleri

```
Sorun: "Failed to start... Unit not found"
Cozum:
  1. Unit dosyasinin doğru konumda olduğundan emin olun
  2. sudo systemctl daemon-reload
  3. systemctl list-unit-files | grep myapp

Sorun: "Job for X.service failed because the control process exited with error"
Cozum:
  1. journalctl -u myapp.service -n 50
  2. ExecStart komutunu elle calistirarak test edin
  3. Izinleri (User, Group, dosya izinleri) kontrol edin
  4. SELinux/AppArmor loglarini kontrol edin

Sorun: Servis sürekli restart ediyor
Cozum:
  1. journalctl -u myapp.service ile crash nedenini bulun
  2. systemctl show myapp.service -p NRestarts (kac kez restart etmis)
  3. RestartSec degerini artirin
  4. StartLimitBurst/StartLimitIntervalSec ayarlayin

Sorun: "Unit is masked"
Cozum:
  sudo systemctl unmask myapp.service

Sorun: Degisiklikler uygulanmiyor
Cozum:
  sudo systemctl daemon-reload
  sudo systemctl restart myapp.service
```

### Faydali Debug Komutlari

```bash
# systemd'nin genel durumunu gor
systemctl status

# Cgroup hiyerarsisini göster
systemd-cgls

# Kaynak kullanımını canli izle
systemd-cgtop

# Boot log'unu incele
journalctl -b -p warning

# Belirli bir unit'in environment'ini göster
systemctl show-environment

# Unit dosyasinin etkin halini göster (override'lar dahil)
systemctl cat myapp.service

# Beklenen vs gerçek bağımlılık sirasini kontrol et
systemd-analyze dot myapp.service | dot -Tsvg > deps.svg
```

> [!tip] systemd-analyze security
> `systemd-analyze security myapp.service` komutu, servisinizin güvenlik yapılandırmasını puanlar ve iyilestirme onerileri sunar. Yeni bir servis olusturduktan sonra bu komutu calistirarak güvenlik seviyenizi kontrol edin.

---

## Ozet ve En Iyi Pratikler

```
systemd En Iyi Pratikleri:

1. Type secimi:
   - Modern uygulamalar için Type=simple
   - Fork yapan daemon'lar için Type=forking + PIDFile
   - Baslatma süresi olan servisler için Type=notify

2. Restart politikasi:
   - Kritik servisler: Restart=always + RestartSec=5
   - Normal servisler: Restart=on-failure + RestartSec=10
   - Rate limiting: StartLimitBurst + StartLimitIntervalSec

3. Guvenlik:
   - User/Group ile non-root çalıştırma
   - ProtectSystem=strict
   - ProtectHome=true
   - NoNewPrivileges=true
   - PrivateTmp=true

4. Kaynak kontrolü:
   - MemoryMax ile bellek limiti
   - CPUQuota ile CPU limiti
   - TasksMax ile process limiti

5. Loglama:
   - StandardOutput=journal
   - SyslogIdentifier ile isim verme

6. Timer'lar:
   - cron yerine systemd timer kullanin
   - Persistent=true ile kacirilan görevleri yakalarin
   - RandomizedDelaySec ile herd etkisini onleyin
```
