<!-- testflight-7.1.1-4267:start -->
### TestFlight 7.1.1 (4267)

- Kildecommit og tag: `c11e27b135565c6fd971bdd7d4dc632986806c5a` / `testflight-7.1.1-4267`.
- Tests: 1001/1001 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-24T14:58:33.150542+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/db8aeb8a-6980-47c5-952f-ae98c7a6a286).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4267:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

# Nuværende featuregren: Apple Sundhed-bolus og kulhydrater

Opdateret 24. september 2026. **Denne funktion er kun gemt som kildekode på
`feature/healthkit-bolus-carbs`; der er ikke lavet et nyt TestFlight-build,
upload eller installation på fysiske enheder.** Den udgivne 7.1.1 (4266)
forbliver uændret.

- Udgivet udgangspunkt: `testflight-7.1.1-4266`, kildecommit
  `a54cbcb492d3c1c411de5ed52cc6260350c69cb9`. Featuregrenen blev
  oprettet fra den efterfølgende videreførte commit
  `74f69be9bed5bc56b5eceefaa453526683341b23`, så release- og
  statusændringerne efter 4266 blev bevaret. Den testede appkode, nye tests og
  funktionsvejledning er gemt i commit
  `eaf4773d2204a5c0330cddd4af7bf9d9315c1d06` (tree
  `decbd3298473b5a2b18ac94cd5488e107237e0a8`).
- To importkontakter er som standard slukket. Brugeren giver separat læseadgang
  og vælger en faktisk Apple Sundhed-kilde for insulin og kulhydrater. Den
  eksisterende glukoseeksport er uafhængig. Kun eksplicit bolusklassificerede,
  tidsmæssigt entydige insulindoser og enkelte kulhydratposter bliver
  behandlinger; basal og uklare poster bidrager ikke til IOB/COB. Oprindeligt
  tidspunkt, HealthKit-UUID og kilde bevares i Core Data-model v33.
- Observer- og anchored queries håndterer paginering, genstart, efterregistrering,
  dokumenterede sletninger, kildevalg og genforsøg. Et anker flyttes først efter
  varig lokal lagring. Status er ufuldstændig under fler-siders import, ved
  læse-/skrivefejl og ved relevante uklare poster. Samme HealthKit-UUID
  genimporteres ikke. Eksakt delt oprindelses-ID giver en eksisterende ekstern
  import forrang; tid og mængde alene slår aldrig to behandlinger sammen.
  Health-importerede behandlinger sendes ikke automatisk til Nightscout eller
  tilbage til Sundhed. Eksisterende beregningsmodeller, ekstern kildeprioritet,
  Watch-transport og friskhedsregler anvendes uændret.
- Syntetiske, isolerede tests: **17/17** i `HealthKitTherapyImportTests`.
  Den **fulde XCTest-suite bestod 1001/1001**, 0 fejl og 0 skipped, inklusive
  backup-provenienstesten og relevante Watch/Libre-, Nightscout- og
  TherapyMetrics-tests. Projektets offline Python-kontroller bestod
  **12/12, 30/30, 17/17, 24/24 og 40/40**. Både iPhone- og
  Watch-simulatorbuilds bestod. Det autoritative `.xcresult` og logs ligger
  lokalt under `build/local/healthkit-feature-final-3/` (ignoreret af Git).
  De tidligere **983/983** hører alene til 4266-baselinen.
- Åbent før intern afprøvning: rigtige HealthKit-kilder, faktisk læseadgang,
  baggrundslevering, korrektion/sletning og iPhone/Watch-friskhed skal
  efterprøves fysisk efter en særskilt godkendt TestFlight-release. Apple
  afslører ikke fuld læseadgang; et synkroniseringstidspunkt er ikke bevis på
  komplette data. Kilder uden delt oprindelses-ID kan ikke deduplikeres sikkert
  mod en anden import alene ud fra tid og mængde. Den særskilte
  `invalidPayload`-risiko og de historisk dokumenterede full-suite-fejl nedenfor
  er fortsat åbne. Se [førstegangsopsætning og fysisk testplan](HEALTHKIT-THERAPY-IMPORT.md).

Det næste TestFlight-build skal stadig følge den faste tag-baserede proces og
kræver en ny, versionsspecifik **GO UPLOAD**. Ingen ny API-nøgle eller ændring af
releaseautomatiseringen indgik i denne feature.

---

<!-- testflight-7.1.1-4266:start -->
### TestFlight 7.1.1 (4266)

- Kildecommit og tag: `a54cbcb492d3c1c411de5ed52cc6260350c69cb9` / `testflight-7.1.1-4266`.
- Tests: 983/983 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-24T13:36:52.453398+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/ebccc754-ccd5-4354-8b6e-063f3dd05248).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4266:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

# 7.1.1-releaseforløb før endeligt upload

Opdateret 24. september 2026. Brugeren har nu givet udtrykkeligt **GO UPLOAD for
7.1.1**, inklusive automatisk buildnummer, tracked versionsændring,
checkpoint/push/tag, signering, arkiv/IPA, upload til app `6795645396`,
tilknytning til **Ole Internal** og efterfølgende statuscommit. Tilladelsen
skal genbruges for denne release; der skal ikke spørges om et nyt GO UPLOAD
eller et manuelt buildnummer.

## Permanent automatisering og faktisk verifikation

- Udgangspunkt: integrationsgren `integration/upstream-7.1.1`,
  dokumentationscommit `48a1ccc59fba38c752c8dddff778fdf836307d71` og uændret
  appkodecommit `f90b1dcb1d716aea41a0c68be7c6a47cc405ceee`.
- `scripts/apple_release.py` læser Apples offentlige API med en ekstern ES256
  API-nøgle. Alle sider af builds og buildUploads samt den aktuelle versions
  eksplicitte resultater kontrolleres. Nummeret vælges automatisk over alle
  registrerede numre; igangværende og fejlede uploads medregnes.
