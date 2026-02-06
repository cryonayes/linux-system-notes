# Linux Cryptography ve TLS

Modern sistemlerde veri güvenliğinin temeli **kriptografi** ve **TLS** (Transport Layer Security) protokoludur.
Bu not; simetrik/asimetrik şifreleme, hashing, dijital imza, PKI, TLS handshake, disk encryption ve pratik OpenSSL kullanımını kapsar.

> [!info] İlişkili Notlar
> - Container güvenliği ve secret management --> [[Docker Security]]
> - Network stack ve TCP/IP --> [[TCP-IP Stack Internals]]
> - Docker Compose ile TLS konfigürasyonu --> [[Docker Compose]]

---

## Symmetric vs Asymmetric Encryption

Kriptografide iki temel yaklaşım vardır: **simetrik** ve **asimetrik** şifreleme.

### Simetrik Şifreleme (Symmetric Encryption)

Aynı anahtar hem **şifreleme** hem **çözme** için kullanılır.

```
  Plaintext          Ciphertext          Plaintext
     |                   |                   |
     v                   v                   v
 [Encrypt] --key-->  ********  --key-->  [Decrypt]
     ^                                       ^
     |                                       |
     +--------  AYNI ANAHTAR (K)  -----------+
```

| Algoritma | Anahtar Boyutu | Blok Boyutu | Kullanım |
|-----------|---------------|-------------|----------|
| **AES-128** | 128 bit | 128 bit | Genel amaçlı, hızlı |
| **AES-256** | 256 bit | 128 bit | Yüksek güvenlik, disk encryption |
| **ChaCha20** | 256 bit | Stream | Mobil cihazlar, TLS 1.3 |
| 3DES | 168 bit | 64 bit | Eski, kullanımdan kaldırılıyor |

```bash
# AES-256-CBC ile dosya şifreleme
openssl enc -aes-256-cbc -salt -in secret.txt -out secret.enc -pbkdf2

# Cozme
openssl enc -d -aes-256-cbc -in secret.enc -out secret.txt -pbkdf2

# AES-256-GCM (authenticated encryption)
openssl enc -aes-256-gcm -in data.bin -out data.enc -K <hex_key> -iv <hex_iv>
```

> [!tip] AES Modları
> - **CBC** (Cipher Block Chaining): Klasik, IV gerektirir, authentication yok
> - **GCM** (Galois/Counter Mode): Hem şifreleme hem authentication (AEAD), TLS'te tercih edilir
> - **CTR** (Counter Mode): Paralel işlenebilir, hızlı

### Asimetrik Şifreleme (Asymmetric Encryption)

İki farklı anahtar kullanılır: **public key** (açık) ve **private key** (gizli).

```
  Gonderici (Alice)                     Alici (Bob)
       |                                     |
  Plaintext                             Ciphertext
       |                                     |
       v                                     v
  [Encrypt]                             [Decrypt]
       |                                     |
  Bob'un PUBLIC key                    Bob'un PRIVATE key
  (herkes biliyor)                     (sadece Bob biliyor)
```

| Algoritma | Anahtar Boyutu | Hız | Kullanım |
|-----------|---------------|-----|----------|
| **RSA** | 2048-4096 bit | Yavaş | Dijital imza, key exchange (eski) |
| **ECC (ECDSA/ECDH)** | 256-384 bit | Hızlı | TLS 1.3, SSH, modern protokoller |
| **Ed25519** | 256 bit | Çok hızlı | SSH key, dijital imza |

```bash
# RSA key pair oluşturma (2048 bit)
openssl genpkey -algorithm RSA -out private.pem -pkeyopt rsa_keygen_bits:2048

# Public key'i cikarma
openssl pkey -in private.pem -pubout -out public.pem

# ECC key pair oluşturma (P-256 curve)
openssl ecparam -genkey -name prime256v1 -out ec_private.pem

# Ed25519 key pair (SSH için)
ssh-keygen -t ed25519 -C "user@host" -f ~/.ssh/id_ed25519
```

### Key Exchange (Anahtar Değişimi)

Simetrik anahtarın güvenli şekilde paylaşımı için **key exchange** protokolleri kullanılır.

```
Alice                                    Bob
  |                                       |
  |--- g^a mod p (Alice public) --------> |
  |                                       |
  |<------ g^b mod p (Bob public) ------- |
  |                                       |
  Shared Secret = (g^b)^a mod p    Shared Secret = (g^a)^b mod p
  |                                       |
  +---- AYNI SHARED SECRET (K) ---------- +
```

| Yöntem | Kullanım | Not |
|--------|----------|-----|
| **DH** (Diffie-Hellman) | Klasik key exchange | Forward secrecy sağlar |
| **ECDH** (Elliptic Curve DH) | TLS 1.3, modern | Daha kısa key, aynı güvenlik |
| **X25519** | TLS 1.3 default | En hızlı, en güvenli |

> [!warning] RSA Key Exchange Kaldırıldı
> TLS 1.3'te RSA key exchange **tamamen kaldırıldı**. Çünkü RSA key exchange **forward secrecy** sağlamaz:
> sunucunun private key'i ele geçirilirse, önceki tüm trafik çözülebilir.
> TLS 1.3 sadece **ephemeral Diffie-Hellman** (DHE/ECDHE) kullanır.

---

## Hashing

Hash fonksiyonları **sabit uzunlukta** çıktı üreten tek yönlü fonksiyonlardır. Çözülemez, sadece doğrulanır.

```
  Girdi (herhangi boyut)         Cikti (sabit boyut)
  "merhaba"              --->    2cf24dba5fb0a30e26e83b2ac5b9e29e...
  "merhaba!"             --->    d7a8fbb307d7809469ca9abcb0082e4f...
                                 ^^ bir karakter bile degisse tamamen farkli
```

### Kriptografik Hash Fonksiyonları

