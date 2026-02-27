Daha **küçük**, **hızlı**, **güvenli** ve **cache-dostu** image'lar oluşturmak için Dockerfile yazım kuralları.

---

## ENTRYPOINT vs CMD

Her ikisi de container başladığında çalışacak komutu belirler ama davranışları farklıdır.

#### CMD
- Container'ın **default komutu**
- `docker run` ile **override edilebilir**

```dockerfile
FROM node:20-alpine
CMD ["node", "server.js"]
```

```bash
docker run myapp                  # → node server.js
docker run myapp node repl        # → node repl (CMD override edildi)
```

#### ENTRYPOINT
- Container'ın **sabit çalıştırılacak programı**
- `docker run` argümanları **ENTRYPOINT'e eklenir**

```dockerfile
FROM alpine
ENTRYPOINT ["ping"]
CMD ["google.com"]
```

```bash
docker run myapp                  # → ping google.com
docker run myapp cloudflare.com   # → ping cloudflare.com (CMD override, ENTRYPOINT sabit)
```

#### Birlikte Kullanım (exec form)

| ENTRYPOINT | CMD | Sonuç |
|------------|-----|-------|
| `["ping"]` | `["google.com"]` | `ping google.com` |
| Yok | `["node", "server.js"]` | `node server.js` |
| `["node"]` | `["server.js"]` | `node server.js` |

> [!tip] Kural
> - **ENTRYPOINT** = bu container ne yapar (program)
> - **CMD** = default argümanlar (override edilebilir)
> - CLI tool image'ları → `ENTRYPOINT` kullan
> - Uygulama image'ları → `CMD` genelde yeterli

#### Shell Form vs Exec Form

```dockerfile
# Shell form (PID 1 = /bin/sh, SIGTERM düzgün çalışmaz)
CMD node server.js

# Exec form (PID 1 = node, SIGTERM düzgün yakalanır) ✓
CMD ["node", "server.js"]
```

> [!warning] Her zaman exec form kullan
> Shell form'da process `/bin/sh -c` altında çalışır.
> `SIGTERM` signal'i shell'e gider, uygulamaya ulaşmaz → **graceful shutdown** çalışmaz.

---

## Multi-Stage Build

Tek Dockerfile'da birden fazla `FROM` kullanarak **build dependency'lerini final image'dan çıkarmak**.

#### Problem: Tek stage
```dockerfile
FROM node:20
WORKDIR /app
COPY . .
RUN npm install
RUN npm run build
CMD ["node", "dist/server.js"]
# Image boyutu: ~1 GB (node_modules, devDependencies, build tools hepsi içeride)
```

#### Çözüm: Multi-stage
```dockerfile
# Stage 1: Build
FROM node:20 AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Stage 2: Production
FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/package*.json ./
RUN npm ci --only=production
CMD ["node", "dist/server.js"]
# Image boyutu: ~150 MB
```

#### Go Örneği (daha dramatik fark)
```dockerfile
# Build stage
FROM golang:1.22 AS builder
WORKDIR /app
COPY . .
RUN CGO_ENABLED=0 go build -o server .

# Final stage
FROM scratch
COPY --from=builder /app/server /server
CMD ["/server"]
# Image boyutu: ~10 MB (sadece binary!)
```

---

## Layer Cache Optimizasyonu

Docker her `RUN`, `COPY`, `ADD` komutunu ayrı bir layer olarak cache'ler.
Bir layer değişirse, **ondan sonraki tüm layer'lar invalidate olur**.

#### Kötü: Her değişiklikte tüm dependency'ler yeniden yüklenir
```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY . .                    # Kod değişince bu layer bozulur
RUN npm install             # Bu da yeniden çalışır (yavaş!)
CMD ["node", "server.js"]
```

#### İyi: Dependency'ler ayrı layer'da, sadece değişince yeniden yüklenir
```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./       # Sadece package.json değişirse bozulur
RUN npm ci                  # Dependency cache korunur
COPY . .                    # Kod değişiklikleri sadece burayı etkiler
CMD ["node", "server.js"]
```

