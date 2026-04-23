# GitOps-flöde: GitHub → GHCR → Railway

> Skapad: 2026-04-23
> Projekt: railway-hello-api (PoC)
> Railway-plan: Hobby ($5/mån)
> GitHub-repo: Publikt
> Status: **Verifierad end-to-end**

---

## Vad är det här?

En PoC (proof of concept) för att sätta upp ett automatiserat deploy-flöde där ett `git push` räcker för att bygga, paketera och driftsätta en Node.js-app på Railway.

Målet var inte att bygga något avancerat — utan att verifiera att flödet faktiskt fungerar och dokumentera varje beslut, problem och lösning så att det enkelt kan återanvändas i ett riktigt projekt med separat API och frontend.

---

## Hur flödet fungerar

```
git push main
      │
      ▼
GitHub Actions
      │
      ├─ Bygger Docker-imagen från Dockerfilen
      ├─ Pushar imagen till GHCR (GitHub Container Registry)
      │    ghcr.io/palhamel/railway-hello-api:latest
      │    ghcr.io/palhamel/railway-hello-api:<commit-sha>
      └─ Anropar Railway GraphQL API → "starta om med ny image"
                    │
                    ▼
               Railway
                    │
                    └─ Drar den nya imagen från GHCR
                       Startar om containern
                       Appen är live
```

**Viktigt att förstå:** Railway bygger ingenting. Det är en ren runtime som drar en färdigbyggd image och kör den. All byggintelligens sitter i GitHub Actions och Dockerfilen.

Det betyder att man kan byta ut Railway mot Fly.io, Render eller en egen VPS utan att ändra ett enda byggsteg.

---

## Vad vi byggde, steg för steg

### 1. Appen

En minimal Express-app med två endpoints:

- `GET /` — returnerar `{ message, version, timestamp }`
- `GET /health` — returnerar `{ status: 'ok' }`

Inget mer. Syftet var att ha något körbart att testa flödet med.

**Tre saker i koden som är kritiska för containeriserad miljö:**

```js
// Måste lyssna på 0.0.0.0, INTE localhost
// localhost inuti en container är containerns egna loopback — ej nåbart utifrån
app.listen(PORT, '0.0.0.0', () => { ... })

// PORT måste komma från miljövariabel
// Railway injicerar den dynamiskt — appen får aldrig anta en fast port
const PORT = process.env.PORT || 3000

// APP_VERSION bakas in av CI vid bygget
// Gör det möjligt att verifiera exakt vilken kod som kör i produktion
const VERSION = process.env.APP_VERSION || 'dev'
```

### 2. Teknikval

| Teknik | Version | Varför |
|--------|---------|--------|
| Node.js | 24 (Alpine) | Senaste LTS, ~60 MB image mot ~1 GB för full image |
| Express | 5.2.1 | Express 4.x hade aktiva CVE:er; Express 5 fixade dem och hanterar async-fel automatiskt |
| ES Modules | `"type": "module"` | Node 22+ kör ESM native, ingen transpilering behövs |

Vi startade med Express 4.21.2 — `npm audit` flaggade direkt för `path-to-regexp` ReDoS (high) och `qs` DoS (moderate). Uppgraderingen till Express 5 löste alla sårbarheter och gav `0 vulnerabilities`.

### 3. Dockerfile

```dockerfile
FROM node:24-alpine

WORKDIR /app

COPY --chown=node:node package*.json ./
RUN npm ci --omit=dev

COPY --chown=node:node . .

ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION

USER node

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:${PORT:-3000}/health || exit 1

CMD ["node", "server.js"]
```

**Varför `package*.json` kopieras före koden:**
Docker cachar lager i ordning. Om allt kopieras på en gång ogiltigförklarar ett enda tecken i `server.js` hela `npm ci`-lagret. Rätt ordning: dependencies installeras bara om när `package.json` eller `package-lock.json` ändras.

**Varför `--chown=node:node` på COPY:**
`node:24-alpine` har en inbyggd `node`-användare (icke-root). Filerna måste ägas av den användaren innan vi byter till den med `USER node`. En säkerhetsrevision (se nedan) flaggade att containern körde som root — det fixades med detta mönster.

**Varför `ARG` + `ENV` för APP_VERSION:**
`ARG` tar emot värdet från CI vid bygget (`--build-arg APP_VERSION=<sha>`). `ENV` gör det tillgängligt som miljövariabel i den körande containern. Utan `ENV` skulle `process.env.APP_VERSION` vara undefined vid runtime.

### 4. GitHub Actions-workflow

