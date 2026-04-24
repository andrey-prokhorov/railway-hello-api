# GitOps-plan: joinly (API + App)

> Skapad: 2026-04-23
> Baserat på: Erfarenheter från railway-hello-api PoC
> Repo: https://github.com/andrey-prokhorov/joinly
> Branch att utgå från: `dockerfile`

---

## Vad som redan finns

Teamet på `dockerfile`-branchen har gjort ett solitt grundarbete:

| Vad | Status |
|-----|--------|
| `api/dockerfile` — multi-stage, non-root user, Alpine | Klar |
| `app/dockerfile` — multi-stage Node→Nginx, non-root user | Klar |
| `.dockerignore` i både `api/` och `app/` | Klar |
| CI-workflows för lint, test, säkerhetsaudit | Klar |
| GitHub Actions för image-build och deploy | **Saknas** |

Det som saknas är alltså själva GitOps-delen: automatisk bygge, push till GHCR och Railway-redeploy vid merge till `main`.

---

## Arkitekturen

```
joinly/
├── api/                   ← Node.js 22, Express 5, TypeScript, SQLite
│   ├── dockerfile
│   ├── .dockerignore
│   └── src/
├── app/                   ← React 19, Vite, TypeScript, MUI
│   ├── dockerfile
│   ├── .dockerignore
│   └── src/
└── .github/
    └── workflows/
        ├── api-ci.yml     ← Finns redan (lint, test, audit)
        ├── app-ci.yml     ← Finns redan
        ├── app-playwright.yml ← Finns redan
        ├── deploy-api.yml ← Ska skapas
        └── deploy-app.yml ← Ska skapas
```

**Tjänster och portar:**

| Tjänst | Port | Teknologi |
|--------|------|-----------|
| API | 3001 | Node.js/Express/TypeScript |
| App | 80 | React/Vite → Nginx |

---

## Viktiga skillnader från PoC:n

### 1. TypeScript — kräver build-steg

Appen är skriven i TypeScript och måste kompileras till JavaScript innan den kan köras. Multi-stage Dockerfilen hanterar detta:

```
Stage 1 (build):  Node 22 Alpine → npm ci → npm run build → dist/
Stage 2 (runtime): Node 22 Alpine → kopiera bara dist/ + node_modules
```

Det innebär att `npm run build` körs inuti Docker-bygget, inte i CI-steget. CI behöver bara trigga `docker build`.

### 2. SQLite — kräver persistent volym på Railway

SQLite är en filbaserad databas. Datafilen ligger i `api/data/`. Det är ett kritiskt problem för containeriserade miljöer:

**Utan volym:** Varje redeploy startar en ny container. All data i `data/`-mappen försvinner.

**Lösning:** Railway Volumes — en persistent disk som mountas in i containern.

```
Railway Volume
    /data (persistent disk)
        ↕ monteras in i containern som
api-container
    /app/data/joinly.db   ← databasefilen lever här
```

Volymen överlever redeploys och skalning. Se "Sätta upp Railway" nedan för hur det konfigureras.

### 3. Dockerfile heter `dockerfile` (lowercase)

Docker letar som standard efter filen `Dockerfile` (stor D). Teamets filer heter `dockerfile` (liten d). Docker build-kommandot måste ha en explicit `-f`-flagga:

```yaml
file: api/dockerfile   # i build-push-action
```

**Rekommendation:** Byt namn till `Dockerfile` (stor D) när branchen mergas — det är standardkonventionen och minskar risken för förvirring.

### 4. Kommunikation mellan tjänster

App-containern (Nginx) serverar enbart statiska filer. Den behöver veta var API:et är för att göra API-anrop. Det löses med en Railway-intern URL som sätts som build-arg vid bygget:

```
VITE_API_URL=https://joinly-api.railway.internal
```

Eller via den publika Railway-domänen om intern routing inte används:
```
VITE_API_URL=https://joinly-api-production.up.railway.app
```

Railway-interna URLer (`.railway.internal`) är inte nåbara utifrån — bara mellan tjänster i samma Railway-projekt.

### 5. Miljövariabler som behövs