| Algoritma | Çıktı Boyutu | Hız | Kullanım |
|-----------|-------------|-----|----------|
| **SHA-256** | 256 bit (32 byte) | Hızlı | Dosya bütünlüğü, sertifika, blockchain |
| **SHA-384** | 384 bit | Hızlı | TLS sertifikaları |
| **SHA-512** | 512 bit | Hızlı | Yüksek güvenlik gereken durumlar |
| MD5 | 128 bit | Çok hızlı | **Kullanılmamalı** (collision bulundu) |
| SHA-1 | 160 bit | Hızlı | **Kullanılmamalı** (collision bulundu) |

```bash
# SHA-256 hash hesaplama
echo -n "merhaba" | sha256sum
# 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824

# Dosya hash'i (integrity check)
sha256sum ubuntu-22.04.iso
# a1b2c3d4... ubuntu-22.04.iso

# OpenSSL ile hash
openssl dgst -sha256 myfile.txt
```

### Password Hashing

Şifre hashleme için **genel amaçlı** hash fonksiyonları (SHA-256) **uygun değildir**.
Çünkü çok hızlı çalışırlar ve brute-force saldırılarında saniyede milyarlarca deneme yapılabilir.

| Algoritma | Özellik | Tercih |
|-----------|---------|--------|
| **Argon2id** | Memory-hard, GPU-resistant, en modern | Birincil tercih |
| **bcrypt** | CPU-hard, cost factor ayarlanabilir | Yaygın, güvenilir |
| **scrypt** | Memory-hard | Argon2'den önce standart |
| PBKDF2 | İterasyon sayısı ayarlanabilir | Eski ama hala kabul görür |

```bash
# bcrypt ile şifre hashleme (Python)
python3 -c "
import bcrypt
password = b'gizli_şifre'
salt = bcrypt.gensalt(rounds=12)  # cost factor = 12
hashed = bcrypt.hashpw(password, salt)
print(hashed.decode())
# \$2b\$12\$LJ3m4ys3Lgm/JQ8HnGBJCeYz2.ePNQX7mGkF9aCEIvkDzKxEy1SaO
"

# argon2 ile şifre hashleme
python3 -c "
from argon2 import PasswordHasher
ph = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4)
hashed = ph.hash('gizli_şifre')
print(hashed)
# \$argon2id\$v=19\$m=65536,t=3,p=4\$<salt>\$<hash>
"
```

> [!tip] Hash Kullanım Alanları
> - **Integrity**: Dosya bütünlüğü doğrulama (SHA-256)
> - **Password storage**: Şifre saklama (Argon2id, bcrypt)
> - **Digital signature**: İmzalama öncesi özetleme (SHA-256)
> - **HMAC**: Mesaj doğrulama kodu (Hash-based Message Authentication Code)
> - **Key derivation**: Anahtardan alt anahtar türetme (HKDF)

---

## Digital Signature (Dijital İmza)

Dijital imza, bir mesajın **kim tarafından** gönderildiğini ve **değiştirilmediğini** garanti eder.

### Nasıl Çalışır?

```
IMZALAMA (Gonderici)
====================
                    +----------+
  Mesaj  ---------> |  SHA-256 | ---------> Hash
                    +----------+              |
                                              v
                                     +----------------+
                                     | RSA/ECDSA      |
  Private Key ------>                | ENCRYPT (sign) | -------> Imza (Signature)
                                     +----------------+

DOGRULAMA (Alici)
=================
                    +----------+
  Mesaj  ---------> |  SHA-256 | ---------> Hash_1
                    +----------+

                                     +-----------------+
  Imza (Signature) ----------------> | RSA/ECDSA       |
  Public Key ------->                | DECRYPT(verify) | -------> Hash_2
                                     +-----------------+

  Hash_1 == Hash_2  ?  -->  GECERLI (mesaj degismemis, gönderici dogrulandi)
  Hash_1 != Hash_2  ?  -->  GECERSIZ (mesaj degismis veya gönderici farkli)
```

### OpenSSL ile Dijital İmza

```bash
# 1. Private key olustur
openssl genpkey -algorithm RSA -out private.pem -pkeyopt rsa_keygen_bits:2048

# 2. Public key'i çıkar
openssl pkey -in private.pem -pubout -out public.pem

# 3. Mesaji imzala
echo -n "Onemli mesaj" > mesaj.txt
openssl dgst -sha256 -sign private.pem -out imza.bin mesaj.txt

# 4. Imzayi dogrula
openssl dgst -sha256 -verify public.pem -signature imza.bin mesaj.txt
# Verified OK
```

### ECDSA ile Dijital Imza

```bash
# ECC key pair
openssl ecparam -genkey -name prime256v1 -out ec_priv.pem
openssl ec -in ec_priv.pem -pubout -out ec_pub.pem

# Imzala
openssl dgst -sha256 -sign ec_priv.pem -out signature.der document.pdf

# Dogrula
openssl dgst -sha256 -verify ec_pub.pem -signature signature.der document.pdf
```

> [!info] Non-Repudiation
> Dijital imza **inkar edilemezlik** sağlar. İmzalayan kişi "ben imzalamadım" diyemez,
> çünkü sadece onun private key'i ile bu imza oluşturulabilir.

---

## PKI (Public Key Infrastructure)

PKI, açık anahtar kriptografisinin **güvene dayalı** bir sistemle yönetilmesini sağlar.
"Bu public key gerçekten bu kişiye mi ait?" sorusunun cevabını verir.

### PKI Bileşenler

```
Root CA (en ust otorite, self-signed)
  |
  |-- [imzalar]
  |
  v
Intermediate CA (ara otorite)
  |
  |-- [imzalar]
  |
  v
End-Entity Certificate (sunucu/istemci sertifikası)
  |
  |-- örnek.com
  |-- api.örnek.com
```

| Bileşen | Açıklama |
|---------|----------|
| **CA (Certificate Authority)** | Sertifika imzalayan güvenilir otorite |
| **Root CA** | En üst CA, kendi kendini imzalar (self-signed) |
| **Intermediate CA** | Root CA tarafından imzalanan ara CA |
| **End-Entity Certificate** | Sunucu veya istemciye verilen sertifika |
| **CRL (Certificate Revocation List)** | İptal edilen sertifikaların listesi |
| **OCSP** | Online sertifika durumu sorgulama protokolü |

