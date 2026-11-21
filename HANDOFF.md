# Reprise — état du projet DSH Docker (2026-11-21, fin de session)

Fichier de travail personnel, à supprimer une fois le projet terminé.

## Ce qui est fait et vérifié

### Faits DSH vérifiés sur l'installation réelle (0.2.2-rc.5, npm `latest`)

| Point | Résultat observé |
|---|---|
| Version npm | `0.2.2-rc.5` (dist-tags : `latest` = `next` = `0.2.2-rc.5`, `alpha` = `0.2.2-alpha.3`) |
| Node requis | `engines: node >=24.9.0` (l'hôte en Node 22 casse : erreur EROFS d'abord, mais surtout incompatible) |
| `--host 0.0.0.0` / `::` | **refusé** au démarrage : « unspecified (wildcard) address … would expose remote code execution to the network » |
| `--host <IP non locale>` | échec de bind (services `webServer` manquants) |
| `--host 172.17.0.2` (IP d'interface conteneur) | **fonctionne** ; publication `-p` Docker → joignable depuis l'hôte |
| Authentification | `GET /` sans cookie → **401** ; `?token=…` valide → **303** + cookie `dsh-auth-*` (HttpOnly, SameSite=Strict) ; mauvais token → 401 |
| Fence Host/Origin | requête `/api/` avec `Host` étranger → **403** |
| WebSocket | `/api/remote.mux` : sans cookie → 401 ; avec cookie → **101** |
| `--trusted-host` | Le cookie est lié à l'autorité (Host) utilisée au login. Derrière un reverse proxy il faut **un seul** host accepté (le FQDN public) + `--public-url`, sinon le login via l'IP ne vaut pas pour le FQDN (401). |
| Chemins de persistance | `$DSH_HOME` (défaut `~/.dsh`) : `.credentials.yaml`, `profiles/<profil>/cordis.yml` (+ patch), `storages/`, logs |
| Fichier `cordis.yml` | **écrit au démarrage** dans `$DSH_HOME/profiles/web/` : le volume DSH_HOME doit être inscriptible |
| Crédentials | `$DSH_HOME/.credentials.yaml` (écrit par l'UI), fallback `<cwd>/.env` puis `$DSH_HOME/.env` |
| Arrêt | SIGTERM → sortie propre en ~400 ms, code 0 |
| Planification | DSH a un plugin Schedule natif (cron/rrule/daily/weekly, cibles session) **inclus dans le profil web** (pas le bundle retiré) → à privilégier, Planificateur Synology en secours |
| Mode headless | `dsh headless "tâche"`, options `--json`, `--session-id`, `--permission-mode`, `--approval-policy ask\|never`, `--add-dir` |

### Fichiers créés dans le dépôt

- `package.json` / `package-lock.json` — DSH épinglé à `0.2.2-rc.5`, lockfile v3 complet (743 paquets, 100 % registry).
- `Dockerfile` — image minimale ; base `node:24-bookworm-slim` épinglée par digest `sha256:dc26ae92…` ; apt épinglé sur snapshot Debian `20261104T212339Z` (bookworm + bookworm-security, `Check-Valid-Until false` car la fenêtre Release du snapshot est expirée) ; paquets : ca-certificates, curl, git, iproute2, tini ; npm 11 ; `npm ci` dans `/opt/dsh` + symlink `/opt/dsh/bin/dsh`, `/opt/dsh` en lecture seule ; utilisateur `dsh` uid/gid 1000 (reprise du compte `node` existant via `usermod`/`groupmod`) ; **`USER dsh:dsh` ajouté à la fin de session (pas encore rebuild)** ; `DSH_HOME=/home/dsh/.dsh`, `TZ=Europe/Paris`, `WORKDIR /workspace`, `EXPOSE 3080`, HEALTHCHECK, ENTRYPOINT tini.
- `docker/entrypoint.sh` — refuse root ; `web` : résout l'IP d'interface (`hostname -i` ou `DSH_LISTEN_HOST`) et lance `dsh web --no-open --host IP --port $DSH_LISTEN_PORT` + `--public-url` / `--trusted-host` éventuels ; `headless` : `dsh headless "$@"`.
- `docker/healthcheck.sh` — curl sur `http://<ip>:<port>/`, accepte 2xx/3xx/401/403/404, échoue si connexion refusée.
- `docker/zz-dsh-tz.sh` — profil bash qui recale `/etc/localtime` sur `TZ` à l'ouverture d'un shell (Debian lit le fuseau au démarrage).
- `.dockerignore`, `.gitignore` — exclusion de `.git`, secrets, `.scratch`.
- `tests/integration.sh` — test d'intégration complet, port hôte `39080` par défaut (ne touche pas 3080/3081), conteneur éphémère `dshtest-…`, volumes éphémères, nettoyage par `trap`. Vérifie : démarrage, tini PID 1, uid 1000, no_new_privs, caps à zéro, pas de bind loopback, 401/303/HTML, fence Host 403, WebSocket 401 puis 101, versions git/node/dsh/curl, HEALTHCHECK healthy, redémarrage, persistance `/workspace` et `DSH_HOME`, recréation de conteneur avec le même volume, refus du root, arrêt propre SIGTERM code 0.
- `.github/workflows/docker.yml` — **fichier incomplet fourni par l'utilisateur** (voir plus bas).

### Build local

`docker build -t dsh-docker:local .` **réussit** (~2 min à froid). Taille ≈ **2,44 Go**. Répartition : `node_modules` DSH 1,3 Go (dont `@deepseek-ai` 955 Mo, `node-pty`, `sherpa-onnx-linux-x64`, SDK IA), reste ~110 Mo. Pas d'optimisation agressive retenue : DSH charge des paquets dynamiquement, un élagage risquerait de casser le runtime.

> Note : les commandes Docker locales ont besoin de `DOCKER_CONFIG=$PWD/.scratch/docker-config TMPDIR=$PWD/.scratch/tmp` (état de buildx non inscriptible hors du dépôt).

## Point d'arrêt : ce qui reste à faire (dans cet ordre)

1. **Rebuild** : `docker build -t dsh-docker:local .` (la directive `USER dsh:dsh` vient d'être ajoutée et n'a pas été testée).
   - *Cause de l'échec du premier test d'intégration* : sans `USER`, l'image tournait en root ; l'entrypoint refusait de démarrer (« refusing to run as root ») — le contrôle lui-même est donc validé, c'est l'image qui était fautive.
2. **Relancer** `sh tests/integration.sh dsh-docker:local` et corriger jusqu'au vert (vérifier notamment : `pgrep` dans le contrôle uid, le pack de caps à zéro sur `/proc/1` pour tini, le HEALTHCHECK).
3. **Workflow GitHub Actions** : remplacer `.github/workflows/docker.yml` (actuellement 2 lignes `username:`/`password:` → invalide) par :
   - job `test` sur PR (aucun secret) : build `linux/amd64` + `tests/integration.sh` ;
   - job `publish` sur `main` + `workflow_dispatch`, `needs: test`, permissions `contents: read`, `docker/login-action` avec `vars.DOCKERHUB_USERNAME` / `secrets.DOCKERHUB_TOKEN` ;
   - tags : `latest`, `main`, `sha-<7>`, `dsh-0.2.2-rc.5` (+ `edge` éventuel) ; cache `type=gha` ; `provenance`/`sbom` activés ;
   - dépôt Docker Hub configurable : variable `DOCKERHUB_REPOSITORY` (défaut = nom du repo GitHub).
4. **`docker-compose.yml`** + `.env.example` : `user` implicite (uid 1000), `cap_drop: [ALL]`, `security_opt: no-new-privileges`, `read_only: true` + tmpfs sur `/tmp` (à tester), `mem_limit: 2g`, `cpus: 1.5`, `pids_limit`, volumes nommés (`dsh-home`, `dsh-workspace`), `TZ=Europe/Paris`, port variable, `restart: unless-stopped`, `pull_policy: if_not_present` (pas de mise à jour auto sur le NAS).
5. **`.github/dependabot.yml`** : npm (root, `package-lock.json`), docker (base `Dockerfile`), github-actions ; pas d'auto-merge. Précision vérifiée : Dependabot **ne propose pas** les préversions par défaut → compléter par un contrôle qui compare `npm view @deepseek-ai/dsh dist-tags` au `latest` publié (script/issue cron), car DSH n'est distribué qu'en `-rc`/`-alpha` (pas de version stable).
6. **Doc française** : `README.md`, `docs/SYNOLOGY.md`, `docs/GITHUB_ACTIONS.md`, `docs/SECURITY.md`, `docs/UPDATES.md`, `docs/AUTOMATIONS.md`, `CHANGELOG.md`.
   - Synology : modèle DSM 7.2 / Container Manager, volume `/docker/dsh/{data,workspace}` (uid 1000), journal Docker pour récupérer l'URL avec token, retour arrière par tag `sha-…`/`dsh-…`, sauvegarde/restauration des volumes.
   - Reverse proxy / Tailscale : un seul `--trusted-host` (FQDN) + `--public-url https://fqdn`, WebSocket `/api/remote.mux` à autoriser dans le proxy.
7. **Variante `docker/dev/Dockerfile`** (`FROM dsh-docker:<base>` de préférence une image auto-construite ; sinon `FROM node:24-bookworm-slim` + mêmes copies) : git, curl, php-cli 8.2 (+ mbstring/xml/curl/intl/zip/sqlite3/mysql), Composer 2.8.x vérifié par SHA-256, Node/npm déjà présents, GitHub CLI (`gh`) ; pas de Chromium.
8. Supprimer ce fichier, `git add` et faire un premier commit (rien n'a été commité ni poussé : tout est `??` dans `git status`).

## Identifiants GitHub / Docker Hub (donnés par l'utilisateur)

- Dépôt Docker Hub cible : **`yanntassy/dsh-docker`** (compte : `yanntassy`).
- GitHub : variable `vars.DOCKERHUB_USERNAME` déjà renseignée, secret `secrets.DOCKERHUB_TOKEN` déjà renseigné.
- Le workflow doit donc utiliser `images: yanntassy/dsh-docker` par défaut, et rester configurable via une variable `DOCKERHUB_REPOSITORY` (défaut : `${vars.DOCKERHUB_USERNAME}/dsh-docker`).

## Décisions / contraintes à conserver

- Le fichier `cordis.yml` est réécrit à chaque démarrage → ne jamais monter de volume en `:ro` sur `/home/dsh/.dsh`.
- Derrière un proxy : un seul host accepté, et se connecter **par le FQDN public** (le cookie est lié à l'autorité).
- Ne pas utiliser `--user 0` ni `privileged` ; l'entrypoint refuse root explicitement.
- Pas de socket Docker, pas de montage de dossiers système Synology ni du home admin.
- Ports locaux de l'utilisateur à ne pas occuper : DSH 3080/3081 (session en cours).
