Linux kernel'inde network stack'in çalışma prensibi. Paketlerin fiziksel kablodan uygulamaya kadar nasıl yolculuk ettiğini, TCP'nin güvenilirlik mekanizmalarını ve kernel buffer tuning yöntemlerini kapsar.

> [!info] İlişkili notlar
> Soket programlama detayları için → [[Linux Socket Programming]]
> Docker bridge/overlay networking → [[Docker Networking]]
> Paket filtreleme ve NAT → [[iptables ve nftables]]

---

## OSI vs TCP/IP Model Karşılaştırması

Teorik OSI modeli 7 katmandan oluşurken, pratikte kullanılan TCP/IP modeli 4 katmana indirger.

| OSI Katmanı | TCP/IP Katmanı | Protokoller | Linux Karşılığı |
|-------------|---------------|-------------|-----------------|
| 7 - Application | Application | HTTP, DNS, SSH, FTP | Userspace (socket API) |
| 6 - Presentation | Application | TLS/SSL, encoding | Userspace / kTLS |
| 5 - Session | Application | Session yönetimi | Userspace |
| 4 - Transport | Transport | TCP, UDP, SCTP | `net/ipv4/tcp.c`, `udp.c` |
| 3 - Network | Internet | IP, ICMP, ARP | `net/ipv4/ip_input.c` |
| 2 - Data Link | Network Access | Ethernet, Wi-Fi | NIC driver, `net/ethernet/` |
| 1 - Physical | Network Access | Kablo, fiber, radyo | Donanım |

```
OSI Model                    TCP/IP Model
┌─────────────────┐          ┌─────────────────┐
│  7. Application │          │                 │
├─────────────────┤          │   Application   │
│  6. Presentation│          │  (HTTP,DNS,SSH) │
├─────────────────┤          │                 │
│  5. Session     │          ├─────────────────┤
├─────────────────┤          │   Transport     │
│  4. Transport   │          │   (TCP, UDP)    │
├─────────────────┤          ├─────────────────┤
│  3. Network     │          │   Internet      │
├─────────────────┤          │   (IP, ICMP)    │
│  2. Data Link   │          ├─────────────────┤
├─────────────────┤          │  Network Access │
│  1. Physical    │          │ (Ethernet, ARP) │
└─────────────────┘          └─────────────────┘
```

> [!tip] Pratik kural
> Gerçek dünyada OSI değil TCP/IP kullanılır. OSI'yi "referans çerçeve" olarak bilin, ancak troubleshooting ve kod yazarken TCP/IP katmanlarını düşünün.

---

## Paket Yapısı — Encapsulation

Bir HTTP isteği gönderildiğinde, veri her katmanda bir header ile sarmalanır (encapsulation). Alıcı tarafta ise bu katmanlar tek tek soyulur (decapsulation).

```
 Encapsulation (gönderici taraf)
 ────────────────────────────────────────────────────────

 Application Layer:
 ┌─────────────────────────────────────────────────────┐
 │                   HTTP Data                         │
 └─────────────────────────────────────────────────────┘

 Transport Layer (TCP):
 ┌──────────────┬──────────────────────────────────────┐
 │  TCP Header  │              HTTP Data               │
 │  (20 byte)   │             (payload)                │
 └──────────────┴──────────────────────────────────────┘

 Internet Layer (IP):
 ┌──────────────┬──────────────┬───────────────────────┐
 │  IP Header   │  TCP Header  │       HTTP Data       │
 │  (20 byte)   │  (20 byte)   │      (payload)        │
 └──────────────┴──────────────┴───────────────────────┘

 Network Access Layer (Ethernet):
 ┌──────────────┬──────────────┬──────────────┬────────────────────┬─────┐
 │  Eth Header  │  IP Header   │  TCP Header  │     HTTP Data      │ FCS │
 │  (14 byte)   │  (20 byte)   │  (20 byte)   │    (payload)       │(4B) │
 └──────────────┴──────────────┴──────────────┴────────────────────┴─────┘
 │◄──────────────────── Ethernet Frame (max 1518 byte) ──────────────────►│
```

### Ethernet Frame Yapısı

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 Byte Offset
 ┌───────────────────────────────────────────────────────────────┐
 │          Destination MAC Address (6 byte)                     │ 0-5
 ├───────────────────────────────────────────────────────────────┤
 │          Source MAC Address (6 byte)                          │ 6-11
 ├───────────────────────────────────────────────────────────────┤
 │       EtherType (2 byte)                                     │ 12-13
 │       0x0800 = IPv4, 0x0806 = ARP, 0x86DD = IPv6             │
 ├───────────────────────────────────────────────────────────────┤
 │                                                               │
 │              Payload (46 - 1500 byte)                         │ 14-1513
 │              (IP paketi burada yer alir)                      │
 │                                                               │
 ├───────────────────────────────────────────────────────────────┤
 │       Frame Check Sequence - FCS (4 byte, CRC-32)            │ 1514-1517
 └───────────────────────────────────────────────────────────────┘
```

- **MTU (Maximum Transmission Unit):** Ethernet payload'inin maksimum boyutu, varsayılan değer **1500 byte**
- **MSS (Maximum Segment Size):** TCP payload'inin maksimum boyutu = MTU - IP header(20) - TCP header(20) = **1460 byte**
- **Jumbo frame:** MTU 9000 byte'a kadar çıkarılabilir (datacenter içinde)

---

## IPv4 Header Yapısı

```
  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 ├─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┤
 │Version│  IHL  │    DSCP   │ECN│         Total Length          │  0-3
 ├───────┴───────┼───────────┴───┼──────┬────────────────────────┤
 │  Identification (16 bit)      │Flags │Fragment Offset (13 bit)│  4-7
 ├───────────────┬───────────────┼──────┴────────────────────────┤
 │   TTL (8 bit) │Protocol (8b)  │   Header Checksum (16 bit)    │  8-11
 ├───────────────┴───────────────┴───────────────────────────────┤
 │                  Source IP Address (32 bit)                   │  12-15
 ├───────────────────────────────────────────────────────────────┤
 │                Destination IP Address (32 bit)                │  16-19
 ├───────────────────────────────────────────────────────────────┤
 │                  Options (0-40 byte, opsiyonel)               │  20+
 └───────────────────────────────────────────────────────────────┘
