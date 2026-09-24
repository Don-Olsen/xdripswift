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

Fortsæt i `../xdripswift-upstream-7.1.1`, branch `integration/upstream-7.1.1`.
Appkodecommit `f90b1dcb1d716aea41a0c68be7c6a47cc405ceee` har 983/983 beståede
XCTest-tests og beståede iPhone-/Watch-simulatorbuilds. De efterfølgende
procesændringer ændrer ikke appkoden. Checkpointet for 4263 og den ældre
arbejdskopi er bevaret. Se aktuel adgangs-/uploadstatus i PROJECT-STATUS.md.

Brugeren har givet **GO UPLOAD for 7.1.1**, inklusive automatisk valg af nummer,
tracked versionsændring, checkpoint/push/tag, signering, arkiv/IPA, upload og
Ole Internal. Der kræves ikke endnu et GO UPLOAD for samme udgivelse.
Marketingversionen er 7.1.1 på alle fem bundles. Fallback 4231 er ikke et
release-buildnummer og må ikke uploades.

## Permanent automatisk TestFlight-proces

Læs [AGENTS.md](../AGENTS.md) og [PROJECT-STATUS.md](PROJECT-STATUS.md).
Forløbet er **test → Apple-buildstatus → automatisk nummer → tracked version/build
→ test release-tree → commit/push → tag → arkiv/IPA fra tag → verify → autoriseret
upload → Apple-status/Ole Internal → statuscommit/push**.

Agenten gennemgår/stager den ønskede kode, tests og projekt-/procesfiler.
Den almindelige lokale buildproces uploader aldrig. Efter brugerens GO UPLOAD
for den konkrete version køres:

```sh
# Kun efter agentens gennemgang af den præcise staged diff og brugerens GO UPLOAD:
XDRIP_STAGED_DIFF_REVIEWED=YES \
XDRIP_GO_UPLOAD=YES XDRIP_GO_UPLOAD_VERSION=7.1.1 \
  python3 -B scripts/release-testflight.py release
```

Ingen buildnummer- eller Apple-statusvariabler udfyldes manuelt. `release`
genoptager det registrerede forløb og kører selv prepare, checkpoint, publish,
build, verify, upload, processing-kontrol og status. Ved en afsluttet release
og nye kildeændringer vælges et nyt nummer; uændret kode gen-uploades ikke.
En anden marketingversion kræver sin egen brugerautorisation og matchende
`XDRIP_GO_UPLOAD_VERSION`.

Deltrinene kan køres særskilt, f.eks. under en teknisk undersøgelse:

```sh
python3 -B scripts/release-testflight.py apple-status  # Read-only Apple-opslag
XDRIP_STAGED_DIFF_REVIEWED=YES python3 -B scripts/release-testflight.py prepare
XDRIP_STAGED_DIFF_REVIEWED=YES python3 -B scripts/release-testflight.py checkpoint
python3 -B scripts/release-testflight.py publish
python3 -B scripts/release-testflight.py build
python3 -B scripts/release-testflight.py verify
# Upload kræver stadig versionsspecifik GO UPLOAD, også som selvstændigt trin.
XDRIP_GO_UPLOAD=YES XDRIP_GO_UPLOAD_VERSION=7.1.1 \
  python3 -B scripts/release-testflight.py upload
python3 -B scripts/release-testflight.py status
```

`prepare` kontrollerer API-adgang, kører de indledende Python-kontroller og
henter alle sider af Apples builds og buildUploads samt eksplicit den aktuelle
versions builds/uploads. App-ID, bundle-ID og iOS-platform valideres. Nummeret
vælges numerisk over alle registrerede numre, også igangværende, fejlede og
andre marketingversioner. Dotted buildnumre sammenlignes numerisk; ukendte
formater eller ufuldstændige svar stopper uden at gætte. Et allerede brugt eller
lokalt reserveret tag/nummer genbruges ikke. `allocation.json` gemmer valgt
nummer og det sanitiserede API-snapshot under `build/testflight-<version>-<build>/`.
Aktivt forløb registreres i `build/release-automation/active.json`.

Kun `xDrip/Version.xcconfig` stages automatisk efter nummerændringen. Andre
ændringer skal allerede være gennemgået og staged. Personlige konfigurationer,
secrets og buildprodukter afvises fra indekset. `checkpoint` kører nu
`local-build.sh release-test`: alle Python-kontroller, **hele XCTest-suiten**,
resultatkontrol af de otte krævede Watch/Libre-suiter samt begge simulatorbuilds.
Den fulde suite omfatter også CareLink, Dexcom og statistikrettelserne.
Git tree-hash kontrolleres før/efter test og efter commit. Tidligere 983/983 er
baseline, ikke release-kvittering for en senere ændret versionsfil.