- `scripts/release-testflight.py release` håndterer automatisk allokering,
  tracked buildnummer, fuld release-tree-test, checkpoint/push/tag, arkiv og
  IPA fra tagget, source/signaturkontrol, direkte upload af den verificerede
  IPA, op til 15 minutters processing, intern gruppetilknytning og statuscommit.
  En optaget slot før upload medfører nyt nummer og nye test-/buildprodukter;
  gamle tags bevares. Uklar upload undersøges uden blind gentagelse.
- `AGENTS.md`, `docs/MAC-BUILD.md` og `docs/workspace-AGENTS.md` beskriver den
  faste proces. Den lokale parent-workspace `../AGENTS.md` peger nu også på
  den aktuelle 7.1.1-worktree. Personlig API-konfiguration er ignoreret/afvist
  fra Git. Ingen nye værktøjer eller dependencies er installeret.
- Nye lokale Python-resultater: **12/12, 30/30, 17/17, 24/24 og 40/40**.
  De 24 release-guards inkluderer syntetisk Git-checkpoint/push/tag/status,
  fuld genallokering/gentest ved nummerkonflikt, versionsspecifik uploadtilladelse,
  uændrede tags, direkte IPA-upload og afvisning af usikker status.
  De 40 API-tests dækker authentication, pagination, numerisk valg, processing,
  transient GET-retry og bekræftet intern gruppetilknytning. Alle tests er offline
  med syntetiske data og midlertidige repositories; fixture-numre i logs er ikke
  rigtige Apple-buildnumre.
- Shell-/Python-syntaks og diff-kontrol består. **1149 app-/projekt-/XCTest-filer**
  matcher den tidligere testede appkode byte-for-byte. Der er ikke lavet ny
  appkode. Den senere 4264-release-tree blev testet særskilt med **983/983**
  XCTest og begge simulatorbuilds; et nyt nummer udløser igen alle kontroller.
- GitHubs eksisterende adgang fungerer med release-scriptets normale Git-kald;
  `push --dry-run` bestod uden nye credentials eller konfigurationsændringer.
- Logs og bevis ligger lokalt under `build/release-automation-7.1.1/`:
  `python/logs/`, `auth-check/result.log`, `auth-check/release-attempt.log` og
  `source-scope.json`. De pushes ikke.

## Signering og nummerering før næste forsøg

App Store Connect-adgangen er nu konfigureret uden for Git med en Admin-teamnøgle
og ejerbegrænsede filrettigheder. Et læsende opslag på den eksisterende app
`6795645396` lykkedes. Xcodes CLI kunne ikke bruge det synlige Apple-login til
lokal distributionseksport, og en App Manager-teamnøgle blev afvist til
cloud-signering. Den godkendte Admin-teamnøgle gennemførte derefter en
**lokal distributionssigneret eksport** fra det eksisterende 4264-arkiv.
Ingen nøgleindhold er lagt i projektet.

Det første automatiske releaseforsøg testede **983/983 XCTest** uden fejl eller
skipped, byggede både iPhone og Watch til simulator, checkpointede/pushede
`435115f7f7d434030c8be468d6a628aa8e5b2b33` og oprettede det uflyttede
tag `testflight-7.1.1-4264`. Det lokale udviklingssignerede arkiv blev kontrolleret
for alle fem bundles. Eksporttrinnet i den daværende proces stoppede, før der
blev uploadet. Apples API viser nu 4264 som `AWAITING_UPLOAD`, ikke som et
modtaget eller testbart build. Den efterfølgende manuelle eksport var kun en
signeringsprøve; den er ikke uploadet.

Den næste automatiske kørsel valgte **4265** og testede netop den release-tree
med **983/983** beståede XCTest, 0 fejl/skipped og begge simulator-builds.
Checkpoint `e150560769e467c6c801b931c586e3c5b811118f` blev pushet med det
uflyttede tag `testflight-7.1.1-4265`. Både det signede Release-arkiv og den
distributionssignerede IPA blev oprettet og kontrolleret for de fem bundles.
Ingen IPA er uploadet: Xcodes eksport oprettede selv et tomt `AWAITING_UPLOAD`
hos Apple, som den gamle upload-guard fejlagtigt klassificerede som et fremmed
upload. Apple viser nu både 4264 og 4265 som `AWAITING_UPLOAD`, uden modtaget
Build for 7.1.1. Begge tags og de lokale produkter bevares.

Release-scriptet er nu rettet til at sende Admin-teamnøglens eksterne sti og
ikke-hemmelige ID'er til Xcodes understøttede signeringsflag. Det registrerer
Apple-status før eksport og det præcise ID på en ny, tom eksportreservation efter
eksport. Kun samme tomme ID må accepteres før altool-upload; andre poster
stopper eller udløser ny allokering. **24/24** syntetiske release-guards består,
inklusive den nye reservationstest. Den næste allokerede kandidat er **4266**;
den skal testes, checkpointes, tagges, bygges og verificeres særskilt før upload.

Den separate `invalidPayload`-risiko og fysisk Watch-afprøvning er stadig åbne.
Ingen fysisk iPhone eller Watch er installeret, startet eller ændret. De følgende
integrationsafsnit bevarer tidligere resultater og fejl som historik.

---

# Projektstatus – officiel 7.1.1-integration

Opdateret 24. september 2026. Den officielle opdatering er integreret på
`integration/upstream-7.1.1` i `../xdripswift-upstream-7.1.1`.
**Dette er ikke en TestFlight-udgivelse. Der er ikke uploadet eller installeret
noget på fysiske enheder.** 7.0.0 (4263) er fortsat det seneste bekræftede
Internal / Testing-build; dets historiske kildebeskrivelse nedenfor er bevaret.

## Rettelser efter integrationens første testkørsel

Brugeren godkendte de konkrete releaseblokeringer rettet med “fix det” og har
allerede godkendt upload af 7.1.1 med “opload”. Der kræves ikke et nyt GO UPLOAD
for denne samme udgivelse. **Upload er endnu ikke udført**: App Store Connect
har ikke kunnet kontrolleres gennem det tilgængelige browserværktøj, og næste
buildnummer må fortsat ikke gættes. Intet release-tag, signeret 7.1.1-arkiv
eller IPA er oprettet.

