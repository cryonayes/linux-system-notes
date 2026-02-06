# Linux File Permissions

Linux'ta dosya ve dizin erişimine **kim**, **ne yapabilir** sorusu permission (izin) sistemiyle cevaplanır. Temel DAC modelinden özel bitlere, ACL'lerden capability'lere kadar katmanlı bir yetki mimarisi vardır.

> [!info] İlişkili
> Container güvenlik katmanları → [[Docker Security]]
> User Namespace ve UID mapping → [[Linux Namespaces#User Namespace]]
> Non-root container → [[Dockerfile Best Practices#Non-Root User]]
> SUID binary ve dynamic linking → [[Linux Dynamic Libraries]]

---

## DAC — Discretionary Access Control

Linux varsayılan olarak **DAC** modeli kullanır. Dosya sahibi, o dosyanın izinlerini **kendi iradesiyle** belirler.

Her dosya ve dizin için üç katman yetki tanımlanır:

```
-rwxr-xr-- 1 ayber developers 4096 Feb 06 10:30 deploy.sh
│├─┤├─┤├─┤
│ │  │  └─── Other  (diger kullanicilar)
│ │  └─────── Group  (grup uyeleri)
│ └────────── Owner  (dosya sahibi)
└──────────── Dosya tipi (- = dosya, d = dizin, l = symlink)
```

#### İzin Tipleri

| İzin | Harf | Octal | Dosya Üzerinde | Dizin Üzerinde |
|------|------|-------|----------------|----------------|
| Read | `r` | 4 | Dosya içeriğini oku | Dizin içeriğini listele (`ls`) |
| Write | `w` | 2 | Dosya içeriğini değiştir | Dizinde dosya oluştur/sil |
| Execute | `x` | 1 | Dosyayı çalıştır | Dizine gir (`cd`) |

> [!warning] Dizin Execute İzni
> Bir dizinde `x` izni yoksa, içindeki dosyaların adını bilsen bile erişemezsin. `r` izni dizin içeriğini listelemeye izin verir ama `x` olmadan dosyalara ulaşılamaz.

```bash
# Dizin izin örnekleri
mkdir /tmp/testdir
chmod 744 /tmp/testdir   # owner: rwx, group: r--, other: r--
# Baska kullanıcı: ls yapabilir ama cd yapamaz

chmod 711 /tmp/testdir   # owner: rwx, group: --x, other: --x
# Baska kullanıcı: cd yapabilir ama ls yapamaz (dosya adını bilmesi gerekir)

chmod 755 /tmp/testdir   # owner: rwx, group: r-x, other: r-x
# Herkes hem ls hem cd yapabilir (en yaygin dizin izni)
```

---

## Permission Hesaplama — Octal ve Symbolic

#### Octal (Sayısal) Gösterim

Her izin grubundaki harfler bir toplam oluşturur:

```
r = 4
w = 2
x = 1

rwx = 4+2+1 = 7
r-x = 4+0+1 = 5
r-- = 4+0+0 = 4
--- = 0+0+0 = 0
```

Yaygın octal değerler:

| Octal | Symbolic | Kullanım |
|-------|----------|----------|
| `755` | `rwxr-xr-x` | Script, dizin (owner yazabilir, herkes çalıştırabilir) |
| `644` | `rw-r--r--` | Normal dosya (owner yazabilir, herkes okuyabilir) |
| `700` | `rwx------` | Özel script/dizin (sadece owner) |
| `600` | `rw-------` | Hassas dosya (SSH key, config) |
| `777` | `rwxrwxrwx` | Herkes her şeyi yapabilir (güvenlik riski!) |
| `750` | `rwxr-x---` | Owner + grup erişilebilir, diğer erişemez |
| `640` | `rw-r-----` | Owner yazar, grup okur, diğer erişemez |
| `444` | `r--r--r--` | Herkes sadece okuyabilir |

#### chmod — İzin Değiştirme

**Octal notasyon:**
```bash
chmod 755 deploy.sh      # rwxr-xr-x
chmod 644 config.yaml    # rw-r--r--
chmod 600 ~/.ssh/id_rsa  # rw------- (SSH key için zorunlu)
chmod 700 ~/.ssh          # rwx------ (SSH dizini için zorunlu)
```

**Symbolic notasyon:**
```bash
# u = user (owner), g = group, o = other, a = all

chmod u+x script.sh      # Owner'a execute ekle
chmod g-w file.txt        # Gruptan write kaldir
chmod o=r file.txt        # Other için sadece read ayarla
chmod a+r file.txt        # Herkese read ekle
chmod u+rwx,g=rx,o= secret.sh   # owner:rwx, group:r-x, other:---
chmod ug+x deploy.sh     # Owner ve gruba execute ekle

# Recursive (dizin ve altindaki tüm dosyalar)
chmod -R 755 /var/www/html
chmod -R u+rwX,go+rX,go-w /var/www/html
# Buyuk X: sadece dizinlere ve zaten execute olan dosyalara x verir
```

> [!tip] Büyük X Kullanımı
> `chmod -R a+X` komutu sadece **dizinlere** ve **zaten en az bir execute biti olan dosyalara** execute izni verir. Bu, tüm dosyaları korkusuzca executable yapma hatasını önler. Web dizinlerinde çok kullanışlıdır.

---

## chown ve chgrp — Sahiplik Değiştirme

#### chown

```bash
# Dosya sahibini değiştir
chown ayber file.txt

# Dosya sahibi ve grubunu değiştir
chown ayber:developers file.txt

# Sadece grubu değiştir
chown :developers file.txt

# Recursive (dizin ve içeriği)
chown -R www-data:www-data /var/www/html

# Symbolic link'in kendisini değiştir (hedefi değil)
chown -h ayber symlink.txt
```

#### chgrp

```bash
# Dosya grubunu değiştir
chgrp developers project/

# Recursive
chgrp -R developers project/
```

> [!info] Sadece root veya dosya sahibi
> `chown` sadece **root** tarafından çalıştırılabilir. Normal kullanıcı kendi dosyasının sahibini değiştiremez (güvenlik nedeniyle). `chgrp` ise dosya sahibi tarafından, sadece **kendisinin üye olduğu gruplara** değiştirme yapabilir.

---

## umask — Varsayılan İzin Maskesi

Yeni oluşturulan dosya ve dizinlerin izinlerini belirleyen **çıkarma maskesi**.

#### Hesaplama Mantığı

```
Dosya base izni:  666 (rw-rw-rw-)  — dosyalar default olarak execute almaz
Dizin base izni:  777 (rwxrwxrwx)

Sonuc = Base - umask (bitwise AND NOT)

umask 022 ise:
  Dosya: 666 - 022 = 644 (rw-r--r--)
  Dizin: 777 - 022 = 755 (rwxr-xr-x)

umask 077 ise:
  Dosya: 666 - 077 = 600 (rw-------)
  Dizin: 777 - 077 = 700 (rwx------)

umask 002 ise:
  Dosya: 666 - 002 = 664 (rw-rw-r--)
  Dizin: 777 - 002 = 775 (rwxrwxr-x)
```

> [!warning] Umask Hesaplama Detayı
> Umask aslında **çıkarma değil bitwise AND NOT** işlemidir. `umask 033` durumunda dosya izni `666 AND NOT 033 = 644` olur, `633` değil. Pratikte çoğu zaman basit çıkarma doğru sonuç verir ama `3` veya `5` gibi değerlerde dikkatli olmak gerekir.

#### Umask Ayarlama

```bash
# Mevcut umask'i gor
umask         # 0022 (octal)
umask -S      # u=rwx,g=rx,o=rx (symbolic gösterim)

# Gecici olarak değiştir (mevcut shell için)
umask 077     # Yeni dosyalar 600, dizinler 700

# Kalici ayarlama:
# Sistem geneli → /etc/profile veya /etc/login.defs
# Kullanici bazli → ~/.bashrc veya ~/.profile
```

#### Nerede Ayarlanır?

| Dosya | Kapsam | Ne Zaman Yüklenir |
|-------|--------|-------------------|
| `/etc/profile` | Sistem geneli (tüm kullanıcılar) | Login shell başladığında |
| `/etc/profile.d/*.sh` | Sistem geneli (modüler) | `/etc/profile` tarafından source edilir |
| `/etc/login.defs` | `UMASK` ayarı (pam_umask) | Login sırasında |
| `~/.bashrc` | Kullanıcı bazlı | Her interactive bash shell |
| `~/.profile` | Kullanıcı bazlı | Login shell |
| `~/.bash_profile` | Kullanıcı bazlı (bash specific) | Bash login shell |

```bash
# /etc/profile örneği
if [ "$(id -gn)" = "developers" ]; then
    umask 002    # Grup yazabilsin
else
    umask 022    # Standart
fi

# ~/.bashrc örneği
umask 077        # Kisisel dosyaları sadece ben gorebilirim
```

> [!tip] Servis Umask
> systemd servislerinde `UMask=` directive'i ile servisin umask değeri ayarlanabilir. Örneğin web sunucusu için `UMask=0022` yaygındır.

---

## Özel Bitler — SUID, SGID, Sticky Bit

Normal `rwx` izinlerinin ötesinde üç özel bit vardır. Bunlar **4 haneli octal** gösterimde ilk haneyi oluşturur:

| Bit | Octal | Sembolik | Dosyada | Dizinde |
|-----|-------|----------|---------|---------|
| SUID | `4` | `u+s` | Dosya sahibinin yetkileriyle çalışır | (etkisiz) |
| SGID | `2` | `g+s` | Dosya grubunun yetkileriyle çalışır | Yeni dosyalar dizinin grubunu miras alır |
| Sticky | `1` | `+t` | (etkisiz) | Sadece dosya sahibi silebilir |

```bash
# ls -l ciktisinda özel bitler:
-rwsr-xr-x  # SUID set → owner execute yerinde 's'
-rwxr-sr-x  # SGID set → group execute yerinde 's'
drwxrwxrwt  # Sticky set → other execute yerinde 't'

# Buyuk S/T → execute izni YOK ama özel bit SET
-rwSr-xr-x  # SUID set ama owner execute yok (uyarı: islevsiz olabilir)
drwxrwxrwT  # Sticky set ama other execute yok
```

---

## SUID (Set User ID) — Detaylı

SUID bit set edilmiş bir **binary** çalıştırıldığında, process **dosya sahibinin UID'si** ile çalışır — onu çalıştıran kullanıcının değil.

#### Nasıl Çalışır?

```
Normal çalıştırma:
  ayber → ./program → process UID = ayber (1000)

SUID set edilmiş binary:
  ayber → ./program (owner: root, SUID set) → process UID = root (0)
  Effective UID = root
  Real UID = ayber
```

```c
// SUID binary içinde UID durumu
#include <stdio.h>
#include <unistd.h>

int main() {
    printf("Real UID:      %d\n", getuid());   // Calistiran kullanıcı
    printf("Effective UID: %d\n", geteuid());  // Dosya sahibi (SUID sayesinde)
    // Eger SUID root binary ise:
    // Real UID:      1000 (ayber)
    // Effective UID: 0    (root)
    return 0;
}
```

#### /usr/bin/passwd Örneği

`passwd` komutu her kullanıcının kendi şifresini değiştirmesine izin verir. Ama şifreler `/etc/shadow` dosyasında saklanır ki sadece root okuyabilir.

```bash
ls -l /usr/bin/passwd
# -rwsr-xr-x 1 root root 68208 ... /usr/bin/passwd
#    ^
#    SUID bit

ls -l /etc/shadow
# -rw-r----- 1 root shadow 1234 ... /etc/shadow
# Sadece root yazabilir
```

Akis:
1. Normal kullanıcı `passwd` çalıştırır
2. SUID sayesinde process effective UID = root olur
3. Process `/etc/shadow` dosyasına yazabilir
4. Ama program **sadece** çalıştıran kullanıcının şifresini değiştirir (real UID kontrol edilir)

#### SUID Ayarlama

```bash
# SUID set etme
chmod u+s program       # Symbolic
chmod 4755 program      # Octal (4 = SUID)

# SUID kaldirma
chmod u-s program
chmod 0755 program
```

#### SUID Root Binary Tarama — Güvenlik Auditi

```bash
# Sistemdeki tüm SUID binary'leri bul
find / -perm -4000 -type f 2>/dev/null

# Sadece root'a ait SUID binary'ler
find / -perm -4000 -user root -type f 2>/dev/null

# Detayli çıktı
find / -perm -4000 -type f -exec ls -la {} \; 2>/dev/null

# Bilinen SUID binary'ler (normal olan)
# /usr/bin/passwd
# /usr/bin/sudo
# /usr/bin/su
# /usr/bin/newgrp
# /usr/bin/chsh
# /usr/bin/gpasswd
# /usr/bin/mount
# /usr/bin/umount
# /usr/bin/pkexec
```

> [!warning] SUID Güvenlik Riski — Binary Exploitation
> SUID root binary'ler saldırganlar için **privilege escalation** vektörüdür. Eğer SUID binary'de bir buffer overflow veya format string güvenlik açığı varsa, saldırgan root yetkisiyle kod çalıştırabilir.
>
> **Örnek saldırı senaryosu:**
> 1. Saldırgan SUID root binary'de buffer overflow bulur
> 2. Shellcode veya ROP chain ile exploit yazar
> 3. Exploit çalıştığında process zaten effective UID = 0 (root)
> 4. Saldırgan root shell elde eder
>
> **GTFOBins** — bazı SUID binary'ler tasarım gereği kötü kullanılabildiği için kontrol edilmelidir:
> `find`, `vim`, `python`, `nmap` (eski versiyon), `bash` gibi binary'ler SUID ile tehlikelidir.

```bash
# GTFOBins örneği: find ile SUID exploitation
# Eger /usr/bin/find SUID root ise:
find . -exec /bin/sh -p \;
# -p flag'i sh'nin effective UID'yi dusurmesini engeller → root shell

# Python SUID ise:
python3 -c 'import os; os.execl("/bin/sh", "sh", "-p")'

# vim SUID ise:
vim -c ':!/bin/sh'
```

---

## SGID (Set Group ID) — Detaylı

#### Dosyalarda SGID

SGID bit set edilmiş bir binary çalıştırıldığında, process **dosya grubunun GID'si** ile çalışır.

```bash
ls -l /usr/bin/wall
# -rwxr-sr-x 1 root tty 19024 ... /usr/bin/wall
#        ^
#        SGID bit — process "tty" grubuyla çalışır
```

#### Dizinlerde SGID — Grup Inheritance

SGID'in **en yaygın ve faydalı** kullanımı dizinlerdedir. SGID set edilmiş bir dizinde oluşturulan yeni dosya ve dizinler, **oluşturanın primary group'u yerine dizinin grubunu** miras alır.

```
SGID olmadan:
  /shared/ (group: developers)
  ayber dosya oluşturur → dosya grubu: ayber (kendi primary group'u)

SGID ile:
  /shared/ (group: developers, SGID set)
  ayber dosya oluşturur → dosya grubu: developers (dizinin grubu)
```

#### Shared Directory Senaryosu

```bash
# Takim dizini olustur
mkdir /opt/project
groupadd developers
chgrp developers /opt/project

# SGID set et — yeni dosyalar "developers" grubunu miras alsin
chmod 2775 /opt/project
# 2 = SGID, 775 = rwxrwxr-x

# Kullanicilari gruba ekle
usermod -aG developers ayber
usermod -aG developers mehmet

# Ayber bir dosya oluşturur
su - ayber
touch /opt/project/app.py
ls -l /opt/project/app.py
# -rw-rw-r-- 1 ayber developers ...  ← grup "developers" (SGID sayesinde)

# Mehmet de okuyup yazabilir (aynı grupta)
su - mehmet
echo "# new code" >> /opt/project/app.py   # başarılı

# Alt dizinler de SGID'yi miras alir
mkdir /opt/project/src
ls -ld /opt/project/src
# drwxrwsr-x 2 ayber developers ...  ← SGID propagate oldu
```

#### SGID Ayarlama

```bash
chmod g+s directory/     # Symbolic
chmod 2775 directory/    # Octal (2 = SGID)

# Kaldirma
chmod g-s directory/
```

---

## Sticky Bit — Detaylı

Sticky bit set edilmiş bir dizinde, dosyaları **sadece dosya sahibi, dizin sahibi veya root** silebilir/yeniden adlandırabilir. Diğer kullanıcılar (yazma izni olsa bile) başkalarının dosyalarını silemez.

#### /tmp Örneği

```bash
ls -ld /tmp
# drwxrwxrwt 15 root root 4096 ... /tmp
#          ^
#          Sticky bit — 't' isaretli

# /tmp dizininde herkes dosya oluşturabilir (777)
# Ama sadece kendi dosyasini silebilir (sticky bit sayesinde)
```

```bash
# Senaryo: sticky bit olmadan
mkdir /tmp/nonsticky
chmod 777 /tmp/nonsticky

su - ayber
touch /tmp/nonsticky/ayber.txt

su - mehmet
rm /tmp/nonsticky/ayber.txt    # BASARILI — sticky bit yok, write izni yeterli

# Senaryo: sticky bit ile
mkdir /tmp/sticky
chmod 1777 /tmp/sticky          # 1 = sticky bit

su - ayber
touch /tmp/sticky/ayber.txt

su - mehmet
rm /tmp/sticky/ayber.txt
# rm: cannot remove '/tmp/sticky/ayber.txt': Operation not permitted
# Sticky bit sayesinde baskasinin dosyasini silemez
```

#### Neden Gerekli?

`/tmp` gibi **herkese açık yazma izni olan** dizinlerde, bir kullanıcının başkasının dosyalarını silmesini önlemek için **zorunludur**. Sticky bit olmadan herhangi bir kullanıcı `/tmp` içindeki tüm dosyaları silebilir — bu ciddi bir güvenlik ve kararlılık sorunudur.

#### Sticky Bit Ayarlama

```bash
chmod +t directory/      # Symbolic
chmod 1777 directory/    # Octal (1 = sticky)

# Kaldirma
chmod -t directory/
```

---

## ACL — Access Control Lists

Standart DAC (owner/group/other) yetersiz kaldığında **ACL** ile belirli kullanıcı ve gruplara özel izinler tanımlanabilir.

#### Neden Gerekli?

```
Sorun: file.txt sahibi ayber, grubu developers
       Ama "mehmet" (developers grubunda değil) de okuyabilmeli

DAC ile: imkansız (other'a izin vermek herkese açar)
ACL ile: sadece mehmet için read izni verilebilir
```

#### setfacl — ACL Ayarlama

```bash
# Belirli kullanıcıya izin ver
setfacl -m u:mehmet:r file.txt        # mehmet okuyabilir
setfacl -m u:mehmet:rw file.txt       # mehmet okuyup yazabilir

# Belirli gruba izin ver
setfacl -m g:testers:rx script.sh     # testers grubu calistirabilir

# Birden fazla kural
setfacl -m u:mehmet:rw,g:testers:r file.txt

# ACL kaldir
setfacl -x u:mehmet file.txt          # Mehmet'in ACL'ini kaldir
setfacl -b file.txt                   # Tum ACL'leri kaldir

# Recursive
setfacl -R -m u:mehmet:rx /opt/project/
```

#### getfacl — ACL Görüntüleme

```bash
getfacl file.txt
# # file: file.txt
# # owner: ayber
# # group: developers
# user::rw-              ← owner izni
# user:mehmet:rw-        ← mehmet için özel ACL
# group::r--             ← group izni
# group:testers:r-x      ← testers grubu için özel ACL
# mask::rwx              ← effective izin ust sınırı
# other::r--             ← other izni

# ls ciktisinda ACL var mi kontrol
ls -l file.txt
# -rw-rw-r--+ 1 ayber developers ...
#           ^
#           '+' isareti = ACL tanımlı
```

#### Mask — Effective İzin Sınırı

ACL mask değeri, owner hariç tüm ACL entry'lerinin **üst sınırını** belirler. Mask `r--` ise, gruba veya kullanıcıya `rwx` verilse bile effective izin `r--` olur.

```bash
# Mask ayarlama
setfacl -m m::rx file.txt    # Mask = r-x

getfacl file.txt
# user:mehmet:rw-       #effective:r--    ← mask r-x ile kisitlandi
# group:testers:rwx     #effective:r-x    ← mask r-x ile kisitlandi
```

> [!warning] chmod ve Mask
> `chmod` komutu ACL mask değerini **otomatik değiştirir**. ACL tanımlı bir dosyada `chmod g=r` yapılırsa mask `r--` olur ve tüm ACL entry'leri kısıtlanır. ACL kullanıyorsanız `chmod` ile dikkatli olun.

#### Default ACL — Dizinlerde Otomatik ACL

Default ACL, bir dizinde oluşturulan yeni dosya ve dizinlerin **otomatik olarak** alacağı ACL kurallarını belirler.

```bash
# Default ACL ayarla
setfacl -d -m u:mehmet:rwx /opt/project/
setfacl -d -m g:testers:rx /opt/project/

# Default ACL'i gormek
getfacl /opt/project/
# # file: opt/project/
# user::rwx
# group::rwx
# other::r-x
# default:user::rwx
# default:user:mehmet:rwx
# default:group::rwx
# default:group:testers:r-x
# default:mask::rwx
# default:other::r-x

# Simdi yeni dosya olustur
touch /opt/project/newfile.txt
getfacl /opt/project/newfile.txt
# user:mehmet:rwx     #effective:rw-   ← default ACL otomatik uygulandi
```

#### Pratik Senaryo: Web Sunucu Dizini

```bash
# Web dizini: www-data (apache) okuyabilmeli, developers yazabilmeli
mkdir /var/www/mysite
chown -R root:root /var/www/mysite

# Base izin
chmod 750 /var/www/mysite

# ACL ile ince ayar
setfacl -R -m u:www-data:rx /var/www/mysite
setfacl -R -m g:developers:rwx /var/www/mysite

# Default ACL (yeni dosyalar da aynı kuralları alsin)
setfacl -R -d -m u:www-data:rx /var/www/mysite
setfacl -R -d -m g:developers:rwx /var/www/mysite
```

---

## Linux Capabilities — Dosya Üzerinde

Geleneksel Unix modeli **ya root ya değil** ikiliğine dayanır. Capabilities bu yetkileri **granül parçalara** böler ve dosya bazında atanabilir.

> [!info] Docker Capabilities
> Docker'da capability yönetimi için → [[Docker Security#Linux Capabilities]]

#### SUID Yerine Capability Kullanımı

SUID root binary tüm root yetkilerini verir. Capability ile sadece **gereken yetki** verilebilir.

| Yaklaşım | Risk | Örnek |
|----------|------|-------|
| SUID root | Tüm root yetkileri | `chmod u+s /usr/bin/myapp` |
| Capability | Sadece gereken yetki | `setcap cap_net_bind_service+ep /usr/bin/myapp` |

#### setcap — Capability Atama

```bash
# Dosyaya capability ver
setcap cap_net_bind_service+ep /usr/bin/myapp
# +e = effective (aktif)
# +p = permitted (izin verilen)
# +i = inheritable (miras alinabilir)

# Örnek: ping için raw socket yetkisi (SUID yerine)
setcap cap_net_raw+ep /usr/bin/ping

# Örnek: 1024 alti port dinleme (SUID yerine)
setcap cap_net_bind_service+ep /usr/bin/node

# Örnek: tcpdump için paket yakalama
setcap cap_net_raw,cap_net_admin+ep /usr/sbin/tcpdump
```

#### getcap — Capability Görüntüleme

```bash
# Dosyanin capability'lerini gor
getcap /usr/bin/ping
# /usr/bin/ping cap_net_raw=ep

# Tum dosyalarin capability'lerini tara
getcap -r / 2>/dev/null

# Belirli dizin
getcap -r /usr/bin/ 2>/dev/null
```

#### Önemli Capability Listesi

| Capability | Verdiği Yetki |
|------------|---------------|
| `CAP_NET_BIND_SERVICE` | 1024 altı porta bind |
| `CAP_NET_RAW` | Raw socket (ping, tcpdump) |
| `CAP_NET_ADMIN` | Network yapılandırması |
| `CAP_DAC_OVERRIDE` | Dosya izin kontrolünü bypass |
| `CAP_DAC_READ_SEARCH` | Dosya okuma ve dizin arama izin bypass |
| `CAP_SYS_ADMIN` | mount, namespace ops (çok geniş — SUID kadar tehlikeli) |
| `CAP_SYS_PTRACE` | ptrace ile process debug |
| `CAP_SETUID` | UID değiştirme |
| `CAP_SETGID` | GID değiştirme |
| `CAP_CHOWN` | Dosya sahipliği değiştirme |
| `CAP_FOWNER` | Dosya sahibi kontrolünü bypass |
| `CAP_KILL` | Herhangi bir process'e signal gönderme |
| `CAP_SYS_MODULE` | Kernel modülü yükleme/kaldırma |

```bash
# Capability kaldir
setcap -r /usr/bin/myapp

# Process'in capability'lerini gor
cat /proc/self/status | grep Cap
# CapInh: Inheritable
# CapPrm: Permitted
# CapEff: Effective
# CapBnd: Bounding set
# CapAmb: Ambient

# Decode
capsh --decode=00000000a80425fb
```

> [!tip] En İyi Pratik
> SUID root binary oluşturmak yerine **capability** kullanmak her zaman daha güvenlidir. SUID root tüm yetkileri verirken, capability sadece gereken yetkileri verir. Saldırı yüzeyini önemli ölçüde küçültür.

---

## Filesystem Attributes — chattr ve lsattr

Standart izinlerin ötesinde, ext2/ext3/ext4 dosya sistemlerinde **özel nitelikler** (attributes) atanabilir.

#### chattr — Nitelik Değiştirme

```bash
# Immutable (degistirilemez) — root bile silemez/degistiremez
chattr +i important.conf
rm important.conf
# rm: cannot remove 'important.conf': Operation not permitted

# Root olarak bile:
sudo rm important.conf
# rm: cannot remove 'important.conf': Operation not permitted

# Immutable kaldirmak için önce niteliği kaldir
chattr -i important.conf
rm important.conf    # simdi başarılı

# Append-only — sadece ekleme yapılabilir, mevcut içerik degistirilemez
chattr +a /var/log/audit.log
echo "yeni log" >> /var/log/audit.log    # başarılı
echo "overwrite" > /var/log/audit.log    # Operation not permitted
rm /var/log/audit.log                    # Operation not permitted

# Compression
chattr +c largefile.dat     # Dosya seffaf olarak sikistirilir

# No dump — dump ile yedeklenmez
chattr +d tempfile.dat

# Secure deletion — silindikten sonra uzerine sifir yazılır
chattr +s secret.key
```

#### lsattr — Nitelikleri Görüntüleme

```bash
lsattr important.conf
# ----i--------e-- important.conf
#     ^
#     immutable

lsattr /var/log/audit.log
# -----a-------e-- /var/log/audit.log
#      ^
#      append-only

# Dizindeki tüm dosyalar
lsattr /etc/*.conf
```

#### Önemli Nitelikler

| Flag | Nitelik | Açıklama |
|------|---------|----------|
| `i` | Immutable | Değiştirilemez, silinemez, rename edilemez, link oluşturulamaz |
| `a` | Append-only | Sadece ekleme yapılabilir |
| `c` | Compressed | Şeffaf sıkıştırma |
| `d` | No dump | `dump` ile yedeklenmez |
| `s` | Secure delete | Silindikten sonra üzerine sıfır yaz |
| `u` | Undeletable | Silindiğinde içerik kurtarılabilir |
| `e` | Extents | ext4 extent formati (otomatik set edilir) |

> [!warning] Immutable ve Güvenlik
> `chattr +i` bir dosyayı root dahil herkesin değiştirmesini önler. Ama **root** kullanıcı `chattr -i` ile niteliği kaldırabilir. Bu nedenle `chattr` tek başına bir güvenlik mekanizması değildir — ama kazara değişikliklere karşı iyi bir koruma sağlar. Container ortamında `CAP_LINUX_IMMUTABLE` capability'si düşürülebilir.

---

## Container'da Permission Sorunları

Container ortamında dosya izinleri ek karmaşıklık katmanları içerir. En yaygın sorunlar UID eşleşmezliği ve volume mount ownership'tir.

#### Root vs Non-Root Container

```bash
# Root olarak çalışan container (varsayilan)
docker run -it ubuntu whoami
# root

# Problem: container içinde root → host'ta da root (user namespace yoksa)
# Container escape durumunda host'ta root yetkisi elde edilir
```

```dockerfile
# Non-root kullanıcı ile çalıştırma (onerilen)
FROM node:20-alpine

# Uygulama dizini
WORKDIR /app
COPY --chown=node:node . .

# Non-root kullanıcıya gec
USER node

CMD ["node", "server.js"]
```

#### Volume Mount Ownership Sorunu

```bash
# Host'ta: /data dizini uid=1000 (ayber) sahipliginde
ls -ld /data
# drwxr-xr-x 2 ayber ayber 4096 ... /data

# Container'da root (uid=0) olarak calisiyorsa:
docker run -v /data:/data ubuntu touch /data/test
# Basarili — root her seyi yazabilir

# Container'da non-root (uid=1000) olarak calisiyorsa:
docker run -v /data:/data --user 1000:1000 ubuntu touch /data/test
# Basarili — UID eslesiyor

# Container'da non-root (uid=999) olarak calisiyorsa:
docker run -v /data:/data --user 999:999 ubuntu touch /data/test
# Permission denied — UID eslesmiyor
```

#### UID Mapping Problemi

```
Host:                          Container:
uid=1000 (ayber)              uid=1000 (node)
                               ← aynı UID, farkli isim ama sorun yok

Host:                          Container:
uid=1000 (ayber)              uid=101 (nginx)
                               ← farkli UID = permission sorunu
```

```bash
# Cozum 1: Container içinde aynı UID kullanan kullanıcı olustur
FROM nginx:alpine
RUN adduser -u 1000 -D -H appuser
USER appuser

# Cozum 2: Entrypoint'te izinleri duzelt
#!/bin/bash
# entrypoint.sh
chown -R appuser:appuser /app/data
exec gosu appuser "$@"

# Cozum 3: Host'ta dizin iznini ayarla
mkdir /data && chown 101:101 /data   # nginx'in UID/GID'si
```

#### User Namespace Remapping

```bash
# /etc/docker/daemon.json
{
  "userns-remap": "default"
}

# Bu durumda:
# Container uid 0 → Host uid 100000
# Container uid 1 → Host uid 100001
# ...

# Volume mount'ta dikkat:
# Host'taki /data dizini uid 100000'e ait olmali
chown 100000:100000 /data
```

> [!tip] Init Container Patterni
> Kubernetes ortamında `initContainer` kullanılarak volume izinleri düzeltilir. Docker Compose'da ise `entrypoint` script'i ile aynı iş yapılabilir.

---

## Docker USER Directive ve Permission

Dockerfile'da `USER` directive'i container process'inin hangi kullanıcıyla çalışacağını belirler.

```dockerfile
FROM python:3.12-slim

# Sistem kullanicisi olustur (no home, no login)
RUN groupadd -r appgroup && \
    useradd -r -g appgroup -d /app -s /sbin/nologin appuser

# Uygulama dizini
WORKDIR /app

# Dosyalari kopyala ve sahipligi ayarla
COPY --chown=appuser:appgroup requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY --chown=appuser:appgroup . .

# Yazilmasi gereken dizinleri olustur
RUN mkdir -p /app/logs /app/tmp && \
    chown -R appuser:appgroup /app/logs /app/tmp

# Non-root kullanıcıya gec
USER appuser

# Port 1024 üstü (non-root port bind edebilir)
EXPOSE 8080

CMD ["python", "app.py"]
```

#### Permission Katmanları

```
Dockerfile build sirasinda:
  COPY → dosyalar root:root sahipliginde (--chown ile override edilebilir)
  RUN  → root olarak çalışır (USER'dan önceki satirlar)
  USER → bu satirdan sonra tüm RUN, CMD, ENTRYPOINT non-root

Runtime sirasinda:
  docker run --user 1000:1000 → Dockerfile'daki USER'i override eder
  docker run --cap-drop=ALL   → capability kisitlamasi
```

> [!warning] Build vs Runtime UID
> Dockerfile'daki `USER appuser` build sırasında oluşturulan kullanıcının adını kullanır. Eğer runtime'da `--user 1234:1234` verirseniz ve bu UID image içinde tanımlı değilse, process çalışmaya devam eder ama `whoami` komutu "I have no name!" gösterir. Dosya izinleri yine UID bazlı çalışır.

---

## Security Audit — Permission Tarama

Sistem güvenlik denetiminde dosya izinleri kritik bir kontrol noktasıdır.

#### SUID/SGID Binary Tarama

```bash
# Tum SUID binary'ler
find / -perm -4000 -type f 2>/dev/null | sort

# Tum SGID binary'ler
find / -perm -2000 -type f 2>/dev/null | sort

# SUID veya SGID (ikisi birden)
find / \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | sort

# Detayli çıktı (tarih ve boyut ile)
find / -perm -4000 -type f -exec ls -lh {} \; 2>/dev/null

# Bilinen listeyle karsilastir (baseline)
find / -perm -4000 -type f 2>/dev/null | sort > /tmp/suid_current.txt
diff /tmp/suid_baseline.txt /tmp/suid_current.txt
# Fark varsa → yeni SUID binary eklenmiş olabilir (alarm!)
```

#### World-Writable Dosya ve Dizin Tarama

```bash
# World-writable dosyalar (sticky bit olmadan)
find / -xdev -perm -0002 -type f 2>/dev/null

# World-writable dizinler (sticky bit olmadan — tehlikeli)
find / -xdev -perm -0002 -not -perm -1000 -type d 2>/dev/null

# /tmp ve /var/tmp haric
find / -xdev -perm -0002 -type f \
  -not -path "/tmp/*" -not -path "/var/tmp/*" 2>/dev/null
```

#### Sahipsiz Dosyalar

```bash
# Sahibi olmayan dosyalar (kullanıcı silinmis olabilir)
find / -xdev -nouser 2>/dev/null

# Grubu olmayan dosyalar
find / -xdev -nogroup 2>/dev/null
```

#### Hassas Dosya İzinleri

```bash
# /etc/shadow okunabilir mi? (sadece root:shadow olmali)
ls -l /etc/shadow
# -rw-r----- 1 root shadow ...  ← doğru

# SSH anahtarlari izinleri
ls -la ~/.ssh/
# id_rsa: 600 olmali
# id_rsa.pub: 644 olabilir
# authorized_keys: 600 olmali
# .ssh dizini: 700 olmali

# Home dizinleri izinleri
ls -ld /home/*/
# Herkes için okunabilir olmamali (750 veya 700 onerilen)

# Crontab izinleri
ls -la /etc/cron*
ls -la /var/spool/cron/crontabs/
```

#### Capability Tarama

```bash
# Capability set edilmiş dosyalar
getcap -r / 2>/dev/null

# Sonucu değerlendirme:
# /usr/bin/ping cap_net_raw=ep           ← normal
# /usr/bin/traceroute cap_net_raw=ep     ← normal
# /usr/local/bin/myapp cap_sys_admin=ep  ← SUPHELILI — incelenmeli
```

#### Tek Script ile Toplu Audit

```bash
#!/bin/bash
# permission_audit.sh

echo "=== SUID Binary'ler ==="
find / -perm -4000 -type f 2>/dev/null | sort

echo ""
echo "=== SGID Binary'ler ==="
find / -perm -2000 -type f 2>/dev/null | sort

echo ""
echo "=== World-Writable Dosyalar ==="
find / -xdev -perm -0002 -type f -not -path "/proc/*" -not -path "/sys/*" 2>/dev/null

echo ""
echo "=== World-Writable Dizinler (sticky bit yok) ==="
find / -xdev -perm -0002 -not -perm -1000 -type d -not -path "/proc/*" 2>/dev/null

echo ""
echo "=== Sahipsiz Dosyalar ==="
find / -xdev \( -nouser -o -nogroup \) 2>/dev/null

echo ""
echo "=== Capability Set Edilmis Dosyalar ==="
getcap -r / 2>/dev/null

echo ""
echo "=== /etc/shadow Izni ==="
ls -l /etc/shadow

echo ""
echo "=== SSH Dizin Izinleri ==="
ls -la /root/.ssh/ 2>/dev/null
for dir in /home/*/.ssh; do
    ls -la "$dir" 2>/dev/null
done
```

---

## Özet Tablosu

| Kavram | Komut | Örnek |
|--------|-------|-------|
| İzin değiştir | `chmod` | `chmod 755 file` / `chmod u+x file` |
| Sahip değiştir | `chown` | `chown user:group file` |
| Grup değiştir | `chgrp` | `chgrp developers dir/` |
| Varsayılan maske | `umask` | `umask 022` |
| SUID ayarla | `chmod u+s` | `chmod 4755 binary` |
| SGID ayarla | `chmod g+s` | `chmod 2775 dir/` |
| Sticky bit | `chmod +t` | `chmod 1777 dir/` |
| ACL ayarla | `setfacl` | `setfacl -m u:user:rwx file` |
| ACL gör | `getfacl` | `getfacl file` |
| Capability ata | `setcap` | `setcap cap_net_raw+ep binary` |
| Capability gör | `getcap` | `getcap -r /` |
| Nitelik ata | `chattr` | `chattr +i file` |
| Nitelik gör | `lsattr` | `lsattr file` |
| SUID tara | `find` | `find / -perm -4000 -type f` |
