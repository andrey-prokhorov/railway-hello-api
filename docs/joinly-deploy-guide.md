# Deploya joinly till Railway — snabbguide

> För teamet som byggt Dockerfilerna på `dockerfile`-branchen

---

## Vad vi gör

Vi sätter upp ett flöde där ett `git push` till `main` automatiskt:
1. Bygger Docker-imagen i GitHub Actions
2. Pushar den till GHCR (GitHub's egna container registry — ingen Docker Hub)
3. Säger åt Railway att starta om med den nya imagen

---

## Tre saker att göra i repot

### 1. Byt namn på Dockerfilerna

Docker förväntar sig stort D. Gör detta i `dockerfile`-branchen:

```
api/dockerfile   →   api/Dockerfile
app/dockerfile   →   app/Dockerfile
```

### 2. Lägg till APP_VERSION i båda Dockerfilerna

Lägg till dessa två rader i varje Dockerfile, precis före `USER`-direktivet:

```dockerfile
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
```

Gör det möjligt att se exakt vilken commit som kör live.

### 3. Skapa två workflow-filer

Skapa `.github/workflows/deploy-api.yml`:

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
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Compute image name
        id: image
        run: |
          echo "name=ghcr.io/$(echo ${{ github.repository }} | tr '[:upper:]' '[:lower:]')-api" >> $GITHUB_OUTPUT

      - uses: docker/build-push-action@v5
        with:
          context: ./api
          file: api/Dockerfile
          push: true
          tags: |
            ${{ steps.image.outputs.name }}:latest
            ${{ steps.image.outputs.name }}:${{ github.sha }}
          build-args: APP_VERSION=${{ github.sha }}
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

Skapa `.github/workflows/deploy-app.yml`:

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
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Compute image name
        id: image
        run: |
          echo "name=ghcr.io/$(echo ${{ github.repository }} | tr '[:upper:]' '[:lower:]')-app" >> $GITHUB_OUTPUT

      - uses: docker/build-push-action@v5
        with:
          context: ./app
          file: app/Dockerfile
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

## Sätta upp Railway

### API-tjänsten

1. Railway → **New Project** → **New Service** → **Docker Image**
2. Image: `ghcr.io/andrey-prokhorov/joinly-api:latest`
3. **Settings → Networking** → sätt port `3001`
4. **Variables** → lägg till `JWT_SECRET`
5. **Volumes** → **Create Volume** → mount path: `/app/data`
   ⚠️ Detta är kritiskt — utan volymen förlorar ni all SQLite-data vid varje redeploy
6. **Networking → Generate Domain**
7. Notera **Service ID** från URL:en

### App-tjänsten

1. **New Service** → **Docker Image**
2. Image: `ghcr.io/andrey-prokhorov/joinly-app:latest`
3. Port: `80`
4. **Networking → Generate Domain**
5. Notera **Service ID** från URL:en

### Hämta IDs och token

| Vad | Var |
|-----|-----|
| Service ID | URL:en när du är inne på servicen: `.../service/DETTA-ID` |
| Environment ID | URL:en på environment-sidan: `.../environment/DETTA-ID` |
| Railway Token | Avatar nere till vänster → Account Settings → Tokens → Create token |

---

## GitHub Secrets

Lägg till på `github.com/andrey-prokhorov/joinly/settings/secrets/actions`:

| Secret | Vad |
|--------|-----|
| `RAILWAY_TOKEN` | Account token från Railway |
| `API_RAILWAY_SERVICE_ID` | Service ID för API |
| `API_RAILWAY_ENVIRONMENT_ID` | Environment ID |
| `APP_RAILWAY_SERVICE_ID` | Service ID för App |
| `APP_RAILWAY_ENVIRONMENT_ID` | Environment ID (samma som ovan) |
| `VITE_API_URL` | Publika URL:en för API:et, t.ex. `https://joinly-api-production.up.railway.app` |

---

## Gör GHCR-paketen tillgängliga

GHCR-paket är privata som standard. Efter första push:

`github.com/andrey-prokhorov` → **Packages** → välj paketet → **Package settings** → **Public**

Gör detta för både `joinly-api` och `joinly-app`.

---

## Merge och första deploy

1. Merga `dockerfile`-branchen till `main`
2. GHA triggar automatiskt båda workflows
3. Verifiera att båda är gröna i **Actions**-fliken
4. Testa live:

```bash
curl https://joinly-api-production.up.railway.app/health
```

---

## Checklista

**I repot:**
- [ ] `api/dockerfile` → `api/Dockerfile`
- [ ] `app/dockerfile` → `app/Dockerfile`
- [ ] `ARG APP_VERSION` + `ENV APP_VERSION` i båda Dockerfiles
- [ ] `deploy-api.yml` skapad
- [ ] `deploy-app.yml` skapad

**Railway:**
- [ ] API-tjänst skapad med port `3001`
- [ ] Volym skapad på API med mount path `/app/data`
- [ ] `JWT_SECRET` satt i API Variables
- [ ] App-tjänst skapad med port `80`
- [ ] Domäner genererade för båda

**GitHub:**
- [ ] 6 secrets inlagda
- [ ] GHCR-paketen gjorda publika efter första push
