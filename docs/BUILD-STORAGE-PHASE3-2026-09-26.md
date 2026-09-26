# xDrip lagerfase 3 – historiske builds, 26. september 2026

Denne revision ændrede ingen historiske release-statusfiler og ingen appkode.
Før sletning blev alle fire worktrees, 4275, Git-referencer, lokal release-evidens
og Apples officielle API kontrolleret. Apple-opslaget kl. 11:32:29 UTC viste
4264 og 4265 alene som `AWAITING_UPLOAD`; 4274 havde ingen Apple-build eller
upload. Ingen af de tre var et accepteret TestFlight-build. 4275 var fortsat
`VALID / INTERNAL_ONLY / IN_BETA_TESTING`.

## Rekonstrueret livscyklus

| Build | Kildecommit/tag, version | Lokal test, arkiv, signering, IPA | Apple/upload | Årsag til ikke-afsluttet status | Klassifikation |
|---|---|---|---|---|---|
| 4264 | `435115f7f7d434030c8be468d6a628aa8e5b2b33`, `testflight-7.1.1-4264`, 7.1.1 | 983/983 tests; arkiv lykkedes; første eksport fejlede pga. manglende distribution-certifikat/konto, særskilt Admin-eksport lykkedes og gav IPA med SHA-256 `1a0e6c27fcbbe73e543ff486f518c9d1d7819d14244748f9cbea81d3160374`; arkivets dSYM findes | Ingen upload-attempt/log eller accepteret build; én `AWAITING_UPLOAD`-post | Automatisk release-state blev ved `tagged`; den særskilte eksport afsluttede ikke upload-/statusforløbet | `ABORTED_REPRODUCIBLE` |
| 4265 | `e150560769e467c6c801b931c586e3c5b811118f`, `testflight-7.1.1-4265`, 7.1.1 | 983/983 tests; arkiv, signeret eksport og lokal IPA-verifikation lykkedes; IPA SHA-256 `ab6a8b450a3b3243fc786ec33d97a3ed55982e3d1a1f01637cd10c8981746b79`; dSYM findes | Ingen upload-attempt/log eller accepteret build; én anden `AWAITING_UPLOAD`-post | Automationen registrerede `superseded`: `a different Apple upload now occupies the selected build number` | `ABORTED_REPRODUCIBLE` |
| 4274 | `031a3e40f6d0a5e5307aff50ad5e621814666298`, `testflight-7.1.1-4274`, 7.1.1 | 1055/1055 tests og simulatorbuilds; arkiv fejlede i `CodeSign` på Watch-komplikationen efter File Provider-attributter; ingen færdig IPA/arkiv | Ingen Apple-build eller upload | Automationen stoppede efter tagget, før arkiv/IPA/upload; derfor `tagged` | `FAILED_REPRODUCIBLE` |

Alle tre tags findes stadig, peger på release-state-felternes commits, og
commitsenes Git-træer matcher de registrerede testtræer. En nyere verificeret
4275 findes. Reproducerbarhed gælder kilde og genskabelige compilerprodukter;
den oprindelige signerede binær er ikke nødvendigvis bit-identisk ved en ny
signering. Derfor er 4264/4265 IPA, arkiv og dSYM bevaret.

4264 blev publiceret som Git-tag kl. 12:31:25 UTC den 24. september. 4265
blev tagget kl. 13:08:06, bygget kl. 13:10:09 og markeret `superseded`
kl. 13:10:18 samme dag. 4274 blev tagget kl. 07:56:22 UTC den 26. september.
Release-automationen klassificerede dem korrekt som uafsluttede; der var
ingen historisk statusfejl at rette, og statusfilerne er uændrede.

## Checkpoint 4263

`checkpoint/post-testflight-4263` peger på `5a0ce985c86909e3827970f4487ca573bd46a7a5`.
Kodecommit `bbd19bdef2a97847e82b12e08e7c2a28993d3d74` bevarer de fire
relevante Swift-/testfiler; integrationens patch og testdokumentation findes.
4263 blev oprindeligt bygget fra lokale ændringer før den nye tag-proces.
Der findes derfor **ikke** et retroaktivt 4263-release-tag. Git bevarer nu
kilden, men er ikke alene nok til at bevare den præcise signerede IPA.
Derfor er IPA, signeret arkiv, dSYM, XCResult, logs, JSON og kildepatcher
bevaret. Kun compiler-cache og genererede simulatorprodukter fra
`build/integration-20260924/DerivedData` og
`build/release-integration-20260924/DerivedData-unsigned` blev ryddet.

## Slettet og bevaret

En afgrænset reconciliation kontrollerede for hvert build tag/commit/træ,
release-state, tests, arkiv-/eksportlogs, IPA-hash, fravær af uploadkvittering,
frisk Apple-status og åbne filer. Den valgte kun enkeltfiler med godkendte
compiler-cache-/genereret-produkt-stier. Den brugte den eksisterende
buildlås, proceskontrol, `lsof`, filfingeraftryk og sikker fil-for-fil-sletning.
Ingen hele release-, DerivedData- eller checkpointmapper blev slettet.

