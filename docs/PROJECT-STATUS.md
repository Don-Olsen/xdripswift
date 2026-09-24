# Projektstatus – officiel 7.1.1-integration

Opdateret 24. september 2026. Den officielle opdatering er integreret på
`integration/upstream-7.1.1` i `../xdripswift-upstream-7.1.1`.
**Dette er ikke en TestFlight-udgivelse. Der er ikke uploadet eller installeret
noget på fysiske enheder.** 7.0.0 (4263) er fortsat det seneste bekræftede
Internal / Testing-build; dets historiske kildebeskrivelse nedenfor er bevaret.

## Kildegrundlag og konfliktløsning

- Uændret checkpoint før opdateringen: `checkpoint/post-testflight-4263`,
  `5a0ce985c86909e3827970f4487ca573bd46a7a5`.
- Officiel kilde: `JohanDegraeve/xdripswift`, tag **7.1.1**, verificeret til
  `c268542e64626c564e626658fa9a6b90a059ada4`.
- Integrationskodecommit: **`a0a4a101c921b41e2942873f2bf58883bddb707f`**,
  med checkpointet og det officielle tag-commit som de to forældre. Det er et
  integrationscheckpoint, ikke et release-tag. Denne efterfølgende statusændring
  ændrer kun dokumentation.
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

## Verifikation af 7.1.1

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

## Åbne fund og releaseblokeringer

Den fulde suite er ikke grøn. Nye fund må ikke kaldes gamle fejl alene på grund
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
arkiv/IPA fra tagget. Upload kræver et nyt, særskilt **GO UPLOAD** for denne version.

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