Kode-/testrettelserne er committet som
**`f90b1dcb1d716aea41a0c68be7c6a47cc405ceee`**, oven på
`200afbb03e525e4ce70f9c16eb491db17c874fa5`
(integrationskoden `a0a4a101c921b41e2942873f2bf58883bddb707f` med efterfølgende
statusdokumentation). Den præcise testede lokale diff og 1220 hashes af
versionerede filer uden dokumentation er bevaret lokalt i
`build/release-fixes-7.1.1/source-before-tests.patch` og
`tested-source-hashes.json`. Resultaterne nedenfor er nye kørsler af den rettede
kode; de historiske fejl og deres oprindelige bevis er bevaret længere nede.

De konkrete ændringer er:

- Dexcom-batteriets seks timers opstartsfilter gælder kun de to
  Dexcom-batterialarmtyper. Andre alarmtyper, herunder glukose og manglende
  målinger, bliver ikke undertrykt af dette batterifilter. Alarmgrænser,
  snooze, delegation og Watch-lokal alarmkode er uændrede.
- Nightscout-treatment-download gemmer URL/port før forespørgslen og bruger
  samme kilde ved præcise ID-opslag. Forældede svar og fortsættelser afvises
  igen på Core Data-køen før import, kvittering eller sletningsmarkering.
  Seks isolerede tests dækker URL-/portskift og den uændrede normale vej.
  Dette er en afgrænset rettelse af download/afstemning, ikke en ny atomisk
  transaktion for alle treatment-uploadveje. Glukosehistorikkøen er uændret.
- Statistikvisningens heltalsfordeling håndterer matematisk ens decimalrester
  deterministisk trods binær afrundingsstøj. Reelle forskelle bevarer deres
  rækkefølge; procent- og minuttotaler bevares. Glukoseberegning ændres ikke.
- CareLinks syntetiske hukommelseslager beskytter samtidig load/save/clear.
  Logout-testen holder et mock-svar eksplicit tilbage, og therapy-testen
  isolerer sin patientopsætning fra separat auto-selection/KVO-polling.
  Appens Keychain-lager og loginadfærd er uændrede.
- Core Data-roundtriptestene venter på afsluttet save i parent-testlageret, bruger
  permanente object-ID'er
  og nulstiller begge konteksters cache. Roundtriptestene bruger et
  hukommelseslager; de er ikke bevis for diskvarighed. Migrationstesten bruger sine private
  konteksters køer. Appens Core Data-manager og migrationsmodeller er uændrede.
- Tre GS1-testforventninger er rettet til de faktisk indkodede serienumre;
  en ekstra regression bevarer et ægte indledende 1-tal. Parseren er uændret.
  Dexcom-statustesten sammenligner de korrekte lokaliseringsnøgler frem for
  engelske tekster på en dansk simulator. Submission-kontrollerne er bevaret.

Alle 228 eksisterende metoder i de seks ændrede testfiler er bevaret, og
11 regressioner er tilføjet. Ingen tests er slået fra eller gjort til forventede
fejl. Bluetooth/reconnect, sensoridentitet/-overdragelse, Watch/Libre,
durability/restore, kalibrering, smoothing, alarmansvar og snooze er uændrede.
Ingen nye funktioner, dependencies, Apple-ændringer eller fysiske installationer.

Den første kompilering i denne rettelsesrunde stoppede ved en ældre test, som
læste og skrev direkte til det nu private syntetiske tokenfelt; ingen XCTest
blev kørt. Den bruger nu samme trådsikre load/save-API som andre forbrugere. Loggen
`build/release-fixes-7.1.1/logs/all-xctest.log` er bevaret særskilt.

Den afsluttende kørsel har **983/983 beståede tests, 0 fejl, 0 skipped** i den
færdige `.xcresult`; `xcodebuild` afsluttede med exit 0 / `TEST SUCCEEDED`.
De ti konkrete tidligere fejl er hver især slået op som bestået i resultattræet.
Den tidligere røde kørsel nedenfor ændres ikke til grøn med tilbagevirkende kraft.

| Kontrol på den rettede kode | Resultat | Lokalt bevis under `build/release-fixes-7.1.1/` |
| --- | --- | --- |
| Hele `xdripTests`, iPhone 17 / iOS 27 simulator | **983/983**, 0 fejl/skipped | `full-v2/results/AllTests.xcresult`, `logs/all-xctest-v2.log` |
| De otte krævede suites, som delmængde af samme fulde kørsel | **490/490** | `full-v2/results/stability-summary.json` og tilhørende Xcode-summary/test-tree |
| De otte Windows-durability-tests plus restore-regressionen | **9/9**, hver metode kontrolleret | `regression-comparison.json` |
| De 11 nye regressioner og de ti tidligere fejlede metoder | **Alle bestået**, navne kontrolleret i resultattræet | `regression-comparison.json` |
| Offline Python-kontroller | **12/12, 30/30, 17/17, 8/8** | `python/logs/` |
| iPhone-simulatorbuild, scheme `xdrip` | **Bestået** | `simulator-builds/logs/iphone-build.log` |
| Watch-simulatorbuild, scheme `xDrip Watch App` | **Bestået** | `simulator-builds/logs/watch-build.log` |
| Fem produktidentiteter, version og Watch-indlejring | **Bestået**, version 7.1.1 / udviklingsfallback 4231 | `simulator-products.json` |

De otte krævede suites består af LibreWatch 259, Troubleshooting 87,
WatchRefresh 41, PhoneRefresh 25, Snapshot 6, Delivery 30, NightscoutHistory 26
og RootHomeInteraction 16. De berørte øvrige suites består også: CareLink
108/108, DexcomG6SensorLabel 22/22, DexcomG7Calibration 41/41,
FollowerBackgroundKeepAlive 26/26 og GlucoseRangeDistribution 16/16.
Disse tal er delmængder af 983, ikke ekstra testkørsler.

De 11 nye metoder, alle bestået:

- `testMemoryTokenStoreConcurrentAccessKeepsWholeCredentials`
- `testSerialPreservesLeadingDigitsAfterApplicationIdentifier`
- `testDexcomBatterySettlingNeverSuppressesOtherAlertKinds`
- `testAllocatorKeepsDecimalTiesStableAcrossEquivalentWeights`
- `testAllocatorKeepsGenuinelyDifferentRemaindersOrdered`
- `testTreatmentBulkResponseAfterSiteSwitchCannotImportUpdateOrAcknowledge`
- `testTreatmentBulkResponseAfterPortSwitchCannotImportUpdateOrAcknowledge`
- `testTreatmentSiteSwitchDuringExactLookupPreservesEntriesAndStopsLookups`
- `testTreatmentPortSwitchDuringExactLookupPreservesEntriesAndStopsLookups`
- `testTreatmentReconciliationRechecksSourceBeforeApplyingExactResponse`
- `testTreatmentUnchangedSourceImportsUpdatesAndConfirmsDeletion`

Xcodes efterfølgende diagnoseindsamling ramte samme 600-sekunders timeout som
før; testkørslen selv sluttede normalt uden host-crash. Den færdige resultatpakke
og exitstatus er kontrolleret efter timeouten. Den er ikke talt som en testfejl
eller skjult i loggen. Simulator- og testbuilds genbrugte eksisterende DerivedData
fra første 7.1.1-kørsel; de nye logs/resultatpakker har egne stier og overskriver
ikke de tidligere fejlbeviser. Ingen fysisk enhed eller ekstern testtjeneste blev
brugt. Alle 1220 ikke-dokumentationsfiler matcher den efterfølgende kodecommit
byte-for-byte; manifestet angiver både testens oprindelige HEAD og kodecommitten.

Den separate `invalidPayload`-risiko og fysisk Watch-test er stadig åbne.
Simulatorresultater beviser ikke fysisk Bluetooth-stabilitet eller hørbare
alarmer. Når Apples buildnummer er bekræftet, skal det sættes i den tracked
versionsfil **før** release-scriptets nye testkvittering, checkpoint/push, tag,
arkiv/IPA fra tagget og verifikation. Udviklingsfallback 4231 må ikke uploades.

## Kildegrundlag og konfliktløsning

- Uændret checkpoint før opdateringen: `checkpoint/post-testflight-4263`,
  `5a0ce985c86909e3827970f4487ca573bd46a7a5`.
- Officiel kilde: `JohanDegraeve/xdripswift`, tag **7.1.1**, verificeret til
  `c268542e64626c564e626658fa9a6b90a059ada4`.
- Integrationskodecommit: **`a0a4a101c921b41e2942873f2bf58883bddb707f`**,
  med checkpointet og det officielle tag-commit som de to forældre. Det er et
  integrationscheckpoint, ikke et release-tag. Statuscommitten `200afbb03e525e4ce70f9c16eb491db17c874fa5`
  efter denne kodecommit ændrede kun dokumentation; den nyere rettelsesrunde
  er beskrevet ovenfor.
  Det lokale reference-tag hedder
  `upstream/7.1.1`; det er ikke et TestFlight-tag og pushes ikke.
- Der er foretaget en konkret trevejssammenfletning, ikke en erstatning med
  upstream-filer. De 16 konfliktfiler er løst enkeltvis.
- Projektfilen indeholder både alle officielle nye kildefiler og vores
  Watch-/testfiler, uden dobbelte source-memberships. Team, fem bundle IDs,
  entitlements/App Groups og kildecommit-stempling er bevaret. Alle fem
  simulatorprodukter har marketingversion **7.1.1**.
- Watch-status har fået upstreams therapy metrics gennem den eksisterende
  samlede statuslevering. Watch-ejerskab, handoff, recovery, lokal målingskø,
  restore-rettelse, alarmansvar og snooze er bevaret. Ingen ny statuskoordinator
  eller Apple Sundhed-insulinimport er tilføjet.
- Telefonens officielle Libre-frameassembler og ankomsttid bruges sammen med
  vores ejerskabs-/pausekontroller. Den eksisterende pausekontrol blev flyttet
  før upstreams udtrukne fælles connect-helper, så den fortsat stopper discovery.
  Watch-modtagerens lagrings-/kvitteringsmetoder og parent-store completion er
  uændrede. Køskrivefejl blokerer fortsat ikke Watch-lokal visning eller alarmer.
- Nightscouts officielle upsert-ændring var allerede tilbageført med stærkere
  historikkø-/site-/revisionkontroller. Den er ikke implementeret dobbelt.
  Vores præcise SGV-sletning og kvitteringskø er bevaret; officiel afstemning
  af slettede treatments er indarbejdet.
- HealthKit beholder vores versionerede, serielle retry-kø. Officielle
  forgrund-/unlock-genforsøg, validering mod aktuelle Core Data-værdier og
  præcis sletning af skjulte målings-ID'er er integreret i samme kø. En ny
  syntetisk regression dækker bevarede revisioner og sen completion efter
  sletning/genoprettelse.
- Officiel trend-/model-/backup-/UI-/Dexcom-funktionalitet er med. Diagnosejournal
  og klinisk kø forbliver adskilte. Accepterede direkte målinger logges efter
  efterbehandling; Watch-historik går fortsat uden om live-alarmvejen.
- Testens telefonparser har fået det krævede `newestReadingDate`-argument.
  En forældet logfilter-forventning er tilpasset det officielle format, hvor
  enheden står i rapporthovedet. Ingen test er deaktiveret.
- Resultatparseren skelner nu mellem XCTest-klassen og dens extensions, når
  upstream placerer flere testklasser i samme Swift-fil. De syv nye
  `RootHomeStatisticsEasterEggTests` tilskrives ikke længere fejlagtigt
  `RootHomeInteractionTests`. Intet krav eller testudvalg er fjernet;
  parserens syntetiske ejerskabs-/resultatkontroller er udvidet til 30.
- Mac-værktøjer og signeringsopsætning er genbrugt uden installationer eller
  Apple-ændringer. `codemagic.yaml` er urørt. Release-commitbeskeden har nu
  `[skip ci]`; workflows har ingen aktive push/tag-triggere.

## Historisk verifikation før release-rettelserne

Resultaterne for 4263 nedenfor må ikke bruges som bevis for denne integration.
De nye logs og `.xcresult` ligger under `build/upstream-7.1.1-integration/`.
Den første kompilering stoppede ved det nye parserargument; den er bevaret i
`initial-full/`. Den efterfølgende fulde suite og den afsluttende Watch-regression
rapporteres separat:

| Kørsel | Faktisk resultat | Bevis |
| --- | --- | --- |
| Fuld `xdripTests`, før logtest-tilpasning | **972 udført; 962 bestået, 10 fejlet, 0 skipped** | `full-v2/results/AllTests.xcresult`, `full-v2-summary.json`, `full-v2-test-tree.json` |
| Afsluttende otte Watch/Libre-suiter | **484 udført; 484 bestået, 0 fejlet, 0 skipped**, bekræftet i færdig `.xcresult` og parser | `final-ci/results/Verification.xcresult`, `final-ci/results/stability-summary.json`, `final-ci/logs/xctest-verification.log` |
| Officiel Dexcom G7-statustest med engelsk sprog | **1/1 bestået** | `english-status.xcresult`, `english-status-summary.json` |
| Offline Python-kontroller | **12/12, 30/30, 17/17 og 8/8** | `python-final/logs/` |

Den fulde suites afsluttende konsollinje talte kun sidste test-host-proces
(748 tests); de **972** ovenfor er Xcodes samlede `.xcresult` inklusive
host-genstarter. Den fulde suite er ikke efterfølgende omklassificeret som grøn.
Appkoden er den samme i fuld kørsel og afsluttende regression; logtestens
forventning og resultatparseren er de beskrevne efterfølgende testværktøjstilpasninger.
Alle 617 kilde-/test-/projekt-/modelhashes fra den afsluttende kandidat blev
kontrolleret uændrede ved integrationens commit. Manifestet er
`tested-source-hashes.json`; testens oprindelige Git HEAD var basiscommitten,
fordi sammenfletningen endnu ikke var committet, da XCTest startede.

Den afsluttende udvælgelse består af `LibreWatchValuePipelineTests` 259,
`TroubleshootingLogTests` 87, `WatchRefreshCoordinatorTests` 41,
`WatchPhoneRefreshServiceTests` 25, `WatchSnapshotSemanticsTests` 6,
`WatchDeliveryEvidenceTests` 30, `NightscoutHistoryWriteTests` 20 og
`RootHomeInteractionTests` 16. De otte `testSubmission…`-metoder og
`testSubmissionRestoreSelectsNewerFileReadingAfterInitialReadFailure`, som
navngives i 4263-afsnittet nedenfor, er genkørt og bestået i denne integration.
Den nye `testHealthKitCadenceDeletionRetainsOtherRevisionsAndSurvivesRestart`
er også bestået. Dette er nye resultater, ikke genbrug af de historiske 475/475.

Den fulde kørsel indeholder desuden blandt andet beståede officielle suites:
`BasalInjectionTests` 24/24, `BatteryHistoryTests` 20/20,
`BgReadingTrendTests` 4/4, `BluetoothSignalStrengthTests` 17/17,
`GMIStatisticsTests` 6/6, `Libre2FrameAssemblerTests` 3/3,
`LiveActivityWarmupTests` 7/7, `TherapyMetricsTests` 48/48 og
`RootHomeStatisticsEasterEggTests` 7/7. Ingen fysiske enheder eller
personlige testdata blev brugt.

Xcodes efterfølgende simulator-diagnoseindsamling bruger igen op til 600 sekunder
og kan melde timeout, ligesom baseline. XCTest-resultaterne ovenfor kommer fra
selve testkørslerne; diagnoseindsamlingen er ikke talt som beståede tests.

Begge separate simulatorbuilds er bestået (iPhone `xdrip` og Watch
`xDrip Watch App`), med logs i `simulator-builds/logs/`. Kontrollen i
`simulator-products.json` bekræfter korrekt indlejring og alle fem identiteter.
Build **4231** er alene den bevarede udviklingsfallback i disse simulatorprodukter,
**ikke** et valgt eller bekræftet næste TestFlight-buildnummer.

En isoleret native macOS/Core Data-kontrol migrerede en SQLite-database oprettet
med checkpointets præcise v27-model til den officielle v32-model og genåbnede
den i en tredje proces. Otte syntetiske records og 22 værdi-/relationskontroller
bestod ved både migration og genåbning: målings-ID/værdi/tid, kalibrering/sensor,
alarmer, snooze og periferidata. Den gamle kilde-model var utilgængelig under
migrationen. Derfor blev de officielle historiske modeller ikke ændret.
Bevis: `build/migration-v27-v32-audit/summary.json`, `authoritative.log` og
`reopen.log`. Dette er macOS-migrationsbevis, ikke test på alle understøttede
fysiske iOS-versioner.

## Historiske fund før release-rettelserne

Dette afsnit bevarer de tidligere fejl og vurderinger. Deres aktuelle status
fremgår af rettelsesafsnittet ovenfor; de er ikke slettet fra historikken.
Den daværende fulde suite var ikke grøn. Nye fund må ikke kaldes gamle fejl alene på grund
af tidligere suiteproblemer. Sammenligningen bruger den oprindelige rå log
`../xdripswift/build/local-setup-20260923/logs/all-xctest-iphone17.log` og den nye
resultatpakke (`baseline-comparison.json`):