### Certificate Chain (Sertifika Zinciri)

```
Browser/Client
    |
    |  "Bu sertifika geçerli mi?"
    |
    v
+------------------------------------------+
| End-Entity Certificate                   |
| Subject: örnek.com                       |
| Issuer: Intermediate CA                  |
| Imza: Intermediate CA'nin private key'i  |
+------------------------------------------+
    |  "Imzalayan CA geçerli mi?"
    v
+------------------------------------------+
| Intermediate CA Certificate              |
| Subject: Intermediate CA                 |
| Issuer: Root CA                          |
| Imza: Root CA'nin private key'i          |
+------------------------------------------+
    |  "Root CA taninir mi?"
    v
+------------------------------------------+
| Root CA Certificate (self-signed)        |
| Subject: Root CA                         |
| Issuer: Root CA                          |
| --> OS/Browser trust store'da mi?  EVET  |
+------------------------------------------+
    |
    v
  GUVENILIR (tüm zincir dogrulandi)
```

> [!warning] Root CA Güvenliği
> Root CA'nin private key'i **offline** tutulur (air-gapped HSM).
> Root CA doğrudan sertifika imzalamaz, bunun yerine Intermediate CA kullanılır.
> Root CA ihlal edilirse **tüm PKI zinciri çöker**.

---

## X.509 Sertifika Yapısı

X.509, dijital sertifikaların **standart formatıdır**. TLS, email imzalama, kod imzalama gibi alanlarda kullanılır.

### Sertifika Alanları

```
+--------------------------------------------------------+
|                 X.509 v3 Certificate                   |
+--------------------------------------------------------+
| Version:             3 (0x2)                           |
| Serial Number:       03:A1:B2:C3:...                   |
| Signature Algorithm: sha256WithRSAEncryption           |
|                                                        |
| Issuer:              CN=Let's Encrypt Authority X3     |
|                      O=Let's Encrypt                   |
|                      C=US                              |
|                                                        |
| Validity:                                              |
|   Not Before:        Jan  1 00:00:00 2025 UTC          |
|   Not After:         Apr  1 00:00:00 2025 UTC          |
|                                                        |
| Subject:             CN=örnek.com                      |
|                                                        |
| Subject Public Key Info:                               |
|   Algorithm:         id-ecPublicKey (P-256)            |
|   Public Key:        04:AB:CD:...                      |
|                                                        |
| X509v3 Extensions:                                     |
|   Subject Alternative Name (SAN):                      |
|     DNS: örnek.com                                     |
|     DNS: www.örnek.com                                 |
|     DNS: api.örnek.com                                 |
|                                                        |
|   Key Usage: Digital Signature, Key Encipherment       |
|   Extended Key Usage: TLS Web Server Authentication    |
|   Basic Constraints: CA:FALSE                          |
|                                                        |
| Signature Algorithm: sha256WithRSAEncryption           |
| Signature Value:     3A:4B:5C:...                      |
+--------------------------------------------------------+
```

| Alan | Açıklama |
|------|----------|
| **Subject** | Sertifika sahibi (CN=Common Name) |
| **Issuer** | Sertifikayı imzalayan CA |
| **Validity** | Geçerlilik başlangıç/bitiş tarihi |
| **SAN (Subject Alternative Name)** | Alternatif domain/IP adresleri |
| **Key Usage** | Anahtarın kullanım amacı (imza, şifreleme) |
| **Extended Key Usage** | Detaylı kullanım (server auth, client auth) |
| **Basic Constraints** | CA:TRUE ise bu bir CA sertifikasıdır |
| **Serial Number** | CA tarafından verilen benzersiz numara |

```bash
# Sertifika içeriğini inceleme
openssl x509 -in cert.pem -text -noout

# Sertifika SAN bilgilerini gorme
openssl x509 -in cert.pem -noout -ext subjectAltName

# Sertifika geçerlilik tarihlerini gorme
openssl x509 -in cert.pem -noout -dates

# Sertifika issuer ve subject
openssl x509 -in cert.pem -noout -issuer -subject

# Uzak sunucunun sertifikasini indirme
openssl s_client -connect örnek.com:443 -servername örnek.com < /dev/null 2>/dev/null \
  | openssl x509 -text -noout
```

> [!tip] SAN vs CN
> Modern browser'lar **CN (Common Name)** alanını artık kontrol etmiyor.
> Domain doğrulaması için **SAN (Subject Alternative Name)** alanı kullanılır.
> Sertifika oluşturulurken mutlaka SAN belirtilmelidir.

---

## TLS Handshake Detay

TLS, istemci ve sunucu arasında **güvenli kanal** oluşturur.
Handshake sırasında kimlik doğrulaması yapılır ve simetrik anahtar üzerinde uzlaşılır.

### TLS 1.2 Handshake

```
Client                                                Server
  |                                                      |
  |--- ClientHello ------------------------------------->|
  |    - TLS version (1.2)                               |
  |    - Client Random (28 byte)                         |
  |    - Cipher Suite listesi                            |
  |    - Compression methods                             |
  |    - SNI (Server Name Indication)                    |
  |                                                      |
  |<-- ServerHello --------------------------------------|
  |    - Secilen TLS version                             |
  |    - Server Random (28 byte)                         |
  |    - Secilen Cipher Suite                            |
  |    - Session ID                                      |
  |                                                      |
  |<-- Certificate --------------------------------------|
  |    - Sunucu sertifikası (X.509 chain)                |
  |                                                      |
  |<-- ServerKeyExchange --------------------------------|
  |    - DH/ECDH parametreleri (DHE/ECDHE kullaniliyorsa)|
  |    - Sunucu imzasi                                   |
  |                                                      |
  |<-- ServerHelloDone ----------------------------------|
  |                                                      |
  |--- ClientKeyExchange ------------------------------->|
  |    - Pre-master secret (RSA) veya                    |
  |    - Client DH/ECDH public value                     |
  |                                                      |
  |    [Her iki taraf Pre-Master Secret'tan              |
  |     Master Secret ve Session Key turetir]            |
  |                                                      |
  |--- ChangeCipherSpec -------------------------------->|
  |--- Finished (encrypted) ---------------------------->|
  |                                                      |
  |<-- ChangeCipherSpec ---------------------------------|
  |<-- Finished (encrypted) -----------------------------|
  |                                                      |
  |<=== Encrypted Application Data (HTTP, etc.) ========>|
  |                                                      |
  |    Toplam: 2-RTT (2 round trip)                      |
```

