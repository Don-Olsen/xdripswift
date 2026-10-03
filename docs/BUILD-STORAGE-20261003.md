# Buildlager og arbejdsmappens placering — 3. oktober 2026

Vedligeholdelse efter TestFlight 4288; intet nyt appbuild, versionsskift,
signering eller upload blev udført.

## Resultat

- 64.093 validerede cachefiler slettet; 7.388 GiB allokerede data.
- Observeret fysisk fri plads steg 7.321 GiB under oprydningen. APFS og samtidig
  diskaktivitet betyder, at dette ikke er identisk med filernes allokerede plads.
- Målt buildområde før/efter: 20,18 → 12,83 GiB. Dette omfatter den aktive
  checkouts buildmappe, det centrale område, ekstern 4288-signering og de tre
  registrerede lokale runs; det er ikke en komplet måling af de bevarede
  historiske Documents-worktrees. Planer og slettejournaler indgår i eftertallet.
- Den aktive checkout fylder efter kontrol ca. 3,73 GiB, heraf 3,51 GiB builddata.
  Ekstern 4288-signering fylder yderligere 1,52 GiB. Sidste måling viste
  ca. 21,29 GiB fysisk fri diskplads.
- Oprydning gentaget: **0 filer og 0 byte slettet**. Alle tilbageværende
  release-/testfiler og Git-status var uændrede ved begge gennemløb.

## Konkrete sletninger

Kun selektivt validerede compiler-, modul-, indeks- og produktfiler blev
slettet under nedenstående stier. Mapperne, logs, JSON, kildefiler og XCResult
blev bevaret. Hvert run blev først kontrolleret mod rå XCResult og buildlogs.
De tidligere registrerede testresultater var henholdsvis 1115/1115, 1115/1115
og 588/588 i rækkefølgen nedenfor; ingen af dem blev genkørt som app-tests.

| Cachemappe | Slettede filer | Allokeret størrelse |
|---|---:|---:|
| `/private/tmp/xdrip-alarm-refresh-full-20261003/DerivedData` | 27,051 | 3.132 GiB |
| `/private/tmp/xdrip-alarm-4284-preflight-20261003/DerivedData` | 27,052 | 3.133 GiB |
| `/private/tmp/xdrip-alarm-refresh-20261003/DerivedData` | 9,990 | 1.124 GiB |

Desuden fjernedes den bekræftet tomme
`~/Documents/Codex/xdrip-release-4288-provider-inode` med `rmdir`, og en efterladt
`log stream`-proces fra uploaddiagnostikken blev afsluttet efter kontrol af dens
præcise kommando. Ingen andre mapper blev slettet.

## Beskyttelse af 4288 og kildekode

- Apple bekræftede build 4288: `VALID`, `INTERNAL_ONLY`, `IN_BETA_TESTING`,
  fortsat tilknyttet Ole Internal.
- IPA SHA-256 er uændret:
  `e37c0b8ea078fbfd36682fa3f8cc2e546dc905f18bfa9ff596bf28878332156e`.
- `active.json`, release-state, Apple-status, uploadkvittering, allokering og
  `xDrip/Version.xcconfig` er byteidentiske før/efter.
- Aktuelt IPA, XCArchive/dSYM, XCResult, logs og øvrige 4288-artefakter er bevaret.
- Ingen app-, Watch-, Bluetooth-, alarm- eller prognosekode er ændret.
- Historiske Git-indexer, HEAD, refs og worktree-metadata er uændrede.
  Checkpoint 4263 og HealthKit-worktree er rene. Physical-therapy-worktree
  beholder sin eksisterende plist-ændring. Den historiske integrationskopis tre
  allerede staged filer er uændrede; kun en ny lokal AGENTS-henvisning til den
  aktive checkout er tilføjet uden staging. Hovedworktreets fulde status gav
  fortsat timeout; det blev derfor bevaret og må ikke betegnes som kontrolleret
  rent. Ingen oprydning blev foretaget i historiske worktrees eller SafetyBackups.

## Fast arbejdssted og forebyggelse

Den lokale, selvstændige Git-kopi er flyttet fra
`~/DeveloperBuildData/xDrip/release-4288-local` til `~/Developer/xdripswift`.
Alle 41.949 poster blev kontrolleret for identitet, type, størrelse, mtime og
linkmål før/efter flytningen. Det tidligere sted er et kompatibilitetslink.
Git connectivity-kontrol bestod; en urefereret tree-object blev blot rapporteret.

Nye builds kontrollerer File Provider-markører og mindst 10 GiB fri plads før
Xcode. Den delte lokale cache genbruges; isolerede afsluttede caches kræver
verificerede kvitteringer og ryddes gennem det eksisterende cleanup-script.
Aktive, nyere, uafsluttede, delte eller ændrede caches bevares. Ingen vilkårlig
sletning for at opnå en pladsgrænse. Reglerne står i [MAC-BUILD.md](MAC-BUILD.md).

Codex-projektets gemte primære mappe pegede fortsat på den historiske
Documents-kopi ved slutkontrollen. Det tilgængelige UI-værktøj afviser adgang
til selve Codex-appen, også efter brugerens tilladelse; der findes ingen
projektredigeringsfunktion i de tilgængelige appværktøjer. Brugeren skal derfor
vælge `~/Developer/xdripswift` som primær mappe via projektets Edit project.
Ingen chats eller private Codex-konfigurationsdatabaser blev ændret.

## Kontroller

- Hele `local-build.sh python`: exit 0; **139 unit-tests** bestået
  (11 kvittering, 9 miljø, 39 cleanup, 12 processing, 28 releaseguard, 40 Apple).
- Yderligere **54 syntetiske selvkontroller** af XCTest-evidens/signaturregler.
  Alle Apple-uploadhandlinger i tests er mocks, ingen faktisk upload.
- Shellsyntaks, diff-whitespacekontrol og afgrænsning til scripts/dokumentation
  bestod.
- Læsende `xcodebuild -list` på flyttet workspace: exit 0, fem schemes, 1,65 sek.
- Eksisterende 4288 har allerede 1148/1148 XCTest og begge simulatorbuilds på
  releasekilden. De blev ikke kørt igen for denne script-/dokumentationsændring.
- Præcis filjournal og før/efter-inventar:
  `build/release-automation/cleanup/20261003T164102.185309Z/`.
- Idempotenskontrol: `build/release-automation/cleanup/20261003T164145.889578Z/`.
- Øvrige lokale beviser og testlogs:
  `build/release-automation/maintenance/20261003/`.

Det normale forbrug er reduceret, men 5–10 GiB for hele projektets historik
kan ikke loves: komplette aktuelle releaseartefakter, historiske worktrees og
nødvendige diagnostik-/Git-hjælpekopier bevares. Kontrollerne forebygger den
identificerede File Provider-fejl og cacheophobning; de garanterer ikke, at enhver
fremtidig Xcode- eller Apple-fejl er elimineret.
