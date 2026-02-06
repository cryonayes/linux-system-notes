# iptables ve nftables

Linux kernel'inin **packet filtering** framework'ü. Network paketlerini filtreleme, NAT, port yönlendirme ve trafik kontrolü sağlar.

> [!info] Docker ile ilişki
> Docker, container networking için **otomatik** iptables kuralları oluşturur → [[Docker Networking#iptables NAT Kuralları]]

---

## Netfilter Mimarisi

**Netfilter**, Linux kernel'inde paket işleme framework'üdür. `iptables` ve `nftables` bu framework'ün **userspace araçlarıdır**.

```
Paket gelir
    │
    ▼
┌────────────┐     ┌─────────────────┐
│ PREROUTING │────→│ ROUTING DECISION│
│ (DNAT)     │     └────────┬────────┘
└────────────┘              │
                   ┌────────┴────────┐
                   │                 │
            Bu host'a mı?     Başka host'a mı?
                   │                 │
                   ▼                 ▼
            ┌──────────┐      ┌──────────┐
            │  INPUT   │      │ FORWARD  │
            │(filter)  │      │(filter)  │
            └────┬─────┘      └────┬─────┘
                 │                 │
                 ▼                 │
           Local Process           │
                 │                 │
                 ▼                 │
            ┌──────────┐           │
            │  OUTPUT  │           │
            │(filter)  │           │
            └────┬─────┘           │
                 │                 │
                 └───────┬─────────┘
                         │
                         ▼
                  ┌─────────────┐
                  │ POSTROUTING │
                  │ (SNAT/MASQ) │
                  └──────┬──────┘
                         │
                         ▼
                    Paket çıkar
```

---

## Netfilter Hook'ları (Zincirler)

Paket kernel'den geçerken **5 hook noktasından** geçer:

| Hook | Zaman | Kullanım |
|------|-------|----------|
| **PREROUTING** | Paket NIC'e geldiğinde (routing kararı öncesi) | DNAT, port redirect |
| **INPUT** | Paket **bu host'a** yönlendirilmişse | Gelen trafik filtreleme |
| **FORWARD** | Paket **başka bir host'a** yönlendiriliyorsa | Router/bridge trafik filtreleme |
| **OUTPUT** | Paket **bu host'tan** çıkıyorsa | Giden trafik filtreleme |
| **POSTROUTING** | Paket NIC'ten çıkmadan hemen önce | SNAT, MASQUERADE |

#### Paket Akış Senaryoları

**Dışarıdan gelen, bu host'a yönelik paket:**
```
NIC → PREROUTING → INPUT → Local Process
```

**Bu host'tan çıkan paket:**
```
Local Process → OUTPUT → POSTROUTING → NIC
```

**Forward edilen paket (router/bridge):**
```
NIC → PREROUTING → FORWARD → POSTROUTING → NIC
```

---

## iptables

`iptables` = Netfilter'ın klasik userspace aracı. Kurallar **tablo → zincir → kural** hiyerarşisinde düzenlenir.

#### Tablolar

| Tablo | Amaç | Kullanılan Zincirler |
|-------|-------|---------------------|
| **filter** | Paket filtreleme (default) | INPUT, FORWARD, OUTPUT |
| **nat** | Network Address Translation | PREROUTING, OUTPUT, POSTROUTING |
| **mangle** | Paket değiştirme (TTL, TOS, mark) | Tüm zincirler |
| **raw** | Connection tracking bypass | PREROUTING, OUTPUT |

#### Temel Syntax

```bash
iptables -t <tablo> -A <zincir> <match> -j <target>
#         │          │           │         │
#         tablo      append      eşleşme   aksiyon
```

#### Target'lar (Aksiyonlar)

| Target | Açıklama |
|--------|----------|
| `ACCEPT` | Paketi kabul et |
| `DROP` | Paketi sessizce at (cevap yok) |
| `REJECT` | Paketi at + ICMP hata mesajı gönder |
| `LOG` | Paketi logla, işlemeye devam et |
| `DNAT` | Destination adresini değiştir |
| `SNAT` | Source adresini değiştir |
| `MASQUERADE` | SNAT'ın dinamik IP versiyonu |
| `REDIRECT` | Paketi local port'a yönlendir |

---

## iptables Pratik Örnekler

#### Gelen Trafik Filtreleme (filter/INPUT)

```bash
# SSH izin ver
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# HTTP ve HTTPS izin ver
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# Established bağlantılara izin ver
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Loopback izin ver
iptables -A INPUT -i lo -j ACCEPT

# Diğer her şeyi engelle
iptables -A INPUT -j DROP

# Belirli IP'den erişimi engelle
iptables -A INPUT -s 192.168.1.100 -j DROP

# Belirli IP aralığına izin ver
iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport 5432 -j ACCEPT
```

#### Port Forwarding (nat/PREROUTING)

```bash
# Gelen 8080 trafiğini 80'e yönlendir
iptables -t nat -A PREROUTING -p tcp --dport 8080 -j REDIRECT --to-port 80

# Gelen trafiği başka bir host'a yönlendir (DNAT)
iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 192.168.1.10:8080

# IP forwarding'i aktifleştir (DNAT için gerekli)
echo 1 > /proc/sys/net/ipv4/ip_forward
```

#### NAT / MASQUERADE (nat/POSTROUTING)

```bash
# İç network'ün dış dünyaya çıkışı (source NAT)
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE

# Statik SNAT
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j SNAT --to-source 203.0.113.5
```

#### Rate Limiting

```bash
# SSH brute force koruması (dakikada max 5 bağlantı)
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m limit --limit 5/min --limit-burst 10 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j DROP

# ICMP flood koruması
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s --limit-burst 4 -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
```

---

## Connection Tracking (conntrack)

Netfilter **stateful** packet filtering sağlar. Her bağlantıyı takip eder.

```bash
# Aktif bağlantıları görmek
conntrack -L
# tcp  6 300 ESTABLISHED src=192.168.1.10 dst=10.0.0.1 sport=42356 dport=80 ...

# Bağlantı sayısı
conntrack -C

# Belirli bağlantıyı sil
conntrack -D -s 192.168.1.100
```

#### Bağlantı Durumları

| Durum | Açıklama |
|-------|----------|
| **NEW** | İlk paket (SYN) |
| **ESTABLISHED** | Karşılıklı trafik var |
| **RELATED** | Mevcut bağlantıyla ilişkili (FTP data, ICMP error) |
| **INVALID** | Tanınamayan paket |

```bash
# Stateful firewall kuralı (en yaygın pattern)
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
```

---

## Docker ve iptables

Docker, container networking için **otomatik** iptables kuralları ekler.

#### Docker'ın Oluşturduğu Kurallar

```bash
# Docker zincirleri
iptables -L -n -v
# Chain DOCKER (forward)
# Chain DOCKER-ISOLATION-STAGE-1 (forward)
# Chain DOCKER-ISOLATION-STAGE-2 (forward)
# Chain DOCKER-USER (forward)

# NAT kuralları
iptables -t nat -L -n -v
```

#### MASQUERADE (container → dış dünya)
```bash
# Container'lardan çıkan trafiğin source IP'si host IP'sine dönüşür
-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
```

#### DNAT (port mapping: dış dünya → container)
```bash
# docker run -p 8080:80 çalıştırınca:
-A DOCKER -p tcp --dport 8080 -j DNAT --to-destination 172.17.0.2:80
```

#### FORWARD (container'lar arası)
```bash
# Aynı bridge'deki container'lar arası iletişim
-A FORWARD -i docker0 -o docker0 -j ACCEPT

# Container → dış dünya
-A FORWARD -i docker0 ! -o docker0 -j ACCEPT

# Dış dünya → container (established)
-A FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

#### DOCKER-USER Zinciri

Docker **kendi kurallarını** otomatik yönetir. Custom kuralları `DOCKER-USER` zincirine ekle:

```bash
# Docker container'larına dışarıdan erişimi kısıtla
# DOCKER-USER zinciri Docker kurallarından ÖNCE işlenir
iptables -I DOCKER-USER -i eth0 -s 10.0.0.0/24 -j ACCEPT
iptables -A DOCKER-USER -i eth0 -j DROP
```

> [!warning] UFW ve Docker
> Docker iptables kurallarını **doğrudan** ekler, UFW'yi **bypass** eder.
> UFW'de port kapatsanız bile Docker publish edilen porta dışarıdan erişim açar.
> Çözüm: `DOCKER-USER` zincirini kullan veya `/etc/docker/daemon.json`'da `"iptables": false` ayarla.

---

## nftables

`nftables` = iptables'ın **modern halefi**. Kernel 3.13+ ile gelir, iptables'ı tamamen değiştirir.

#### iptables vs nftables

| Özellik | iptables | nftables |
|---------|----------|----------|
| Tablo/zincir | Sabit (filter, nat, mangle) | Kullanıcı tanımlı |
| Syntax | Her tablo ayrı komut (`iptables`, `ip6tables`, `arptables`) | Tek araç (`nft`) |
| IPv4/IPv6 | Ayrı kural setleri | Birleşik |
| Performans | Linear kural tarama | **Set/map** ile O(1) lookup |
| Atomic update | Hayır | **Evet** (tüm kurallar tek seferde) |
| Uyumluluk | Yaygın, legacy | Yeni standard |

#### nftables Temel Syntax

```bash
# Tablo oluştur
nft add table inet my_filter

# Zincir oluştur
nft add chain inet my_filter input { type filter hook input priority 0 \; policy drop \; }
nft add chain inet my_filter forward { type filter hook forward priority 0 \; policy drop \; }
nft add chain inet my_filter output { type filter hook output priority 0 \; policy accept \; }

# Kural ekle
nft add rule inet my_filter input ct state established,related accept
nft add rule inet my_filter input iif lo accept
nft add rule inet my_filter input tcp dport 22 accept
nft add rule inet my_filter input tcp dport { 80, 443 } accept
nft add rule inet my_filter input counter drop
```

#### nftables Script (Dosya ile Yönetim)

```bash
#!/usr/sbin/nft -f

flush ruleset

table inet firewall {
    chain input {
        type filter hook input priority 0; policy drop;

        # Established bağlantılar
        ct state established,related accept

        # Loopback
        iif lo accept

        # ICMP
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        # SSH
        tcp dport 22 accept

        # HTTP/HTTPS
        tcp dport { 80, 443 } accept

        # Log + drop
        counter log prefix "nft-drop: " drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        # Docker kuralları burada
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
```

```bash
# Script'i uygula (atomic — tüm kurallar tek seferde)
nft -f /etc/nftables.conf

# Mevcut kuralları göster
nft list ruleset

# Belirli tablo
nft list table inet firewall
```

#### nftables Set (Yüksek Performanslı Eşleşme)

```bash
# IP set tanımla
nft add set inet firewall blocklist { type ipv4_addr \; }

# IP ekle
nft add element inet firewall blocklist { 192.168.1.100, 10.0.0.50 }

# Set'i kuralda kullan
nft add rule inet firewall input ip saddr @blocklist drop

# Port set
nft add set inet firewall allowed_ports { type inet_service \; }
nft add element inet firewall allowed_ports { 22, 80, 443 }
nft add rule inet firewall input tcp dport @allowed_ports accept
```

> [!tip] Set Performansı
> iptables'da 1000 IP engellemek = 1000 kural (linear scan).
> nftables'da 1000 IP engellemek = 1 kural + 1 set (hash lookup, O(1)).

#### nftables NAT

```bash
table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100;

        # Port forwarding
        tcp dport 8080 dnat to 192.168.1.10:80
    }

    chain postrouting {
        type nat hook postrouting priority 100;

        # Masquerade
        oif "eth0" masquerade
    }
}
```

---

## iptables Yönetim Komutları

```bash
# Kuralları listele
iptables -L -n -v                 # filter tablosu
iptables -t nat -L -n -v          # nat tablosu
iptables -t mangle -L -n -v       # mangle tablosu

# Satır numaralarıyla listele
iptables -L --line-numbers

# Kural ekle
iptables -A INPUT -p tcp --dport 22 -j ACCEPT    # Sona ekle
iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT  # Başa ekle

# Kural sil
iptables -D INPUT 3                               # 3. kuralı sil
iptables -D INPUT -p tcp --dport 22 -j ACCEPT     # Matching ile sil

# Tüm kuralları temizle
iptables -F                       # Flush (tüm kurallar)
iptables -X                       # User-defined zincirleri sil
iptables -Z                       # Counter'ları sıfırla

# Kuralları kaydet / yükle
iptables-save > /etc/iptables/rules.v4
iptables-restore < /etc/iptables/rules.v4

# Default policy
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT
```

---

## Temel Firewall Şablonu (iptables)

```bash
#!/bin/bash
# Temiz başla
iptables -F
iptables -X
iptables -Z

# Default policy
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Loopback
iptables -A INPUT -i lo -j ACCEPT

# Established/related
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# ICMP (ping)
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# SSH (rate limited)
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m limit --limit 5/min -j ACCEPT

# HTTP/HTTPS
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# Log dropped
iptables -A INPUT -j LOG --log-prefix "iptables-drop: " --log-level 4
iptables -A INPUT -j DROP
```