| Test | Sammenligning/status |
| --- | --- |
| `BluetoothPeripheralDisplayStatusTests.testNewPeripheralPersistsFalseActivationSuccessByDefault` | Tidligere fejlet, nu bestået. |
| `DexcomG6SensorLabelTests.testDecodesAllObservedSensorLabels` | Samme tre strengafvigelser som baseline; stadig fejlet. |
| `DexcomG6SensorLabelTests.testRoundTripsSensorStartMetadataThroughCoreData` | Samme Core Data 133000-fejl som baseline. |
| `DexcomG6SensorLabelTests.testMigratesExistingSensorFromV26ToV27` | Crash; den gamle rå log viser også host-genstart ved denne metode, selv om den tidligere oversigt ikke navngav den. Den særskilte v27→v32-migration ovenfor er en anden test. |
| `CareLinkTests.testBlockedTherapyImportCannotBlockGlucoseOrAnotherPoll` | Tidligere crash; nu assertion-fejl. Fejltypen er ændret og fortsat åben. |
| `CareLinkTests.testSlowLogoutCannotClearANewerSession` | Tidligere bestået, nu crash. **Ny uafklaret regression**, ikke mærket som kendt baselinefejl. |
| `DexcomG6SensorLabelTests.testRoundTripsDexcomG7LabelAndConnectionSettingsThroughCoreData` | Ny officiel test fejler med Core Data 133000; ingen tilsvarende baseline-metode. Uafklaret. |
| `DexcomG7CalibrationTests.testCalibrationStatusShortDescriptionsAndSubmissionGating` | Fejler på danske strenge; uændret test består med engelsk sprog. |
| `GlucoseRangeDistributionTests.testClinicalTIRBucketsShareWholePercentAndMinuteAllocation` og `testLargestRemainderPreventsIndependentRoundingFromProducing101Percent` | To nye officielle testfejl, reproduceret fra uændret upstream-kode. |
| `TroubleshootingLogTests.testActivityLogFilterMatchesRenderedMessagesAndRestoresFullListForBlankText` | Fejlede i fuld kørsel; logformat-forventningen er tilpasset, og testen består i afsluttende regression. |

De fem tidligere CareLink-crashmetoder `testAllPersonalGlucoseFamilies`,
`testCarePartnerResolvesLinkedPatientsAndScopesPeriodicRequest`,
`testPeriodicCompatibilityEndpointFallback`,
`testPumpOnlyPeriodicPayloadRemainsUsableDuringSensorGap` og
`testSuccessfulEmptyRouteTakesPrecedenceOverLaterFallbackErrors` består nu.
Ingen af disse resultater ændrer den historiske 4263-rapport.

Følgende er holdt adskilt fra integrationen:

- Officiel afrundingskode giver `[3, 88, 9]`, hvor to nye tests forventer
  `[4, 87, 9]`. Uændrede kilde-/testfiler er sammenlignet byte-for-byte med
  `c268542`, og resultatet er reproduceret i en native Swift-kørsel.
  Bevis: `build/upstream-baseline-reproduction/`.
- En ny officiel Dexcom G7-test forventer engelske statustekster, men får de
  officielle danske lokaliseringer på denne simulator. Den samme uændrede test
  er efterfølgende kørt isoleret med `-testLanguage en -testRegion US` og bestod
  **1/1**, dokumenteret i `english-status.xcresult` og
  `english-status-summary.json`. Den danske fejl er bevaret, ikke skjult.
- **Officiel Dexcom-alarmfejl:** den nye batteri-opstartskontrol i
  `AlertManager.checkAlertAndFire` tester ikke alarmtypen. Ved en Dexcom-batteripakke
  og hardware yngre end seks timer eller ukendt alder kan den også undertrykke
  glukosealarmer og missed-reading-planlægning. Kaldesti og kode er verificeret
  mod upstream; der er ikke foretaget fysisk alarmtest. Almindelige Libre-pakker
  og vores Watch-lokale alarmvej går ikke gennem denne kontrol. En rettelse af
  selve alarmreglen er en særskilt opgave, ikke udført her.
- Officiel Nightscout-treatment-afstemning tager site-snapshot efter den første
  netværksrespons. Et serverskift under forespørgslen kan derfor føre til kontrol
  mod en forkert server. Dette er et kodegennemgangsfund i den uændrede officielle
  treatment-vej; vores sitebundne glukosekø er bevaret. Ikke fysisk reproduceret.
- Den separate `invalidPayload`-risiko fra 4263 og fysisk Watch-test af
  forgrund/baggrund, reconnect, offline-efterlevering, alarmer og snooze er fortsat
  åbne. Simulatorresultater dokumenterer ikke fysisk Bluetooth-stabilitet eller
  hørbare alarmer.

Der er **intet nyt release-checkpoint/tag, signeret arkiv eller IPA**.
Release kræver afklaring af de nye relevante testfejl samt et aktuelt bekræftet
buildnummer hos Apple. Browserkontrollen afviste adgang til App Store Connect;
der er ikke forsøgt omgåelse, og der er ikke gættet på 4264 eller kopieret et
upstream-buildnummer. Når det er afklaret, sættes nummeret i den versionerede
`xDrip/Version.xcconfig` **før** release-scriptets tests, checkpoint/push, tag og
arkiv/IPA fra tagget. Brugerens senere “opload” godkender upload af denne version; Apple-nummeret og
den faste releaseproces mangler fortsat som beskrevet ovenfor.

---

# Projektstatus – post-TestFlight 4263 checkpoint

Opdateret 24. september 2026. Version **7.0.0 (4263)** er uploadet til den
eksisterende TestFlight-app og står som **Internal / Testing**. Den indeholder
Windows-patchen til Watch-målingskøen, de nyere Mac-rettelser og den testede
restore-rettelse. **475/475 relevante XCTest-tests bestod før upload.**
Ingen fysisk enhed blev installeret eller startet under opgaven.

**4263 er sidste build efter den gamle proces.** Det blev bygget fra den lokale
integrations-worktree med ikke-committede ændringer, **ikke** fra et på forhånd
pushet release-tag. Branch `checkpoint/post-testflight-4263` bevarer koden og
den nye release-proces *efter* uploaden; der oprettes intet retroaktivt
`testflight-7.0.0-4263`-tag. Fra næste build gælder
**test → checkpoint/push → tag → build fra tag → verify → GO UPLOAD → TestFlight → status**.
Se [AGENTS.md](../AGENTS.md) og [Mac-build-processen](MAC-BUILD.md).

## Kilde og adskilte arbejdskopier

- Remote: `https://github.com/Don-Olsen/xdripswift.git`.
- Den bevarede integrationsworktree er `../xdripswift-watch-reading-integration`.
  Den permanente branch er `checkpoint/post-testflight-4263`. Første commit
  `bbd19bdef2a97847e82b12e08e7c2a28993d3d74` gemmer præcis de fire
  Swift-kode- og testfiler, som 4263 brugte. En efterfølgende commit gemmer
  release-proces, projektmetadata og dokumentation.
- Den historiske integrationsbasis var overleveringscommitten
  `7656891576a25246cf12c33214efa81cc88076dd`.
