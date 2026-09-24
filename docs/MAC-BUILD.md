# Lokal Mac-build af Don-Olsen/xdripswift

Maskin- og baselineoplysningerne nedenfor blev verificeret den 23. september
2026. Release-reglen nedenfor gælder fremtidige TestFlight-builds fra dette
repository. Det allerede uploadede 7.0.0 (4263) brugte den ældre proces og
må ikke efterfølgende beskrives som bygget fra et tag.
Den nuværende permanente checkpoint-branch er
`checkpoint/post-testflight-4263`; kode- og testcommitten er
`bbd19bdef2a97847e82b12e08e7c2a28993d3d74`. Den næste commit på
branchen bevarer denne vejledning og release-scriptet. Oplysningerne under
"Historisk Mac-baseline" beskriver den ældre checkout før integrationen.

## Aktuel 7.1.1-integrationsworktree

Den officielle 7.1.1-opdatering arbejdes på i
`../xdripswift-upstream-7.1.1`, branch `integration/upstream-7.1.1`, fra
checkpoint `5a0ce985c86909e3827970f4487ca573bd46a7a5`. Den gamle
integrationsworktree og checkpointet er bevaret. Genbrug denne eksisterende
worktree; begynd ikke igen i 4263-checkoutet. Se den aktuelle teststatus og
releaseblokeringer i [PROJECT-STATUS.md](PROJECT-STATUS.md).

Mac-værktøjer, lokal identitetskonfiguration og signeringsaktiver er genbrugt.
Marketingversionen er 7.1.1 på alle fem bundles, men det næste release-buildnummer
er endnu ikke bekræftet hos Apple. Simulatorens fallback 4231 må ikke uploades.
De konkrete releaseblokeringer er rettet: 983/983 XCTest-tests og begge
simulatorbuilds består; detaljer står i PROJECT-STATUS.md. Brugeren har
efterfølgende godkendt upload af 7.1.1 med
“opload”; der kræves ikke endnu en godkendelse for samme udgivelse. Et aktuelt
Apple-bekræftet buildnummer og den faste tag-baserede releaseproces mangler
fortsat. Genbrug ikke udviklingsbuildet eller et historisk testresultat som
release-kvittering efter ændring af versionsfilen.

## Fast TestFlight-proces fra næste build

Læs [AGENTS.md](../AGENTS.md) og [aktuel projektstatus](PROJECT-STATUS.md).
En ny Codex-chat skal udføre checkpoint, commit, push og tag som en normal del
af enhver fremtidig TestFlight-udgivelse. Brug samme eksisterende app
`6795645396`, team `GFZ896KN66` og de fem bundle IDs. Få det næste ledige
buildnummer fra App Store Connect; versionsfilens ældre fallback er ikke nok.

Inden test sættes `CURRENT_PROJECT_VERSION` i den **tracked**
`xDrip/Version.xcconfig` til det bekræftede buildnummer. Gennemgå koden og
stage præcis den kildekode, tests, projektkonfiguration og dokumentation, der
skal med. Gennemgå den faktiske staged diff for funktionalitet, utilsigtede
filer og secrets. Release-scriptet stager intet selv og afviser både unstaged
ændringer, untracked filer og kendte artefakt-/credential-filnavne. Ignorerede
signeringsindstillinger er lokale; de er aldrig en del af Git-træet.

Kør derefter sekvensen med det samme buildnummer i miljøet:

```sh
export XDRIP_BUILD_NUMBER=<bekræftet-ledigt-nummer>
export XDRIP_ASC_BUILD_CONFIRMED=YES
./scripts/release-testflight.py check

# Efter gennemgang af `git diff --cached`:
XDRIP_STAGED_DIFF_REVIEWED=YES ./scripts/release-testflight.py checkpoint
./scripts/release-testflight.py publish
./scripts/release-testflight.py build
./scripts/release-testflight.py verify
```

`checkpoint` kører Python-kontroller (inklusive syntetiske release-spærretests),
de otte relevante XCTest-suiter og
separate iPhone-/Watch-simulatorbuilds på præcis samme staged Git-træ. Kun ved
bestået resultat committes det træ; træ-hashen kontrolleres igen bagefter.
`publish` pusher checkpoint-committen og opretter/pusher et **annoteret** tag
`testflight-<version>-<buildnummer>` på præcis denne commit. Begge fjernrefs
kontrolleres. Eksisterende tags flyttes aldrig. Alle tests, logs og
release-state gemmes lokalt under `build/testflight-<version>-<buildnummer>/`.