Workflowen har sex steg:

1. **Checkout** — hämtar koden
2. **Docker Buildx** — modern byggmotor med cache-stöd
3. **Login till GHCR** — med det automatiska `GITHUB_TOKEN`, kräver `packages: write` i permissions
4. **Lowercase image-namn** — Docker kräver lowercase; GitHub-reponamn kan ha versaler
5. **Build + push** — bygger imagen med commit-SHA inbakat, pushar två tags
6. **Railway redeploy** — GraphQL-anrop som ber Railway dra den nya imagen

**Varför lowercase-steget är nödvändigt:**
```yaml
echo "name=ghcr.io/$(echo ${{ github.repository }} | tr '[:upper:]' '[:lower:]')" >> $GITHUB_OUTPUT
```
Om man skriver `ghcr.io/${{ github.repository }}` direkt och reponamnet innehåller versaler kraschar pushen mot GHCR. Det är ett tyst fel som är svårt att felsöka.

**Varför dubbla tags:**
- `:latest` — Railway drar alltid senaste
- `:<sha>` — oföränderlig historik, man kan rulla tillbaka till exakt en tidigare commit

**Varför GHA cache:**
```yaml
cache-from: type=gha
cache-to: type=gha,mode=max
```
`mode=max` sparar alla mellanliggande Docker-lager. En Express-app med oförändrade dependencies bygger på ~5 sek istället för ~45 sek.

**Varför Railway-triggern är ett GraphQL-anrop:**
Railway har webhooks, men de triggas av Railway-interna händelser — inte utifrån. För att trigga från GHA krävs GraphQL API. Mutationen kräver BÅDA `serviceId` och `environmentId` — bara `serviceId` räcker inte eftersom Railway stödjer flera miljöer per service.

### 5. Säkerhetsrevision

Innan första commit kördes en säkerhetsrevision. Den flaggade två saker:

| Problem | Fix |
|---------|-----|
| Container körde som root | `USER node` + `--chown=node:node` på COPY-stegen |
| Ingen HEALTHCHECK | `HEALTHCHECK` via `wget` (finns inbyggt i Alpine) |

En tredje sak noterades men valdes bort medvetet: SHA-pinning av GitHub Actions (`@v4` → `@sha256:...`). Det är supply-chain best practice för produktionskritiska pipelines men overkill för en PoC. Beslut: ta med det i det riktiga projektet.

### 6. Sätta upp Railway

Den första deployn gjordes manuellt — GHA-workflowen kan inte trigga Railway förrän Secrets är på plats, och Secrets kräver att man vet Railway-ID:na.

**Ordningen som fungerade:**

1. Skapa Railway-projekt → **New Service** → **Docker Image**
2. Ange `ghcr.io/palhamel/railway-hello-api:latest`
3. Railway deployar direkt (fungerar utan env-variabler — `PORT` injiceras automatiskt)
4. **Networking → Generate Domain** → appen är live
5. Hämta `RAILWAY_SERVICE_ID` från URL:en när man är inne på servicen:
   `railway.app/project/.../service/DETTA-ÄR-ID:T`
6. Hämta `RAILWAY_ENVIRONMENT_ID` från URL:en på environment-sidan
7. Hämta `RAILWAY_TOKEN` (account token, format `token_xxx`) under:
   Avatar **nere till vänster** → Account Settings → Tokens → Create token
   *(Inte project token — det fungerar inte för API-anrop)*
8. Lägg in alla tre som **Repository secrets** (inte Variables, inte Environment secrets) på:
   `github.com/palhamel/railway-hello-api/settings/secrets/actions`

### 7. Problem vi stötte på

**`version: "dev"` i produktion**
Första live-deploy visade `version: "dev"` trots att det var en riktig deploy. Orsak: `APP_VERSION` var inte satt. Lösning: baka in commit-SHA i imagen vid bygget med `ARG`/`ENV` i Dockerfilen och `build-args` i workflowen. Nu visar varje deploy exakt vilken commit som kör.

**Node.js 20 deprecation-varning i GHA**
CI visade:
```
Node.js 20 actions are deprecated... Actions will be forced to run with
Node.js 24 by default starting June 2nd, 2026.
```
Lösning: opt-in till Node 24 direkt med en workflow-env-variabel:
```yaml
env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
```
Alternativet (uppdatera till nya major-versioner av actions) valdes bort för att man inte kan vara säker på exakta versionsnummer utan att leta upp dem manuellt. Åtgärdas i det riktiga projektet.