### TLS 1.3 Handshake

```
Client                                              Server
  |                                                    |
  |--- ClientHello ----------------------------------->|
  |    - TLS version (1.3)                             |
  |    - Client Random                                 |
  |    - Cipher Suite listesi                          |
  |    - Key Share (ECDHE public value)   <-- FARK!    |
  |    - Supported Groups (X25519, P-256)              |
  |    - Signature Algorithms                          |
  |    - SNI                                           |
  |                                                    |
  |<-- ServerHello ------------------------------------|
  |    - Server Random                                 |
  |    - Secilen Cipher Suite                          |
  |    - Key Share (ECDHE public value)                |
  |                                                    |
  |    [Handshake key'ler turetilir]                   |
  |                                                    |
  |<-- {EncryptedExtensions} --------------------------|  <-- şifreli!
  |<-- {Certificate} ----------------------------------|  <-- şifreli!
  |<-- {CertificateVerify} ----------------------------|  <-- şifreli!
  |<-- {Finished} -------------------------------------|  <-- şifreli!
  |                                                    |
  |--- {Finished} ------------------------------------>|
  |                                                    |
  |<=== Encrypted Application Data ===================>|
  |                                                    |
  |    Toplam: 1-RTT (1 round trip)                    |
```

### TLS 1.2 vs TLS 1.3 Karşılaştırma

| Özellik | TLS 1.2 | TLS 1.3 |
|---------|---------|---------|
| **Handshake RTT** | 2-RTT | 1-RTT (0-RTT resumption) |
| **Key Exchange** | RSA, DHE, ECDHE | Sadece ECDHE (ephemeral) |
| **Forward Secrecy** | Opsiyonel | Zorunlu |
| **Sertifika** | Açık metin | Şifreli gönderilir |
| **Cipher Suite sayisi** | 300+ | 5 adet |
| **Compression** | Desteklenir | Kaldırıldı (CRIME atak) |
| **Renegotiation** | Desteklenir | Kaldırıldı |
| **0-RTT** | Yok | Var (opsiyonel, replay riski) |

### TLS 1.3 Cipher Suite'ler

TLS 1.3'te sadece **5 cipher suite** desteklenir:

```
TLS_AES_256_GCM_SHA384        (zorunlu)
TLS_AES_128_GCM_SHA256        (zorunlu)
TLS_CHACHA20_POLY1305_SHA256  (onerilen)
TLS_AES_128_CCM_SHA256
TLS_AES_128_CCM_8_SHA256
```

> [!warning] Kaldırılan Özellikler (TLS 1.3)
> - RSA key exchange (forward secrecy yok)
> - CBC mode cipher'lar (padding oracle atakları)
> - RC4, 3DES, DES (zayıf algoritmalar)
> - MD5, SHA-1 (zayıf hash)
> - Static DH/ECDH (forward secrecy yok)
> - Compression (CRIME atağı)
> - Renegotiation (complexity ve atak yüzey alanı)

---

## TLS 1.3 İyileştirmeleri

### 1-RTT Handshake

TLS 1.2'de handshake **2 round-trip** gerektirirken, TLS 1.3'te **1 round-trip** yeterlidir.
Client ilk mesajda key share bilgisini de gönderdiği için server hemen simetrik anahtar üretebilir.

### 0-RTT (Early Data)

Daha önce bağlantı kurulmuş bir sunucuya **sıfır round-trip** ile veri gönderilebilir.

```
Client                                 Server
  |                                      |
  |--- ClientHello + Early Data -------->|   <-- 0-RTT: ilk pakette şifrelenmiş veri
  |    (önceki session'dan PSK ile)      |
  |                                      |
  |<-- ServerHello + Finished -----------|
  |                                      |
  |<=== Application Data ===============>|
```

> [!warning] 0-RTT Replay Riski
> 0-RTT verisi **replay attack**'a açıktır. Saldırgan aynı paketi tekrar gönderebilir.
> Bu nedenle 0-RTT sadece **idempotent** istekler (GET gibi) için kullanılmalıdır.
> State değiştiren işlemler (POST, PUT, DELETE) için 0-RTT **asla** kullanılmamalıdır.

### Forward Secrecy (İleri Gizlilik)

TLS 1.3'te **her bağlantı** için yeni bir ephemeral key pair oluşturulur.
Sunucu private key'i ele geçirilse bile geçmiş trafik çözülemez.

```
Baglanti 1: Ephemeral Key A  --->  Session Key 1  (bağlantı bittikten sonra A silinir)
Baglanti 2: Ephemeral Key B  --->  Session Key 2  (bağlantı bittikten sonra B silinir)
Baglanti 3: Ephemeral Key C  --->  Session Key 3  (bağlantı bittikten sonra C silinir)

Sunucu private key ele gecirilse bile:
  - Ephemeral key'ler bellekten silinmis
  - Onceki session key'ler turetilEMEZ
  - Gecmis trafik COZULEMEZ
```

---

## OpenSSL CLI

OpenSSL, kriptografik işlemler için **standart komut satırı aracı**dır.

### Key Generation (Anahtar Oluşturma)

```bash
# RSA 4096-bit private key olustur
openssl genpkey -algorithm RSA -out server.key -pkeyopt rsa_keygen_bits:4096

# RSA private key'i parola ile koru
openssl genpkey -algorithm RSA -out server.key -aes256 -pkeyopt rsa_keygen_bits:4096

# ECC private key (P-256)
openssl ecparam -genkey -name prime256v1 | openssl ec -out server-ec.key

# Ed25519 private key
openssl genpkey -algorithm ED25519 -out ed25519.key

# Public key cikarma
openssl pkey -in server.key -pubout -out server.pub
```

