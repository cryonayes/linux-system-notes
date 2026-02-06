# Linux Boot Process

Bilgisayarın güç tuşuna basıldığı andan kullanıcının karşısına login ekranı gelene kadar gerçekleşen **tüm adımların** ayrıntılı incelemesi.

> [!info] İlişkili
> PID 1 ve process yönetimi → [[Linux Process Management]]
> Container'da boot davranışı → [[Docker Temelleri]]
> PID 1 ve signal handling → [[Dockerfile Best Practices#Shell Form vs Exec Form]]
> Filesystem bağlama süreci → [[Linux Filesystem Internals]]

---

## Boot Zinciri - Genel Bakış

```
Power On
  │
  ▼
┌─────────────────────────────────────────────────────────────────┐
│  FIRMWARE (BIOS / UEFI)                                         │
│  POST → donanım kontrolü → boot device secimi                   │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  BOOTLOADER (GRUB2)                                             │
│  Stage 1 → Stage 1.5 → Stage 2                                  │
│  grub.cfg yükle → kernel + initramfs'i memory'ye yükle          │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  KERNEL                                                         │
│  decompress → start_kernel() → subsystem init → driver init     │
│  /sysfs ve /proc mount                                          │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  INITRAMFS (Early Userspace)                                    │
│  geçici root filesystem → gerekli driver'lari yükle             │
│  gerçek root partition'i mount et → switch_root                 │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  INIT / SYSTEMD (PID 1)                                         │
│  default.target → servis başlat → login prompt                  │
└─────────────────────────────────────────────────────────────────┘
```

Bu zincirdeki her halka bir sonrakine kontrolü devreder. Herhangi bir noktada hata oluşursa sistem **boot edemez** veya **recovery moduna** düşer.

---

## BIOS vs UEFI

### BIOS (Basic Input/Output System)

**BIOS**, 1980'lerden beri kullanılan eski firmware standartıdır. **16-bit real mode**'da çalışır ve ciddi kısıtlamaları vardır.

```
BIOS Boot Akisi:

Power On → POST (Power-On Self-Test)
              │
              ├── RAM kontrolü
              ├── CPU kontrolü
              ├── Disk kontrolü
              └── Klavye/Ekran kontrolü
              │
              ▼
         Boot device sec (BIOS ayarlarindaki sıra)
              │
              ▼
         MBR'nin ilk 446 byte'ini oku (bootloader Stage 1)
              │
              ▼
         Bootloader'a kontrolü devret
```

### UEFI (Unified Extensible Firmware Interface)

**UEFI**, BIOS'un modern halefidir. **32/64-bit protected mode**'da çalışır, GUI destekler ve Secure Boot sağlar.

```
UEFI Boot Akisi:

Power On → SEC (Security Phase)
              │
              ▼
         PEI (Pre-EFI Initialization) → RAM init
              │
              ▼
         DXE (Driver Execution Environment) → device driver'lar
              │
              ▼
         BDS (Boot Device Selection) → ESP partition'dan .efi dosyasini bul
              │
              ▼
         EFI uygulamasini çalıştır (GRUB2'nin .efi dosyasi)
              │
              ▼
         Bootloader'a kontrolü devret
```

### MBR vs GPT Karşılaştırma

| Özellik | MBR (Master Boot Record) | GPT (GUID Partition Table) |
|---------|--------------------------|---------------------------|
| **Firmware** | BIOS | UEFI (BIOS uyumluluk var) |
| **Maks disk boyutu** | 2 TB | 9.4 ZB (zettabyte) |
| **Maks partition sayısı** | 4 primary (veya 3 primary + 1 extended) | 128 partition |
| **Partition tablo yedeği** | Yok | Diskin sonunda yedek kopya |
| **Bootloader konumu** | MBR (512 byte, 446 kullanılabilir) | ESP (EFI System Partition) - FAT32 |
| **Veri bütünlüğü** | Koruma yok | CRC32 checksum |
| **Secure Boot** | Desteklenmiyor | Destekleniyor |

### MBR Yapısı (512 byte)

```
Offset    Boyut     İçerik
──────────────────────────────────────
0x000     446 byte  Bootstrap Code (Stage 1 bootloader)
0x1BE     16 byte   Partition Entry 1
0x1CE     16 byte   Partition Entry 2
0x1DE     16 byte   Partition Entry 3
0x1EE     16 byte   Partition Entry 4
0x1FE     2 byte    Boot Signature (0x55AA)
──────────────────────────────────────
Toplam:   512 byte
```

```bash
# MBR'yi okuma (ilk 512 byte)
sudo dd if=/dev/sda bs=512 count=1 | hexdump -C

# MBR'yi yedekleme
sudo dd if=/dev/sda of=mbr_backup.bin bs=512 count=1

# GPT partition tablosunu görüntüleme
sudo gdisk -l /dev/sda
sudo parted /dev/sda print
```

### Secure Boot

**Secure Boot**, UEFI'nin bir özelliğidir. Boot sürecinde yüklenen her yazılımın **dijital olarak imzalanmış** olmasını zorunlu kılar.

```
Secure Boot Zinciri:

Platform Key (PK) - OEM tarafından yüklenir
       │
       ▼
Key Exchange Key (KEK) - imza doğrulama
       │
       ▼
Signature Database (db) - izin verilen imzalar
       │
       ▼
Forbidden Signature Database (dbx) - yasakli imzalar

Boot sirasinda:
UEFI → .efi dosyasinin imzasini kontrol et
     → db'de var mi? → EVET → yükle
                     → HAYIR → reddet (boot başarısız)
```

```bash
# Secure Boot durumunu kontrol etme
mokutil --sb-state

# Kayitli anahtarlari listeleme
mokutil --list-enrolled

# UEFI degiskenlerini görüntüleme (efivarfs mount edilmiş olmali)
ls /sys/firmware/efi/efivars/
```

> [!warning] Dikkat
> Secure Boot aktifken imzasız kernel modülleri yüklenemez. Bu, NVIDIA veya VirtualBox gibi üçüncü parti driver'larda sorun oluşturabilir. `mokutil` ile kendi anahtarınızı kaydedebilirsiniz.

---

## GRUB2 (GRand Unified Bootloader)

GRUB2, Linux sistemlerde en yaygın kullanılan bootloader'dir. Görevi: **kernel ve initramfs'i belleğe yükleyip kernel'a kontrolü devretmek**.

### GRUB2 Stage'leri

```
BIOS/MBR Sistemlerde:

Stage 1 (boot.img)          → MBR'nin 446 byte'inda
  │                            Gorevi: Stage 1.5'i yuklemek
  ▼
Stage 1.5 (core.img)        → MBR ile ilk partition arasındaki bosluk
  │                            (~30 KB, filesystem driver iceriyor)
  ▼
Stage 2 (/boot/grub/)       → /boot/grub/grub.cfg
                               Menu göster, kernel yükle

UEFI Sistemlerde:

EFI Application              → ESP:/EFI/ubuntu/grubx64.efi
  │                             (imzalı .efi dosyasi)
  ▼
Stage 2 (/boot/grub/)        → /boot/grub/grub.cfg
                                Menu göster, kernel yükle
```

### grub.cfg Yapısı

```bash
# grub.cfg dosyasinin konumu
/boot/grub/grub.cfg       # Debian/Ubuntu
/boot/grub2/grub.cfg      # RHEL/CentOS

# ASLA elle duzenlemeyin! Asagidaki komutla olusturun:
sudo grub-mkconfig -o /boot/grub/grub.cfg

# gerçek yapılandırma dosyaları:
/etc/default/grub              # ana yapılandırma
/etc/grub.d/                   # script'ler
  ├── 00_header                # genel ayarlar
  ├── 10_linux                 # Linux kernel girisleri
  ├── 20_linux_xen             # Xen kernel girisleri
  ├── 30_os-prober             # diger işletim sistemleri
  ├── 40_custom                # kullanıcı tanımlı girisler
  └── 41_custom                # ek kullanıcı girisleri
```

### /etc/default/grub Örneği

```bash
# Varsayilan menu girişi (0-indexed)
GRUB_DEFAULT=0

# Menu bekleme süresi (saniye)
GRUB_TIMEOUT=5

# Kernel command line parametreleri
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""

# Konsol cozunurlugu
GRUB_GFXMODE=1024x768
```

### Kernel Command Line Parametreleri

Boot sırasında kernel'a geçirilen parametreler **çok kritiktir**. Sorun gidermede en çok kullanılan aracınız bu olacaktır.

| Parametre | Açıklama | Örnek |
|-----------|----------|-------|
| `root=` | Root filesystem'in konumu | `root=/dev/sda2`, `root=UUID=xxxx` |
| `ro` / `rw` | Root'u read-only / read-write mount et | `ro` (genelde ilk boot'ta ro) |
| `init=` | İlk çalıştırılacak process | `init=/bin/bash` (kurtarma) |
| `quiet` | Kernel mesajlarını gizle | boot ekranı temiz kalır |
| `splash` | Grafik splash screen göster | Plymouth ile |
| `single` / `1` | Single-user mode | Kurtarma için |
| `systemd.unit=` | Hedef systemd target'i | `systemd.unit=rescue.target` |
| `nomodeset` | Kernel mode setting'i devre dışı bırak | GPU sorunlarında |
| `acpi=off` | ACPI devre dışı bırak | Donanım uyumsuzluğunda |
| `mem=` | Kullanılabilir RAM sınırla | `mem=4G` (test için) |
| `panic=` | Kernel panic sonrasi bekleme | `panic=10` (10sn sonra reboot) |
| `rd.break` | initramfs içinde shell aç | Root şifre sıfırlama |

```bash
# Calistirilan kernel'in command line'ini görüntüleme
cat /proc/cmdline

# Örnek çıktı:
# BOOT_IMAGE=/vmlinuz-5.15.0-91-generic root=UUID=a1b2c3d4 ro quiet splash
```

> [!tip] GRUB Menüsünde Geçici Düzenleme
> Boot sırasında GRUB menüsünde `e` tuşuna basarak kernel satırını geçici olarak düzenleyebilirsiniz. Değişiklikler kalıcı değildir, sadece o boot için geçerlidir. `Ctrl+X` ile boot edin.

### GRUB2 Kurulum ve Bakım

```bash
# GRUB'u MBR'ye kurma (BIOS)
sudo grub-install /dev/sda

# GRUB'u EFI'ye kurma (UEFI)
sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu

# grub.cfg yeniden oluşturma
sudo grub-mkconfig -o /boot/grub/grub.cfg
# veya Debian/Ubuntu'da:
sudo update-grub

# GRUB rescue (GRUB bozulduysa)
# GRUB rescue prompt'unda:
grub rescue> ls                          # partition'lari listele
grub rescue> ls (hd0,msdos1)/           # içerik kontrol
grub rescue> set root=(hd0,msdos1)      # root partition
grub rescue> set prefix=(hd0,msdos1)/boot/grub
grub rescue> insmod normal
grub rescue> normal                      # normal GRUB'a gec
```

---

## Kernel Boot Süreci

Bootloader, sıkıştırılmış kernel imajını (`vmlinuz`) ve `initramfs`'i RAM'e yükledikten sonra kernel'a kontrolü devreder.

### Kernel Dosyaları

```
/boot/ dizini içeriği:

/boot/
├── vmlinuz-5.15.0-91-generic      # sıkıştırılmış kernel imaji
├── initrd.img-5.15.0-91-generic   # initramfs arsivi
├── System.map-5.15.0-91-generic   # kernel sembol tablosu
├── config-5.15.0-91-generic       # kernel derleme yapısı
├── grub/
│   └── grub.cfg                   # GRUB yapılandırması
└── efi/                           # UEFI dosyaları (UEFI sistemde)
    └── EFI/
        └── ubuntu/
            └── grubx64.efi
```

### Kernel Boot Adımları

```
Bootloader kernel'i RAM'e yukledi
           │
           ▼
    ┌──────────────────────────────────┐
    │  1. DECOMPRESS                   │
    │  vmlinuz → vmlinux               │
    │  (gzip/bzip2/lzma/xz/lz4/zstd)   │
    └──────────────┬───────────────────┘
                   │
                   ▼
    ┌──────────────────────────────────────────────────┐
    │  2. start_kernel()                               │
    │  arch/x86/kernel/head_64.S                       │
    │  → init/main.c: start_kernel()                   │
    │                                                  │
    │  Sirasiyla:                                      │
    │  ├── setup_arch()        (CPU, memory tespiti)   │
    │  ├── mm_init()           (memory manager)        │ 
    │  ├── sched_init()        (scheduler)             │
    │  ├── init_IRQ()          (interrupt handler)     │
    │  ├── time_init()         (zamanlama)             │
    │  ├── console_init()      (konsol)                │
    │  └── rest_init()         (PID 1 olustur)         │
    └──────────────┬───────────────────────────────────┘
                   │
                   ▼
    ┌────────────────────────────────────┐
    │  3. EARLY INIT                     │
    │  ├── CPU online et                 │
    │  ├── Memory zone'lari kur          │
    │  ├── VFS (Virtual Filesystem) init │
    │  └── procfs, sysfs mount           │
    └──────────────┬─────────────────────┘
                   │
                   ▼
    ┌──────────────────────────────────┐
    │  4. DRIVER INIT                  │
    │  ├── PCI bus tarama              │
    │  ├── Disk controller driver      │
    │  ├── Network driver              │
    │  ├── USB subsystem               │
    │  └── Diger donanım driver'lari   │
    └──────────────┬───────────────────┘
                   │
                   ▼
    ┌──────────────────────────────────┐
    │  5. INITRAMFS CALISTIR           │
    │  /init script'ini çalıştır       │
    │  (veya /sbin/init)               │
    └──────────────────────────────────┘
```

### rest_init() ve PID 1

```
rest_init()
     │
     ├── kernel_thread(kernel_init)  → PID 1 (user-space init olacak)
     │        │
     │        ├── initramfs varsa → /init çalıştır
     │        └── yoksa → /sbin/init, /etc/init, /bin/init, /bin/sh dene
     │
     ├── kernel_thread(kthreadd)     → PID 2 (kernel thread yöneticisi)
     │
     └── cpu_idle()                  → idle loop (PID 0, swapper)
```

```bash
# Kernel versiyonunu görüntüleme
uname -r

# Kernel derleme yapılandırmasını görüntüleme
cat /boot/config-$(uname -r) | grep CONFIG_DEFAULT_INIT

# Kernel boot mesajlarini görüntüleme
dmesg | head -50

# Kernel command line
cat /proc/cmdline
```

---

## initramfs / initrd

### Neden Gerekli?

Kernel boot ederken root filesystem'i mount etmesi gerekir. Ancak root filesystem bir **LVM** üzerinde, **RAID** dizisinde, **şifrelenmiş** bir partition'da veya **NFS** üzerinde olabilir. Bu durumlarda kernel'in ilgili driver'ları **önceden yüklemesi** gerekir, ama driver'lar henüz mount edilmemiş bir filesystem'de bulunuyor. Bu **tavuk-yumurta problemidir**.

```
Tavuk-Yumurta Problemi:

Kernel root filesystem'i mount etmek istiyor
  → ama ext4 driver'i gerekli
    → driver root filesystem'de (/lib/modules/...)
      → ama root filesystem henuz mount edilmedi!

Cozum: initramfs

Bootloader, kernel ile birlikte initramfs'i de RAM'e yükler
  → initramfs geçici bir root filesystem olarak mount edilir
    → gerekli driver'lar initramfs içinden yüklenir
      → gerçek root filesystem mount edilir
        → switch_root ile gerçek root'a gecilir
```

### initrd vs initramfs

| Özellik | initrd (eski) | initramfs (modern) |
|---------|---------------|-------------------|
| **Format** | Block device imajı (ext2) | cpio arşivi (gzip ile sıkıştırılmış) |
| **Mount** | Sanal block device olarak | tmpfs/ramfs'e doğrudan açılır |
| **Boyut** | Sabit boyut | Dinamik, ihtiyaç kadar yer kaplar |
| **Root geçişi** | pivot_root | switch_root |
| **Kernel desteği** | CONFIG_BLK_DEV_INITRD | CONFIG_BLK_DEV_INITRD + CONFIG_TMPFS |

### initramfs Akışı

```
Kernel initramfs'i RAM'e acar (tmpfs olarak)
           │
           ▼
    /init script'i çalıştırılır
           │
           ├── udev başlatılır (device node'lar oluşur)
           │
           ├── Gerekli kernel modulleri yüklenir
           │     ├── disk controller (ahci, nvme, virtio_blk)
           │     ├── filesystem (ext4, xfs, btrfs)
           │     ├── LVM (dm-mod)
           │     ├── RAID (md-mod)
           │     └── encryption (dm-crypt)
           │
           ├── Root device tespit edilir (UUID, LABEL, /dev/...)
           │
           ├── Root filesystem mount edilir (/sysroot veya /root)
           │
           ├── switch_root /sysroot /sbin/init
           │     (initramfs temizlenir, gerçek root'a gecilir)
           │
           └── /sbin/init (systemd) PID 1 olarak başlar
```

### initramfs Yönetimi

```bash
# ---- INITRAMFS OLUSTURMA ----

# Debian/Ubuntu: mkinitramfs (initramfs-tools)
sudo mkinitramfs -o /boot/initrd.img-$(uname -r) $(uname -r)

# Debian/Ubuntu: update-initramfs (daha kolay)
sudo update-initramfs -u              # mevcut kernel için güncelle
sudo update-initramfs -u -k all       # tüm kernel'lar için güncelle
sudo update-initramfs -c -k 5.15.0-91-generic  # yeni olustur

# RHEL/CentOS/Fedora: dracut
sudo dracut --force /boot/initramfs-$(uname -r).img $(uname -r)
sudo dracut --force --add "lvm crypt" /boot/initramfs-$(uname -r).img $(uname -r)
sudo dracut --regenerate-all          # tüm kernel'lar için

# ---- INITRAMFS INCELEME ----

# Icerigini listeleme
lsinitramfs /boot/initrd.img-$(uname -r)

# veya detayli:
lsinitramfs -l /boot/initrd.img-$(uname -r)

# dracut ile inceleme
lsinitrd /boot/initramfs-$(uname -r).img

# Manuel olarak acma
mkdir /tmp/initramfs && cd /tmp/initramfs
zcat /boot/initrd.img-$(uname -r) | cpio -idmv
# veya (microcode + initramfs bilesik ise):
unmkinitramfs /boot/initrd.img-$(uname -r) /tmp/initramfs

# ---- ICERIK ORNEGI ----
# Acilan initramfs içeriği:
# /init                  → ana başlatma script'i
# /bin/                  → busybox, sh, mount, ...
# /lib/modules/          → kernel modulleri
# /etc/                  → yapılandırma dosyaları
# /scripts/              → hook script'leri
```

> [!tip] initramfs içine ek modül ekleme
> `/etc/initramfs-tools/modules` dosyasına modül adı ekleyip `update-initramfs -u` çalıştırarak özel modülleri initramfs'e dahil edebilirsiniz. Örneğin özel bir RAID controller driver'ı.

---

## Kernel Modül Yönetimi

Linux kernel **monolitik** bir kernel'dir ancak **modül desteği** sayesinde tüm driver'ların derleme zamanında kernel'a gömülmesi gerekmez. Modüller çalışma zamanında yüklenip kaldırılabilir.

### Modül Dosyaları

```
Kernel modulleri:

/lib/modules/$(uname -r)/
├── kernel/                        # kaynak agacina gore duzenlenmis modüller
│   ├── drivers/
│   │   ├── net/                   # ağ driver'lari (e1000, rtl8xxxu)
│   │   ├── gpu/                   # GPU driver'lari
│   │   ├── usb/                   # USB driver'lari
│   │   ├── scsi/                  # SCSI/SATA driver'lari
│   │   └── ...
│   ├── fs/                        # filesystem modulleri (ext4, xfs, nfs)
│   ├── net/                       # ağ protokolleri (bridge, vxlan)
│   ├── crypto/                    # kriptografik modüller
│   └── sound/                     # ses driver'lari
├── modules.dep                    # modül bağımlılıkları
├── modules.dep.bin                # binary format
├── modules.alias                  # donanım → modül eslemesi
├── modules.symbols                # sembol → modül eslemesi
└── modules.builtin                # kernel'a gomulu modüller
```

### Modül Komutları

```bash
# ---- MODUL LISTELEME VE BILGI ----

# Yuklenmis modulleri listele
lsmod
# Cikti: Module    Size  Used by
#        ext4     811008  1
#        mbcache   16384  1 ext4

# Modul hakkinda detayli bilgi
modinfo ext4
# filename:    /lib/modules/.../kernel/fs/ext4/ext4.ko
# license:     GPL
# description: Fourth Extended Filesystem
# depends:     mbcache,jbd2
# ...

# Modul parametrelerini görüntüleme
modinfo -p e1000e
# IntMode:Interrupt Mode (parm)
# ...

# ---- MODUL YUKLEME ----

# insmod: tek modül yükle (bağımlılıkları COZEMEZ)
sudo insmod /lib/modules/$(uname -r)/kernel/fs/ext4/ext4.ko

# modprobe: modül yükle (bağımlılıkları OTOMATIK çözer)
sudo modprobe ext4
sudo modprobe vfat              # FAT filesystem desteği
sudo modprobe bridge            # network bridge

# Parametreyle yükleme
sudo modprobe e1000e IntMode=2

# ---- MODUL KALDIRMA ----

# rmmod: modülü kaldir
sudo rmmod ext4

# modprobe -r: modülü ve kullanilmayan bagimliklarini kaldir
sudo modprobe -r ext4

# ---- BAGIMLILIKLARI GUNCELLEME ----

# depmod: modules.dep dosyasini yeniden olustur
sudo depmod -a
# Yeni bir modül eklediyseniz veya modules.dep bozulduysa gerekli
```

### Modül Yapılandırma

```bash
# ---- BOOT'TA OTOMATIK YUKLEME ----

# Yontem 1: /etc/modules (Debian/Ubuntu)
cat /etc/modules
# loop
# bridge
# vhost_net

# Yontem 2: /etc/modules-load.d/ (systemd)
cat /etc/modules-load.d/bridge.conf
# bridge
# br_netfilter

# ---- MODUL BLACKLISTING (yuklenmesini engelleme) ----

# /etc/modprobe.d/ altında .conf dosyasi olusturun
cat /etc/modprobe.d/blacklist-nouveau.conf
# Nouveau (açık kaynak NVIDIA) driver'ini engelle
# NVIDIA proprietary driver kullanmak için:
blacklist nouveau
options nouveau modeset=0

# Blacklist sonrasi initramfs'i guncelleyin
sudo update-initramfs -u

# ---- MODUL PARAMETRELERI ----

# Calisma zamaninda parametre ayarlama
cat /etc/modprobe.d/custom.conf
# options snd_hda_intel power_save=1
# options iwlwifi 11n_disable=1

# Calisma zamaninda parametre görüntüleme
cat /sys/module/ext4/parameters/commit_interval
```

> [!warning] insmod vs modprobe
> `insmod` sadece belirtilen modülü yükler, bağımlılık çözümlemesi yapmaz. Üretim ortamında **her zaman** `modprobe` kullanın. `insmod` yalnızca geliştirme/debug amaçlı kullanılmalıdır.

---

## /proc ve /sys Oluşumu

Kernel boot sürecinde iki önemli sanal filesystem oluşturur: **procfs** ve **sysfs**. Bu filesystem'ler **diskte yer kaplamaz**, tamamen kernel tarafından RAM'de oluşturulur.

### procfs (/proc)

**procfs**, kernel ve process bilgilerini user-space'e sunan sanal filesystem'dir. Kernel boot sırasında `proc_root_init()` ile oluşturulur.

```
/proc/
├── [PID]/                    # her process için bir dizin
│   ├── cmdline               # process'in komut satiri
│   ├── environ               # ortam değişkenleri
│   ├── status                # durum bilgisi (UID, GID, memory)
│   ├── fd/                   # açık file descriptor'lar
│   ├── maps                  # memory mapping'leri
│   ├── cgroup                # cgroup uyeligi
│   ├── ns/                   # namespace referanslari
│   └── ...
├── cpuinfo                   # CPU bilgisi
├── meminfo                   # bellek bilgisi
├── version                   # kernel versiyonu
├── cmdline                   # kernel command line
├── filesystems               # desteklenen filesystem'ler
├── mounts                    # mount edilmiş filesystem'ler
├── partitions                # disk partition'lari
├── interrupts                # interrupt sayaclari
├── sys/                      # kernel tunables (sysctl)
│   ├── kernel/
│   │   ├── hostname
│   │   ├── pid_max
│   │   └── panic
│   ├── net/
│   │   └── ipv4/
│   │       └── ip_forward
│   ├── vm/
│   │   ├── swappiness
│   │   └── overcommit_memory
│   └── fs/
│       └── file-max
└── ...
```

```bash
# procfs mount (genelde otomatik)
mount -t proc proc /proc

# Örnek kullanım
cat /proc/cpuinfo           # CPU bilgisi
cat /proc/meminfo           # bellek durumu
cat /proc/1/cmdline         # PID 1'in komut satiri
cat /proc/sys/vm/swappiness # swap agresifligi

# sysctl ile /proc/sys altini okuma/yazma
sysctl vm.swappiness                    # oku
sudo sysctl -w vm.swappiness=10         # yaz (geçici)
# Kalici: /etc/sysctl.conf veya /etc/sysctl.d/
```

### sysfs (/sys)

**sysfs**, donanım ve driver bilgilerini düzenli bir ağaç yapısında sunan sanal filesystem'dir. Kernel'daki `kobject` hiyerarşisini yansıtır.

```
/sys/
├── block/                    # block device'lar
│   ├── sda/
│   │   ├── size
│   │   ├── queue/
│   │   └── sda1/, sda2/
│   └── nvme0n1/
├── bus/                      # bus tipleri
│   ├── pci/
│   │   └── devices/          # PCI cihazlari
│   ├── usb/
│   └── ...
├── class/                    # cihaz siniflari
│   ├── net/                  # ağ arayuzleri
│   │   ├── eth0/
│   │   └── wlan0/
│   ├── block/
│   └── tty/
├── devices/                  # fiziksel cihaz ağacı
│   ├── system/
│   │   ├── cpu/
│   │   │   ├── cpu0/
│   │   │   └── cpu1/
│   │   └── memory/
│   └── pci0000:00/
├── firmware/                 # firmware bilgileri
│   ├── efi/
│   └── acpi/
├── fs/                       # filesystem bilgileri
│   ├── cgroup/               # cgroup hiyerarsisi
│   └── ext4/
├── kernel/                   # kernel parametreleri
│   └── mm/                   # memory management
└── module/                   # yüklenmiş kernel modulleri
    ├── ext4/
    │   └── parameters/
    └── e1000e/
        └── parameters/
```

```bash
# sysfs mount (genelde otomatik)
mount -t sysfs sysfs /sys

# Örnek kullanım
cat /sys/class/net/eth0/address          # MAC adresi
cat /sys/block/sda/size                  # disk boyutu (512-byte blok)
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq  # CPU frekansi
ls /sys/bus/pci/devices/                 # PCI cihazlari

# sysfs üzerinden donanım kontrolü
echo 1 > /sys/class/leds/input0::scrolllock/brightness  # LED yak
cat /sys/class/power_supply/BAT0/capacity                # batarya yuzdesi
```

> [!info] /proc vs /sys
> `/proc` daha çok **process ve kernel bilgisi** için kullanılır (eski, biraz karışık). `/sys` ise **donanım ve driver bilgisi** için daha yapılandırılmış bir arayüz sunar (Linux 2.6 ile geldi). Yeni kernel ayarları genellikle `/sys` altına eklenir.

---

## systemd - PID 1

Kernel, initramfs'ten gerçek root filesystem'e geçiş yaptıktan sonra `/sbin/init`'i çalıştırır. Modern Linux sistemlerde bu `/sbin/init` aslında **systemd**'ye bir sembolik link'tir.

### systemd'nin PID 1 Olarak Görevleri

```
systemd (PID 1)
     │
     ├── Tum diger process'lerin atasi (parent)
     ├── Servisleri başlatma/durdurma/izleme
     ├── Socket activation
     ├── Mount point yönetimi
     ├── Device yönetimi (udev)
     ├── Log yönetimi (journald)
     ├── Cron benzeri zamanlama (timer)
     ├── Ağ yapılandırması (networkd)
     ├── DNS cozumlemesi (resolved)
     ├── Login yönetimi (logind)
     └── Yetim (orphan) process'leri toplama (reaping)
```

### systemd Target'ları

Target'lar, SysV init'teki **runlevel** kavramının karşılık gelir. Bir target, bir grup servisin bir arada başlatılmasını ifade eder.

```
Target Hiyerarsisi:

poweroff.target (runlevel 0) ← sistemi kapat
      │
rescue.target (runlevel 1) ← tek kullanıcı, minimal servisler
      │
multi-user.target (runlevel 3) ← çok kullanıcı, agla, GUI'siz
      │
graphical.target (runlevel 5) ← multi-user + GUI (display manager)
      │
reboot.target (runlevel 6) ← yeniden başlat

emergency.target ← en minimal mod (sadece root shell, / read-only)
```

| Target | Eski Runlevel | Açıklama |
|--------|--------------|----------|
| `poweroff.target` | 0 | Sistemi kapat |
| `rescue.target` | 1 | Tek kullanıcı modu, temel servisler |
| `multi-user.target` | 3 | Çok kullanıcı, ağ aktif, GUI yok |
| `graphical.target` | 5 | Tam grafik masaüstü |
| `reboot.target` | 6 | Yeniden başlat |
| `emergency.target` | - | En minimal, root shell, / read-only |

```bash
# Varsayilan target'i görüntüleme
systemctl get-default
# graphical.target

# Varsayilan target'i değiştirme
sudo systemctl set-default multi-user.target

# Anlik target degisimi (reboot gerektirmez)
sudo systemctl isolate rescue.target
sudo systemctl isolate multi-user.target

# Target'a bağlı servisleri listeleme
systemctl list-dependencies multi-user.target

# Tum target'lari listeleme
systemctl list-units --type=target
```

### systemd Boot Akışı

```
systemd PID 1 olarak başlar
           │
           ▼
    default.target'i oku (genelde graphical.target)
           │
           ▼
    Bagimliliklari coz (Wants=, Requires=, After=, Before=)
           │
           ▼
    ┌──────────────────────────────────────────────────────┐
    │  Paralel olarak başlat:                              │
    │                                                      │
    │  local-fs.target      → disk mount                   │
    │  swap.target          → swap aktif                   │
    │  sysinit.target       → sistem ilk ayarlari          │
    │  basic.target         → temel servisler              │
    │       │                                              │
    │       ├── network.target    → ağ servisleri          │
    │       ├── sshd.service      → SSH server             │
    │       ├── cron.service      → zamanlanmis gorevler   │
    │       ├── docker.service    → Docker daemon          │
    │       └── ...                                        │
    │       │                                              │
    │       ▼                                              │
    │  multi-user.target                                   │
    │       │                                              │
    │       ├── display-manager.service (gdm, lightdm)     │
    │       │                                              │
    │       ▼                                              │
    │  graphical.target                                    │
    └──────────────────────────────────────────────────────┘
           │
           ▼
    Login ekrani (tty veya display manager)
```

---

## systemd-analyze - Boot Süresi Analizi

`systemd-analyze`, boot performansını ölçmek ve yavaş servisleri tespit etmek için çok güçlü bir araçtır.

```bash
# ---- GENEL BOOT SURESI ----
systemd-analyze
# Startup finished in 3.456s (firmware) + 2.123s (loader) + 1.789s (kernel)
#                     + 5.432s (initrd) + 12.345s (userspace) = 25.145s
# graphical.target reached after 12.000s in userspace

# Açıklama:
# firmware  → BIOS/UEFI süresi
# loader    → GRUB süresi
# kernel    → kernel boot süresi
# initrd    → initramfs süresi
# userspace → systemd servislerin baslatilma süresi
```

```bash
# ---- EN YAVAS SERVISLER (BLAME) ----
systemd-analyze blame
#  8.123s NetworkManager-wait-online.service
#  3.456s docker.service
#  2.789s snapd.service
#  1.234s systemd-journal-flush.service
#  0.987s dev-sda2.device
#  ...

# Bu liste en yavaş servisten en hizliya doğru siralanir.
# Gereksiz servisleri devre dışı bırakarak boot suresini azaltabilirsiniz:
sudo systemctl disable NetworkManager-wait-online.service
sudo systemctl disable snapd.service
```

```bash
# ---- KRITIK ZINCIR (CRITICAL-CHAIN) ----
systemd-analyze critical-chain
# graphical.target @12.000s
# └─ display-manager.service @11.500s +0.500s
#    └─ multi-user.target @11.400s
#       └─ docker.service @7.944s +3.456s
#          └─ network-online.target @7.900s
#             └─ NetworkManager-wait-online.service @2.100s +5.800s
#                └─ NetworkManager.service @1.800s +0.300s
#                   └─ basic.target @1.700s
#                      └─ sockets.target @1.699s

# '@' = servisin başladığı zaman
# '+' = servisin baslamasi için geçen süre
# Bu çıktı, hangi servisin darbogaz olduğunu gösterir.
```

```bash
# ---- SVG GRAFIK OLUSTURMA (PLOT) ----
systemd-analyze plot > boot-timeline.svg
# Tarayicida acilabilen bir SVG dosyasi üretir.
# Her servisin ne zaman başladığı ve ne kadar surdugu görünür.

# ---- BELIRLI SERVISIN KRITIK ZINCIRI ----
systemd-analyze critical-chain docker.service

# ---- SERVIS BAGIMLILIKLARI ----
systemd-analyze dot docker.service | dot -Tsvg > docker-deps.svg
# graphviz ile bağımlılıkları gorsellestir

# ---- BOOT LOG DOGRULAMA ----
systemd-analyze verify default.target
# Unit dosyalarinda hata varsa raporlar
```

> [!tip] Boot Optimizasyonu Adımları
> 1. `systemd-analyze blame` ile en yavaş servisleri tespit edin
> 2. `systemd-analyze critical-chain` ile darboğazları bulun
> 3. Gereksiz servisleri `systemctl disable` ile devre dışı bırakın
> 4. `systemd-analyze plot` ile görsel kontrol yapın

---

## Boot Sorun Giderme

### Rescue Mode

**Rescue mode**, temel servislerin başlatıldığı minimal bir ortamdır. Root filesystem **read-write** mount edilir. Ağ genelde aktif değildir.

```bash
# Rescue mode'a girmenin yollari:

# Yontem 1: GRUB menusunden
# Boot sirasinda GRUB'da 'e' tusuna bas
# linux satirin sonuna ekle:
systemd.unit=rescue.target
# Ctrl+X ile boot et

# Yontem 2: Calisirken
sudo systemctl isolate rescue.target

# Yontem 3: Kernel parametresi
# GRUB'da linux satirina ekle:
single
# veya:
1
```

### Emergency Mode

**Emergency mode**, rescue'dan bile daha minimaldir. Root filesystem **read-only** mount edilir. Sadece **root shell** alınır, hiçbir servis başlamaz.

```bash
# Emergency mode'a girmenin yollari:

# Yontem 1: GRUB'dan
# linux satirin sonuna ekle:
systemd.unit=emergency.target

# Yontem 2: Calisirken
sudo systemctl isolate emergency.target

# Emergency mode'da root'u read-write yapmak için:
mount -o remount,rw /
```

### init=/bin/bash (En Düşük Seviye Kurtarma)

systemd bile başlatılmaz, doğrudan **bash** shell alınır. Root şifre sıfırlamak için çok kullanılır.

```bash
# GRUB'da linux satirin sonuna ekle:
init=/bin/bash

# Boot sonrasi:
# - Hicbir servis calismaz
# - Root filesystem read-only
# - ağ yok, logging yok

# Root şifre sifirlama örneği:
mount -o remount,rw /      # read-write yap
passwd root                 # yeni şifre belirle
mount -o remount,ro /       # tekrar read-only yap
exec /sbin/reboot           # veya: echo b > /proc/sysrq-trigger
```

### Rescue vs Emergency vs init=/bin/bash

| Özellik | Rescue | Emergency | init=/bin/bash |
|---------|--------|-----------|----------------|
| **Init sistemi** | systemd (sınırlı) | systemd (minimal) | Yok |
| **Root FS** | read-write | read-only | read-only |
| **Servisler** | Temel servisler | Hiçbiri | Hiçbiri |
| **Ağ** | Genelde yok | Yok | Yok |
| **Journald** | Aktif | Aktif | Yok |
| **Kullanım** | Servis sorunları | FS sorunları | Şifre sıfırlama |

### fsck ile Filesystem Onarımı

```bash
# Filesystem kontrolü (MOUNT EDILMEMIS partition üzerinde!)
sudo fsck /dev/sda2

# Otomatik onarim
sudo fsck -y /dev/sda2

# ext4 için özel araç
sudo e2fsck -f /dev/sda2

# XFS için
sudo xfs_repair /dev/sda1

# Boot sirasinda otomatik fsck zorlamak için:
# GRUB'da linux satirina ekle:
fsck.mode=force

# veya dosya olustur:
sudo touch /forcefsck    # sonraki boot'ta fsck çalışır (eski yöntem)
```

> [!warning] ASLA mount edilmiş filesystem'de fsck çalıştırmayın!
> Mount edilmiş bir filesystem üzerinde fsck çalıştırmak **veri kaybına** yol açabilir. Öncelikle `umount` ile çıkartın veya rescue/emergency modda read-only olarak çalışın.

### rd.break ile initramfs İçinde Durma

```bash
# GRUB'da linux satirina ekle:
rd.break

# initramfs içinde shell alinir (switch_root oncesi)
# Gercek root filesystem /sysroot altında mount edilmistir

# Root şifre sifirlama (RHEL/CentOS):
mount -o remount,rw /sysroot
chroot /sysroot
passwd root
touch /.autorelabel          # SELinux için gerekli
exit
exit                         # boot devam eder
```

---

## Kernel Panic ve OOM

### Kernel Panic

**Kernel panic**, kernel'in kurtarılamaz bir hatayla karşılaştığında tüm sistemi durdurmasını ifade eder. User-space'teki **segfault**'un kernel versiyonudur.

```
Yaygin Kernel Panic Sebepleri:

1. Root filesystem mount edilemiyor
   → "VFS: Unable to mount root fs on unknown-block"
   → Cozum: initramfs'te gerekli driver var mi? root= parametresi doğru mu?

2. init/systemd baslatilamiyor
   → "Kernel panic - not syncing: Attempted to kill init!"
   → Cozum: init=/bin/bash ile boot edip /sbin/init kontrolü

3. Bozuk kernel modülü
   → "BUG: unable to handle kernel NULL pointer dereference"
   → Cozum: sorunlu modülü blacklist'e alin

4. Donanim arizasi (RAM, disk)
   → "Machine check exception"
   → Cozum: memtest86+ calistirin, disk SMART kontrolü
```

```bash
# Kernel panic sonrasi otomatik reboot
# /etc/sysctl.conf:
kernel.panic = 10           # 10 saniye sonra reboot
kernel.panic_on_oops = 1    # oops'ta da panic yap

# veya kernel parametresi:
panic=10

# Son kernel panic bilgisini görüntüleme
dmesg | grep -i panic
dmesg | grep -i "call trace" -A 20

# Onceki boot'un log'larini görüntüleme (journald persistent ise)
journalctl -b -1            # bir önceki boot
journalctl -b -1 -p err     # sadece hatalar
journalctl --list-boots     # tüm boot'lari listele
```

### OOM Killer (Out of Memory)

Sistem bellek tükendiğinde kernel, **OOM killer** mekanizmasını devreye sokarak en uygun process'i öldürüp bellek açar. Her process'e bir **oom_score** atanır.

```
OOM Killer Karar Sureci:

Bellek tukendi (RAM + Swap)
         │
         ▼
Kernel OOM Killer'i cagir
         │
         ▼
Her process için oom_score hesapla
  ├── Bellek tuketimi (yüksek = daha çok aday)
  ├── CPU süresi
  ├── oom_score_adj (-1000 ile +1000 arasi)
  │     -1000 = ASLA öldürme
  │         0 = normal
  │     +1000 = ilk bunu öldür
  └── Root process'ler biraz daha korunur
         │
         ▼
En yüksek oom_score'lu process'e SIGKILL gönder
         │
         ▼
Bellek acildi, sistem calismaya devam eder
```

```bash
# Process'lerin OOM score'larini görüntüleme
cat /proc/[PID]/oom_score
cat /proc/[PID]/oom_score_adj

# Kritik servisi OOM'dan koruma
echo -1000 > /proc/$(pidof sshd)/oom_score_adj

# systemd service dosyasinda:
# [Service]
# OOMScoreAdjust=-900

# OOM olaylarini inceleme
dmesg | grep -i "oom\|out of memory\|killed process"
journalctl -k | grep -i "oom"

# Örnek OOM log:
# [  123.456789] Out of memory: Killed process 1234 (java)
#                total-vm:4096000kB, anon-rss:3500000kB, file-rss:1000kB

# ---- BELLEK DURUMU IZLEME ----
free -h
cat /proc/meminfo
vmstat 1                    # 1 saniye aralikla bellek durumu

# ---- OOM DAVRANIŞI AYARLAMA ----
# overcommit_memory:
# 0 = heuristic (varsayilan)
# 1 = her zaman izin ver
# 2 = sinirla (swap + RAM * ratio)
sysctl vm.overcommit_memory
sudo sysctl -w vm.overcommit_memory=2
```

> [!warning] Kernel Panic vs OOM Farkı
> **Kernel Panic**: Kernel kendi hatası - sistem durur, hiçbir şey çalıştıramaz. **OOM Kill**: Bellek yetmezliği - kernel bir process öldürür ama sistem çalışmaya devam eder. OOM kill sonrası sistem hala kullanılabilir durumdadır.

---

## dmesg ile Analiz

`dmesg`, kernel ring buffer'ındaki mesajları okur. Boot sorunlarını teşhis etmek için en temel araçtır.

```bash
# Tum kernel mesajları
dmesg

# Zaman damgali (human-readable)
dmesg -T

# Belirli seviye (err ve daha kotu)
dmesg --level=err,crit,alert,emerg

# Renklendirmeli
dmesg --color=always | less -R

# Canli izleme
dmesg -w

# Boot ile ilgili kritik mesajları arama
dmesg | grep -i "error\|fail\|warn\|panic\|oom"

# Belirli bir alt sistemi arama
dmesg | grep -i "usb"
dmesg | grep -i "ext4"
dmesg | grep -i "scsi\|ata\|sata"

# Ring buffer'i temizleme
sudo dmesg -c
```

```
Örnek dmesg çıktısı (boot sırası):

[    0.000000] Linux version 5.15.0-91-generic (buildd@...) (gcc-11)
[    0.000000] Command line: BOOT_IMAGE=/vmlinuz-5.15.0-91 root=UUID=... ro quiet
[    0.000000] x86/fpu: Supporting XSAVE feature: x87 floating point
[    0.000023] BIOS-provided physical RAM map:
[    0.034567] Memory: 16285432K/16777216K available
[    0.123456] CPU: Physical Processor ID: 0
[    0.234567] pid_max: default: 32768 minimum: 301
[    0.345678] Mount-cache hash table entries: 65536
[    0.456789] ACPI: Core revision 20210930
[    0.567890] PCI: Using configuration type 1 for base access
[    0.678901] clocksource: tsc: mask: 0xffffffffffffffff
[    1.234567] EXT4-fs (sda2): mounted filesystem with ordered data mode
[    1.345678] systemd[1]: systemd 249 running in system mode
```

---

## Container'da Boot - Docker PID 1

Docker container'larda geleneksel boot süreci **çalışmaz**. Container, doğrudan belirtilen process'i **PID 1** olarak çalıştırır.

### Container vs VM Boot Karşılaştırması

```
Sanal Makine (VM):                Container (Docker):

BIOS/UEFI                         Yok
     │                                 │
Bootloader                        Yok
     │                                 │
Kernel boot                       Host kernel (paylasimli)
     │                                 │
initramfs                         Yok
     │                                 │
systemd (PID 1)                   CMD/ENTRYPOINT (PID 1)
     │                                 │
Servisler başlat                  Tek process (genelde)
     │                                 │
Login prompt                      Process çalışır
```

### Docker'da PID 1 Problemi

```dockerfile
# ---- SHELL FORM (sorunlu) ----
CMD node app.js
# Aslinda: /bin/sh -c "node app.js"
# PID 1 = /bin/sh (node değil!)
# docker stop → SIGTERM → sh'a gider → sh signal forward etmez!
# 10 saniye sonra SIGKILL (graceful shutdown yok)

# ---- EXEC FORM (doğru) ----
CMD ["node", "app.js"]
# PID 1 = node app.js (doğrudan)
# docker stop → SIGTERM → node'a gider → graceful shutdown
```

```
Shell Form PID Agaci:         Exec Form PID Agaci:

PID 1: /bin/sh -c "node.."   PID 1: node app.js
  └── PID 2: node app.js

SIGTERM → PID 1 (sh)          SIGTERM → PID 1 (node)
sh signal forward ETMEZ!       node SIGTERM'i yakalayabilir
```

### Neden systemd Container'da Sorunlu?

systemd, PID 1 olarak çalışmayı bekler ve birçok **kernel özelliğine** ihtiyaç duyar:

```
systemd Container'da Sorun Yaratan Ozellikleri:

1. cgroups v1/v2 erişimi gerektirir
   → Container içinde cgroup mount kısıtlı
   → --privileged veya --cgroupns=host gerekir

2. /sys/fs/cgroup yazma erişimi
   → Container'da default olarak read-only

3. D-Bus socket
   → Container içinde D-Bus yok

4. tmpfs mount'lari
   → /run, /tmp için tmpfs gerekir

5. Birden fazla servis yönetimi
   → Container felsefesi: tek process, tek sorumluluk

6. journald log yönetimi
   → Docker log driver ile catisir
```

```bash
# systemd'yi container'da calistirmanin "yolu" (onerilmez):
docker run -d \
  --name systemd-container \
  --privileged \
  --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run \
  --tmpfs /tmp \
  ubuntu:22.04 /sbin/init

# Neden onerilmez:
# - --privileged tüm güvenlik izolasyonunu kirar
# - Container'in amacı hafif ve tek görevli olmak
# - Multi-service için docker-compose veya Kubernetes kullanin
```

### Doğru Yaklaşım: Tini veya dumb-init

PID 1'in **signal forwarding** ve **zombie reaping** görevlerini yerine getirmesi için hafif init sistemleri kullanin.

```dockerfile
# ---- TINI (Docker'in resmi init'i) ----
# Docker 1.13+ ile dahili:
docker run --init myimage

# veya Dockerfile'da:
RUN apt-get update && apt-get install -y tini
ENTRYPOINT ["tini", "--"]
CMD ["node", "app.js"]

# ---- DUMB-INIT ----
RUN apt-get update && apt-get install -y dumb-init
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "app.js"]
```

```
Tini ile PID Agaci:

PID 1: tini -- node app.js     (signal handler + zombie reaper)
  └── PID 2: node app.js       (ana uygulama)

docker stop → SIGTERM → tini → SIGTERM → node → graceful shutdown
Zombie process → tini otomatik olarak wait() yapar → temizlenir
```

> [!tip] Container PID 1 Kuralları
> 1. **Exec form** kullanın (`CMD ["..."]`), shell form değil
> 2. Uygulamanız SIGTERM handle edemiyorsa `--init` veya `tini` kullanın
> 3. Container içinde systemd çalıştırmak yerine **her servisi ayrı container**'da çalıştırın
> 4. Birden fazla process gerekiyorsa **supervisord** veya **s6-overlay** değerlendirin

---

## Özet - Boot Aşamaları ve Araçlar

| Aşama | Süre | Analiz Aracı | Sorun Giderme |
|-------|------|-------------|---------------|
| **Firmware** | 1-5s | `systemd-analyze` (firmware) | BIOS/UEFI ayarları |
| **Bootloader** | 1-3s | `systemd-analyze` (loader) | GRUB rescue, grub-install |
| **Kernel** | 1-5s | `dmesg`, `systemd-analyze` (kernel) | Kernel parametreleri, nomodeset |
| **initramfs** | 1-10s | `systemd-analyze` (initrd), `lsinitramfs` | mkinitramfs, dracut, rd.break |
| **Userspace** | 5-30s | `systemd-analyze blame/critical-chain` | systemctl disable, rescue mode |

```bash
# Hizli boot analizi workflow'u:

# 1. Genel süre
systemd-analyze

# 2. En yavaş servisler
systemd-analyze blame | head -10

# 3. Darbogaz zinciri
systemd-analyze critical-chain

# 4. Kernel hatalari
dmesg --level=err,crit,alert,emerg

# 5. Onceki boot hatalari (systemd persistent journal gerekli)
journalctl -b -1 -p err

# 6. Gorsel rapor
systemd-analyze plot > /tmp/boot.svg
```
