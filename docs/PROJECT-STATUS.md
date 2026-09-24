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