`publish` pusher checkpointet og et uforanderligt annoteret
`testflight-<version>-<build>`-tag; begge fjernrefs verificeres. `build` kræver
rent working tree, matching testkvittering og Apple-allokering. Kilden udtrækkes
fra tagget med `git archive`. Xcode genbruger team GFZ896KN66 og automatisk
signering; eksisterende signeringsaktiver bevares. Alle fem bundles kontrolleres,
inklusive entitlements, profiler, version/build og indbygget source commit.
`verify` pakker den faktiske IPA ud igen og verificerer den, inden IPA- og
arkivhashes gemmes.

Umiddelbart før upload læses Apple igen. Ved et optaget nummer **før eget
uploadforsøg** vælges automatisk et nyt nummer, versionsfilen ændres og
release-kontrollerne køres igen før nyt checkpoint/tag/arkiv. Det gamle tag
flyttes aldrig. Der tillades højst tre automatiske kollisionsrunder.
Upload bruger Apples `xcrun altool --upload-package` på den verificerede IPA;
der laves ikke en ny eksport med andre bytes i uploadtrinnet. Eksporten har
`testFlightInternalTestingOnly=true` og `manageAppVersionAndBuildNumber=false`.

En eksklusivt oprettet `upload-attempt.json` gemmer source commit, tag og
IPA-hash **før** upload. Ved uklar afslutning undersøges Apple, men et matchende
buildnummer alene bruges ikke som bevis for, at vores bytes blev modtaget.
Der startes ikke automatisk et nyt upload eller vælges et nyt nummer i denne
situation. Et dokumenteret modtaget upload fortsætter til processing-kontrol.

Der følges med i op til 15 minutter. `VALID` og `INTERNAL_ONLY` kontrolleres,
og kun den eksisterende interne gruppe **Ole Internal** tilknyttes. Den faktiske
buildrelation og `IN_BETA_TESTING` skal være bekræftet, før status bliver
**Internal / Testing**. Der oprettes ingen grupper/testere eller ekstern test.
Manglende compliance-erklæringer, aftaler og rettigheder gættes ikke.
En processing-timeout registreres som faktisk modtaget/behandles, ikke som
mislykket upload. `status` gemmer Apples observerede status i PROJECT-STATUS.md
og laver/pusher en separat dokumentationscommit uden at flytte release-tagget.

## App Store Connect API-adgang

Xcodes eksisterende Apple-login bruges fortsat til signering. Apples offentlige
REST API kræver en Apple-udstedt ES256 `.p8`-nøgle; der findes ikke en understøttet
konvertering fra et almindeligt Xcode-login til denne API-adgang.
`scripts/apple_release.py` bruger Python-standardbiblioteket og macOS' eksisterende
OpenSSL. Der installeres ikke Homebrew, Fastlane eller nye Python-pakker.
Ingen browsercookies, Xcode-login-tokens eller private Apple-API'er bruges.

Genbrug en eksisterende API-nøgle, hvis den findes. Ellers skal kontoejeren via
Apples normale App Store Connect-konto oprette/downloade en individuel API-nøgle
eller en teamnøgle med de nødvendige app-/TestFlight-rettigheder. En individuel
nøgle arver brugerens adgang og kan bruges til denne proces; Xcode håndterer
fortsat provisioning. Hvis generering ikke er tilladt, skal en administrator
give den relevante API-adgang. Private nøgledata må aldrig indsættes i chatten.

Konfigurationen ligger som standard uden for Git i
`~/.config/xdrip-release/app-store-connect.json` (eller stien i
`XDRIP_ASC_CONFIG`). Både konfigurationen og `.p8` skal ejes af den aktuelle
Mac-bruger og have adgang `600`. Eksempel med fiktive, offentlige ID'er:

```json
{
  "keyID": "ABCDEFGHIJ",
  "privateKeyPath": "/Users/<bruger>/.appstoreconnect/private_keys/AuthKey_ABCDEFGHIJ.p8"
}
```

Ved en teamnøgle tilføjes dens `issuerID`; ved en individuel nøgle udelades det.
Nøglen og konfigurationen må ikke ligge i nogen Git-worktree. JWT signeres og
beholdes i hukommelsen; hverken private nøgledata eller JWT skrives i logs/Git.
Kun `https://api.appstoreconnect.apple.com/v1/` tillades, inklusive pagination;
redirects videresender ikke authentication. Midlertidige GET-fejl genforsøges
begrænset, men mutationer gentages ikke blindt. Et usikkert gruppesvar kontrolleres
ved efterfølgende læsning af relationen.

Manglende API-adgang er en reel authentication-/rettighedsblokering. Agenten
skal afklare denne adgang og fortsætte de uafhængige lokale trin; den må ikke
omgå problemet ved at bede om et manuelt buildnummer. Den endelige upload må
ikke påstås udført, før Apple faktisk har kvitteret.

Officielle kilder:

- [API-nøgler](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
- [JWT-autentifikation](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)
- [Buildoversigt](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds)
- [Build uploads, inklusive processing og fejl](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-apps-_id_-builduploads)
- [Intern gruppetilknytning](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betagroups-_id_-relationships-builds)

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
