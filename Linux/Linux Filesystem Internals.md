# Linux Filesystem Internals

Linux kernel, dosya sistemlerini **VFS (Virtual File System)** adlı bir soyutlama katmanı üzerinden yönetir. User-space uygulamaları `open()`, `read()`, `write()` gibi syscall'larla çalışırken, VFS bu çağrıları ilgili filesystem driver'ına yönlendirir. Bu not, VFS katmanından başlayarak inode, dentry, superblock yapılarını, ext4/xfs/btrfs karşılaştırmasını, journaling mekanizmasını ve pratik komutları derinlemesine ele alır.

> [!info] İlişkili Notlar
> - Docker'ın OverlayFS kullanımı --> [[Docker Temelleri#Union File System (OverlayFS)]]
> - Docker veri kalıcılığı --> [[Docker Storage ve Volumes]]
> - Process'lerin dosya descriptor kullanımı --> [[Linux Process Management]]
> - Virtual memory ve mmap --> [[Linux Virtual Memory]]

---

## VFS (Virtual File System) Katmanı

VFS, farklı dosya sistemlerini (ext4, xfs, btrfs, tmpfs, procfs, overlayfs) **tek bir arayüz** altında birleştiren kernel soyutlama katmanıdır. User-space uygulamaları hangi filesystem'in kullanıldığını bilmek zorunda kalmaz.

```
User Space
┌─────────────────────────────────────────────────┐
│  Application (cat, ls, vim, nginx, postgres)    │
│       open() / read() / write() / stat()        │
└──────────────────────┬──────────────────────────┘
                       │ syscall (int 0x80 / syscall)
═══════════════════════╪══════════════════════════════
Kernel Space           │
┌──────────────────────▼──────────────────────────┐
│                System Call Layer                │
│          sys_open, sys_read, sys_write          │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼───────────────────────────┐
│              VFS (Virtual File System)           │
│                                                  │
│  ┌───────────┐ ┌──────────┐ ┌──────────────────┐ │
│  │ superblock│ │  inode   │ │     dentry       │ │
│  │ operations│ │operations│ │   operations     │ │
│  └───────────┘ └──────────┘ └──────────────────┘ │
│  ┌──────────────────────────────────────────┐    │
│  │          file operations                 │    │
│  │   open, read, write, llseek, mmap, ioctl │    │
│  └──────────────────────────────────────────┘    │
└──────────────────────┬───────────────────────────┘
                       │
       ┌───────────────┼───────────────┐
       │               │               │
┌──────▼─────┐  ┌──────▼─────┐  ┌──────▼─────┐
│   ext4     │  │   xfs      │  │  btrfs     │
│   driver   │  │   driver   │  │  driver    │
└──────┬─────┘  └──────┬─────┘  └──────┬─────┘
       │               │               │
┌──────▼───────────────▼───────────────▼─────┐
│            Block Layer (bio)               │
│     I/O scheduler, merging, plugging       │
└──────────────────────┬─────────────────────┘
                       │
┌──────────────────────▼─────────────────────┐
│          Block Device Driver               │
│          (SCSI, NVMe, virtio)              │
└──────────────────────┬─────────────────────┘
                       │
┌──────────────────────▼─────────────────────┐
│            Hardware (SSD / HDD)            │
└────────────────────────────────────────────┘
```

#### VFS'in Dört Temel Nesnesi