### CSR (Certificate Signing Request) Oluşturma

```bash
# Interaktif CSR oluşturma
openssl req -new -key server.key -out server.csr

# Tek satirda CSR oluşturma
openssl req -new -key server.key -out server.csr \
  -subj "/C=TR/ST=Istanbul/L=Istanbul/O=Sirketim/CN=örnek.com"

# SAN ile CSR oluşturma (config dosyasi ile)
cat > csr.conf << 'EOF'
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no

[dn]
C = TR
ST = Istanbul
L = Istanbul
O = Sirketim
CN = örnek.com

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = örnek.com
DNS.2 = www.örnek.com
DNS.3 = api.örnek.com
IP.1 = 10.0.0.1
EOF

openssl req -new -key server.key -out server.csr -config csr.conf

# CSR içeriğini inceleme
openssl req -in server.csr -text -noout
```

### Self-Signed Sertifika Oluşturma

```bash
# Tek komutla self-signed sertifika (key + cert)
openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt \
  -days 365 -nodes \
  -subj "/C=TR/ST=Istanbul/L=Istanbul/O=Sirketim/CN=örnek.com"

# SAN ile self-signed sertifika
openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt \
  -days 365 -nodes -config csr.conf -extensions v3_req

# Mevcut key ile self-signed sertifika
openssl req -x509 -key server.key -out server.crt -days 365 \
  -subj "/C=TR/ST=Istanbul/CN=örnek.com"
```

### Mini CA Oluşturma (Internal PKI)

```bash
# 1. Root CA olustur
openssl genpkey -algorithm RSA -out ca.key -pkeyopt rsa_keygen_bits:4096
openssl req -x509 -new -key ca.key -out ca.crt -days 3650 \
  -subj "/C=TR/O=Internal CA/CN=My Root CA"

# 2. Sunucu key + CSR olustur
openssl genpkey -algorithm RSA -out server.key -pkeyopt rsa_keygen_bits:2048
openssl req -new -key server.key -out server.csr \
  -subj "/C=TR/O=Sirketim/CN=myserver.local"

# 3. CA ile sunucu sertifikasini imzala
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 365 \
  -extfile <(printf "subjectAltName=DNS:myserver.local,DNS:*.myserver.local")

# 4. Sertifika zincirini dogrula
openssl verify -CAfile ca.crt server.crt
# server.crt: OK
```

### Sertifika İnceleme ve Test

```bash
# Sertifika detaylarini gorme
openssl x509 -in server.crt -text -noout

# Sertifika fingerprint
openssl x509 -in server.crt -fingerprint -sha256 -noout

# Sertifika PEM -> DER donusumu
openssl x509 -in cert.pem -outform DER -out cert.der

# DER -> PEM donusumu
openssl x509 -in cert.der -inform DER -outform PEM -out cert.pem

# Uzak sunucu sertifikasini kontrol etme
openssl s_client -connect örnek.com:443 -servername örnek.com < /dev/null

# TLS versiyonunu zorlama
openssl s_client -connect örnek.com:443 -tls1_3

# Cipher suite'leri test etme
openssl s_client -connect örnek.com:443 -cipher 'ECDHE-RSA-AES256-GCM-SHA384'

# Sertifika zincirini gorme
openssl s_client -connect örnek.com:443 -showcerts < /dev/null
```

> [!tip] s_client Hata Ayıklama
> `openssl s_client` TLS bağlantı sorunlarını teşhis etmek için en güçlü araçtır:
> - Sertifika geçerlilik kontrolü
> - Desteklenen cipher suite'ler
> - TLS versiyon uyumsuzlukları
> - Sertifika zinciri sorunları

---

## mTLS (Mutual TLS)

Normal TLS'te sadece **sunucu** kimliğini kanıtlar. mTLS'te **hem sunucu hem istemci** birbirini doğrular.

### Normal TLS vs mTLS

```
Normal TLS (tek yonlu):
========================
Client ---- "Sen kimsin?" ----> Server
Client <--- Sertifika --------- Server   (sunucu kanitlar)
Client ---- OK, guveniyorum --> Server

mTLS (karsilikli):
==================
Client ---- "Sen kimsin?" ----> Server
Client <--- Sertifika --------- Server   (sunucu kanitlar)
Client <--- "Sen kimsin?" ----- Server   (sunucu da sorar)
Client ---- Sertifika -------> Server    (istemci kanitlar)
Client <=== Sifreli Trafik ===> Server
```

### Ne Zaman Kullanılır?

| Senaryo | Açıklama |
|---------|----------|
| **Microservice arası iletişim** | Service mesh (Istio, Linkerd) |
| **Container arası güvenli kanal** | Aynı cluster'da bile şifreleme |
| **API gateway + backend** | Backend'in de client'ı doğrulaması |
| **Zero Trust Architecture** | "Hiçbir şeye güvenmiyoruz" prensibi |
| **IoT cihaz doğrulama** | Her cihazın kendi sertifikası |

### mTLS Kurulumu

```bash
# 1. CA olustur (ortak güven noktasi)
openssl genpkey -algorithm RSA -out ca.key -pkeyopt rsa_keygen_bits:4096
openssl req -x509 -new -key ca.key -out ca.crt -days 3650 \
  -subj "/CN=Internal mTLS CA"

# 2. Sunucu sertifikası
openssl genpkey -algorithm RSA -out server.key -pkeyopt rsa_keygen_bits:2048
openssl req -new -key server.key -out server.csr -subj "/CN=myserver"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 365

# 3. İstemci sertifikası
openssl genpkey -algorithm RSA -out client.key -pkeyopt rsa_keygen_bits:2048
openssl req -new -key client.key -out client.csr -subj "/CN=myclient"
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out client.crt -days 365

# 4. mTLS ile bağlantı testi
# Sunucu tarafi (başka bir terminalde)
openssl s_server -accept 8443 -cert server.crt -key server.key \
  -CAfile ca.crt -Verify 1

# İstemci tarafi
openssl s_client -connect localhost:8443 -cert client.crt -key client.key \
  -CAfile ca.crt
```