`build` kræver et rent working tree, testkvitteringen samt pushet branch og tag
på samme commit. `scripts/local-build.sh archive` udtrækker kildekoden direkte
fra taggets Git-træ og bygger det developer-signerede arkiv og den lokalt
cloud-distributionssignerede IPA. Buildnummeret kommer fra den taggede
versionsfil; der skrives ingen ny versionsfil ind i buildkilden. Det indbyggede
`XDripSourceCommit` kommer fra checkpoint-committen via Xcode-buildsettingen
og kontrolleres i iPhone- og Watch-produktet. De fem bundles, profiler,
entitlements, version og build verificeres. `verify` genkontrollerer den
eksporterede app og gemmer IPA'ens SHA-256. Ingen af disse kommandoer uploader.

**Kun efter brugerens udtrykkelige `GO UPLOAD` for dette build** og et frisk
opslag af app/version/build i App Store Connect må uploadtrinnet udføres:

```sh
XDRIP_GO_UPLOAD=YES XDRIP_ASC_UPLOAD_SLOT_CONFIRMED=YES \
  ./scripts/release-testflight.py upload
```

Dette bruger Xcodes `-exportArchive` med `destination=upload`, automatic
signing, `testFlightInternalTestingOnly=true` og det samme arkiv som den
verificerede eksport. En lokal `upload-attempt.json` skrives **før** kaldet,
så timeout eller ukendt resultat ikke udløser et automatisk dobbelt-upload.
Kontrollér først Apples faktiske modtagelsesstatus ved usikkerhed.

Når Apple er kontrolleret, angives den observerede status (`received`,
`processing` eller `internal-testing`) og det præcise buildlink. Ved intern
test angives også navnet på den **eksisterende** gruppe:

```sh
XDRIP_ASC_STATUS=internal-testing \
XDRIP_ASC_BUILD_URL=<buildets-App-Store-Connect-link> \
XDRIP_ASC_INTERNAL_GROUP=<eksisterende-gruppenavn> \
  ./scripts/release-testflight.py status
```

`status` opdaterer kun `docs/PROJECT-STATUS.md`, laver en separat
dokumentationscommit og pusher den. Tagget bliver på den oprindelige
build-commit. Oplys også fortsat kendte fejl og fysisk testbehov; et bestået
simulatorbuild dokumenterer ikke fysisk Bluetooth-drift eller hørbare alarmer.
Ingen `.ipa`, `.xcarchive`, `.xcresult`, DerivedData, profiler, certifikater,
nøgler, tokens, logs eller sundhedsdata må pushes.

## Historisk Mac-baseline 23. september 2026

- Daværende projektmappe: den ældre søster-checkout `../xdripswift`
- Remote (fetch og push): `https://github.com/Don-Olsen/xdripswift.git`
- Aktiv branch: `fix/nightscout-safe-history-upsert`
- Commit: `d09bac575d9622d1368cbba0dc3039862d997ed3`
- Upstream-afvigelse ved start: `+0/-0`
- Klonen er shallow.
- Den oprindelige tracked/untracked-status var ren. Ingen branch blev skiftet, og der blev ikke kørt merge, rebase, reset, commit eller push.
- Tidligere analyse ligger uden for Git i `../ANALYSE-XDRIP-WATCH.md`.

Denne opsætning tilføjede dengang to untracked projektfiler, som nu er bevaret
i procescommitten på checkpoint-branchen:

- `docs/MAC-BUILD.md`
- `scripts/local-build.sh`

Følgende lokale filer er med vilje ignoreret af Git:

- `xDripConfigOverride.xcconfig`, som vælger det eksisterende team `GFZ896KN66` og lader arkivfasen bruge `Apple Development`
- `build/`, som indeholder logs, DerivedData og testresultater

På dette historiske tidspunkt var `codemagic.yaml`, projektfilen og appkoden
urørte. Den senere Watch-integration er dokumenteret i `PROJECT-STATUS.md`.

Det verificerede workspace er `xdrip.xcworkspace`. Xcode viser disse delte schemes:

- `xdrip`
- `xDrip Notification Context Extension`
- `xDrip Watch App`
- `xDrip Watch Complication Extension`
- `xDrip Widget Extension`