| Nesne | Görevi | Kernel Struct |
|-------|--------|---------------|
| **superblock** | Filesystem metadata (boyut, blok sayısı, mount bilgisi) | `struct super_block` |
| **inode** | Dosya metadata (izinler, boyut, blok pointer'ları) | `struct inode` |
| **dentry** | Dizin girişi, path lookup için cache | `struct dentry` |
| **file** | Açık dosya instance'ı (offset, erişim modu) | `struct file` |

> [!tip] VFS'in Gücü
> Aynı `read()` syscall'ı ile `/etc/passwd` (ext4), `/proc/cpuinfo` (procfs), `/sys/class/net/eth0/mtu` (sysfs) ve hatta network share (NFS) okunabilir. VFS hepsini aynı arayüzle sunar.

---

## Inode Yapısı

**Inode (Index Node)**, bir dosyanın **metadata**'sını ve **veri bloklarına pointer'larını** tutan kernel yapısıdır. Her dosya ve dizin tam olarak bir inode'a sahiptir.

```
struct inode (basitleştirilmiş)
┌──────────────────────────────────────────┐
│  i_mode      : dosya tipi + izinler      │  (regular, dir, symlink, socket, pipe)
│  i_uid       : sahip kullanıcı ID        │
│  i_gid       : sahip grup ID             │
│  i_size      : dosya boyutu (byte)       │
│  i_atime     : son erişim zamani         │
│  i_mtime     : son değişiklik zamani     │
│  i_ctime     : inode değişiklik zamani   │
│  i_nlink     : hard link sayisi          │
│  i_blocks    : ayrilan blok sayisi       │
│  i_ino       : inode numarası            │
├──────────────────────────────────────────┤
│  Veri Bloklarina Pointer'lar             │
│  ├── Direct blocks (0-11)   [12 adet]    │
│  ├── Single indirect        [1 adet]     │
│  ├── Double indirect        [1 adet]     │
│  └── Triple indirect        [1 adet]     │
└──────────────────────────────────────────┘
```

#### Direct ve Indirect Block Yapısı (ext2/ext3)

```
inode
┌──────────────────┐
│  Direct 0   ────────→ [Data Block 0]     (4 KB)
│  Direct 1   ────────→ [Data Block 1]     (4 KB)
│  ...             │
│  Direct 11  ────────→ [Data Block 11]    (4 KB)
│                  │                       Toplam: 12 × 4KB = 48 KB
├──────────────────┤
│  Single Indirect ───→ ┌────────────┐
│                  │    │ ptr → Data │ × 1024
│                  │    └────────────┘    Toplam: 1024 × 4KB = 4 MB
├──────────────────┤
│  Double Indirect ───→ ┌─────────────────┐
│                  │    │ ptr → [Indirect]│ × 1024
│                  │    │   └→ ptr → Data │ × 1024
│                  │    └─────────────────┘ Toplam: 1024² × 4KB = 4 GB
├──────────────────┤
│  Triple Indirect ───→ ┌──────────────────────┐
│                  │    │ ptr → [Dbl Indirect] │ × 1024
│                  │    │   └→ [Indirect]      │ × 1024
│                  │    │       └→ ptr → Data  │ × 1024
│                  │    └──────────────────────┘ Toplam: 1024³ × 4KB = 4 TB
└──────────────────┘
```

> [!info] ext4 Farkı
> ext4 artık direct/indirect block pointer yerine **extents** kullanır. Bir extent, ardışık blokları tek bir kayıtla temsil eder: `(başlangıç bloğu, uzunluk)`. Bu özellikle büyük dosyalarda çok daha verimlidir.

#### stat() ile Inode İnceleme

```bash
# Dosyanin inode bilgilerini görüntüle
stat /etc/passwd
```

```
  File: /etc/passwd
  Size: 2845            Blocks: 8          IO Block: 4096   regular file
Device: 8,1             Inode: 131074      Links: 1
Access: (0644/-rw-r--r--)  Uid: (    0/    root)   Gid: (    0/    root)
Access: 2024-12-15 10:30:22.000000000 +0300
Modify: 2024-12-10 08:15:41.000000000 +0300
Change: 2024-12-10 08:15:41.000000000 +0300
 Birth: 2024-11-01 12:00:00.000000000 +0300
```

```bash
# Sadece inode numarasını göster
ls -i /etc/passwd
# 131074 /etc/passwd

# Filesystem'deki tüm inode kullanımını göster
df -i

# Belirli bir dizindeki dosyaların inode numaraları
ls -li /etc/ | head -20
```

#### Inode Yapısı C'de (Kernel Tarafında)

```c
// linux/fs.h (basitleştirilmiş)
struct inode {
    umode_t             i_mode;     // dosya tipi + izinler
    unsigned short      i_opflags;
    kuid_t              i_uid;      // sahip UID
    kgid_t              i_gid;      // sahip GID
    unsigned int        i_flags;

    const struct inode_operations  *i_op;   // inode operasyonlari
    struct super_block             *i_sb;   // ait olduğu superblock
    const struct file_operations   *i_fop;  // dosya operasyonlari

    unsigned long       i_ino;      // inode numarası
    unsigned int        i_nlink;    // hard link sayisi
    dev_t               i_rdev;     // device numarası (device dosyasi ise)
    loff_t              i_size;     // dosya boyutu

    struct timespec64   i_atime;    // son erişim
    struct timespec64   i_mtime;    // son içerik degisikligi
    struct timespec64   __i_ctime;  // son inode degisikligi

    blkcnt_t            i_blocks;   // ayrilan 512-byte blok sayisi
    unsigned int        i_blkbits;  // blok boyutu (log2)

    struct address_space *i_mapping; // page cache
    // ...
};
```

> [!warning] Inode Tükenmesi
> Bir filesystem'de inode sayısı **oluşturulurken** belirlenir. Disk boş olsa bile inode biterse yeni dosya oluşturulamaz.
> ```bash
> # Inode kullanımını kontrol et
> df -i /
> # Filesystem     Inodes  IUsed  IFree IUse% Mounted on
> # /dev/sda1     6553600 234567 6319033    4% /
> ```

---

## Dentry (Directory Entry) ve Dcache

**Dentry**, dosya adını inode'a bağlayan yapıdır. Path lookup işlemini hızlandırmak için kernel **dcache (directory entry cache)** kullanır.

```
Path: /home/ayber/notes/docker.md

Lookup zinciri:
  "/" (root dentry)
   └─ "home" (dentry) → inode 2001 (dizin)
       └─ "ayber" (dentry) → inode 3045 (dizin)
            └─ "notes" (dentry) → inode 4120 (dizin)
                 └─ "docker.md" (dentry) → inode 5678 (dosya)
```

#### Dentry'nin Yapısı

```c
// linux/dcache.h (basitleştirilmiş)
struct dentry {
    struct dentry        *d_parent;   // ust dizinin dentry'si
    struct qstr           d_name;     // dosya/dizin adı
    struct inode         *d_inode;    // işaret ettigi inode
    const struct dentry_operations *d_op;

    struct super_block   *d_sb;       // ait olduğu superblock
    struct list_head      d_child;    // parent'in child listesi
    struct list_head      d_subdirs;  // alt dizinler (bu bir dizinse)
    // ...
};
```

#### Dcache (Dentry Cache)

Dcache, daha önce çözümlenmiş path'leri bellekte tutar. Her path lookup'ta diskten okumak yerine cache'e bakılır.

```
Path Lookup: /home/ayber/notes/docker.md

1. Adim: dcache'de "/"            → HIT  (root her zaman cache'de)
2. Adim: dcache'de "/home"        → HIT  (sik erisilen dizin)
3. Adim: dcache'de "/home/ayber"  → HIT
4. Adim: dcache'de "/home/ayber/notes" → MISS
   └─ Disk'ten oku, inode bul, dcache'e ekle
5. Adim: dcache'de "/home/ayber/notes/docker.md" → MISS
   └─ Disk'ten oku, inode bul, dcache'e ekle

Sonraki erisimde tüm path dcache'den gelir → çok hızlı
```

```bash
# Dcache istatistiklerini gormek
cat /proc/sys/fs/dentry-state
# 45231  32100  45  0  0  0
# [total] [unused] [age_limit] ...

# Dentry cache'i bosaltmak (test/debug amaçlı)
echo 2 > /proc/sys/vm/drop_caches
```

#### Negative Dentry

Var olmayan dosyalar için de dentry oluşturulur (**negative dentry**). Bu, tekrarlanan "dosya bulunamadı" sorgularını hızlandırır.

```
stat("/tmp/nonexistent")  → -ENOENT
   └─ Negative dentry oluşturulur: "/tmp/nonexistent" → NULL inode
   └─ Sonraki aynı sorgu dcache'den doğrudan ENOENT döner
```

---

## Superblock

**Superblock**, bir filesystem'in **genel metadata**'sını tutar. Mount işlemi sırasında diskten okunur ve bellekte tutulur.

```
Superblock içeriği (kavramsal)
┌───────────────────────────────────────────────┐
│  s_type          : filesystem tipi (ext4)     │
│  s_blocksize     : blok boyutu (4096)         │
│  s_maxbytes      : max dosya boyutu           │
│  s_magic         : magic number (0xEF53=ext4) │
│  s_op            : superblock operasyonlari   │
│  s_flags         : mount flag'leri (ro, rw)   │
│  s_root          : root dentry                │
│  s_dev           : device numarası            │
│  s_bdev          : block device               │
│  s_inodes_count  : toplam inode sayisi        │
│  s_blocks_count  : toplam blok sayisi         │
│  s_free_inodes   : bos inode sayisi           │
│  s_free_blocks   : bos blok sayisi            │
│  s_mtime         : son mount zamani           │
│  s_wtime         : son yazma zamani           │
│  s_state         : filesystem durumu          │
│  s_feature_compat  : uyumlu ozellikler        │
│  s_feature_incompat: uyumsuz ozellikler       │
└───────────────────────────────────────────────┘
```

```bash
# ext4 superblock bilgisini gormek
sudo tune2fs -l /dev/sda1

# Örnek çıktı (kisaltilmis):
# Filesystem volume name:   <none>
# Last mounted on:          /
# Filesystem UUID:          a1b2c3d4-...
# Filesystem magic number:  0xEF53
# Filesystem state:         clean
# Inode count:              6553600
# Block count:              26214400
# Free blocks:              18234567
# Free inodes:              6319033
# Block size:               4096
# Journal inode:            8
# Default mount options:    user_xattr acl

# debugfs ile superblock'u inceleme
sudo debugfs /dev/sda1
debugfs: stats
debugfs: show_super_stats
```

```c
// linux/fs.h (basitleştirilmiş)
struct super_block {
    struct list_head    s_list;       // tüm superblock'larin listesi
    dev_t               s_dev;        // device id
    unsigned char       s_blocksize_bits;
    unsigned long       s_blocksize;
    loff_t              s_maxbytes;   // max dosya boyutu
    struct file_system_type *s_type;  // filesystem tipi
    const struct super_operations *s_op;  // operasyonlar

    unsigned long       s_magic;      // magic number
    struct dentry       *s_root;      // root dentry
    // ...
};
```

> [!tip] Superblock Yedekleri
> ext4, superblock'un birden fazla kopyasını tutar (block group 0, 1, 3, 5, 7, ...). Ana superblock bozulursa yedekten kurtarma yapılabilir:
> ```bash
> # Yedek superblock konumlarini bul
> sudo mke2fs -n /dev/sda1
> # Yedek superblock'tan mount et
> sudo mount -o sb=32768 /dev/sda1 /mnt
> ```

---

## File Descriptor Table Zinciri

Bir process `open()` çağırdığında, kernel üç katmanlı bir yapıyla dosyaya erişim sağlar.

```
Process A (PID 1000)                    Process B (PID 2000)
┌────────────────────┐                 ┌────────────────────┐
│  fd table          │                 │  fd table          │
│  (task_struct ->   │                 │  (task_struct ->   │
│   files_struct)    │                 │   files_struct)    │
│                    │                 │                    │
│  fd 0 ──→ [ptr] ───┼──┐              │  fd 0 ──→ [ptr] ───┼───┐
│  fd 1 ──→ [ptr] ───┼──┼──┐           │  fd 1 ──→ [ptr] ───┼───┼──┐
│  fd 2 ──→ [ptr] ───┼──┼──┼──┐        │  fd 3 ──→ [ptr] ───┼───┼──┼──┐
│  fd 3 ──→ [ptr] ───┼──┼──┼──┼──┐     │  fd 4 ──→ [ptr] ───┼───┼──┼──┼──┐
└────────────────────┘  │  │  │  │     └────────────────────┘   │  │  │  │
                        │  │  │  │                              │  │  │  │
  ══════════════════════╪══╪══╪══╪══════════════════════════════╪══╪══╪══╪═══
  KERNEL                │  │  │  │                              │  │  │  │
                        ▼  ▼  ▼  ▼                              ▼  ▼  ▼  ▼
            ┌───────────────────────────────────────────────────────────────┐
            │              Open File Table (system-wide)                    │
            │  ┌───────────────────────────────────────────┐                │
            │  │ Entry 0:                                  │                │
            │  │   f_pos    = 0 (dosya offset)             │ ← A:fd0        │
            │  │   f_flags  = O_RDONLY                     │                │
            │  │   f_mode   = read                         │                │
            │  │   f_op     = &ext4_file_operations        │                │
            │  │   f_inode ──→ [inode ptr]  ───────────┐   │                │
            │  ├───────────────────────────────────────────┤  │             │
            │  │ Entry 1:                                  │  │             │
            │  │   f_pos    = 1024                         │  │ ← A:fd1     │
            │  │   f_flags  = O_WRONLY                     │  │             │
            │  │   f_inode ──→ [inode ptr]  ──────┐        │  │             │
            │  ├───────────────────────────────────────────┤  │  │          │
            │  │ Entry 2:                                  │  │  │          │
            │  │   f_pos    = 512                          │  │  │ ← A:fd3  │
            │  │   f_inode ──→ [inode ptr]  ──┐            │  │  │   B:fd4  │
            │  └───────────────────────────────────────────┘  │  │  │       │
            └─────────────────────────────────────────────────┘  │  │       │
                                                 │               │  │  │    │
  ═══════════════════════════════════════════════╪═══════════════╪══╪══╪════╪═
                                                 │               │  │  │    │
            ┌────────────────────────────────────▼───────────────▼──▼──▼────▼─┐
            │              Inode Table (bellekte, VFS katmanı)                │
            │  ┌───────────────────────────────────────┐                      │
            │  │ Inode 131074 (/etc/passwd)            │ ← Entry 0            │
            │  │   i_mode  = 0644                      │                      │
            │  │   i_size  = 2845                      │                      │
            │  │   i_nlink = 1                         │                      │
            │  │   i_blocks → [disk bloklari]          │                      │
            │  ├───────────────────────────────────────┤                      │
            │  │ Inode 256001 (/var/log/syslog)        │ ← Entry 1            │
            │  │   i_mode  = 0640                      │                      │
            │  │   i_size  = 1048576                   │                      │
            │  ├───────────────────────────────────────┤                      │
            │  │ Inode 389120 (/tmp/shared.dat)        │ ← Entry 2            │
            │  │   i_mode  = 0666                      │                      │
            │  │   i_size  = 8192                      │                      │
            │  └───────────────────────────────────────┘                      │
            └─────────────────────────────────────────────────────────────────┘
```

#### Önemli Noktalar

- Her process **kendi fd table**'ına sahiptir (fork sonrası kopyalanır)
- Aynı dosyayı açan iki process **farklı open file entry**'lerine sahiptir (farklı offset)
- `dup()` veya `fork()` ile **aynı open file entry** paylaşımı olur (aynı offset)
- Birden fazla open file entry **aynı inode**'a işaret edebilir
- Inode bellekte **tek kopya** olarak tutulur (inode cache)

```bash
# Bir process'in açık dosyalarını gormek
ls -la /proc/$$/fd
# lrwx------ 1 root root 64 ... 0 -> /dev/pts/0
# lrwx------ 1 root root 64 ... 1 -> /dev/pts/0
# lrwx------ 1 root root 64 ... 2 -> /dev/pts/0
# lr-x------ 1 root root 64 ... 3 -> /etc/passwd

# Sistem genelinde açık dosyaları gormek
lsof | head -20

# Belirli bir dosyayi kimin actigini gormek
lsof /var/log/syslog
```

---

## ext4 Internals

ext4, Linux'un **varsayılan** ve en yaygın kullanılan dosya sistemidir. ext3'ün evrimidir ve büyük dosya/partition desteği, extent tabanlı yapılar ve geliştirilmiş journaling sunar.

#### Block Group Yapısı

ext4, diski **block group**'lara böler. Her block group kendi inode table'ına ve veri bloklarına sahiptir.

```
ext4 Disk Layout
┌─────────┬───────────────┬───────────────┬───────────────┬─────┐
│ Boot    │ Block Group 0 │ Block Group 1 │ Block Group 2 │ ... │
│ Sector  │               │               │               │     │
│ (1024B) │               │               │               │     │
└─────────┴───────┬───────┴───────────────┴───────────────┴─────┘
                  │
                  ▼
Block Group 0 Detay:
┌──────────┬───────┬──────────┬──────────┬──────────┬────────────┐
│Superblock│ GDT   │Data Block│Inode     │ Inode    │Data Blocks │
│          │(Group │ Bitmap   │ Bitmap   │ Table    │            │
│(4KB)     │Desc.  │(1 block) │(1 block) │(N blocks)│(veri)      │
│          │Table) │          │          │          │            │
└──────────┴───────┴──────────┴──────────┴──────────┴────────────┘

Superblock      : filesystem genel bilgisi (yedek kopyalar bazi gruplarda)
GDT             : her block group'un metadata'si
Data Block Bitmap: hangi veri bloklarinin dolu/bos olduğu (1 bit/blok)
Inode Bitmap    : hangi inode'larin dolu/bos olduğu (1 bit/inode)
Inode Table     : bu gruba ait inode'lar
Data Blocks     : dosya verisi
```

#### Extents (ext4)

ext4, eski direct/indirect block pointer sistemi yerine **extent** kullanır. Her extent, ardışık disk bloklarını tek bir kayıtla temsil eder.

```
Eski Sistem (ext2/ext3):              Yeni Sistem (ext4 extents):
inode                                  inode
├── blk 100                           ├── extent: start=100, len=500
├── blk 101                           │   (100'den 599'a kadar tek kayit)
├── blk 102                           │
├── ...                               ├── extent: start=2000, len=300
├── blk 599                           │   (2000'den 2299'a kadar tek kayit)
├── blk 2000                          │
├── blk 2001                          └── (2 kayit ile 800 blok temsil edildi)
├── ...
└── blk 2299
(800 ayri pointer gerekli)
```

```c
// ext4 extent yapısı (linux/ext4_extents.h)
struct ext4_extent {
    __le32  ee_block;     // dosya icindeki mantıksal blok numarası
    __le16  ee_len;       // ardisik blok sayisi (max 32768 = 128MB)
    __le16  ee_start_hi;  // fiziksel blok numarası (ust 16 bit)
    __le32  ee_start_lo;  // fiziksel blok numarası (alt 32 bit)
};

// Extent header (her extent agacinda)
struct ext4_extent_header {
    __le16  eh_magic;     // magic: 0xF30A
    __le16  eh_entries;   // geçerli entry sayisi
    __le16  eh_max;       // maximum entry kapasitesi
    __le16  eh_depth;     // ağaç derinligi (0 = leaf)
    __le32  eh_generation;
};
```

> [!tip] Extent Avantajları
> - Büyük ardışık dosyalarda dramatik performans artışı
> - Daha az metadata overhead (800 pointer yerine 2 extent)
> - Daha hızlı dosya oluşturma ve silme
> - ext4 inode içinde 4 extent doğrudan saklanabilir (ek blok gerektirmez)

#### ext4 Journal

ext4, veri bütünlüğünü sağlamak için **journal** mekanizması kullanır. Detayları aşağıdaki "Journaling Nasıl Çalışır" bölümünde açıklanmıştır.

```bash
# ext4 filesystem oluşturma
mkfs.ext4 -L mydata /dev/sdb1

# ext4 bilgilerini görüntüleme
sudo tune2fs -l /dev/sda1

# debugfs ile detayli inceleme
sudo debugfs /dev/sda1
debugfs: stat /etc/passwd
debugfs: imap <inode_no>
debugfs: blocks <inode_no>
debugfs: dump_extents /etc/passwd
```

---

## xfs vs btrfs vs ext4 Karşılaştırması

| Özellik | ext4 | XFS | Btrfs |
|---------|------|-----|-------|
| **Geliştirici** | Linux community | SGI (şimdi Linux) | Oracle/Facebook/SUSE |
| **Max dosya boyutu** | 16 TB | 8 EB | 16 EB |
| **Max filesystem boyutu** | 1 EB | 8 EB | 16 EB |
| **Varsayılan blok boyutu** | 4 KB | 4 KB | 4 KB (16 KB sectorsize) |
| **Metadata yapısı** | Extent tree | B+ tree | B-tree (CoW) |
| **Journaling** | Evet (JBD2) | Evet (metadata only) | Yok (CoW-based) |
| **Copy-on-Write** | Hayır | Hayır | Evet (tüm veri) |
| **Snapshot** | Hayır | Hayır (LVM gerekir) | Evet (native, anlık) |
| **Compression** | Hayır | Hayır | Evet (zlib, lzo, zstd) |
| **RAID** | Hayır (mdraid/LVM) | Hayır (mdraid/LVM) | Evet (native RAID 0,1,5,6,10) |
| **Deduplication** | Hayır | Hayır (reflink var) | Evet (offline + reflink) |
| **Online shrink** | Evet | Hayır | Evet |
| **Online grow** | Evet | Evet | Evet |
| **Reflink (CoW copy)** | Hayır | Evet (`cp --reflink`) | Evet |
| **Performans (random I/O)** | İyi | Çok iyi | Orta |
| **Performans (sequential)** | İyi | Çok iyi | İyi |
| **Küçük dosya performansı** | İyi | Orta | Orta |
| **Olgunluk** | Çok yüksek | Yüksek | Orta-Yüksek |
| **Kullanım alanı** | Genel amaçlı, root FS | Büyük dosyalar, DB, enterprise | NAS, snapshot, esnek depolama |

```bash
# ext4 bilgisi
sudo tune2fs -l /dev/sda1 | grep -E "Filesystem|Block|Inode|Journal"

# XFS bilgisi
xfs_info /dev/sdb1
# veya
xfs_info /mnt/data

# Btrfs bilgisi
sudo btrfs filesystem show /dev/sdc1
sudo btrfs filesystem df /mnt/btrfs
sudo btrfs subvolume list /mnt/btrfs
```

> [!warning] Seçim Rehberi
> - **ext4**: Genel amaçlı sunucu, root filesystem, Docker overlay2 için ideal
> - **XFS**: Büyük dosya ve yüksek throughput gereken iş yükleri (medya sunucusu, veritabanı)
> - **Btrfs**: Snapshot, compression, esnek disk yönetimi gereken ortamlar (NAS, geliştirme)

---

## Journaling Nasıl Çalışır?

Journaling, **ani güç kesintisi** veya **sistem çöküşü** durumunda dosya sistemi tutarlılığını korumak için kullanılır. Temel fikir: değişiklikleri diske yazmadan önce bir **log (journal)** alanına kaydet.

```
Normal Yazma (journaling olmadan):
1. Inode güncelle  → GUC KESINTISI! → Inode güncel ama data blogu eski
2. Data blogu yaz                      (tutarsiz filesystem!)
3. Bitmap güncelle

Journaling ile Yazma:
1. Journal'a yaz: "inode X ve data blogu Y guncellenecek"
2. Journal commit (journal kaydini tamamla)
3. Gercek yere yaz: inode güncelle, data blogu yaz, bitmap güncelle
4. Journal'dan sil (checkpoint)

GUC KESINTISI durumunda:
- Boot sirasinda journal kontrol edilir
- Tamamlanmamis islemler → geri al (discard)
- Commit edilmiş ama yazilmamis islemler → yeniden yaz (replay)
```

#### Journal Modları (ext4)

| Mod | Açıklama | Performans | Güvenlik |
|-----|----------|------------|----------|
| **journal** | Hem metadata hem data journal'lanır | En yavaş | En güvenli |
| **ordered** (varsayılan) | Sadece metadata journal'lanır, data metadata'dan önce diske yazılır | Orta | İyi |
| **writeback** | Sadece metadata journal'lanır, data sırası garanti edilmez | En hızlı | En düşük |

```
journal modu:
┌──────────┐    ┌──────────┐    ┌──────────┐
│ Data +   │───→│ Journal  │───→│ Gercek   │
│ Metadata │    │ (log)    │    │ Konum    │
└──────────┘    └──────────┘    └──────────┘
Her sey önce journal'a yazılır → Tam koruma ama yavaş (çift yazma)

ordered modu (varsayilan):
┌──────┐    ┌──────────┐    ┌──────────┐
│ Data │───→│ Diske    │    │          │
│      │    │ yazılır  │    │          │
└──────┘    └──────┬───┘    │          │
                   │ (önce) │          │
┌──────────┐       │        │ Gercek   │
│ Metadata │───────┼───→ ┌──┤ Konum    │
│          │  journal    │  │          │
└──────────┘    sonra    │  └──────────┘
                         │
Data önce diske yazılır, metadata journal'dan sonra gerçek yerine yazılır.

writeback modu:
┌──────┐           ┌──────────┐
│ Data │───→ ?     │ Diske    │  (sıra garanti yok)
└──────┘           │ yazılır  │
┌──────────┐       └──────────┘
│ Metadata │───→ journal ───→ gerçek konum
└──────────┘
Metadata korunur ama data kaybi olabilir (dosya ici cop veri)
```

```bash
# Mevcut journal modunu gormek
cat /proc/mounts | grep ' / '
# /dev/sda1 / ext4 rw,relatime,errors=remount-ro,data=ordered 0 0

# Journal modunu değiştirmek (mount sirasinda)
sudo mount -o remount,data=journal /dev/sda1 /
# veya /etc/fstab'da:
# /dev/sda1  /  ext4  defaults,data=journal  0  1

# Journal boyutunu gormek
sudo tune2fs -l /dev/sda1 | grep -i journal
# Journal size: 128M

# Journal boyutunu ayarlamak (oluşturma sirasinda)
mkfs.ext4 -J size=256 /dev/sdb1
```

#### XFS Journaling

XFS sadece **metadata journaling** yapar (ext4'ün writeback moduna benzer). Ancak XFS'in journal'ı daha gelişmiştir:

```bash
# XFS journal bilgisi
xfs_info /dev/sdb1
# log      =internal               bsize=4096   blocks=2560, version=2

# Harici journal device kullanma (performans için)
mkfs.xfs -l logdev=/dev/sdc1,size=128m /dev/sdb1
```

> [!info] Btrfs ve CoW
> Btrfs journal kullanmaz. Bunun yerine **Copy-on-Write (CoW)** yaklaşımını benimser: mevcut veri asla yerinde değiştirilmez, yeni veri başka bir konuma yazılır ve atomik olarak pointer güncellemesi yapılır. Bu yaklaşım journal'a gerek kalmadan tutarlılık sağlar.

---

## Hard Link vs Soft Link

Linux'ta iki tür link vardır: **hard link** ve **symbolic (soft) link**. Araları inode seviyesinde temel bir fark vardır.

#### Hard Link

Aynı inode'a birden fazla dizin girişi (dentry) işaret eder. Inode'un `i_nlink` sayacı artar.

```
Hard Link: file_a ve file_b AYNI inode'a işaret eder

Dentry Table            Inode Table              Data Blocks
┌────────────────┐     ┌───────────────────┐    ┌───────────────┐
│ "file_a" ──────┼──┐  │ Inode 5678        │    │               │
└────────────────┘  ├─→│   i_nlink = 2     │───→│  Dosya içeriği│
┌────────────────┐  │  │   i_size  = 1024  │    │  (gerçek veri)│
│ "file_b" ──────┼──┘  │   i_mode  = 0644  │    │               │
└────────────────┘     │   i_uid   = 1000  │    └───────────────┘
                       │   i_blocks → [ptr]│
                       └───────────────────┘

file_a silinirse:
- Inode 5678: i_nlink = 2 → 1
- Veri SILINMEZ (nlink > 0)
- file_b hala çalışıyor

file_b de silinirse:
- Inode 5678: i_nlink = 1 → 0
- Kernel veri bloklarini serbest bırakır
- Inode serbest bırakılır
```

#### Soft Link (Symbolic Link)

Yeni bir inode oluşturulur ve içinde **hedef dosyanın path'i** saklanır.

```
Soft Link: symlink_a → file_a (farkli inode)

Dentry Table            Inode Table              Data Blocks
┌────────────────┐     ┌────────────────────┐    ┌───────────────┐
│ "file_a" ──────┼──→  │ Inode 5678         │───→│  Dosya içeriği│
└────────────────┘     │   i_nlink = 1      │    │  (gerçek veri)│
                       │   i_mode = regular │    └───────────────┘
                       └────────────────────┘

┌────────────────┐     ┌────────────────────┐    ┌───────────────┐
│ "symlink_a" ───┼──→  │ Inode 9012         │───→│ "/path/file_a"│
└────────────────┘     │   i_nlink = 1      │    │ (hedef path)  │
                       │   i_mode = symlink │    └───────────────┘
                       └────────────────────┘

file_a silinirse:
- Inode 5678 serbest bırakılır
- symlink_a hala var ama "dangling link" olur
- symlink_a'ya erişim → "No such file or directory"
```

#### Karşılaştırma Tablosu

| Özellik | Hard Link | Soft Link (Symlink) |
|---------|-----------|---------------------|
| **Inode** | Aynı inode'u paylaşır | Yeni inode oluşturur |
| **i_nlink** | Artar | Etkilenmez |
| **Dizinler arası** | Aynı filesystem'de olmalı | Farklı filesystem'ler arası olabilir |
| **Dizinlere link** | Hayır (döngü riski) | Evet |
| **Hedef silinirse** | Veri erişimi devam eder | Dangling link (bozuk) |
| **Boyut** | Ek boyut yok | Hedef path kadar |
| **Performans** | Doğrudan inode erişimi | Ekstra indirection (path resolve) |
| **`ls -l` görünümü** | Normal dosya gibi | `lrwxrwxrwx ... symlink -> hedef` |

```bash
# Hard link oluşturma
ln /etc/passwd /tmp/passwd_hardlink
# Her ikisi de aynı inode'a işaret eder
ls -li /etc/passwd /tmp/passwd_hardlink
# 131074 -rw-r--r-- 2 root root 2845 ... /etc/passwd
# 131074 -rw-r--r-- 2 root root 2845 ... /tmp/passwd_hardlink
#   ^aynı inode       ^nlink=2

# Soft link oluşturma
ln -s /etc/passwd /tmp/passwd_symlink
ls -li /etc/passwd /tmp/passwd_symlink
# 131074 -rw-r--r-- 1 root root 2845 ... /etc/passwd
# 789012 lrwxrwxrwx 1 root root   11 ... /tmp/passwd_symlink -> /etc/passwd
#  ^farkli inode                    ^hedef path boyutu

# Bir inode'a işaret eden tüm hard link'leri bul
find / -inum 131074 2>/dev/null
```

> [!warning] Hard Link Kısıtlamaları
> - Farklı filesystem'ler arasında hard link oluşturulamaz (inode numaraları filesystem'e özgüdür)
> - Dizinlere hard link oluşturulamaz (dizin döngülerini önlemek için)
> - `ln` komutu varsayılan olarak hard link oluşturur, `-s` ile symlink

---

## fsync(), O_DIRECT ve Write Barrier'lar

Veri bütünlüğü için kritik mekanizmalar.

#### fsync() ve fdatasync()

```c
#include <unistd.h>
#include <fcntl.h>

int fd = open("/data/important.db", O_WRONLY | O_CREAT, 0644);

// Veri yazma
write(fd, buffer, size);

// fsync: hem veri hem metadata (boyut, mtime) diske yazılır
// Donus = veri GARANTI olarak diskte
fsync(fd);

// fdatasync: sadece veri diske yazılır
// Metadata (mtime vs.) yazilmayabilir → daha hızlı
fdatasync(fd);

// sync: TUM açık dosyalarin buffer'larini diske yaz
sync();
```

```
write() cagrisi sonrasi veri akisi:
                                                    ┌──────────┐
Application ──write()──→ Page Cache (RAM) ──?──→    │   Disk   │
                              │                     └──────────┘
                              │
    Veri henuz RAM'de!        │
    Guc kesilirse kaybolur!   │
                              │
    fsync() cagrisi:          │
    Page Cache ──flush──→ Disk Controller ──write──→ Disk
                              │
    fsync() dondu =           │
    Veri diskte (garanti)     │
```

```bash
# Sistem genelinde dirty page istatistikleri
cat /proc/meminfo | grep -i dirty
# Dirty:              1024 kB    ← henuz diske yazilmamis veri
# Writeback:            0 kB     ← su anda yazılan veri

# Dirty page flush parametreleri
sysctl vm.dirty_ratio              # %40 (toplam RAM'in %40'i dirty olunca sync)
sysctl vm.dirty_background_ratio   # %10 (arka planda flush başlar)
sysctl vm.dirty_expire_centisecs   # 3000 (30sn sonra expire)
sysctl vm.dirty_writeback_centisecs # 500 (5sn'de bir kontrol)
```

#### O_DIRECT

Page cache'i bypass ederek doğrudan disk'e yazar/okur. Veritabanları (PostgreSQL, MySQL) kendi buffer yönetimini yaparken kullanır.

```c
#include <fcntl.h>
#include <stdlib.h>

// O_DIRECT: page cache bypass
int fd = open("/data/db.file", O_RDWR | O_DIRECT);

// O_DIRECT gereksinimleri:
// 1. Buffer ALIGNED olmali (genellikle 512 byte veya 4KB)
// 2. Boyut ALIGNED olmali
// 3. Offset ALIGNED olmali
void *buf;
posix_memalign(&buf, 4096, 4096);  // 4KB aligned buffer

// Dogrudan disk I/O (page cache kullanılmaz)
pread(fd, buf, 4096, 0);
pwrite(fd, buf, 4096, 0);

free(buf);
close(fd);
```

> [!warning] O_DIRECT Dikkat
> - Page cache'i bypass ettiğinden **kernel level caching yok** → uygulamanın kendi cache'i olmalı
> - Buffer alignment gereksinimleri var, yoksa `EINVAL` hatası alınır
> - Genellikle sadece veritabanları ve özel uygulamalar kullanır
> - Normal uygulamalar için `fsync()` yeterlidir

#### Write Barriers

Write barrier, disk controller'ın yazma sırasını garanti etmesini sağlar. Journal commit'i öncesinde tüm önceki yazmaların diske ulaşmış olmasını zorlar.

```
Journal yazma sırası (barrier ile):

1. Journal metadata yaz
2. ── WRITE BARRIER ──  (önceki yazmalar diskte tamamlanmali)
3. Journal commit blogu yaz
4. ── WRITE BARRIER ──
5. Gercek konuma yaz (checkpoint)

Barrier olmadan disk controller yazma sirasini değiştirebilir
→ commit blogu metadata'dan önce yazilabilir
→ güç kesintisinde tutarsizlik!
```

```bash
# Mount sirasinda barrier kontrolü
mount -o barrier=1 /dev/sda1 /mnt    # barrier aktif (varsayilan)
mount -o barrier=0 /dev/sda1 /mnt    # barrier devre dışı (tehlikeli!)
mount -o nobarrier /dev/sda1 /mnt    # aynı sey

# Battery-backed write cache (BBU) olan RAID controller'larda
# barrier kapatilabilir (controller zaten garanti verir)
```

> [!tip] Veritabanı Önerileri
> - PostgreSQL: `fsync = on`, `wal_sync_method = fdatasync` (varsayılan, iyi)
> - MySQL/InnoDB: `innodb_flush_method = O_DIRECT` (çift buffer önleme)
> - Her zaman barrier aktif bırakın (BBU RAID hariç)

---

## OverlayFS Detay (Docker Union FS Bağlantısı)

OverlayFS, birden fazla dizini **katmanlar halinde** birleştiren bir union filesystem'dir. Docker, container image layer'larını birleştirmek için OverlayFS (overlay2 driver) kullanır.

```
OverlayFS Katman Yapisi:

Container'in gordugu (merged view):
┌──────────────────────────────────────────┐
│              merged/                     │
│  /bin  /etc  /usr  /app  /var            │
│  (tüm katmanlarin birlesik gorunumu)     │
└────────┬──────────────────┬──────────────┘
         │                  │
    ┌────▼─────┐    ┌──────▼────────────────────────────┐
    │ upperdir │    │ lowerdir (read-only)              │
    │ (r/w)    │    │ ┌─────────┐ ┌───────────┐ ┌──────┐│
    │          │    │ │ Layer 3 │:│ Layer 2   │:│ Base ││
    │ Container│    │ │ (COPY .)│ │(npm inst) │ │(node)││
    │ yazmalari│    │ └─────────┘ └───────────┘ └──────┘│
    └──────────┘    └───────────────────────────────────┘
         │
    ┌────▼─────┐
    │ workdir  │  (OverlayFS internal, atomic rename işlemleri)
    └──────────┘
```

#### Kernel Mount İşlemi

```bash
# OverlayFS manual mount (Docker'in arka planda yaptığı)
mount -t overlay overlay \
  -o lowerdir=/var/lib/docker/overlay2/layer3/diff:/var/lib/docker/overlay2/layer2/diff:/var/lib/docker/overlay2/base/diff,\
  upperdir=/var/lib/docker/overlay2/container/diff,\
  workdir=/var/lib/docker/overlay2/container/work \
  /var/lib/docker/overlay2/container/merged
```

#### Docker'da OverlayFS

```bash
# Container'in overlay bilgisini gormek
docker inspect <container> --format '{{json .GraphDriver.Data}}' | python3 -m json.tool
# {
#     "LowerDir": "/var/lib/docker/overlay2/abc.../diff:/var/lib/docker/overlay2/def.../diff",
#     "MergedDir": "/var/lib/docker/overlay2/xyz.../merged",
#     "UpperDir": "/var/lib/docker/overlay2/xyz.../diff",
#     "WorkDir": "/var/lib/docker/overlay2/xyz.../work"
# }

# Overlay2 dizin yapısı
ls /var/lib/docker/overlay2/
# abc123...  (layer 1)
# def456...  (layer 2)
# xyz789...  (container layer)
# l/         (kisaltilmis symlink'ler)

# Container'in mount bilgisini çekirdek seviyesinde gormek
cat /proc/$(docker inspect --format '{{.State.Pid}}' <container>)/mounts | grep overlay
```

#### Copy-on-Write Detay

```
Dosya Okuma (OKUMA):
  merged/app.js istendiginde:
  1. upperdir'de var mi? → Evet → upperdir'den oku
                          → Hayir → lowerdir katmanlarını yukari aşağı tara
  2. lowerdir layer3'te? → Evet → oradan oku
                          → Hayir → layer2? → ... → base?

Dosya Yazma (DEGISTIRME):
  merged/app.js degistirilmek istendiginde:
  1. upperdir'de var mi? → Evet → doğrudan yaz
                          → Hayir → COPY-UP işlemi:
     a. Dosyayi lowerdir'den upperdir'e KOPYALA
     b. Degisikligi upperdir'deki kopya uzerine yap
     c. lowerdir DEGISMEZ

Dosya Silme:
  merged/config.ini silinmek istendiginde:
  1. upperdir'de "whiteout" dosyasi oluşturulur:
     upperdir/config.ini (character device: 0/0)
  2. merged gorunumunde dosya artik gorunmez
  3. lowerdir'deki orijinal DEGISMEZ

Dizin Silme:
  merged/logs/ dizini silinmek istendiginde:
  1. upperdir'de "opaque whiteout" oluşturulur:
     upperdir/logs/.wh..wh..opq
  2. lowerdir'deki logs/ tamamen gizlenir
```

> [!warning] OverlayFS Performans Notları
> - **İlk yazma yavaştır** (copy-up: dosya önce lowerdir'den upperdir'e kopyalanır)
> - Büyük dosyalar için (veritabanı data dosyaları) OverlayFS **UYGUN DEĞİLDİR**
> - Veritabanı container'ları için **volume mount** kullanın → [[Docker Storage ve Volumes]]
> - `open()` ile O_WRONLY bile copy-up tetikler (dosya tamamen kopyalanır)

---

## Pratik Komutlar

#### stat — Dosya/Inode Bilgisi

```bash
# Detayli dosya bilgisi (inode, boyut, bloklar, zamanlar)
stat /etc/passwd
#   File: /etc/passwd
#   Size: 2845       Blocks: 8          IO Block: 4096   regular file
# Device: 8,1        Inode: 131074      Links: 1
# Access: (0644/-rw-r--r--)  Uid: (0/root)   Gid: (0/root)
# Access: 2024-12-15 10:30:22
# Modify: 2024-12-10 08:15:41
# Change: 2024-12-10 08:15:41

# Sadece belirli alanları göstermek
stat -c "%n: inode=%i size=%s links=%h" /etc/passwd
# /etc/passwd: inode=131074 size=2845 links=1

# Filesystem bilgisi
stat -f /
#   File: "/"
#     ID: ... Namelen: 255     Type: ext2/ext3
# Block size: 4096
# Blocks: Total: 26214400   Free: 18234567   Available: 17456789
# Inodes: Total: 6553600    Free: 6319033
```

#### df — Disk ve Inode Kullanımı

```bash
# Disk kullanimi (insan okunur format)
df -h
# Filesystem      Size  Used Avail Use% Mounted on
# /dev/sda1       100G   38G   57G  40% /
# tmpfs           7.8G  1.2M  7.8G   1% /dev/shm
# /dev/sdb1       500G  230G  245G  49% /data

# Inode kullanimi
df -i
# Filesystem      Inodes  IUsed   IFree IUse% Mounted on
# /dev/sda1      6553600 234567 6319033    4% /

# Filesystem tipi ile birlikte
df -Th
# Filesystem     Type   Size  Used Avail Use% Mounted on
# /dev/sda1      ext4   100G   38G   57G  40% /
# /dev/sdb1      xfs    500G  230G  245G  49% /data
```

#### du — Dizin Boyutu

```bash
# Dizin boyutu (özet)
du -sh /var/log
# 2.3G    /var/log

# Alt dizinler ile birlikte, buyukten küçüğe sıralı
du -h --max-depth=1 /var | sort -hr | head -20

# En büyük 10 dosya
du -ah /var/log | sort -hr | head -10

# Apparent size vs disk usage
du -sh --apparent-size /var/log    # dosya boyutları toplami
du -sh /var/log                    # disk uzerindeki gerçek kullanım (blok bazli)
```

#### lsof — Açık Dosyalar

```bash
# Tum açık dosyalar
lsof | head -20

# Belirli bir dosyayi kim kullaniyor
lsof /var/log/syslog

# Belirli bir process'in açık dosyaları
lsof -p $(pgrep nginx | head -1)

# Silinen ama hala açık dosyalar (disk alanı bosaltmak için)
lsof +L1
# Cozum: ilgili process'i restart etmek veya fd'yi truncate etmek

# Belirli port'u kullanan process
lsof -i :80
lsof -i TCP:443

# Belirli kullanıcının açık dosyaları
lsof -u www-data
```

#### debugfs — ext4 Debug

```bash
# debugfs interaktif mod (READ-ONLY varsayilan, güvenli)
sudo debugfs /dev/sda1

# Inode bilgisi
debugfs: stat /etc/passwd
# Inode: 131074   Type: regular    Mode:  0644   Flags: 0x80000
# Links: 1   Blockcount: 8
# Fragment:  Address: 0    Number: 0    Size: 0
# Size: 2845
# ctime: ...   atime: ...   mtime: ...

# Bir dosyanin kullandigi bloklari göster
debugfs: blocks /etc/passwd
# 524288

# Inode'un disk uzerindeki konumu
debugfs: imap <131074>
# Inode 131074 is part of block group 16

# Silinen dosyaları listeleme
debugfs: lsdel
# (silinmis inode'larin listesi)

# Silinen dosyayi kurtarma (DIKKAT: yazma modu gerekli)
sudo debugfs -w /dev/sda1
debugfs: undel <inode_no> /tmp/recovered_file

# Dizin içeriğini gosterme
debugfs: ls /etc/

# Extent bilgisi
debugfs: dump_extents /etc/passwd

# Cikis
debugfs: quit
```

> [!warning] debugfs -w (Yazma Modu)
> `debugfs -w` ile açtığında filesystem'i **doğrudan değiştirebilirsin** (mount durumunda bile). Yanlış kullanım veri kaybına neden olabilir. Sadece kurtarma işlemi için ve mümkünse **unmount** durumda kullan.

#### tune2fs — ext4 Parametreleri

```bash
# Filesystem bilgisi
sudo tune2fs -l /dev/sda1

# Journal modunu değiştir
sudo tune2fs -o journal_data /dev/sda1       # journal modu
sudo tune2fs -o journal_data_ordered /dev/sda1  # ordered modu (varsayilan)
sudo tune2fs -o journal_data_writeback /dev/sda1 # writeback modu

# Reserved block yuzdesini değiştir (varsayilan %5, root için ayrilir)
sudo tune2fs -m 1 /dev/sda1    # %1'e dusur (büyük disklerde yer kazanir)

# Filesystem check interval'ini ayarla
sudo tune2fs -i 30d /dev/sda1   # 30 gunde bir kontrol
sudo tune2fs -c 50 /dev/sda1    # 50 mount'ta bir kontrol

# Label ayarlama
sudo tune2fs -L "my-data" /dev/sda1

# ext4 özelliklerini aktif/deaktif etme
sudo tune2fs -O has_journal /dev/sda1      # journal ekle
sudo tune2fs -O ^has_journal /dev/sda1     # journal kaldir
sudo tune2fs -O extent /dev/sda1           # extent'leri aktif et
```

#### xfs_info — XFS Bilgisi

```bash
# XFS filesystem bilgisi
xfs_info /dev/sdb1
# veya (mount noktasindan)
xfs_info /mnt/data
# meta-data=/dev/sdb1        isize=512    agcount=4, agsize=131072 blks
#          =                 sectsz=512   attr=2, projid32bit=1
# data     =                 bsize=4096   blocks=524288, imaxpct=25
#          =                 sunit=0      swidth=0 blks
# naming   =version 2       bsize=4096   ascii-ci=0, ftype=1
# log      =internal         bsize=4096   blocks=2560, version=2
# realtime =none             extsz=4096   blocks=0, rtextents=0

# XFS repair (unmount durumda)
sudo xfs_repair /dev/sdb1

# XFS buyutme (online, mount durumda)
sudo xfs_growfs /mnt/data

# XFS defragmentasyon
sudo xfs_fsr /mnt/data

# XFS freeze/unfreeze (snapshot almak için)
sudo xfs_freeze -f /mnt/data    # freeze (yazma durdurulur)
# snapshot al...
sudo xfs_freeze -u /mnt/data    # unfreeze
```

---

## Özet: Filesystem İşlem Akışı

Bir dosya okunurken (örneğin `cat /etc/passwd`):

```
1. User space: cat programi read() syscall yapar
           │
2. VFS:    │  Path lookup başlar
           │  "/" → "etc" → "passwd" (dcache kontrol)
           │  dentry → inode bulunur
           │
3. VFS:    │  Inode üzerinden dosya tipi ve izinler kontrol edilir
           │  (permission check: DAC + MAC)
           │
4. VFS:    │  file->f_op->read() çağırılır
           │  (ext4_file_read_iter gibi filesystem-specific fonksiyon)
           │
5. FS:     │  Inode'daki extent/block pointer'lardan disk blok adresleri hesaplanir
           │
6. Cache:  │  Page cache'de var mi?
           │  → EVET: doğrudan RAM'den dondur (disk I/O yok!)
           │  → HAYIR: block layer'a istek gönder
           │
7. Block:  │  I/O scheduler isteği kuyruga alir
           │  → Merge, sort, dispatch
           │
8. Driver: │  Block device driver (NVMe, SCSI) komutu gönderir
           │
9. HW:     │  Disk/SSD veriyi okur → DMA ile RAM'e aktarir
           │
10. Donus: │  Veri page cache'e yazılır + user buffer'a kopyalanir
           │  read() syscall döner
```

> [!tip] Temel Çıkarımlar
> - **VFS**, tüm filesystem'leri tek bir arayüzde birleştirir
> - **Inode** dosya metadata'sının ve veri konum bilgisinin evidir
> - **Dentry + dcache** path lookup'ı dramatik olarak hızlandırır
> - **Page cache** disk I/O'yu minimize eder — çoğu okuma RAM'den gelir
> - **Journaling** güç kesintisinde veri bütünlüğünü korur
> - **OverlayFS** Docker container'larının verimli katmanlı dosya sistemi sağlar
> - **fsync()** çağırılmadıkça yazılanlar sadece RAM'de olabilir
> - Hard link'ler aynı inode'u paylaşır, symlink'ler ise bağımsız inode ile path referansı tutar