### Nginx mTLS Konfigurasyonu

```
server {
    listen 443 ssl;
    server_name myserver.local;

    # Sunucu sertifikası
    ssl_certificate     /etc/nginx/ssl/server.crt;
    ssl_certificate_key /etc/nginx/ssl/server.key;

    # Client sertifika doğrulama (mTLS)
    ssl_client_certificate /etc/nginx/ssl/ca.crt;
    ssl_verify_client on;      # mTLS zorunlu
    ssl_verify_depth 2;

    location / {
        proxy_pass http://backend:8080;
        proxy_set_header X-Client-CN $ssl_client_s_dn_cn;
    }
}
```

---

## dm-crypt / LUKS (Disk Encryption)

Linux'ta **full disk encryption** için `dm-crypt` kernel modülü ve `LUKS` (Linux Unified Key Setup) formatı kullanılır.

### Mimari

```
Kullanici Alani
+------------------------------------------------------+
|  Uygulama (read/write /mnt/encrypted)                |
+------------------------------------------------------+
       |
       v
+------------------------------------------------------+
|  Filesystem (ext4, xfs, btrfs)                       |
+------------------------------------------------------+
       |
       v
+------------------------------------------------------+
|  Device Mapper (/dev/mapper/secure_disk)             |
|  +------------------------------------------------+  |
|  |  dm-crypt (kernel modülü)                      |  |
|  |  - Sifreleme: AES-256-XTS                      |  |
|  |  - Anahtar: LUKS header'dan                    |  |
|  +------------------------------------------------+  |
+------------------------------------------------------+
       |
       v
+------------------------------------------------------+
|  Block Device (/dev/sdb1) - şifreli veri             |
+------------------------------------------------------+
```

### LUKS Header Yapısı

```
+---------------------------------------------------+
|  LUKS Header                                      |
|  - Magic: LUKS\xba\xbe                            |
|  - Version: 2                                     |
|  - Cipher: aes-xts-plain64                        |
|  - Hash: sha256                                   |
|  - Key Slots (0-7): 8 farkli parola/key desteği   |
|  - Master Key (encrypted)                         |
+---------------------------------------------------+
|  Key Material                                     |
+---------------------------------------------------+
|  Encrypted Data                                   |
|  ...                                              |
+---------------------------------------------------+
```

### cryptsetup Komutları

```bash
# 1. LUKS formatlama (DIKKAT: disk silinir!)
sudo cryptsetup luksFormat /dev/sdb1
# Are you süre? YES (büyük harfle)
# Parola gir

# LUKS2 formatlama (detayli)
sudo cryptsetup luksFormat --type luks2 \
  --cipher aes-xts-plain64 \
  --key-size 512 \
  --hash sha256 \
  --iter-time 5000 \
  /dev/sdb1

# 2. Sifreli diski acma (mapping)
sudo cryptsetup luksOpen /dev/sdb1 secure_disk
# veya
sudo cryptsetup open --type luks /dev/sdb1 secure_disk

# 3. Filesystem oluşturma
sudo mkfs.ext4 /dev/mapper/secure_disk

# 4. Mount etme
sudo mount /dev/mapper/secure_disk /mnt/encrypted

# 5. Kullanim bittikten sonra kapatma
sudo umount /mnt/encrypted
sudo cryptsetup luksClose secure_disk
```

### LUKS Key Management

```bash
# Mevcut key slot'lari gorme
sudo cryptsetup luksDump /dev/sdb1

# Yeni parola ekleme (8 slot'a kadar)
sudo cryptsetup luksAddKey /dev/sdb1
# Once mevcut parolayi gir, sonra yeni parolayi gir

# Parola silme
sudo cryptsetup luksRemoveKey /dev/sdb1
# Silinecek parolayi gir

# Key file ile kullanım (otomasyon için)
dd if=/dev/urandom of=/root/keyfile bs=4096 count=1
chmod 600 /root/keyfile
sudo cryptsetup luksAddKey /dev/sdb1 /root/keyfile

# Key file ile acma
sudo cryptsetup luksOpen /dev/sdb1 secure_disk --key-file /root/keyfile
```

### Boot'ta Otomatik Açma

```bash
# /etc/crypttab dosyasi
# <name>       <device>            <keyfile>         <options>
secure_disk    /dev/sdb1           /root/keyfile     luks

# /etc/fstab dosyasi
/dev/mapper/secure_disk  /mnt/encrypted  ext4  defaults  0  2
```

> [!warning] Key File Güvenliği
> Key file kullanılarsa, key file'ın bulunduğu disk de şifreli olmalıdır.
> Aksi halde şifreli diski koruma anlamı kalmaz. Root filesystem'i de LUKS ile şifrelemek en güvenli yaklaşımdır.

---

## /dev/random vs /dev/urandom

Kriptografik işlemler için **kaliteli rastgelelik** (entropy) gerekir.

### Karşılaştırma

```
+----------------------------------+
|  Hardware Noise Sources          |
|  - Klavye zamanlama              |
|  - Mouse hareketi                |
|  - Disk I/O zamanlama            |
|  - Network interrupt'lar         |
|  - CPU jitter (RDRAND/RDSEED)    |
+----------------------------------+
          |
          v
+----------------------------------+
|  Kernel Entropy Pool             |
|  (CSPRNG - ChaCha20 tabanli)     |
+----------------------------------+
     |              |
     v              v
/dev/random    /dev/urandom
```

| Özellik | /dev/random | /dev/urandom |
|---------|-------------|-------------|
| **Blocking** | Eski kernel'larda entropy düşükse bloklar | Asla bloklamaz |
| **Hız** | Yavaş olabilir (blocking) | Hızlı |
| **Güvenlik** | Kernel 5.18+ sonrası urandom ile aynı | Kriptografik olarak güvenli |
| **Kullanım** | Eski alışkı, artık gereksiz | **Tercih edilen** |

```bash
# 16 byte rastgele veri
head -c 16 /dev/urandom | xxd

# 32 byte hex encoded rastgele değer
openssl rand -hex 32

# Entropy havuz durumunu kontrol etme
cat /proc/sys/kernel/random/entropy_avail
# 256 (minimum güvenli seviye)

# Rastgele şifre oluşturma
openssl rand -base64 24
```