**Köad CI-körning som inte startade**
En manuellt re-triggrad körning stod som "Queued" i flera minuter. Det var GitHub Actions-kön som var trög, inte ett konfigurationsfel. En ny push löste det.

---

## Verifierat resultat

```bash
curl https://railway-hello-api-production.up.railway.app/
```

```json
{
  "message": "Hello from Railway!",
  "version": "8c2b32ebfb797ec54aa7198fb7246eeaa6c28d3c",
  "timestamp": "2026-04-23T15:02:33.124Z"
}
```

`version` matchar commit-SHA → rätt kod kör i produktion. Hela kedjan fungerar.

---

## Miljövariabler — vad som behövs och inte

| Variabel | Sätts av | Kommentar |
|----------|----------|-----------|
| `PORT` | Railway automatiskt | Injiceras alltid, sätt den aldrig manuellt |
| `APP_VERSION` | Bakat i imagen av GHA | Commit-SHA, ingen Railway-variabel behövs |

Inga andra env-variabler behövs för denna app. Railway injicerar `PORT` för alla tjänster — det är ett Railway-specifikt beteende som inte är uppenbart första gången.

---

## Nästa steg: skala till API + frontend

### Repostruktur (monorepo)

```
my-project/
├── api/                   ← Node.js/Express backend
│   ├── server.js
│   ├── package.json
│   └── Dockerfile
├── app/                   ← React/Vite frontend
│   ├── src/
│   ├── package.json
│   ├── vite.config.js
│   └── Dockerfile
└── .github/
    └── workflows/
        ├── deploy-api.yml
        └── deploy-app.yml
```

### Separata workflows med path-filter

Varje workflow triggas bara av sina egna filer — ett CSS-fix ska inte bygga om API:et:

```yaml
# deploy-api.yml
on:
  push:
    branches: [main]
    paths:
      - 'api/**'
      - '.github/workflows/deploy-api.yml'
```

```yaml
# deploy-app.yml
on:
  push:
    branches: [main]
    paths:
      - 'app/**'
      - '.github/workflows/deploy-app.yml'
```

### GitHub Secrets per tjänst

| Secret | Används av |
|--------|-----------|
| `RAILWAY_TOKEN` | Båda workflows (samma account token) |
| `API_RAILWAY_SERVICE_ID` | deploy-api.yml |
| `API_RAILWAY_ENVIRONMENT_ID` | deploy-api.yml |
| `APP_RAILWAY_SERVICE_ID` | deploy-app.yml |
| `APP_RAILWAY_ENVIRONMENT_ID` | deploy-app.yml |

### Frontend Dockerfile (multi-stage med Nginx)

Frontend byggs statiskt och serveras av Nginx. Här motiverar multi-stage sig — build-miljön med Node och devDependencies slängs, bara den statiska outputen är med i den slutliga imagen:

```dockerfile
FROM node:24-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

Frontend exponerar port 80 (inte 3000). Railway sköter TLS och routing.

### Kommunikation mellan tjänster

API-tjänsten nås från frontend via en Railway-intern URL — inte publik, bara nåbar inom samma Railway-projekt:

```
VITE_API_URL=https://my-project-api.railway.internal
```

Sätt den som miljövariabel på frontend-tjänsten i Railway.

---

## Checklista för nytt projekt

**Railway:**
- [ ] Skapa projekt med två tjänster: `api` och `app`
- [ ] Sätt source → Docker Image på båda
- [ ] Notera Service ID (från URL) och Environment ID (från URL) för båda
- [ ] Skapa account token: Avatar (nere till vänster) → Account Settings → Tokens
- [ ] Generera domän på båda tjänsterna (Networking → Generate Domain)
- [ ] Sätt `VITE_API_URL` på app-tjänsten till intern Railway-URL för API:et

**GitHub:**
- [ ] Lägg till Repository secrets: `RAILWAY_TOKEN`, `API_RAILWAY_SERVICE_ID`, `API_RAILWAY_ENVIRONMENT_ID`, `APP_RAILWAY_SERVICE_ID`, `APP_RAILWAY_ENVIRONMENT_ID`
- [ ] Skapa `deploy-api.yml` och `deploy-app.yml` med path-filter

**Kod:**
- [ ] Separata Dockerfiles i `api/` och `app/`
- [ ] API: `listen('0.0.0.0')`, `PORT` från env, `APP_VERSION` via ARG/ENV
- [ ] Frontend: multi-stage Dockerfile med Nginx
- [ ] SHA-pinna GitHub Actions (utelämnat i PoC, gör det här)
- [ ] `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` i båda workflows tills actions uppdateras
