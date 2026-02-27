**Docker Compose**, birden fazla container'ı tek bir YAML dosyası ile tanımlayıp yönetmeyi sağlar.

Tek container → `docker run`
Çoklu container → `docker compose`

---

## Temel Yapı

```yaml
# docker-compose.yml (veya compose.yml)
services:
  web:
    image: nginx:alpine
    ports:
      - "8080:80"
  api:
    build: ./api
    ports:
      - "3000:3000"
    environment:
      - DB_HOST=db
  db:
    image: postgres:16
    volumes:
      - pg-data:/var/lib/postgresql/data
    environment:
      - POSTGRES_PASSWORD=secret

volumes:
  pg-data:
```

```bash
# Tüm servisleri başlat
docker compose up -d

# Logları izle
docker compose logs -f

# Durdur ve temizle
docker compose down

# Volume'larla birlikte sil
docker compose down -v
```

---

## depends_on

Service başlatma **sırasını** belirler.

```yaml
services:
  api:
    build: ./api
    depends_on:
      - db
      - redis
  db:
    image: postgres:16
  redis:
    image: redis:alpine
```

- `db` ve `redis` **önce** başlar, sonra `api`
- Ama container'ın **başlaması** ≠ **hazır olması**

> [!warning] Önemli
> `depends_on` sadece container start sırasını kontrol eder.
> PostgreSQL'in bağlantı kabul etmeye hazır olup olmadığını **garanti etmez**.
> Bunun için `healthcheck` + `condition` kullanılmalı.

---

## Healthcheck

Container'ın **gerçekten hazır olup olmadığını** kontrol eder.

```yaml
services:
  api:
    build: ./api
    depends_on:
      db:
        condition: service_healthy
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: secret
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
```

#### Healthcheck Parametreleri
| Parametre | Açıklama |
|-----------|----------|
| `test` | Çalıştırılacak komut |
| `interval` | Kontrol aralığı |
| `timeout` | Komutun max süresi |
| `retries` | Başarısız deneme sayısı |
| `start_period` | İlk kontrol öncesi bekleme süresi |

#### Yaygın Healthcheck Örnekleri
```yaml
# PostgreSQL
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U postgres"]

# MySQL
healthcheck:
  test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]

# Redis
healthcheck:
  test: ["CMD", "redis-cli", "ping"]

# HTTP endpoint
healthcheck:
  test: ["CMD-SHELL", "curl -f http://localhost:3000/health || exit 1"]
```

---

## Environment Management

#### Inline (compose dosyasında)
```yaml
services:
  api:
    environment:
      - NODE_ENV=production
      - DB_HOST=db
      - DB_PORT=5432
```

#### .env Dosyası ile
```bash
# .env (compose dosyasıyla aynı dizinde)
POSTGRES_PASSWORD=supersecret
NODE_ENV=production
API_PORT=3000
```

```yaml
services:
  api:
    ports:
      - "${API_PORT}:3000"
    environment:
      - NODE_ENV=${NODE_ENV}
  db:
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
```

#### env_file ile
```bash
# config/api.env
NODE_ENV=production
DB_HOST=db
JWT_SECRET=mysecretkey
```

```yaml
services:
  api:
    env_file:
      - ./config/api.env
```

> [!tip] Best Practice
> - `.env` dosyasını `.gitignore`'a ekle
> - Sensitive değerler için Docker secrets veya external secret manager kullan
> - `.env.example` dosyası ile gerekli değişkenleri dokümante et

---

## Networking (Compose)

Docker Compose otomatik olarak bir **bridge network** oluşturur.

```yaml
# Compose otomatik "myapp_default" network oluşturur
# Service isimleri DNS olarak çözümlenir
services:
  api:
    build: ./api
    # api container'ından: curl http://db:5432
  db:
    image: postgres:16
```

#### Custom Network Tanımlama
```yaml
services:
  frontend:
    networks:
      - frontend-net
  api:
    networks:
      - frontend-net
      - backend-net
  db:
    networks:
      - backend-net

networks:
  frontend-net:
  backend-net:
```

Bu yapıda:
- `frontend` → `api`'ye erişebilir
- `api` → hem `frontend`'e hem `db`'ye erişebilir
- `frontend` → `db`'ye **erişemez** (network izolasyonu)

---

## Restart Policy

```yaml
services:
  api:
    restart: unless-stopped
```

| Policy | Davranış |
|--------|----------|
| `no` | Restart yok (default) |
| `always` | Her zaman restart |
| `on-failure` | Sadece hata ile çıkışta restart |
| `unless-stopped` | Manuel durdurulmadıkça restart |

---

## Örnek: Nginx + Node.js + PostgreSQL Stack

```yaml
services:
  # Reverse Proxy
  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      api:
        condition: service_healthy
    restart: unless-stopped

  # API Server
  api:
    build:
      context: ./api
      dockerfile: Dockerfile
    environment:
      - NODE_ENV=production
      - DATABASE_URL=postgresql://postgres:${DB_PASSWORD}@db:5432/myapp
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:3000/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 15s
    restart: unless-stopped

  # Database
  db:
    image: postgres:16-alpine
    environment:
      - POSTGRES_DB=myapp
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=${DB_PASSWORD}
    volumes:
      - pg-data:/var/lib/postgresql/data
      - ./db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
    restart: unless-stopped

volumes:
  pg-data:
```

#### Nginx Config (nginx/nginx.conf)
```nginx
upstream api {
    server api:3000;
}

server {
    listen 80;

    location / {
        proxy_pass http://api;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

---

## Compose Komutları Özet

```bash
# Başlat (detached)
docker compose up -d

# Rebuild ile başlat
docker compose up -d --build

# Belirli service'i başlat
docker compose up -d api

# Durdur
docker compose stop

# Durdur + container'ları sil
docker compose down

# Durdur + container + volume sil
docker compose down -v

# Loglar
docker compose logs -f api

# Çalışan container'lar
docker compose ps

# Service'e komut çalıştır
docker compose exec api sh

# Scale (aynı service'den birden fazla)
docker compose up -d --scale api=3

# Config doğrula
docker compose config
```