### getrandom() Syscall

```
getrandom(buf, buflen, flags)

flags:
  0           --> /dev/urandom gibi, boot sonrasi seed'lenene kadar bloklar
  GRND_RANDOM --> /dev/random gibi (artik gereksiz)
  GRND_NONBLOCK --> Bloklamadan hata dondur
```

> [!info] Modern Linux'ta Fark Kalmadı
> Linux 5.18+ sürümlerde `/dev/random` ve `/dev/urandom` **aynı CSPRNG**'yi kullanır.
> `/dev/random` artık entropy azaldığında bloklamaz.
> **Her zaman `/dev/urandom` veya `getrandom()` kullanın.**

---

## Let's Encrypt + ACME Protokolü

Let's Encrypt, **ücretsiz** TLS sertifikası sağlayan bir CA'dir.
ACME (Automatic Certificate Management Environment) protokolünü kullanır.

### ACME Challenge Türleri

| Challenge | Yöntem | Kullanım |
|-----------|--------|----------|
| **HTTP-01** | `http://<domain>/.well-known/acme-challenge/<token>` | Web sunucuları (en yaygın) |
| **DNS-01** | `_acme-challenge.<domain>` TXT record | Wildcard sertifikalar, DNS API gereken durumlar |
| **TLS-ALPN-01** | TLS bağlantısı üzerinden | Sadece 443 portu aciksa |

### ACME Akisi (HTTP-01)

```
Certbot                    Let's Encrypt          Domain (örnek.com)
   |                            |                        |
   |--- Sertifika isteği ------>|                        |
   |    (domain: örnek.com)     |                        |
   |                            |                        |
   |<-- Challenge token --------|                        |
   |    (abc123xyz...)          |                        |
   |                            |                        |
   |--- Token'i yerlestir ------------------------------>|
   |    /.well-known/acme-challenge/abc123xyz            |
   |                            |                        |
   |--- "Hazirim" ------------> |                        |
   |                            |                        |
   |                            |--- HTTP GET ---------->|
   |                            |    /.well-known/       |
   |                            |    acme-challenge/     |
   |                            |    abc123xyz           |
   |                            |                        |
   |                            |<-- Token dogrulandi ---|
   |                            |                        |
   |<-- Sertifika (90 gun) -----|                        |
   |                            |                        |
```

### Certbot Kullanimi

```bash
# Certbot kurulumu
sudo apt install certbot python3-certbot-nginx  # Nginx için
sudo apt install certbot python3-certbot-apache # Apache için

# Nginx ile otomatik sertifika alma ve konfigürasyonu
sudo certbot --nginx -d örnek.com -d www.örnek.com

# Standalone mod (web sunucu yoksa veya durdurabilirsek)
sudo certbot certonly --standalone -d örnek.com

# Webroot mod (web sunucu çalışırken)
sudo certbot certonly --webroot -w /var/www/html -d örnek.com

# Wildcard sertifika (DNS-01 challenge zorunlu)
sudo certbot certonly --manual --preferred-challenges dns \
  -d "*.örnek.com" -d örnek.com

# Sertifika yenileme (dry-run test)
sudo certbot renew --dry-run

# Gercek yenileme
sudo certbot renew
```

### Otomatik Renewal

```bash
# Certbot otomatik renewal timer'i kontrol et
sudo systemctl status certbot.timer
sudo systemctl list-timers | grep certbot

# Manuel cron job (eger timer yoksa)
# /etc/cron.d/certbot
0 0,12 * * * root certbot renew --quiet --post-hook "systemctl reload nginx"
```

### Sertifika Dosyalari

```bash
# Certbot sertifika dizini
ls /etc/letsencrypt/live/örnek.com/

# Dosyalar:
# cert.pem       -> Sunucu sertifikası
# chain.pem      -> Intermediate CA sertifikası
# fullchain.pem  -> cert.pem + chain.pem (Nginx/Apache için bu kullanılır)
# privkey.pem    -> Private key
```

> [!tip] Let's Encrypt Limitleri
> - Sertifika süresi: **90 gun** (otomatik yenileme önemli)
> - Rate limit: Aynı domain için haftada **50 sertifika**
> - SAN limiti: Bir sertifikada **100 domain**
> - Wildcard: Sadece **DNS-01** challenge ile mumkun

---

## Container'da TLS

Container ortamlarinda TLS sertifika yönetimi farkli yaklaşımlar gerektirir.

### Sertifika Mount Etme

```yaml
# docker-compose.yml
services:
  web:
    image: nginx:alpine
    ports:
      - "443:443"
    volumes:
      - ./certs/fullchain.pem:/etc/nginx/ssl/cert.pem:ro
      - ./certs/privkey.pem:/etc/nginx/ssl/key.pem:ro
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
```

```bash
# Docker run ile sertifika mount
docker run -d \
  -p 443:443 \
  -v /etc/letsencrypt/live/örnek.com/fullchain.pem:/etc/ssl/cert.pem:ro \
  -v /etc/letsencrypt/live/örnek.com/privkey.pem:/etc/ssl/key.pem:ro \
  nginx:alpine
```

### Docker Secrets (Swarm Mode)

```bash
# Secret oluşturma
docker secret create server_cert ./server.crt
docker secret create server_key ./server.key

# Service'te kullanma
docker service create \
  --name web \
  --secret server_cert \
  --secret server_key \
  nginx:alpine
# Secret'lar /run/secrets/ altında görünür
```

```yaml
# docker-compose.yml (Swarm mode)
services:
  web:
    image: nginx:alpine
    secrets:
      - server_cert
      - server_key

secrets:
  server_cert:
    file: ./certs/server.crt
  server_key:
    file: ./certs/server.key
```

### Reverse Proxy TLS Termination

TLS islemini **reverse proxy** yapar, backend container'lar **duz HTTP** konusur.