| Variabel | Tjänst | Värde | Var den sätts |
|----------|--------|-------|----------------|
| `PORT` | API | Automatiskt av Railway | Railway (automatiskt) |
| `JWT_SECRET` | API | Hemlig nyckel | Railway → Service → Variables |
| `APP_VERSION` | Båda | Commit-SHA | Bakat i imagen av GHA |
| `VITE_API_URL` | App (build-time) | API:ets URL | GHA build-arg |

`JWT_SECRET` får aldrig vara hårdkodad — sätt den i Railway Variables, inte i koden.

---

## GitHub Actions-workflows

### deploy-api.yml

```yaml
name: Deploy API

on:
  push:
    branches: [main]
    paths:
      - 'api/**'
      - '.github/workflows/deploy-api.yml'

permissions:
  contents: read
  packages: write

env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Compute lowercase image name
        id: image
        run: |
          echo "name=ghcr.io/$(echo ${{ github.repository }} | tr '[:upper:]' '[:lower:]')-api" >> $GITHUB_OUTPUT

      - name: Build and push API image
        uses: docker/build-push-action@v5
        with:
          context: ./api
          file: api/dockerfile
          push: true
          tags: |
            ${{ steps.image.outputs.name }}:latest
            ${{ steps.image.outputs.name }}:${{ github.sha }}
          build-args: |
            APP_VERSION=${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Trigger Railway redeploy
        run: |
          curl --fail -s -X POST https://backboard.railway.com/graphql/v2 \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${{ secrets.RAILWAY_TOKEN }}" \
            -d '{
              "query": "mutation Redeploy($serviceId: String!, $environmentId: String!) { serviceInstanceRedeploy(serviceId: $serviceId, environmentId: $environmentId) }",
              "variables": {
                "serviceId": "${{ secrets.API_RAILWAY_SERVICE_ID }}",
                "environmentId": "${{ secrets.API_RAILWAY_ENVIRONMENT_ID }}"
              }
            }'
```

### deploy-app.yml

```yaml
name: Deploy App

on:
  push:
    branches: [main]
    paths:
      - 'app/**'
      - '.github/workflows/deploy-app.yml'

permissions:
  contents: read
  packages: write

env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Compute lowercase image name
        id: image
        run: |
          echo "name=ghcr.io/$(echo ${{ github.repository }} | tr '[:upper:]' '[:lower:]')-app" >> $GITHUB_OUTPUT

      - name: Build and push App image
        uses: docker/build-push-action@v5
        with:
          context: ./app
          file: app/dockerfile
          push: true
          tags: |
            ${{ steps.image.outputs.name }}:latest
            ${{ steps.image.outputs.name }}:${{ github.sha }}
          build-args: |
            APP_VERSION=${{ github.sha }}
            VITE_API_URL=${{ secrets.VITE_API_URL }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Trigger Railway redeploy
        run: |
          curl --fail -s -X POST https://backboard.railway.com/graphql/v2 \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${{ secrets.RAILWAY_TOKEN }}" \
            -d '{
              "query": "mutation Redeploy($serviceId: String!, $environmentId: String!) { serviceInstanceRedeploy(serviceId: $serviceId, environmentId: $environmentId) }",
              "variables": {
                "serviceId": "${{ secrets.APP_RAILWAY_SERVICE_ID }}",
                "environmentId": "${{ secrets.APP_RAILWAY_ENVIRONMENT_ID }}"
              }
            }'
```

---

## Sätta upp Railway steg för steg

### Steg 1 — Skapa projektet

1. Railway → **New Project** → **Empty project**
2. Namnge projektet `joinly`

### Steg 2 — API-tjänsten

1. I projektet → **+ New Service** → **Docker Image**
2. Image: `ghcr.io/andrey-prokhorov/joinly-api:latest`
3. Konfigureras under **Settings**:
   - **Port:** `3001` (Railway behöver veta vilken port att routa till)
4. Lägg till miljövariabler under **Variables**:
   - `JWT_SECRET` = ditt hemliga värde
5. Notera **Service ID** från URL:en: `railway.app/project/.../service/DETTA-ID`
6. Gå till **Networking → Generate Domain** (intern Railway-URL skapas automatiskt)

### Steg 3 — SQLite-volym på API-tjänsten

SQLite-databasen måste överleva redeploys.

1. I API-projektet → höger-klick "Add New Service" → **Volumes** → **Create Volume**
2. Mount path: `/app/data`
3. Railway skapar en persistent disk och monterar den vid `/app/data` i containern
4. Databasefilen på den sökvägen överlever nu alla framtida redeploys