```

**Kritik alanlar:**

| Alan                                         | Boyut                         | Açıklama                                                         |
| -------------------------------------------- | ----------------------------- | ---------------------------------------------------------------- |
| **Version**                                  | 4 bit                         | IPv4 = 4, IPv6 = 6                                               |
| **IHL**                                      | 4 bit                         | Header uzunluğu (32-bit word cinsinden), min 5 = 20 byte         |
| **TTL**                                      | 8 bit                         | Her router'da 1 azalır, 0 olunca paket drop edilir (loop önleme) |
| **Protocol**                                 | 8 bit                         | Üst katman protokolü: 6=TCP, 17=UDP, 1=ICMP                      |
| **Header Checksum**                          | 16 bit                        | Sadece header için (payload dahil değil)                         |
| **Identification + Flags + Fragment Offset** | Fragmentation için kullanılır |                                                                  |

### IP Fragmentation

MTU'dan büyük paketler parçalanır (fragmentation). Hedef host'ta tekrar birleştirilir (reassembly).

```
Orjinal paket (3000 byte payload, MTU=1500):
┌──────────────────────────────────────────────────┐
│ IP Hdr │          3000 byte veri                 │
└──────────────────────────────────────────────────┘
                        │
                   fragmentation
                        │
          ┌─────────────┼──────────────┐
          ▼             ▼              ▼
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│IP Hdr│1480B │  │IP Hdr│1480B │  │IP Hdr│ 40B  │
│MF=1  │off=0 │  │MF=1  │off=  │  │MF=0  │off=  │
│      │      │  │      │1480  │  │      │2960  │
└─────────────┘  └─────────────┘  └─────────────┘
  Fragment 1       Fragment 2       Fragment 3
```

- **MF (More Fragments)** flag: 1 ise arkadan daha fragment gelecek
- **DF (Don't Fragment)** flag: 1 ise fragmentation yapma, çok büyükse ICMP "need to frag" dön
- **Path MTU Discovery:** DF flag set edilerek yol üzerindeki en küçük MTU bulunur

> [!warning] Fragmentation problemleri
> Fragmentation performansı düşürür ve güvenlik açıklarına neden olabilir. Modern sistemlerde **Path MTU Discovery** ile fragmentation'dan kaçınılır. TCP MSS negotiation zaten bunu önler.

### Routing Table Lookup

Kernel, her giden paket için routing tablosuna bakar. En spesifik eşleşme (longest prefix match) seçilir.

```bash
# Routing tablosunu görüntüle
ip route show

# Örnek çıktı:
# default via 192.168.1.1 dev eth0 proto dhcp metric 100
# 10.0.0.0/8 via 10.0.0.1 dev docker0
# 172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1
# 192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.50
```

```
Routing karari:
                    Hedef IP: 10.0.5.20
                         │
                         ▼
              ┌─────────────────────┐
              │ Routing table lookup│
              │ (longest prefix)    │
              └─────────┬───────────┘
                        │
         ┌──────────────┼──────────────┐
         │              │              │
    10.0.0.0/8    172.17.0.0/16   default
    match!        no match        fallback
         │
         ▼
   via 10.0.0.1
   dev docker0
```

---

## ARP — Address Resolution Protocol

IP adresi bilinen bir hedefe Ethernet frame göndermek için **MAC adresi** gerekir. ARP, IP adresini MAC adresine çevirir (Layer 3 → Layer 2 çözümlemesi).

### ARP Süreci

```
Host A (192.168.1.10)                    Host B (192.168.1.20)
MAC: AA:AA:AA:AA:AA:AA                  MAC: BB:BB:BB:BB:BB:BB

  │                                          │
  │  ARP Request (broadcast)                 │
  │  "192.168.1.20 kimde?"                   │
  │  Dst MAC: FF:FF:FF:FF:FF:FF              │
  │─────────────────────────────────────────→│
  │                                          │
  │  ARP Reply (unicast)                     │
  │  "192.168.1.20 bende,                    │
  │   MAC: BB:BB:BB:BB:BB:BB"                │
  │←─────────────────────────────────────────│
  │                                          │
  │  Artik IP frame gonderebilir             │
  │  Dst MAC: BB:BB:BB:BB:BB:BB              │
  │─────────────────────────────────────────→│
```

### ARP Cache

Çözümlenen MAC adresleri belirli bir süre cache'de tutulur.

```bash
# ARP cache'ini görüntüle
ip neigh show
# veya
arp -a

# Örnek çıktı:
# 192.168.1.1 dev eth0 lladdr 00:11:22:33:44:55 REACHABLE
# 192.168.1.20 dev eth0 lladdr BB:BB:BB:BB:BB:BB STALE
# 10.0.0.5 dev docker0 lladdr 02:42:0a:00:00:05 REACHABLE