```
Internet (HTTPS)          Reverse Proxy              Backend Container'lar
     |                         |                           |
     |--- TLS (şifreli) ------>|                           |
     |                         |--- HTTP (duz) ----------->|  app:8080
     |                         |--- HTTP (duz) ----------->|  api:3000
     |                         |                           |
     |<-- TLS (şifreli) -------|<-- HTTP (duz) ------------|
     |                         |                           |
     TLS BURADA SONLANIR       Nginx/Traefik/HAProxy       Sifreleme yok
```

```yaml
# docker-compose.yml - TLS Termination örneği
services:
  reverse-proxy:
    image: nginx:alpine
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/ssl:ro
    networks:
      - frontend
      - backend

  app:
    image: myapp:latest
    expose:
      - "8080"     # sadece internal network'te erişim
    networks:
      - backend

networks:
  frontend:
  backend:
    internal: true   # dis erişim yok
```

```
# nginx.conf - TLS termination
server {
    listen 80;
    return 301 https://$host$request_uri;   # HTTP -> HTTPS redirect
}

server {
    listen 443 ssl http2;
    server_name örnek.com;

    ssl_certificate     /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;

    # Modern TLS konfigürasyonu
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;

    # HSTS
    add_header Strict-Transport-Security "max-age=63072000" always;

    location / {
        proxy_pass http://app:8080;      # Backend'e duz HTTP
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

> [!info] mTLS vs TLS Termination
> TLS termination **dis trafik** için yeterlidir. Ancak **container'lar arasi** iletisimde
> de şifreleme gerekiyorsa (zero trust), service mesh (Istio, Linkerd) veya
> mTLS konfigürasyonu kullanilmalidir.

---

## Pratik: ssh-keygen ve GPG Temelleri

### ssh-keygen

SSH anahtar çifti oluşturma ve yonetme aracı.

```bash
# Ed25519 key oluşturma (onerilen)
ssh-keygen -t ed25519 -C "user@hostname" -f ~/.ssh/id_ed25519

# RSA 4096-bit key (uyumluluk için)
ssh-keygen -t ed25519 -C "user@hostname"
ssh-keygen -t rsa -b 4096 -C "user@hostname"

# Passphrase değiştirme
ssh-keygen -p -f ~/.ssh/id_ed25519

# Public key'i sunucuya kopyalama
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@server

# Key fingerprint gorme
ssh-keygen -lf ~/.ssh/id_ed25519.pub
# 256 SHA256:AbCdEf... user@hostname (ED25519)

# Known hosts doğrulama
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

### SSH Key Turleri Karsilastirma

| Tur | Boyut | Guvenlik | Hiz | Oneri |
|-----|-------|----------|-----|-------|
| **Ed25519** | 256 bit | Cok yüksek | Cok hızlı | Birincil tercih |
| **ECDSA** | 256-521 bit | Yuksek | Hizli | Uyumluluk için |
| **RSA** | 2048-4096 bit | Yuksek (4096) | Yavas | Eski sistemler için |
| DSA | 1024 bit | Dusuk | - | **Kullanilmamali** |

### GPG (GNU Privacy Guard) Temelleri

GPG, **PGP** (Pretty Good Privacy) standardinin açık kaynak uygulamasidir.
Email şifreleme, dosya imzalama ve yazılım paketi doğrulama için kullanılır.

```bash
# GPG key pair oluşturma
gpg --full-generate-key
# Algoritma: RSA and RSA (default)
# Key boyutu: 4096
# Gecerlilik: 2y (2 yil)
# Isim ve email gir

# Key'leri listeleme
gpg --list-keys
gpg --list-secret-keys --keyid-format=long

# Public key export
gpg --armor --export user@email.com > public.gpg

# Public key import
gpg --import someone_public.gpg

# Dosya şifreleme (alicinin public key'i ile)
gpg --encrypt --recipient user@email.com secret.txt
# Cikti: secret.txt.gpg

# Dosya çözme
gpg --decrypt secret.txt.gpg > secret.txt

# Dosya imzalama
gpg --sign document.pdf           # Binary signature (document.pdf.gpg)
gpg --clearsign message.txt       # Clear text signature
gpg --detach-sign document.pdf    # Ayri imza dosyasi (document.pdf.sig)

# Imza doğrulama
gpg --verify document.pdf.sig document.pdf

# Simetrik şifreleme (parola ile, key pair olmadan)
gpg --symmetric --cipher-algo AES256 secret.txt
gpg --decrypt secret.txt.gpg
```

### GPG ile Git Commit Imzalama

```bash
# GPG key ID'yi bul
gpg --list-secret-keys --keyid-format=long
# sec   rsa4096/ABC1234567890DEF ...

# Git'e GPG key tanımla
git config --global user.signingkey ABC1234567890DEF
git config --global commit.gpgsign true

# Imzali commit
git commit -S -m "Imzali commit mesajı"

# Imzayi dogrula
git log --show-signature -1
```

---

## Ozet Tablosu

| Konu | Anahtar Kavram | Tipik Kullanim |
|------|---------------|----------------|
| **Simetrik Sifreleme** | Aynı anahtar, AES-256-GCM | TLS veri aktarimi, disk encryption |
| **Asimetrik Sifreleme** | Public/private key, RSA/ECC | Key exchange, dijital imza |
| **Hashing** | Tek yonlu, sabit boyut | Password storage (Argon2), integrity |
| **Dijital Imza** | Private key ile imza, public key ile dogrula | Sertifika, kod imzalama |
| **PKI** | CA, certificate chain | TLS sertifika yönetimi |
| **X.509** | SAN, key usage, validity | TLS sertifika formati |
| **TLS 1.3** | 1-RTT, forward secrecy | HTTPS, güvenli iletişim |
| **mTLS** | Karsilikli doğrulama | Microservice, zero trust |
| **LUKS** | dm-crypt, cryptsetup | Full disk encryption |
| **Let's Encrypt** | ACME, certbot | Ucretsiz TLS sertifika |
| **OpenSSL** | Key gen, CSR, s_client | Sertifika işlemleri |
| **GPG** | PGP, email/dosya şifreleme | Imzalama, şifreleme |