| Build | Slettede filer | Allokeret GiB | Bevaret |
|---|---:|---:|---|
| 4264 | 28.728 | 3,657 | IPA, arkiv, dSYM, XCResult, logs, JSON og Git-tag |
| 4265 | 3.625 | 1,254 | IPA, arkiv, dSYM, XCResult, logs, JSON og Git-tag |
| 4274 | 27.687 | 3,302 | fejllog, XCResult, JSON og Git-tag |
| 4263 | 3.478 | 1,176 | kilde/branch, IPA, arkiv, dSYM, XCResult og release-evidens |
| **I alt** | **63.518** | **9,389** | hele aktuelle 4275 |

Den samtidige `disk_usage`-måling under sletningen viste 3.335.155.712 byte
(3,106 GiB) mere fysisk fri plads. Efter alle tests viste den afsluttende
måling 6.553.600.000 byte (6,103 GiB) mere fri plads end før oprydningen;
stigningen ud over den samtidige måling kan omfatte forsinket APFS-frigivelse
og anden systemaktivitet og tilskrives derfor ikke entydigt oprydningen.
Workspace faldt fra
27,002 GiB til 17,636 GiB. Den efterfølgende reconciliation dry-run fandt
0 kandidater, og to almindelige retention-kørsler slettede 0 filer hver.

### Tilbageværende builds, eksklusive 4275

GiB er allokerede filblokke afrundet til tre decimaler. `Andet` omfatter
blandt andet logs, JSON/status, staging, lokale produkter og metadata.

| Build | Git-reference | IPA | dSYM | XCArchive uden dSYM | XCResult | Intermediates | Andet | Total |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 4263 | `checkpoint/post-testflight-4263` | 0,090 | 0,304 | 0,227 | 0,063 | 0,169 | 0,625 | 1,477 |
| 4264 | `testflight-7.1.1-4264` | 0,092 | 0,169 | 0,116 | 0,058 | 0,402 | 0,118 | 0,955 |
| 4265 | `testflight-7.1.1-4265` | 0,092 | 0,169 | 0,116 | 0,057 | 0,094 | 0,444 | 0,972 |
| 4266 | `testflight-7.1.1-4266` | 0,092 | 0,169 | 0,116 | 0,058 | 0,094 | 0,126 | 0,655 |
| 4268 | `testflight-7.1.1-4268` | 0,092 | 0,170 | 0,116 | 0,059 | 0,095 | 0,119 | 0,651 |
| 4269 | `testflight-7.1.1-4269` | 0,092 | 0,170 | 0,116 | 0,059 | 0,095 | 0,118 | 0,650 |
| 4270 | `testflight-7.1.1-4270` | 0,092 | 0,171 | 0,117 | 0,059 | 0,095 | 0,118 | 0,652 |
| 4271 | `testflight-7.1.1-4271` | 0,092 | 0,171 | 0,117 | 0,059 | 0,409 | 0,177 | 1,025 |
| 4272 | `testflight-7.1.1-4272` | 0,092 | 0,172 | 0,117 | 0,059 | 0,411 | 0,126 | 0,978 |
| 4273 | `testflight-7.1.1-4273` | 0,092 | 0,172 | 0,117 | 0,059 | 0,412 | 0,119 | 0,971 |
| 4274 | `testflight-7.1.1-4274` | 0 | 0,003 | 0 | 0,059 | 0,389 | 0,118 | 0,569 |

Artefaktvurdering: For faktisk distribuerede 4263 og 4266–4273 er IPA og
dSYM **nødvendige** til lokal rollback/crash-symbolik. XCArchive og
XCResult er **nyttige men valgfrie** og er bevaret. For aldrig distribuerede
4264/4265 er IPA, dSYM, arkiv og XCResult **nyttige men valgfrie** som præcist
historisk bevis; de er bevaret. 4274's XCResult og fejllogs er tilsvarende
nyttige. De slettede intermediates var **fuldt reproducerbare**. De resterende
intermediates og `Andet` indeholder blandede eller endnu ikke fil-for-fil
validerede typer og er markeret **ukendt** for denne fase; de er bevaret.
Git-referencer og release-status er **nødvendige** og urørte.

Et ældre afsluttet build optager aktuelt typisk 0,65–1,03 GiB, fordi IPA,
dSYM, arkiv, XCResult og bevaringskrævende metadata beholdes. Den aktuelle
4275-release er større, fordi hele dens test- og release-mappe beskyttes.
Den normale retention-politik blev ikke ændret; den behandler fortsat nye
uafsluttede builds som beskyttede, indtil deres faktiske livscyklus er
fastslået separat.

Detaljeret filjournal og bevaringsfingeraftryk ligger under
`build/release-automation/phase3/20260926T113910.728721Z/`.