# ARP entry durumları:
# REACHABLE — geçerli, kullanılabilir
# STALE     — süresi dolmus, bir sonraki kullanımda tekrar dogrulanacak
# DELAY     — doğrulama bekleniyor
# PROBE     — doğrulama paketi gonderildi
# FAILED    — cozumlenemedi
```

### Gratuitous ARP

Bir host, **kendi IP adresini** sorgulayan ARP request gönderir. Amacı:

1. **IP çatışması tespiti:** Aynı IP'yi başkası kullanıyorsa cevap gelir
2. **ARP cache güncelleme:** Failover durumunda yeni MAC adresini duyurma (VRRP, keepalived)
3. **Switch MAC tablosu güncelleme**

```
Gratuitous ARP:
  Sender IP  = 192.168.1.10   (kendi IP'si)
  Target IP  = 192.168.1.10   (kendi IP'si — aynı!)
  Sender MAC = AA:AA:AA:AA:AA:AA
  Target MAC = FF:FF:FF:FF:FF:FF (broadcast)

  "192.168.1.10 kimde?" → herkes cache'ini gunceller
```

> [!warning] ARP Spoofing
> ARP'nin doğrulama mekanizması yoktur. Saldırgan sahte ARP reply göndererek trafiği kendi üzerinden geçirebilir (MITM). Önlem: static ARP entry'leri, 802.1X, Dynamic ARP Inspection (DAI).

---

## TCP Header Yapısı

```
  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 ├─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┤
 │         Source Port (16 bit)  │     Destination Port (16 bit) │  0-3
 ├───────────────────────────────┴───────────────────────────────┤
 │                   Sequence Number (32 bit)                    │  4-7
 ├───────────────────────────────────────────────────────────────┤
 │                Acknowledgment Number (32 bit)                 │  8-11
 ├──────┬──────┬─┬─┬─┬─┬─┬─┬─┬─┬─────────────────────────────────┤
 │Offset│Reserv│C│E│U│A│P│R│S│F│         Window Size (16 bit)    │ 12-15
 │(4bit)│(3bit)│W│C│R│C│S│S│Y│I│                                 │
 │      │      │R│E│G│K│H│T│N│N│                                 │
 ├──────┴──────┴─┴─┴─┴─┴─┴─┴─┴─┼─────────────────────────────────┤
 │        Checksum (16 bit)      │     Urgent Pointer (16 bit)   │ 16-19
 ├───────────────────────────────┴───────────────────────────────┤
 │                    Options (0-40 byte)                        │ 20+
 │         (MSS, Window Scale, SACK, Timestamps)                 │
 └───────────────────────────────────────────────────────────────┘
```

**Önemli TCP flag'leri:**

| Flag | Anlamı |
|------|--------|
| **SYN** | Bağlantı başlatma, sequence number senkronizasyonu |
| **ACK** | Acknowledgment number alanı geçerli |
| **FIN** | Bağlantı kapatma isteği |
| **RST** | Bağlantı anında sıfırlama (reset) |
| **PSH** | Veriyi hemen uygulamaya ilet, buffer'da bekleme |
| **URG** | Urgent pointer geçerli, öncelikli veri |

---

## TCP 3-Way Handshake

TCP bağlantısı kurmak için üç yollu el sıkışma gereklidir. Bu süreçte her iki taraf da **Initial Sequence Number (ISN)** değişimi yapar.

```
  Client                                          Server
    │                                                │
    │           SYN, Seq=ISN_C (örnek: 1000)         │
    │───────────────────────────────────────────────→│  (1)
    │         [Client ISN'ini gönderir]              │
    │                                                │
    │    SYN+ACK, Seq=ISN_S (örnek: 5000),           │
    │            Ack=ISN_C+1 (1001)                  │
    │←───────────────────────────────────────────────│  (2)
    │  [Server ISN'ini gönderir, Client ISN'ini onar]│
    │                                                │
    │           ACK, Seq=ISN_C+1 (1001),             │
    │               Ack=ISN_S+1 (5001)               │
    │───────────────────────────────────────────────→│  (3)
    │       [Her iki tarafin ISN'i onaylandi]        │
    │                                                │
    │         ── ESTABLISHED ──                      │
    │                                                │
    │          Data: Seq=1001, Ack=5001              │
    │───────────────────────────────────────────────→│
```

### Adım Adım

1. **SYN:** Client rastgele bir ISN seçer (örneğin 1000) ve SYN flag'i set edilmiş bir segment gönderir
2. **SYN-ACK:** Server kendi ISN'ini seçer (örneğin 5000), SYN+ACK gönderir. ACK numarası = client ISN + 1
3. **ACK:** Client, server'in ISN'ini onaylar. ACK numarası = server ISN + 1. Bu segmentle birlikte veri de gönderilebilir

### Initial Sequence Number (ISN)

ISN'in rastgele seçilmesi güvenlik için kritiktir:

- **Tahmin edilebilir ISN:** TCP hijacking saldırısı mümkün
- **Modern Linux:** ISN, zamana ve kaynak/hedef IP/port hash'ine dayalı rastgele üretilir (`net/ipv4/tcp_input.c` içindeki `secure_tcp_seq`)
- ISN 32 bit olduğu için 0 ile 4.294.967.295 arasında bir değer alır

> [!info] SYN Flood saldırısı
> Saldırgan çok sayıda SYN paketi gönderip ACK'i göndermez. Server her SYN için kaynak ayırır ve SYN queue dolar. Önlem: **SYN cookies** (`net.ipv4.tcp_syncookies = 1`) — server state tutmadan SYN-ACK'e kriptografik cookie yerleştirir.

```bash
# SYN cookies'i etkinlestir
sysctl -w net.ipv4.tcp_syncookies=1

# SYN queue boyutunu kontrol et
sysctl net.ipv4.tcp_max_syn_backlog
```

---

## TCP 4-Way Teardown

TCP bağlantısı kapatmak için dört yollu bir süreç veya dört adımlı el sıkışma kullanılır. Her yöndeki bağlantı bağımsız olarak kapatılır (half-close mümkün).

```
  Client                                          Server
    │                                                │
    │            FIN, Seq=X                          │
    │───────────────────────────────────────────────→│  (1) Client kapatma başlatır
    │          [FIN_WAIT_1]                          │  [CLOSE_WAIT]
    │                                                │
    │            ACK, Ack=X+1                        │
    │←───────────────────────────────────────────────│  (2) Server FIN'i onaylar
    │          [FIN_WAIT_2]                          │
    │                                                │  Server hala veri gonderebilir
    │            ... (varsa kalan veri) ...          │      (half-close durumu)
    │                                                │
    │            FIN, Seq=Y                          │
    │←───────────────────────────────────────────────│  (3) Server da kapatir
    │          [TIME_WAIT]                           │  [LAST_ACK]
    │                                                │
    │            ACK, Ack=Y+1                        │
    │───────────────────────────────────────────────→│  (4) Client onayli kapatma
    │                                                │  [CLOSED]
    │                                                │
    │   ── 2*MSL bekleme (60 sn) ──                  │
    │          [CLOSED]                              │
```

### TIME_WAIT ve 2*MSL Bekleme Süresi

**MSL (Maximum Segment Lifetime):** Bir TCP segmentinin network'te kalabileceği maksimum süre. Linux'ta varsayılan 60 saniye (toplam TIME_WAIT = 2 * 60 = 120 saniye, ancak pratikte `tcp_fin_timeout` ile ayarlanabilir).

**TIME_WAIT neden gerekli:**

1. **Gecikmiş segmentlerin temizlenmesi:** Eski bağlantıdan kalan segmentlerin yeni aynı port'u kullanan bağlantıya karışmaması için
2. **Son ACK'in kaybolma ihtimali:** Server, FIN'ine karşılık ACK almadıysa FIN'i tekrar gönderir. Client TIME_WAIT'te olduğu için tekrar ACK gönderebilir

```
Neden 2*MSL?

  Client ──FIN──→ Server     (FIN segmenti en fazla 1 MSL surer)
  Client ←──FIN── Server     (Retransmit FIN en fazla 1 MSL surer)
           ▲
           └── Toplam: FIN gidis + FIN dönüş = 2 * MSL
               Bu süre içinde her türlü gecikmi segment expire olur
```

---

## TCP State Machine

TCP bağlantısının tüm durumları ve geçişleri aşağıdaki state diyagramında gösterilmiştir.

```
                           ┌────────┐
                           │ CLOSED │
                           └───┬────┘
                  ┌────────────┼────────────────┐
            passive open  active open       simultaneous
            (listen)      (SYN gönder)         open
                  │            │                │
                  ▼            ▼                │
            ┌──────────┐  ┌──────────┐          │
            │  LISTEN  │  │ SYN_SENT │          │
            └────┬─────┘  └────┬─────┘          │
                 │             │                │
            rcv SYN        rcv SYN+ACK          │
           snd SYN+ACK    snd ACK               │
                 │             │                │
                 ▼             │                │
          ┌──────────────┐     │                │
          │ SYN_RECEIVED │◄────┘                │
          └──────┬───────┘  rcv SYN             │
                 │          snd SYN+ACK         │
            rcv ACK         ┌───────────────────┘
                 │          │
                 ▼          ▼
          ┌─────────────────────┐
          │     ESTABLISHED     │
          └─────────┬───────────┘
           ┌────────┼────────┐
      active close  │   passive close
      (FIN gönder)  │   (rcv FIN, snd ACK)
           │        │        │
           ▼        │        ▼
     ┌────────────┐ │  ┌────────────┐
     │ FIN_WAIT_1 │ │  │ CLOSE_WAIT │
     └─────┬──────┘ │  └─────┬──────┘
           │        │        │
     ┌─────┼────┐   │   close()
     │     │    │   │   FIN gönder
  rcv ACK │  rcv FIN│        │
     │    │  +ACK   │        ▼
     │    │  snd ACK│  ┌──────────┐
     │    │    │    │  │ LAST_ACK │
     ▼    │    │    │  └────┬─────┘
┌──────────┐   │    │       │
│FIN_WAIT_2│   │    │  rcv ACK
└────┬─────┘   │    │       │
     │         │    │       ▼
rcv FIN        │    │  ┌────────┐
snd ACK        │    │  │ CLOSED │
     │         │    │  └────────┘
     │         ▼    │
     │    ┌─────────┐
     │    │ CLOSING │ (simultaneous close)
     │    └────┬────┘
     │         │ rcv ACK
     │         │
     ▼         ▼
  ┌──────────────┐
  │  TIME_WAIT   │
  │  (2*MSL)     │
  └──────┬───────┘
         │ timeout
         ▼
    ┌────────┐
    │ CLOSED │
    └────────┘
```

### Tüm TCP State'lerin Özeti

| State | Açıklama |
|-------|----------|
| **CLOSED** | Bağlantı yok (başlangıç/bitiş durumu) |
| **LISTEN** | Server, gelen SYN'leri bekliyor |
| **SYN_SENT** | Client SYN gönderdi, SYN-ACK bekliyor |
| **SYN_RECEIVED** | Server SYN aldı, SYN-ACK gönderdi, ACK bekliyor |
| **ESTABLISHED** | Bağlantı kuruldu, veri transferi yapılıyor |
| **FIN_WAIT_1** | FIN gönderildi, ACK veya FIN bekleniyor |
| **FIN_WAIT_2** | FIN için ACK alındı, karşı tarafın FIN'i bekleniyor |
| **CLOSE_WAIT** | Karşı tarafın FIN'i alındı, uygulamanın close() çağırması bekleniyor |
| **LAST_ACK** | FIN gönderildi (passive close tamamlanıyor), son ACK bekleniyor |
| **CLOSING** | Her iki taraf aynı anda FIN gönderdi (simultaneous close) |
| **TIME_WAIT** | Son ACK gönderildi, 2*MSL bekleniyor |

> [!warning] CLOSE_WAIT birikiyor mu?
> `ss` çıktısında çok sayıda CLOSE_WAIT görüyorsanız, uygulamanız gelen FIN'lere rağmen soketi kapatmıyor demektir. Bu bir **uygulama bug'ıdır** — soket leak. Kodda `close()` çağrısının eksik olduğu yeri bulun.

---

## TCP Flow Control — Sliding Window

TCP, alıcının işleyebileceğinden fazla veri gönderilmesini **flow control** ile önler. Mekanizma: **sliding window**.

### Temel Kavramlar

- **rwnd (Receiver Window):** Alıcının kabul edebileceği byte miktarı. Her ACK ile birlikte güncellenir
- **Window Size:** TCP header'daki 16-bit alan (max 65535 byte)
- **Window Scaling:** TCP option ile window size 2^14 = 16384 katına kadar büyütülür (RFC 7323). 3-way handshake sırasında negotiate edilir

```
Sender                                          Receiver
  │                                                 │
  │    Seq=1, 1000 byte veri                        │
  │────────────────────────────────────────────────→│
  │                                                 │
  │    Seq=1001, 1000 byte veri                     │
  │────────────────────────────────────────────────→│
  │                                                 │ Receiver buffer
  │    ACK=2001, Window=4000                        │ dolmaya basliyor
  │←────────────────────────────────────────────────│
  │                                                 │
  │    Seq=2001, 1000 byte veri                     │
  │────────────────────────────────────────────────→│
  │                                                 │
  │    Seq=3001, 1000 byte veri                     │
  │────────────────────────────────────────────────→│
  │                                                 │
  │    ACK=4001, Window=1000                        │ Buffer neredeyse dolu!
  │←────────────────────────────────────────────────│
  │                                                 │
  │    Seq=4001, 1000 byte veri                     │
  │────────────────────────────────────────────────→│
  │                                                 │
  │    ACK=5001, Window=0    ← ZERO WINDOW!         │ Buffer tamamen dolu
  │←────────────────────────────────────────────────│
  │                                                 │
  │    [Sender durur, Window Probe timer başlar]    │
  │                                                 │
  │    Window Probe (periyodik)                     │
  │────────────────────────────────────────────────→│
  │                                                 │ Uygulama veri okudu
  │    ACK=5001, Window=8000  ← pencere acildi      │
  │←────────────────────────────────────────────────│
  │                                                 │
  │    [Sender tekrar veri gondermeye başlar]       │
```

### Sliding Window Görselleştirme

```
Gonderici perspektifinden:

Byte sequence:
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ 1 │ 2 │ 3 │ 4 │ 5 │ 6 │ 7 │ 8 │ 9 │10 │11 │12 │13 │14 │15 │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
  ACK'd | Sent (ACK bekleniyor) |  Sendable |  Window dışı
        |<--------- usable window --------->|
```

### Window Scaling

```bash
# Window scaling etkin mi kontrol et
sysctl net.ipv4.tcp_window_scaling
# 1 = etkin (varsayilan)

# Window scale factor handshake sirasinda belirlenir:
# SYN:     Window Scale option = 7 → gerçek window = header_window * 2^7 = 128x
# Boylece: 65535 * 128 = 8.388.480 byte (~8 MB) window mumkun
```

---

## TCP Congestion Control

Flow control alıcının kapasitesini korurken, **congestion control** network'un kapasitesini korur. Gönderici bir **cwnd (congestion window)** tutar.

```
Gercek gonderim penceresi = min(cwnd, rwnd)
```

### Slow Start

Bağlantı başında cwnd küçük başlar ve her ACK'te katlanarak büyür.

```
             cwnd (MSS cinsinden)
               │
          64   │                         xxxxxxxxx
               │                     xxxx
          32   │                  xxx  ← ssthresh'e ulasti
               │               xx       congestion avoidance başlar
          16   │            xxx         (lineer artis)
               │          xx
           8   │        xx
               │      xx
           4   │    xx
               │   x
           2   │  x  ← Slow Start
               │ x    (eksponansiyel artis)
           1   │x
               └──────────────────────────────────── RTT
                1  2  3  4  5  6  7  8  9  10  11
```

### Congestion Control Fazları

| Faz | Koşul | Davranış |
|-----|-------|----------|
| **Slow Start** | cwnd < ssthresh | Her ACK için cwnd += 1 MSS (her RTT'de 2x) |
| **Congestion Avoidance** | cwnd >= ssthresh | Her RTT için cwnd += 1 MSS (lineer artış) |
| **Fast Retransmit** | 3 duplicate ACK alındığında | Timeout beklemeden kayıp segmenti tekrar gönder |
| **Fast Recovery** | 3 dup ACK sonrası | ssthresh = cwnd/2, cwnd = ssthresh + 3 (timeout gibi sıfırlanmaz) |

### Paket Kaybı Sonrası Davranış

```
             cwnd
               │
          32   │          x
               │         x│
          24   │        x │ ← 3 dup ACK (paket kaybi)
               │       x  │   ssthresh = cwnd/2 = 16
          16   │      x   └──→ cwnd = ssthresh (Fast Recovery)
               │     x        │
          12   │              │  Congestion Avoidance
               │              │  (lineer artis)
           8   │              x
               │             x
           4   │            x
               │
               └──────────────────────────────── RTT

Timeout durumunda (daha kotu):
  ssthresh = cwnd/2
  cwnd = 1 MSS         ← sifirdan basla (slow start)
```

### CUBIC vs BBR

| Özellik | CUBIC | BBR |
|---------|-------|-----|
| **Varsayılan** | Linux 2.6.19+ (varsayılan) | Opsiyonel (Google geliştirmesi) |
| **Yaklaşım** | Loss-based | Model-based (bandwidth + RTT) |
| **cwnd artışı** | Cubic fonksiyonu (t^3) | Tahmini BDP (Bandwidth-Delay Product) |
| **Bufferbloat** | Etkilen**ir** | Etkilen**mez** (RTT bazli) |
| **Kullanım** | Genel amaçlı | Yüksek bandwidth, yüksek latency linkleri |

```bash
# Mevcut congestion control algoritması
sysctl net.ipv4.tcp_congestion_control
# cubic

# Kullanilabilir algoritmalar
sysctl net.ipv4.tcp_available_congestion_control
# reno cubic

# BBR etkinlestirme
sysctl -w net.ipv4.tcp_congestion_control=bbr

# BBR için gerekli qdisc
tc qdisc show dev eth0
# fq veya fq_codel olmali
```

> [!tip] BBR ne zaman seçilmeli
> Yüksek latency (WAN, CDN) ve paket kaybı olan ortamlarda BBR, CUBIC'e göre belirgin performans avantajı sağlar. Datacenter içinde (düşük RTT) fark minimumdur.

---

## UDP — User Datagram Protocol

UDP, TCP'nin aksine **connectionless** ve **unreliable** bir protokoldur. Bağlantı kurulmaz, flow/congestion control yoktur, sıralama garantisi yoktur.

### UDP Header Yapısı

```
  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 ├─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┤
 │      Source Port (16 bit)     │    Destination Port (16 bit)  │  0-3
 ├───────────────────────────────┼───────────────────────────────┤
 │      Length (16 bit)          │       Checksum (16 bit)       │  4-7
 ├───────────────────────────────┴───────────────────────────────┤
 │                        Payload                                │  8+
 └───────────────────────────────────────────────────────────────┘

 Toplam header boyutu: sadece 8 byte (TCP: min 20 byte)
```

### TCP vs UDP Karşılaştırması

| Özellik | TCP | UDP |
|---------|-----|-----|
| Bağlantı | Connection-oriented (3-way handshake) | Connectionless |
| Güvenilirlik | Guaranteed delivery (ACK, retransmit) | Best effort |
| Sıralama | Sıralama garantisi var (sequence number) | Sıralama yok |
| Flow control | Sliding window | Yok |
| Congestion control | Var (slow start, CUBIC/BBR) | Yok |
| Header boyutu | 20-60 byte | 8 byte |
| Overhead | Yüksek | Düşük |
| Kullanım | HTTP, SSH, FTP, e-mail | DNS, DHCP, video streaming, VoIP, gaming |

> [!info] UDP neden tercih edilir?
> Düşük latency gerektiren uygulamalarda (oyun, video call) retransmit anlamsızdır çünkü eski veri işine yaramaz. Ayrıca DNS gibi küçük sorgu/cevap protokollerinde 3-way handshake overhead'i gereksizdir. QUIC (HTTP/3) ise UDP üzerinde kendi güvenilirlik katmanını kurar.

---

## Linux Kernel TCP Buffer Tuning

Yüksek trafik altındaki sunucularda varsayılan TCP buffer değerleri yetersiz kalabilir. Kernel sysctl parametreleri ile ince ayar yapılır.

### Temel Buffer Parametreleri

```bash
# ── Soket Buffer Limitleri (tüm protokoller) ──

# Tek bir soketin alabilecegi maksimum buffer (byte)
sysctl net.core.rmem_max          # varsayilan: 212992 (~208 KB)
sysctl net.core.wmem_max          # varsayilan: 212992

# Varsayilan soket buffer boyutu
sysctl net.core.rmem_default      # varsayilan: 212992
sysctl net.core.wmem_default      # varsayilan: 212992


# ── TCP'ye Ozel Buffer Ayarlari ──
# Format: min  default  max (byte cinsinden)

# TCP okuma buffer'i
sysctl net.ipv4.tcp_rmem
# 4096  131072  6291456
# min=4KB  default=128KB  max=6MB

# TCP yazma buffer'i
sysctl net.ipv4.tcp_wmem
# 4096  16384  4194304
# min=4KB  default=16KB  max=4MB


# ── Baglanti Kuyrugu ──

# accept() için maksimum kuyruk uzunlugu (listen backlog)
sysctl net.core.somaxconn         # varsayilan: 4096 (eski kernellerde 128)

# SYN backlog (yarim açık bağlantı kuyruğu)
sysctl net.ipv4.tcp_max_syn_backlog   # varsayilan: 1024
```

### Yüksek Performans İçin Tuning Örneği

```bash
# /etc/sysctl.d/99-tcp-tuning.conf

# Soket buffer max değerlerini yukselt
net.core.rmem_max = 16777216          # 16 MB
net.core.wmem_max = 16777216          # 16 MB

# TCP buffer autotuning için genis aralık
net.ipv4.tcp_rmem = 4096 1048576 16777216    # min 4K, default 1M, max 16M
net.ipv4.tcp_wmem = 4096 1048576 16777216    # min 4K, default 1M, max 16M

# Baglanti kuyruğu
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# TCP memory (page cinsinden, 1 page = 4096 byte)
# low   pressure   high
net.ipv4.tcp_mem = 786432 1048576 1572864
# ~3GB   ~4GB      ~6GB

# TCP autotuning etkin (varsayilan olarak açık)
net.ipv4.tcp_moderate_rcvbuf = 1

# Uygula
# sysctl -p /etc/sysctl.d/99-tcp-tuning.conf
```

### Buffer Akis Diyagrami

```
Uygulama write()          Kernel TCP Stack           Network
     │                         │                        │
     ▼                         │                        │
┌──────────┐                   │                        │
│  send()  │                   │                        │
└────┬─────┘                   │                        │
     │                         │                        │
     ▼                         │                        │
┌──────────────────┐           │                        │
│  Socket Send     │           │                        │
│  Buffer          │──────────→│ TCP segmentation       │
│  (tcp_wmem)      │           │ + congestion control   │
└──────────────────┘           │          │             │
                               │          ▼             │
                               │   ┌────────────┐       │
                               │   │  NIC Queue │──────→│ Wire
                               │   │ (qdisc/txq)│       │
                               │   └────────────┘       │
                               │                        │
                    ┌──────────│←───────────────────────│ Wire
                    │          │                        │
                    │   ┌────────────┐                  │
                    │   │  NIC Ring  │                  │
                    │   │  Buffer    │                  │
                    │   └─────┬──────┘                  │
                    │         │                         │
                    │         ▼                         │
              ┌──────────────────┐                      │
              │  Socket Receive  │                      │
              │  Buffer          │                      │
              │  (tcp_rmem)      │                      │
              └────┬─────────────┘                      │
                   │                                    │
                   ▼                                    │
              ┌──────────┐                              │
              │  recv()  │                              │
              └──────────┘                              │
```

> [!tip] Buffer tuning stratejisi
> - `tcp_rmem` ve `tcp_wmem` icindeki **max** değer, `rmem_max`/`wmem_max`'i asamaz. Once core limitleri yukseltin.
> - Autotuning (`tcp_moderate_rcvbuf=1`) açık ise kernel buffer'i dinamik olarak ayarlar. Sabit buffer set etmek için uygulamada `setsockopt(SO_RCVBUF)` kullanin.
> - Cok büyük buffer = daha fazla bellek tuketimi. Sunucunun toplam RAM'ine gore denge kurun.

---

## TIME_WAIT Problemi ve Cozumleri

Yogun trafik altindaki sunucularda çok sayida kısa omurlu bağlantı (örneğin her HTTP isteği için yeni bağlantı) TIME_WAIT birikimene yol acar.

### Problem

```
Her kapanan bağlantı 60-120 saniye TIME_WAIT'te kalir.
Saniyede 1000 bağlantı kapanirsa:
  1000 * 60 = 60.000 soket TIME_WAIT'te

Her soket bir (src_ip, src_port, dst_ip, dst_port) tuple'i tutar.
Ephemeral port araligi: 32768-60999 (28.232 port)

60.000 > 28.232 → PORT TUKENMESI!
```

```bash
# TIME_WAIT soket sayisini gor
ss -s
# TCP:   12500 (estab 350, closed 11200, timewait 11000)

# Ephemeral port araligini gor
sysctl net.ipv4.ip_local_port_range
# 32768  60999
```

### Cozumler

```bash
# 1. tw_reuse — aynı 4-tuple için TIME_WAIT soketini tekrar kullan
#    (sadece outgoing baglantilar için, client tarafinda)
sysctl -w net.ipv4.tcp_tw_reuse=1

# 2. Ephemeral port araligini genişlet
sysctl -w net.ipv4.ip_local_port_range="1024 65535"

# 3. tcp_max_tw_buckets — TIME_WAIT soket limiti
#    Asildinda yeni TIME_WAIT soketler hemen kapatilir
sysctl -w net.ipv4.tcp_max_tw_buckets=200000

# 4. Uygulama seviyesinde: Connection pooling / Keep-Alive
#    HTTP Keep-Alive ile aynı bağlantı üzerinden birden fazla istek
#    yapilarak bağlantı kapatma sayisi azaltilir

# 5. SO_LINGER ile RST gönderme (dikkatli kullanin!)
#    close() aninda RST gönderir, TIME_WAIT bypass edilir
#    ANCAK: veri kaybi riski var, sadece özel durumlarda
```

> [!warning] tcp_tw_recycle — KULLANMAYIN
> `net.ipv4.tcp_tw_recycle` parametresi Linux 4.12'de **kaldirildi**. NAT arkasindaki istemcilerle ciddi bağlantı sorunlarina neden oluyordu (aynı IP'den gelen farkli istemcilerin timestamp'leri karisiyordu). Asla kullanmayin.

> [!tip] En iyi strateji
> TIME_WAIT'i "ortadan kaldirmaya" çalışmak yerine, **Connection Keep-Alive** ve **connection pooling** ile bağlantı acma/kapama sayisini azaltin. Bu hem TIME_WAIT sorununu çözer hem de 3-way handshake overhead'ini düşürür.

---

## TCP State Analizi — ss ve /proc/net/tcp

### ss Komutu ile TCP State İzleme

`ss` (socket statistics), `netstat`'in modern ve hızlı alternatifidir. Kernel'den doğrudan bilgi okur.

```bash
# Tum TCP soketleri (ESTABLISHED, TIME_WAIT, vs.)
ss -ta

# State filtresi ile
ss -t state established
ss -t state time-wait
ss -t state close-wait
ss -t state listening

# Birden fazla state
ss -t state established state close-wait

# Detayli bilgi (timer, buffer, congestion)
ss -tni

# Örnek çıktı:
# State  Recv-Q  Send-Q   Local Address:Port    Peer Address:Port   Process
# ESTAB  0       0        192.168.1.50:22       192.168.1.10:54321
#        cubic wscale:7,7 rto:204 rtt:1.5/0.75 mss:1460 cwnd:10 ssthresh:20
#        bytes_sent:15000 bytes_received:2400 segs_out:120 segs_in:80

# Process bilgisi ile (-p flagi, root gerektirir)
ss -tnp state established

# State bazinda sayi özeti
ss -s
# Total: 1250
# TCP:   980 (estab 450, closed 200, orphaned 5, timewait 300)
# UDP:   25

# Belirli bir port'u dinleyen süreçler
ss -tlnp sport = :80
ss -tlnp sport = :443
```

### Yaygin ss Filtreleri

```bash
# Belirli bir IP'ye baglantilar
ss -tn dst 10.0.0.5

# Belirli bir port araliginda
ss -tn sport ge :8000 sport le :9000

# Buyuk Send-Q (gonderim kuyrugunun dolup veri gonderilmedigi durum)
ss -tn '( send-q > 0 )'

# Buyuk Recv-Q (uygulama okuma yapmiyor, buffer doluyor)
ss -tn '( recv-q > 0 )'
```

### /proc/net/tcp Okuma

Kernel, TCP soketlerinin ham bilgilerini `/proc/net/tcp` dosyasinda hex formatinda sunar.

```bash
cat /proc/net/tcp
# Örnek satirlar:
#  sl  local_address rem_address   st tx_queue rx_queue ...
#   0: 0100007F:0CEA 00000000:0000 0A 00000000:00000000 ...
#   1: 3201A8C0:0016 0A01A8C0:D431 01 00000000:00000000 ...
```

**Alan acilamalari:**

```
local_address: 0100007F:0CEA
               │         └── port (hex): 0x0CEA = 3306 (MySQL)
               └── IP (hex, ters sirada): 7F.00.00.01 = 127.0.0.1

rem_address:   0A01A8C0:D431
               │         └── port: 0xD431 = 54321
               └── IP: C0.A8.01.0A = 192.168.1.10

st (state):
  01 = ESTABLISHED       06 = TIME_WAIT
  02 = SYN_SENT          07 = CLOSE
  03 = SYN_RECV          08 = CLOSE_WAIT
  04 = FIN_WAIT1         09 = LAST_ACK
  05 = FIN_WAIT2         0A = LISTEN
```

```bash
# /proc/net/tcp'den state dagilimini çıkar
awk '{print $4}' /proc/net/tcp | sort | uniq -c | sort -rn
# Örnek çıktı:
#   450 01    (ESTABLISHED)
#   300 06    (TIME_WAIT)
#    50 0A    (LISTEN)
#    15 08    (CLOSE_WAIT)
```

---

## tcpdump ve Wireshark ile Paket Analizi

### tcpdump Temel Kullanim

```bash
# Belirli bir interface'te tüm trafik
tcpdump -i eth0

# Sadece TCP, belirli port
tcpdump -i eth0 tcp port 80

# Sadece SYN paketleri (3-way handshake başlangıcı)
tcpdump -i eth0 'tcp[tcpflags] & tcp-syn != 0'

# SYN ama SYN-ACK değil (sadece ilk SYN)
tcpdump -i eth0 'tcp[tcpflags] == tcp-syn'

# FIN paketleri
tcpdump -i eth0 'tcp[tcpflags] & tcp-fin != 0'

# RST paketleri (bağlantı sifirlamalari)
tcpdump -i eth0 'tcp[tcpflags] & tcp-rst != 0'

# Belirli bir host ile trafik
tcpdump -i eth0 host 192.168.1.10

# Belirli bir subnet
tcpdump -i eth0 net 10.0.0.0/8

# Verbose + hex dump + dosyaya kaydet
tcpdump -i eth0 -vvv -X -w /tmp/capture.pcap tcp port 443

# Kayitli dosyayi oku
tcpdump -r /tmp/capture.pcap

# ASCII çıktı (HTTP trafigi için faydali)
tcpdump -i eth0 -A port 80
```

### tcpdump ile 3-Way Handshake İzleme

```bash
tcpdump -i eth0 -nn 'tcp port 80 and (tcp[tcpflags] & (tcp-syn|tcp-fin) != 0)'

# Örnek çıktı:
# 10:15:30.123456 IP 192.168.1.10.54321 > 10.0.0.5.80: Flags [S],  seq 1234567890, win 65535, options [mss 1460,sackOK,TS val 123 ecr 0,nop,wscale 7], length 0
# 10:15:30.123789 IP 10.0.0.5.80 > 192.168.1.10.54321: Flags [S.], seq 987654321, ack 1234567891, win 65535, options [mss 1460,sackOK,TS val 456 ecr 123,nop,wscale 7], length 0
# 10:15:30.124012 IP 192.168.1.10.54321 > 10.0.0.5.80: Flags [.],  ack 987654322, win 512, length 0
```

**Flag aciklamalari:**

| tcpdump Flag | Anlam |
|-------------|-------|
| `[S]` | SYN |
| `[S.]` | SYN-ACK |
| `[.]` | ACK (sadece) |
| `[P.]` | PSH-ACK (veri gonderimi) |
| `[F.]` | FIN-ACK |
| `[R]` | RST |
| `[R.]` | RST-ACK |

### Wireshark Filtreleri

Wireshark (veya terminal versiyonu `tshark`) ile daha detayli analiz yapılabilir.

```bash
# tshark ile komut satirindan Wireshark filtreleri
# 3-way handshake'leri filtrele
tshark -i eth0 -Y "tcp.flags.syn == 1"

# Retransmission'lari bul
tshark -i eth0 -Y "tcp.analysis.retransmission"

# Zero window olaylarini bul
tshark -i eth0 -Y "tcp.analysis.zero_window"

# Duplicate ACK'leri bul
tshark -i eth0 -Y "tcp.analysis.duplicate_ack"

# Belirli bir TCP stream'i takip et
tshark -i eth0 -Y "tcp.stream eq 5" -T fields -e data.text

# Yuksek RTT'li baglantilar
tshark -i eth0 -Y "tcp.analysis.ack_rtt > 0.5"
```

### Yaygin Wireshark Display Filtreleri

| Filtre | Açıklama |
|--------|----------|
| `tcp.flags.syn == 1 && tcp.flags.ack == 0` | Sadece SYN (bağlantı başlatma) |
| `tcp.flags.reset == 1` | RST paketleri |
| `tcp.analysis.retransmission` | Tekrar gonderimleri |
| `tcp.analysis.zero_window` | Alici buffer'i dolu |
| `tcp.analysis.window_update` | Window guncellemeleri |
| `tcp.analysis.out_of_order` | Sira dışı paketler |
| `tcp.time_delta > 1` | 1 saniyeden uzun bos kalan baglantilar |
| `dns` | DNS trafigi (UDP port 53) |
| `http.request.method == "GET"` | HTTP GET istekleri |

### Örnek: Yavas Baglanti Analizi

```bash
# 1. Yakalama başlat
tcpdump -i eth0 -w /tmp/slow.pcap host 10.0.0.5 and port 443

# 2. Wireshark ile ac, su filtreleri dene:

# Handshake süresi (SYN → SYN-ACK arasi)
# tcp.flags.syn == 1 → sag tik → Follow TCP Stream
# SYN ve SYN-ACK arasındaki zaman farki = network latency

# Retransmission sayisi
# Statistics → TCP Stream Graphs → Stevens Graph

# Throughput analizi
# Statistics → IO Graphs → tcp.len ifadesi ile
```

> [!tip] Pratik ipucu
> Production ortamda `tcpdump` ile yakalama yaparken **her zaman** dosyaya yazin (`-w`), filtreleme sonra yapin. Canli filtreleme paket kaybina neden olabilir. Ayrica `-c 10000` ile paket sayisini sinirlamayi unutmayin, disk dolabilir.

---

## Ozet — Paket Yolculugu (Uygulama → Kablo)

```
Uygulama: write(fd, "GET / HTTP/1.1\r\n...")
    │
    ▼
┌─────────────────────────────────┐
│ Socket Layer                    │  send buffer'a kopyala
│ (AF_INET, SOCK_STREAM)          │  SO_SNDBUF kontrolü
└───────────┬─────────────────────┘
            │
            ▼
┌─────────────────────────────────┐
│ TCP Layer                       │  Segmentation (MSS'e bol)
│ - Sequence number ata           │  Congestion window kontrolü
│ - TCP header ekle               │  Retransmit timer başlat
│ - Checksum hesapla              │
└───────────┬─────────────────────┘
            │
            ▼
┌─────────────────────────────────┐
│ IP Layer                        │  IP header ekle (src/dst IP)
│ - Routing table lookup          │  TTL set et
│ - Fragmentation (gerekirse)     │  → [[iptables ve nftables]]
│ - Netfilter hooks               │    OUTPUT → POSTROUTING
└───────────┬─────────────────────┘
            │
            ▼
┌─────────────────────────────────┐
│ ARP + Ethernet                  │  Next-hop MAC'i çözümle
│ - ARP cache kontrol             │  Ethernet frame olustur
│ - Ethernet header ekle          │  FCS (CRC-32) ekle
└───────────┬─────────────────────┘
            │
            ▼
┌─────────────────────────────────┐
│ NIC Driver + Donanim            │  DMA ile NIC'e aktar
│ - TX ring buffer                │  Fiziksel ortama gönder
│ - Interrupt/NAPI                │
└─────────────────────────────────┘
            │
            ▼
         ~~~ kablo / kablosuz ~~~
```

---

## Hizli Referans — Kritik sysctl Parametreleri

| Parametre | Varsayilan | Onerilen (yüksek trafik) | Açıklama |
|-----------|-----------|-------------------------|----------|
| `net.core.rmem_max` | 212992 | 16777216 | Max soket okuma buffer |
| `net.core.wmem_max` | 212992 | 16777216 | Max soket yazma buffer |
| `net.ipv4.tcp_rmem` | 4096 131072 6291456 | 4096 1048576 16777216 | TCP okuma buffer (min/def/max) |
| `net.ipv4.tcp_wmem` | 4096 16384 4194304 | 4096 1048576 16777216 | TCP yazma buffer (min/def/max) |
| `net.core.somaxconn` | 4096 | 65535 | Listen backlog max |
| `net.ipv4.tcp_max_syn_backlog` | 1024 | 65535 | SYN queue boyutu |
| `net.ipv4.tcp_syncookies` | 1 | 1 | SYN flood korunma |
| `net.ipv4.tcp_tw_reuse` | 0 | 1 | TIME_WAIT soket yeniden kullanım |
| `net.ipv4.tcp_congestion_control` | cubic | bbr | Congestion algoritma |
| `net.ipv4.ip_local_port_range` | 32768 60999 | 1024 65535 | Ephemeral port araligi |
| `net.ipv4.tcp_fin_timeout` | 60 | 30 | FIN_WAIT_2 timeout |
| `net.ipv4.tcp_keepalive_time` | 7200 | 600 | Keepalive ilk probe (sn) |
| `net.ipv4.tcp_window_scaling` | 1 | 1 | Window scaling etkin |
