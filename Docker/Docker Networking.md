# Docker Networking

Docker, container'ların network iletişimini **Linux kernel network stack** üzerinde yönetir.
Her container kendi [[Linux Namespaces#Network Namespace (netns)|network namespace]]'ine sahiptir.

---

## Network Modları

Docker 4 temel network driver'ı sunar:

| Driver | Açıklama | Kullanım |
|--------|----------|----------|
| **bridge** | Default. İzole sanal network | Tek host, container'lar arası iletişim |
| **host** | Host network'ü doğrudan kullanır | Max performans, izolasyon yok |
| **none** | Network yok | Tamamen izole container |
| **overlay** | Multi-host network | Docker Swarm / cluster |

---

## Bridge Network (Default)

Docker kurulduğunda otomatik `bridge` network oluşturulur (`docker0`).

```
Host
├── eth0 (fiziksel NIC)           ← dış dünya
├── docker0 (bridge, 172.17.0.1) ← sanal switch
│   ├── veth123 ←──── eth0 (Container A, 172.17.0.2)
│   └── veth456 ←──── eth0 (Container B, 172.17.0.3)
└── iptables NAT kuralları
```

#### Ne olur?
1. Container oluşturulur → yeni network namespace
2. **veth pair** yaratılır (sanal kablo)
3. Bir ucu container'a (`eth0`), diğer ucu `docker0` bridge'ine bağlanır
4. Container'a bridge subnet'inden IP atanır
5. iptables NAT kuralları eklenir

```bash
# Default bridge network'ü incele
docker network inspect bridge

# Custom bridge oluştur
docker network create --driver bridge my-network
```

> [!tip] Custom vs Default Bridge
> Custom bridge network'ler **DNS resolution** sağlar (container ismiyle erişim).
> Default bridge'de bu yoktur, sadece IP ile erişilir.

---

## veth Pair Nasıl Çalışır?

**veth (Virtual Ethernet)** = iki uçlu sanal kablo. Bir uca giren paket diğer uçtan çıkar.

```
Container namespace          Host namespace
┌──────────────┐            ┌──────────────┐
│   eth0       │←── veth ──→│   vethXXX    │
│ 172.17.0.2   │            │  (docker0'a  │
└──────────────┘            │   bağlı)     │
                            └──────────────┘
```

```bash
# Host'tan veth pair'leri görmek
ip link show type veth

# Container'ın network interface'leri
docker exec <container> ip addr show

# Bridge'e bağlı interface'ler
brctl show docker0
# veya
bridge link show
```

#### Paket Akışı (Container → Dış Dünya)
```
Container eth0 → veth pair → docker0 bridge → iptables MASQUERADE → host eth0 → internet
```

#### Paket Akışı (Dış Dünya → Container, port mapping ile)
```
internet → host eth0 → iptables DNAT → docker0 bridge → veth pair → Container eth0
```

---

## iptables NAT Kuralları

Docker **iptables** üzerinden otomatik NAT kuralları oluşturur.

#### MASQUERADE (outbound)
Container'dan dışarı çıkan paketlerin source IP'si host IP'sine dönüştürülür.

```bash
# Docker'ın oluşturduğu NAT kurallarını görmek
iptables -t nat -L -n -v

# POSTROUTING zinciri (outbound SNAT)
-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
```

#### DNAT (inbound, port mapping)
`-p 8080:80` kullanıldığında:

```bash
# PREROUTING zinciri (inbound DNAT)
-A DOCKER -p tcp --dport 8080 -j DNAT --to-destination 172.17.0.2:80
```

#### FORWARD zinciri
```bash
# Container'lar arası iletişim izni
-A FORWARD -i docker0 -o docker0 -j ACCEPT

# Container → dış dünya izni
-A FORWARD -i docker0 ! -o docker0 -j ACCEPT

# Dış dünya → container (established connections)
-A FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

> [!warning] Güvenlik
> Docker varsayılan olarak iptables kurallarını **otomatik** ekler.
> Bu, UFW gibi firewall'ları **bypass** edebilir!
> `--iptables=false` ile devre dışı bırakılabilir ama manual kural yönetimi gerekir.

---

## Port Mapping Detayları

```bash
docker run -p 8080:80 nginx
```

Bu komut şunu yapar:

1. Host'un **tüm interface'lerinde** port 8080'i dinler
2. Gelen trafiği container'ın port 80'ine yönlendirir (DNAT)
3. `docker-proxy` process'i oluşturulur (userspace fallback)

#### Farklı Binding Seçenekleri
```bash
# Sadece localhost'tan erişim
docker run -p 127.0.0.1:8080:80 nginx

# Belirli interface
docker run -p 192.168.1.10:8080:80 nginx

# Random host port
docker run -p 80 nginx
docker port <container>  # Atanan portu görmek

# UDP port mapping
docker run -p 8080:80/udp myapp
```

#### docker-proxy Nedir?
```bash
# Her port mapping için bir docker-proxy process'i oluşur
ps aux | grep docker-proxy
# /usr/bin/docker-proxy -proto tcp -host-ip 0.0.0.0 -host-port 8080 -container-ip 172.17.0.2 -container-port 80
```

- iptables kuralları çalışmazsa (hairpin NAT gibi) devreye girer
- Performans overhead'i var
- `"userland-proxy": false` ile `/etc/docker/daemon.json`'da devre dışı bırakılabilir

---

## DNS Resolution

#### Custom Bridge Network ile
```bash
docker network create app-net
docker run -d --name db --network app-net postgres
docker run -d --name api --network app-net myapi
```

Container `api` içinden:
```bash
# İsimle erişim (DNS otomatik çözülür)
ping db           # → 172.18.0.2
curl http://db:5432
```

#### DNS Nasıl Çalışır?
- Docker **embedded DNS server** çalıştırır (`127.0.0.11`)
- Container'ların `/etc/resolv.conf` dosyasına bu DNS yazılır
- Container isimleri ve network alias'ları çözümlenir

```bash
# Container'ın DNS konfigürasyonu
docker exec api cat /etc/resolv.conf
# nameserver 127.0.0.11
```

#### Network Alias
```bash
docker run -d --name db1 --network app-net --network-alias db postgres
docker run -d --name db2 --network app-net --network-alias db postgres

# "db" ismine yapılan DNS sorgusu her ikisini de döner (round-robin)
```

---

## Host Network

```bash
docker run --network host nginx
```

- Container **host'un network namespace'ini kullanır**
- Ayrı IP/interface yok
- Port mapping gereksiz (doğrudan host portları kullanılır)
- **Network izolasyonu yok**

Ne zaman kullanılır:
- Max network performans gerektiğinde
- Bridge overhead istenmeyen durumlar (veth hop + iptables traversal yok)
- Monitoring / network tool container'ları

> [!warning] Dikkat
> Host mode'da port çakışması riski var. İki container aynı portu kullanamaz.

---

## None Network

```bash
docker run --network none myapp
```

- Sadece `lo` (loopback) interface'i var
- Dış dünyayla iletişim **tamamen kapalı**
- Batch processing, offline hesaplama gibi senaryolar için

---

## Overlay Network (Multi-Host)

Docker Swarm veya multi-host ortamları için.

```bash
# Swarm init
docker swarm init

# Overlay network oluştur
docker network create --driver overlay my-overlay

# Service deploy
docker service create --network my-overlay --name web nginx
```

#### Nasıl Çalışır?
```
Host A                          Host B
┌─────────────┐                ┌─────────────┐
│ Container X │                │ Container Y │
│ 10.0.0.2    │                │ 10.0.0.3    │
└──────┬──────┘                └──────┬──────┘
       │ VXLAN tunnel (UDP 4789)      │
       └──────────────────────────────┘
```

- **VXLAN** (Virtual Extensible LAN) encapsulation kullanır
- L2 frame'leri UDP paketleri içine sarar
- Container'lar farklı host'larda olsa bile aynı subnet'te görünür
- Gossip protokolü ile node discovery

---

## Network Komutları Özet

```bash
# Network listele
docker network ls

# Network detayı
docker network inspect <network>

# Network oluştur
docker network create --driver bridge --subnet 172.20.0.0/16 my-net

# Container'ı network'e bağla
docker network connect my-net <container>

# Container'ı network'ten çıkar
docker network disconnect my-net <container>

# Kullanılmayan network'leri temizle
docker network prune
```