## Mac og Xcode

- macOS 27.0, build `26A428`
- Apple Silicon `arm64`
- Cirka 123 GiB ledig diskplads efter verificeringen; der var cirka 142 GiB før build-artefakterne blev oprettet
- Xcode 27.0, build `27A266a`, i `/Applications/Xcode.app`
- Valgt developer directory: `/Applications/Xcode.app/Contents/Developer`
- Swift 6.4 og Apple Clang 21.0.0
- Apple Git 2.54.0
- Python 3.9.6 i `/usr/bin/python3`
- iOS 27.0- og watchOS 27.0-SDK'er installeret
- iOS 27.0- og watchOS 27.0-simulator-runtimes installeret

Xcode-licensen er accepteret, og førstegangsopsætningen er gennemført. Der kræves ingen administratoradgangskode eller licenshandling nu.

Der blev ikke installeret software. Homebrew, CocoaPods og Fastlane er ikke installeret og er ikke nødvendige for den lokale `xcodebuild`-proces. Projektet har ingen submodules, Pods eller Swift Package-afhængigheder. `git submodule sync/update` blev kørt og var en no-op. `Gemfile.lock` låser kun det valgfrie Codemagic/Fastlane-releaseværktøj og blev ikke ændret.

Apples aktuelle uploadkrav siger, at iOS- og watchOS-builds skal være bygget med Xcode 26 eller nyere; siden 28. april 2026 kræves iOS/watchOS 26-SDK eller nyere. Xcode 27 med SDK 27 opfylder dette. Apple har også varslet SDK 27 som minimum fra april 2027. Se [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds), [Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/) og [Submitting](https://developer.apple.com/app-store/submitting/).

## Eksisterende appidentitet

Den eksisterende Codemagic-konfiguration er kilden til produktionsidentiteten:

| Target | Bundle ID |
| --- | --- |
| iPhone-app | `com.GFZ896KN66.xdripswift` |
| Widget | `com.GFZ896KN66.xdripswift.xDripWidget` |
| Watch-app | `com.GFZ896KN66.xdripswift.watchkitapp` |
| Watch complication | `com.GFZ896KN66.xdripswift.watchkitapp.xDripWatchComplication` |
| Notification extension | `com.GFZ896KN66.xdripswift.xDripNotificationContextExtension` |

- Apple Developer Team: `GFZ896KN66`
- App Store Connect-app: `6795645396`
- Marketingversion: `7.0.0`
- Checked-in fallback-buildnummer ved den historiske baseline: `4231`

Buildnummer `4231` må ikke bruges som gæt på næste TestFlight-build. Det næste nummer skal først læses i App Store Connect for app `6795645396`.

Hovedappen bruger HealthKit, NFC, Bluetooth-baggrundstilstand og disse App Groups efter team-substitution:

- `group.com.GFZ896KN66.loopkit.LoopGroup`
- `group.org.nightscout.GFZ896KN66.trio.trio-app-group`

Watch, complication, Widget og Notification-extension bruger LoopGroup. Der er ingen brugerdefineret `keychain-access-groups`-entitlement; CareLink bruger den standardgruppe, som signeringen indsprøjter. Samme team og bundle IDs skal derfor bevares.

## Verificerede tests og builds

Resultaterne ligger i `build/local-setup-20260923/` og fylder cirka 7,6 GiB inklusive DerivedData.

De vigtigste gemte artefakter er:

- `results/Verification-serial.xcresult` og `results/stability-summary.json`
- `logs/xctest-verification-serial.log`
- `logs/iphone-build.log` og `logs/watch-build.log`
- `results/AllTests-iphone17-incomplete.xcresult` og `logs/all-xctest-iphone17.log`

### Bestået

- `scripts/test-check-apple-processing.py`: 12/12
- `scripts/record-watch-test-results.py --self-test`: 12/12 syntetiske kontroller
- `scripts/verify-watch-release.py --self-test`: 17/17 syntetiske kontroller
- Codemagics otte krævede XCTest-suiter: 466 bestået, 0 fejlet, 0 skipped
- Projektets egen xcresult-parser bekræftede samtlige 466 deklarerede metoder
- iPhone simulator-build, scheme `xdrip`: bestået
- Watch simulator-build, scheme `xDrip Watch App`: bestået

Den byggede iPhone-app indeholder Widget, Notification-extension og Watch-app. Watch-appen indeholder complication-extensionen. Alle fem bundles havde teamets korrekte bundle IDs, version `7.0.0` og build `4231` i simulatorproduktet.

Xcode 27 brugte op til 600 sekunder på automatisk simulator-diagnostik efter den beståede XCTest-kørsel og meldte timeout på selve diagnoseindsamlingen. XCTest-kørslen sluttede stadig med `TEST SUCCEEDED`, og det færdige `.xcresult` bestod projektets parser.

### Fejlet og holdt uden for opsætningsændringer

Den komplette `xdripTests`-kørsel er ikke grøn. Xcodes afsluttende konsolresume viste 578 udførte tests og 2 fejl. Den rå log indeholder desuden en tidligere Core Data-fejl før en test-host-genstart samt seks CareLink-tests, der afsluttede processen med `URLComponents` fatal error. Det ufuldstændige resultatbundle og den komplette log er bevaret som henholdsvis `AllTests-iphone17-incomplete.xcresult` og `all-xctest-iphone17.log`.

De registrerede app/testfejl er:

- `BluetoothPeripheralDisplayStatusTests.testNewPeripheralPersistsFalseActivationSuccessByDefault`
- `DexcomG6SensorLabelTests.testDecodesAllObservedSensorLabels`
- `DexcomG6SensorLabelTests.testRoundTripsSensorStartMetadataThroughCoreData`
- `CareLinkTests.testAllPersonalGlucoseFamilies`
- `CareLinkTests.testBlockedTherapyImportCannotBlockGlucoseOrAnotherPoll`
- `CareLinkTests.testCarePartnerResolvesLinkedPatientsAndScopesPeriodicRequest`
- `CareLinkTests.testPeriodicCompatibilityEndpointFallback`
- `CareLinkTests.testPumpOnlyPeriodicPayloadRemainsUsableDuringSensorGap`
- `CareLinkTests.testSuccessfulEmptyRouteTakesPrecedenceOverLaterFallbackErrors`

De er dokumenteret som en separat app/testopgave. Ingen af dem er rettet eller deaktiveret i denne opsætning.

En indledende parallel XCTest-kørsel blev også afbrudt, fordi Xcode 27 ikke kunne starte flere klonede simulatorer og derefter hang. Den autoritative CI-kørsel bruger derfor `-parallel-testing-enabled NO` på én fuldt startet simulator. Den tidligere log og det ufuldstændige bundle er bevaret med `parallel-incomplete` i navnene.

## Lokal daglig proces

Kør fra repoets rod:

```sh
./scripts/local-build.sh all
```

Kommandoen kører de tre oprindelige Python-kontroller samt release-scriptets
syntetiske spærretests, de otte Codemagic XCTest-suiter serielt og iPhone-/
Watch-simulatorbuilds. Den uploader aldrig. Hver kørsel gemmes under
`build/local/<UTC-timestamp>/`.

Andre nyttige kommandoer:

```sh
./scripts/local-build.sh status
./scripts/local-build.sh python
./scripts/local-build.sh test-ci
./scripts/local-build.sh test-all
./scripts/local-build.sh build
./scripts/local-build.sh release-preflight
```

Sæt eventuelt en bestemt simulator uden at ændre scriptet:

```sh
XDRIP_SIMULATOR_ID=<simulator-udid> ./scripts/local-build.sh test-ci
```

## Cloud-managed signering

Den oprindelige Mac-gennemgang fandt én Xcode Apple ID-konto. Ved build 4263
oprettede automatic signing det nødvendige lokale development-certifikat og
profiler, mens eksporten brugte **Cloud Managed Apple Distribution**. Der
kræves fortsat ikke import af Codemagics private distributionsnøgle.

Alle fem Release-targets skal fortsat bruge team `GFZ896KN66`, Automatic
Signing, tomme manuelle profilvalg og de eksisterende bundle IDs. Arkiv og
eksport bruger `-allowProvisioningUpdates`; der bruges ikke
`-allowProvisioningDeviceRegistration`. Preflight og de signerede produkter
kontrolleres før upload. Brug aldrig `match_nuke`, `nuke_certs` eller andre
kommandoer, der tilbagekalder eksisterende assets. Ved capability- eller
App ID-konflikt stoppes processen til særskilt vurdering.