- Overleveringscommitten ligger oven på den nyere appkode
  `d09bac575d9622d1368cbba0dc3039862d997ed3` og ændrer kun dokumentation.
  Den oprindelige Mac-arbejdskopi `../xdripswift` står fortsat på
  `fix/nightscout-safe-history-upsert` ved `d09bac57`.
- Windows-udkastets basis var
  `e11a6f4d3674b0ef58f1ac5159fcf0aac7ca8c21`. Den bevarede patch er
  [watch-reading-durability.patch](handoff/watch-reading-durability/watch-reading-durability.patch)
  (SHA-256 `ced1bf72d67cc9839cfc9907d1a0060895d28b3a32ef4dedb8df49eb127918ed`).
  [README](handoff/watch-reading-durability/README.md) og
  [code-review](handoff/watch-reading-durability/code-review.md) beskriver
  overførslen og den kendte restore-fejl. Det oprindelige udkast var ikke bygget
  eller testet på Mac.

Swift-integrationscommitten ændrer kun fire filer:
`xDrip Tests/LibreWatchValuePipelineTests.swift`,
`xDrip Watch App/DataModels/WatchStateModel.swift`,
`xDrip Watch App/Views/LibreDirectView.swift` og
`xDrip/Managers/Watch/LibreWatchDirectSession.swift`.
Den præcise diff, som XCTest og simulator-builds brugte, ligger i
`build/integration-20260924/integrated-swift-tested.patch`
(SHA-256 `cfc9262a113f78b639cdbe358eb541cea0a7133b018efa8bcd664d54cdf3ef9f`).
Den er 416 tilføjelser og 28 sletninger i forhold til overleveringscommitten.
`docs/MAC-BUILD.md` og `scripts/local-build.sh` kom oprindeligt fra den
tidligere Mac-arbejdskopi. Signaturkontrollen blev siden rettet til Apples
standard-Keychain-gruppe og genkontrol af arkiv/IPA; den permanente version
af filerne ligger i procescommitten. Denne efterfølgende procesændring ændrer
ikke 4263-appkoden. Den ignorerede
`xDripConfigOverride.xcconfig` er også kopieret lokalt; den indeholder
teamvalg, ikke nøgler eller certifikater. `codemagic.yaml` er urørt.

## Integreret adfærd

Det overførte udkast forsøger at gemme et accepteret Watch-payload i den
begrænsede, atomisk skrevne leveringskø **før** lokal visning og alarm.
Målingens ID og oprindelige tidspunkt bevares. Skrivefejl rapporteres, men
lokal visning og eksisterende alarmvej fortsætter; køen kan forsøges gemt igen
ved en eksisterende eksekveringsmulighed. Den nyere
`d09bac57`-registrering af afvisning, accept og faktisk køskrivning er
bevaret under sammenfletningen. En transportafsendelse tæller ikke som
telefonlagring.

Den dokumenterede restore-fejl er rettet ved at vælge den nyeste gyldige
måling **efter**, at en tidligere ulæselig køfil er genlæst og sammenflettet.
Regressionen simulerer en fejlet første læsning, en ældre cachemåling A og en
nyere kømåling B. B bliver gendannet uden nyt ID eller friskere tidsstempel.
Bluetooth, sensorejerskab, glukoseberegning, kalibrering, alarmansvar og snooze
er ikke ændret.

## Verifikation

Før upload udførte den serielle Codemagic-relevante XCTest-kørsel på iPhone-simulatoren
**475 tests, 0 fejl**. Alle otte overførte metoder blev kørt og bestod:

1. `testSubmissionCommitsRealOutboxBeforePublishingAndAllowsDiagnosticReads`
2. `testSubmissionRestartBetweenQueueAndDisplayCacheRecoversNewestReading`
3. `testSubmissionRepairsLegacyAndFailedWriteCacheOnceWithoutChangingID`
4. `testSubmissionConfirmedAndAcknowledgedCacheIsNotRequeuedOnRestart`
5. `testSubmissionFailedWriteKeepsRAMAndClinicalPublicationThenRetries`
6. `testSubmissionRestartRepairsLatestCachedReadingAfterQueueWriteFailure`
7. `testSubmissionDuplicateOutOfOrderAndWrongSessionDoNotPersistOrPublish`
8. `testSubmissionRestorePreservesSessionCalibrationAndAgeBounds`

Den niende, nye regression
`testSubmissionRestoreSelectsNewerFileReadingAfterInitialReadFailure`
blev også kørt og bestod. `xcodebuild` afsluttede med exitkode 0 og
`TEST SUCCEEDED`. Den færdige
`build/integration-20260924/results/Verification.xcresult` og projektets
`stability-summary.json` bekræfter 475/475 beståede, 0 fejlede og 0 skipped;
`LibreWatchValuePipelineTests` udgør 258/258. Kørslens log er
`build/integration-20260924/logs/xctest-verification.log`. Begge separate
simulator-builds bestod:
`build/integration-20260924/logs/iphone-build.log` og
`build/integration-20260924/logs/watch-build.log`.
De to runtime-advarsler i `.xcresult` (SwiftUI-publicering under view-opdatering
og QoS-prioritetsinversion) findes også i den tidligere 466/466-baseline; de
er ikke undersøgt eller skjult af denne integration. Xcodes efterfølgende
simulator-diagnoseindsamling timed out efter 600 sekunder som ved den tidligere
Mac-kørsel; testresultatpakken blev færdig og viser `Passed`.

Den komplette `xdripTests`-suite blev ikke genkørt. Den tidligere Mac-kørsels
kendte BluetoothPeripheral-/Dexcom-fejl og CareLink-crash er fortsat synlige i
den oprindelige arbejdskopis `docs/MAC-BUILD.md` og
`build/local-setup-20260923/`; de blev hverken rettet, deaktiveret eller
omklassificeret af denne integration. Simulator-tests påviser ikke stabil
fysisk Bluetooth-drift eller hørbare alarmer.

## Release og resterende arbejde