#### Cache Kuralları
1. Seyrek değişen dosyaları **önce** kopyala
2. `package.json` / `go.mod` / `requirements.txt` → **koddan önce**
3. `RUN` komutlarını mümkünse **birleştir** (layer sayısını azaltır)

```dockerfile
# Kötü: 3 layer
RUN apt-get update
RUN apt-get install -y curl
RUN apt-get clean

# İyi: 1 layer
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
```

---

## .dockerignore

Build context'ten **gereksiz dosyaları hariç tutar**. `.gitignore` ile aynı syntax.

```
# .dockerignore
node_modules
npm-debug.log
.git
.gitignore
.env
.env.*
Dockerfile
docker-compose.yml
README.md
.vscode
*.md
dist
coverage
.nyc_output
```

Neden önemli:
- Build context boyutunu küçültür → **daha hızlı build**
- Sensitive dosyaların (`*.env`, `.git`) image'a girmesini engeller
- `node_modules`'ın container'a kopyalanmasını önler (zaten `npm install` yapılacak)

---

## Minimal Base Image

| Image | Boyut | Açıklama |
|-------|-------|----------|
| `ubuntu:22.04` | ~77 MB | Tam OS |
| `debian:bookworm-slim` | ~74 MB | Debian minimal |
| `alpine:3.19` | ~7 MB | Musl libc, BusyBox |
| `node:20` | ~1 GB | Full Debian + Node |
| `node:20-alpine` | ~130 MB | Alpine + Node |
| `node:20-slim` | ~200 MB | Debian slim + Node |
| `gcr.io/distroless/nodejs20` | ~130 MB | Shell yok, sadece runtime |
| `scratch` | 0 MB | Boş (statik binary'ler için) |

> [!tip] Seçim Rehberi
> - **Alpine**: Çoğu use case için yeterli, küçük, hızlı
> - **Distroless**: Shell bile yok, attack surface minimum (production)
> - **Scratch**: Go/Rust gibi statik compile edilen diller için ideal
> - **Slim**: Alpine uyumsuzlukları varsa (musl vs glibc)

---

## Non-Root User

Container default olarak **root** çalışır. Bu güvenlik riski oluşturur.

```dockerfile
FROM node:20-alpine

# Non-root user oluştur
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app
COPY --chown=appuser:appgroup . .
RUN npm ci --only=production

# Root'tan çık
USER appuser

CMD ["node", "server.js"]
```

> [!warning] Neden Önemli?
> Root olarak çalışan container'da bir exploit varsa:
> - Container escape riski artar
> - Host filesystem'e erişim mümkün olabilir
> - [[Docker Security]] konusunda detaylı bilgi

---

## Diğer Best Practices

#### LABEL ile metadata
```dockerfile
LABEL maintainer="ayberkeser"
LABEL version="1.0"
LABEL description="My API service"
```

#### HEALTHCHECK
```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD curl -f http://localhost:3000/health || exit 1
```

#### EXPOSE (dokümantasyon amaçlı)
```dockerfile
# Gerçek port mapping yapmaz, sadece belgelendirir
EXPOSE 3000
```

#### ARG vs ENV
```dockerfile
# ARG: Sadece build sırasında (image'da kalmaz)
ARG NODE_VERSION=20

# ENV: Runtime'da da mevcut (image'da kalır)
ENV NODE_ENV=production
```

```bash
# ARG'ı build sırasında override et
docker build --build-arg NODE_VERSION=18 .
```

#### Özet Checklist
- [ ] Multi-stage build kullan
- [ ] `package.json`'u koddan önce kopyala (cache)
- [ ] `.dockerignore` ekle
- [ ] Minimal base image seç (`alpine` / `distroless`)
- [ ] Non-root user ile çalıştır
- [ ] Exec form kullan (`CMD ["node", "server.js"]`)
- [ ] RUN komutlarını birleştir
- [ ] `apt-get clean` / `rm -rf /var/lib/apt/lists/*` ile temizle
- [ ] HEALTHCHECK ekle
- [ ] Sensitive veri image'a koyma (build arg ile secret geçme)