### Steg 4 — App-tjänsten

1. **+ New Service** → **Docker Image**
2. Image: `ghcr.io/andrey-prokhorov/joinly-app:latest`
3. Port: `80` (Nginx)
4. **Networking → Generate Domain** → notera den publika URL:en

### Steg 5 — Hämta Environment ID

1. I Railway-projektet → klicka på miljönamnet (t.ex. `production`)
2. Environment ID finns i URL:en

### Steg 6 — GitHub Secrets

Lägg till på `github.com/andrey-prokhorov/joinly/settings/secrets/actions`:

| Secret | Värde |
|--------|-------|
| `RAILWAY_TOKEN` | Account token från Railway (Avatar nere till vänster → Account Settings → Tokens) |
| `API_RAILWAY_SERVICE_ID` | Service ID för API-tjänsten |
| `API_RAILWAY_ENVIRONMENT_ID` | Environment ID |
| `APP_RAILWAY_SERVICE_ID` | Service ID för App-tjänsten |
| `APP_RAILWAY_ENVIRONMENT_ID` | Environment ID (samma för båda om ett projekt) |
| `VITE_API_URL` | Publika Railway-URL:en för API:et, t.ex. `https://joinly-api-production.up.railway.app` |

### Steg 7 — Gör GHCR-paketen tillgängliga

GHCR-paket är privata som standard. Railway Hobby kan dra privata images, men kräver då credentials.

**Alternativ A (enklast):** Gör paketen publika
- `github.com/andrey-prokhorov` → **Packages** → välj paketet → **Package settings** → **Public**
- Gör detta för både `joinly-api` och `joinly-app` efter första push

**Alternativ B:** Privata paket med Railway-credentials
- Skapa ett GitHub PAT med `read:packages`-scope
- I Railway → Service → Settings → **Deploy** → lägg till registry credentials
- Gör detta för båda tjänsterna

### Steg 8 — Merge dockerfile-branchen och trigga första deploy

1. Skapa en PR från `dockerfile` → `main`
2. Lägg till `deploy-api.yml` och `deploy-app.yml` i `.github/workflows/` som en del av PRen
3. Byt namn på `api/dockerfile` → `api/Dockerfile` och `app/dockerfile` → `app/Dockerfile`
4. Merga till `main`
5. GHA triggar automatiskt båda deploy-workflows
6. Verifiera att Railway drar de nya imagerna

---

## Verifiera att allt fungerar

```bash
# API
curl https://joinly-api-production.up.railway.app/health

# App
curl https://joinly-app-production.up.railway.app/
```

Kontrollera också att databas-volymen fungerar:
- Skapa något i appen (logga in, skapa en post, etc.)
- Trigga en redeploy manuellt i Railway
- Verifiera att datan finns kvar efter deployn

---

## Checklista

**Förberedelser (i dockerfile-branchen, innan merge):**
- [ ] Byt namn: `api/dockerfile` → `api/Dockerfile`
- [ ] Byt namn: `app/dockerfile` → `app/Dockerfile`
- [ ] Lägg till `ARG APP_VERSION=dev` + `ENV APP_VERSION=$APP_VERSION` i båda Dockerfiles
- [ ] Lägg till `deploy-api.yml` i `.github/workflows/`
- [ ] Lägg till `deploy-app.yml` i `.github/workflows/`
- [ ] Kontrollera att `VITE_API_URL` tas emot som build-arg i `app/Dockerfile`

**Railway:**
- [ ] Skapa projekt med tjänsterna `api` och `app`
- [ ] Skapa volym på API-tjänsten, mount path `/app/data`
- [ ] Sätt `JWT_SECRET` i API-tjänstens Variables
- [ ] Sätt port `3001` för API och `80` för App
- [ ] Generera domäner för båda tjänsterna
- [ ] Notera Service ID och Environment ID för båda

**GitHub:**
- [ ] Lägg till alla 6 Repository secrets
- [ ] Gör GHCR-paketen tillgängliga (publika eller Railway-credentials)

**Verifiering:**
- [ ] Båda GHA-workflows gröna efter merge
- [ ] API svarar på `/health`
- [ ] App laddar och kan nå API:et
- [ ] Data finns kvar efter redeploy (volym fungerar)