Den eksisterende App Store Connect-app har app-id
`6795645396`, team `GFZ896KN66`. Build `4263` var ledigt ved
kontrol af version `7.0.0`, hvor seneste tidligere upload var `4262`.
Lokal Release-preflight bestod for samme team, alle fem eksisterende bundle
IDs, Automatic Signing og tomme manuelle profilvalg.

Det faktisk signerede Release-arkiv er
`build/release-upload-20260924/archive/xdrip.xcarchive`. Det blev bygget
fra en isoleret kopi af **den lokale integrationskode**, ikke fra
overleveringscommitten alene. Kildebeviset ligger i
`build/release-upload-20260924/results/archive-source-state.txt`,
`archive-tracked-changes.patch` (SHA-256
`d148464e1f031980c53ae7a25395de21cdd3e259ec2a3db217a16da96c3fbbaf`),
`archive-untracked-files.txt` og `archive-staged-files.json`. De fire
staged Swift-filer blev sammenlignet byte-for-byte med den testede worktree.
Arkivet er development-signeret af det eksisterende team.

Den lokalt eksporterede, distributionssignerede IPA ligger i
`build/release-upload-20260924/export/xdrip.ipa`
(SHA-256 `58ac0488d1a85f0831bdb8ea3540d7d82dc660de52ba74ed00088a654b277466`).
Xcodes eksportresume angiver **Cloud Managed Apple Distribution**.
`archive-development-signed-bundles.json` og
`export-distribution-signed-bundles.json` i samme `results/`-mappe
kontrollerer signaturer, profiler, team, version/build `7.0.0 (4263)`,
App Groups, standard-Keychain-adgang, HealthKit, NFC og indlejring af
iPhone-app, Widget, Notification-extension, Watch-app og Watch complication.
Eksporten havde `destination=export` og uploadede ikke.

Arkivbuildet lykkedes, men det oprindelige lokale kontrolscript stoppede
før eksport, fordi det krævede et eksplicit `keychain-access-groups`-felt.
Den signerede kode har ikke dette valgfrie felt; Apple bruger da appens ID
som standardgruppe, og alle fem profiler autoriserer den. CareLink-koden
angiver ingen særskilt Keychain-gruppe. Kun den lokale verifikator blev
rettet, hvorefter samme arkiv og IPA bestod fuld kontrol.
Se [Apples dokumentation om standard-Keychain-gruppen](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps).

Xcode uploadede **én gang** fra dette arkiv med
`method=app-store-connect`, `destination=upload`,
`testFlightInternalTestingOnly=true` og
`manageAppVersionAndBuildNumber=false`. Loggen
`build/release-upload-20260924/logs/upload.log` ender i
`Upload succeeded`. App Store Connect viste først **Processing** og derefter
**Complete** for build-uploaden. Build 7.0.0 (4263) står nu som
**Internal / Testing** under app `6795645396`.
Den eksisterende interne testergruppe blev tilknyttet automatisk. Ingen ny
gruppe, ny tester, ekstern test eller App Store-udgivelse er oprettet.

Det tidligere unsigned kontrolarkiv i
`build/release-integration-20260924/unsigned/xdrip.xcarchive` er ikke
uploadproduktet.

En separat, ældre kodevurdering peger på, at telefonens midlertidigt manglende
sensor-/kalibreringskontekst kan blive klassificeret som terminal
`invalidPayload`. Denne modtagervej er ikke ændret i den aftalte integration;
fundet er hverken en ny regression eller dokumenteret årsag til en fysisk
måling, der forsvandt. Fysisk test af forgrund, urskive/baggrund,
offline-efterlevering og alarmer er stadig nødvendig før en udgivelsesbeslutning.
Uploaden er kun til intern afprøvning og dokumenterer ikke, at disse
separate fejl eller fysiske Watch-forløb er løst. `invalidPayload`-risikoen og
de tidligere dokumenterede full-suite-fejl står fortsat åbne.

## Lokal release-proces til fremtidige builds

Efter uploaden af 4263 er den lokale proces udvidet med
`AGENTS.md`, `scripts/release-testflight.py`, release-spærretests og
opdateret `scripts/local-build.sh`/`docs/MAC-BUILD.md`. Nye builds skal have
det bekræftede nummer i **Git-versionerede** `xDrip/Version.xcconfig`, et
testet checkpoint, pushet branch og annoteret TestFlight-tag, før et arkiv
kan bygges. Arkivet udtrækker præcis taggets Git-træ. Buildsettingen
`XDRIP_SOURCE_COMMIT` udfylder iPhone- og Watch-Info.plist uden at ændre den
taggede kildekode. Et separat uploadtrin kræver udtrykkeligt `GO UPLOAD` og
frisk kontrol i App Store Connect; et forsøgsstempel hindrer automatisk
gentagelse ved uklar status. Efterfølgende Apple-status skrives i en separat
dokumentationscommit uden at flytte tagget.

Procesfilerne og de nye Info.plist-/xcconfig-felter er bevaret i den anden
commit på checkpoint-branchen. De er fra **efter** 4263-uploaden og var ikke
input til det historiske arkiv. Swift-kodecommitten bevarer de præcise fire
appkode-/testfiler; det lokale arkivs kildebevis ovenfor beskriver også de
dengang genererede buildnummer- og commitstempler. Der er ikke oprettet et
nyt 4263-arkiv eller et retroaktivt tag. De nye
syntetiske release-spærretests bestod **8/8**, inklusive et isoleret lokalt
checkpoint, push, tag og efterfølgende dokumentationscommit uden tagflytning.
De eksisterende offline
Python-kontroller bestod 12/12, 12/12 og 17/17. iPhone- og Watch-simulatorbuilds
med den nye Info.plist-metadata bestod begge; logs ligger i
`build/release-process-smoke-escalated/logs/`. Produkterne viste
`XDripSourceCommit=untagged` i en almindelig simulatorbuild, som forventet;
Release-buildsettings for både iPhone- og Watch-schemes accepterer samme
eksplicitte 40-tegns SHA. Et tagged Release-build får checkpoint-SHA derfra og
kontrolleres efter signering. XCTest blev ikke genkørt for denne rene
release-konfigurationsændring; de 475/475 ovenfor tilhører den faktisk
uploadede integrationskode. Intet nyt arkiv eller upload blev startet.
