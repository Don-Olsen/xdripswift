<!-- testflight-7.1.1-4307:start -->
### TestFlight 7.1.1 (4307)

- Kildecommit og tag: `6564788ef90bbcc343aa6dedbe655dff61e2bf1a` / `testflight-7.1.1-4307`.
- Tests: 1431/1431 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-07T16:36:43.026080+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/a77c5e70-44d5-47d6-8a60-be7fbdaaf810).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4307:end -->

## Optimeringer efter 4307 — lokal validering

8. oktober 2026: arbejdet fortsætter fra `8152d265` med `6564788` / 4307 som
reference; de tre relevante kildefiler var uændrede mellem disse commits.
Klokken sammenligner sin formaterede tekst på hovedtråden og publicerer kun
ved ændring. Skjulte minigrafer starter ingen nye indlæsninger; genvisning
bruger den nye synlighedsværdi og eksisterende `forceReset` til at genlæse
hele den relevante historik. Beregnerens `start()` bruger samme annullerbare
task og generation uden inputforsinkelsen; øvrige kald beholder 400 ms.

Den fulde lokale XCTest-kørsel bestod med **1.439/1.439**, 0 fejl og 0 skipped.
Otte nye tests dækker klokke/minutskift og hovedtråd, skjult minigraf og friske
historiske rettelser/sletninger efter genvisning, samt åbning/genåbning,
hurtige input og afvisning af sene svar efter annullering. Alle Python-kontroller,
resultatkontrollen af de otte krævede suiter og begge simulatorbuilds bestod.
De eksisterende genvejs- og prognoseudløbstests er bevaret og bestod.
Glukosealderens separate 15-sekunders opdatering og prognosens tidskontrol er
kodegennemgået og uændrede; ingen ny fysisk timer-/UI-test er udført.

Dosisregler, lagring, HealthKit, alarmer, Watch/Libre og genvejsrettelsen fra
4307 er uændrede. Der er ingen måling af fysisk svartid eller batteriforbrug.
Ved den lokale validering var version/build, commits og tags uændrede;
intet var pushet eller uploadet. En release kræver ny validering efter nummerallokering.
Test- og buildartefakter ligger i de lokale `DeveloperBuildData`-kørselsmapper.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4306:start -->
### TestFlight 7.1.1 (4306)

- Kildecommit og tag: `d5f55dcda7b6be8a63fed293219362075d9b5d88` / `testflight-7.1.1-4306`.
- Tests: 1425/1425 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-07T16:00:14.772909+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/cdf6794c-54e6-4767-9f9b-6f2c742e6aab).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4306:end -->

## Efter 4306: reproduceret gammel skærmtilstand i bolusgenvejen

4306 løste ikke den fysiske forsinkelse. Den tilsluttede iPhones installerede
app blev kontrolleret som `com.GFZ896KN66.xdripswift`, 7.1.1 (4306). Den
7. oktober modtog scenen genvejen kl. 17.13.48,381. Root havde Home og sine
afhængigheder klar; Home loggede alligevel `ready=0`. Arket blev først
anmodet kl. 17.14.15,804 og vist kl. 17.14.15,871. Tiden fra tryk til ark
var dermed cirka 27,5 sekunder. De tidligere angivne korte tider mellem
ark-anmodning og `onAppear` var **ikke** genvejens samlede svartid.

Den konkrete fejl er reproduceret i den rigtige `RootHomeView`:
de gamle enkeltarguments-`onChange`-callbacks ignorerede den nye anmodning
eller genberegnede readiness fra den tidligere views værdier.
[Apple beskriver eksplicit denne capture-adfærd](https://developer.apple.com/documentation/swiftui/view/onchange(of:perform:)).
Det forklarer også, at den gamle log først skrev »reached Home« efter arkets
visning: forbruget af anmodningen kaldte en closure, der stadig så den gamle
UUID. Eksisterende helper-tests med manuelt angivet `isReady` fangede ikke
fejlen.

Rettelsen observerer ét samlet value-snapshot af anmodning, leveringsrevision,
readiness og arkets tilstand og bruger callbackens **nye** snapshot direkte.
Appens aktive tilstand publiceres fra de eksisterende UIKit-notifikationer,
så UIKit/SwiftUI-aktiveringernes rækkefølge ikke kræver en senere Home-refresh.
Der er ingen ny timer eller ventetid. Kilde-, modal-, scene-, natvisnings- og
grafkontroller er bevaret. Beregner, dosisregler, behandlinger, HealthKit,
prognose, Watch/Libre og alarmer er uændrede.

Fire nye hosted SwiftUI-tests bruger den rigtige Home-visning, quick-action-
handler og `PenDoseCalculatorScreen` i et simulatorvindue med in-memory-data.
Alle fire fejlede mod 4306 (14 assertions); efter rettelsen bestod hele suiten
med 1.429/1.429 tests. De dækker varm anmodning, sceneaktivering, frigivelse af
præsentationsblokering samt gentagne tryk og genbrug af et åbent ark, uden at
vente på grafens 15-sekunders timer. To supplerende hosted tests dækker en
anmodning før Home monteres samt lukning uden genåbning eller gemte
behandlinger, efterfulgt af en ny genvejsanmodning. Den endelige `test-all`
bestod med **1.431/1.431 tests, 0 fejl**. Begge simulatorbuilds (iPhone og
Watch) bestod også. Testsuitens tomme chart-fixtures gav SwiftUI-advarslen
`Invalid frame dimension`; det er ikke undersøgt som en fysisk layoutfejl
i denne afgrænsede rettelse. Ingen tests er fjernet eller svækket.

Kontrollen er en lokal kodeverifikation, ikke en releasekvittering.
Python-releasekontroller, nyt Apple-buildnummer, signering og IPA-kontrol
er ikke kørt for denne unummererede rettelse. Ved en ny udgivelse skal den
fulde releaseprocedure køre på det præcise release-checkpoint.

Ved den lokale kontrol var den rettede kode ikke uploadet eller fysisk verificeret. Ingen
lokal installation eller afbrydelse af CGM er udført. Telefonens konkrete
svartid skal måles igen fra ikontryk til synligt ark; simulatorresultatet er
ikke en garanti for en bestemt fysisk svartid. 4306's statuscommit er nu
også pushet efter en midlertidig GitHub-serverfejl; Apple-uploaden var allerede
bekræftet som Internal / Testing.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4305:start -->
### TestFlight 7.1.1 (4305)

- Kildecommit og tag: `295097f551ba8f187907a48cd98e29cfb364d273` / `testflight-7.1.1-4305`.
- Tests: 1423/1423 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-07T13:53:17.626770+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/253edae0-fe07-4683-bdfa-07e94f19bee8).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4305:end -->

## Kandidat efter 4305: forsinket bolusgenvej fra app-ikonet

Den fysisk installerede 4305 modtog og kølagde genvejen kl. 16.07.53 den
7. oktober, men Home bad først om beregnerarket kl. 16.08.22: 29,5 sekunder
efter trykket. Arket blev vist 0,05 sekunder efter Homes anmodning. Flere
tidligere tryk havde samme mønster: scene-callback og kølægning, men ingen
øjeblikkelig Home-håndtering. Loggen dokumenterer dermed forsinkelsen mellem
kølagt anmodning og Home, ikke en langsom dosisberegning. 4305-loggen viser
ikke, hvilken af Homes tavse ventetilstande der udløste det første tabte skift.

Kandidaten beholder én ventende anmodningsidentitet, men publicerer en ny
leveringshændelse ved hvert app-ikontryk og ved sceneaktivering. Root og Home
reagerer på hændelsen, også når den ventende identitet er uændret. Kun dataløse
markører for leverings- og præsentationstilstand er tilføjet.
Kildekontrol, Home-knap, beregner, dosisregler og behandlingslagring er uændrede.

Regressionstests dækker gentagne tryk og genaktivering. Eksisterende tests
dækker, at anmodningen først forbruges, når arket faktisk vises.
Lokal `release-test` den 7. oktober bestod med 1.425/1.425 XCTest-tests,
alle Python-kontroller og iPhone-/Watch-simulatorbuilds. Dette er kontrol af
den unummererede kandidat; releaseforløbet skal teste igen efter Apples
buildnummer er valgt.
Den fysiske svartid for denne kandidat er endnu ikke verificeret; der er ikke
lavet direkte installation på telefonen eller en ny TestFlight-udgivelse.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4304:start -->
### TestFlight 7.1.1 (4304)

- Kildecommit og tag: `55cf7b24b7d94d079a5ab64d2e4af1db138366f2` / `testflight-7.1.1-4304`.
- Tests: 1421/1421 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-07T10:44:59.573995+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/5ef91ad3-22d1-455d-8e60-0c094dcf2f9b).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4304:end -->

## Kandidat efter 4304: app-ikonets bolusgenvej

På den tilsluttede iPhone 17 Pro Max med den faktisk installerede 4304 viste en
skærmbilledserie genvejsmenuen kl. 14.37.11 og Home kl. 14.37.12. Beregnerarket
var stadig ikke vist kl. 14.37.58. Home-sidens blå + åbnede derefter samme
beregner straks. Den installerede app var responsiv; dette var ikke en målt
16-sekunders beregningstid. Den eksisterende app-journal viste forgrundsskiftet,
men 4304 loggede ikke genvejsforløbets enkelte trin. Den præcise afvisnings-
eller præsentationshændelse på telefonen er derfor endnu ikke dokumenteret.

Kodegennemgangen fandt en konkret tabt-anmodningsvej: Home kvitterede
genvejsanmodningen, når det bad SwiftUI om at vise arket, før arket faktisk
var fremme. En præsentation under scene- eller modalovergang kunne dermed
mislykkes uden mulighed for genforsøg. Home kunne også modtage anmodningen,
mens en anden fane var valgt. Kandidaten holder anmodningen indtil arkets
`onAppear`, begrænser præsentationen til den valgte Home-fane og venter på,
at både app og scene er aktive. En anmodning, som ikke gav et synligt ark
under forgrundsskiftet, kan forsøges igen, når aktiveringen er fuldført.
Dataløse logmarkører
skelner næste gang mellem scene-callback, kildeafvisning, ark-anmodning og
faktisk visning. Beregnerens dosis- og registreringsregler er uændrede.

De målrettede simulator-suiter bestod med 634/634 tests. Efter den sidste
kodegennemgang bestod den fulde lokale kontrol med 1.423/1.423 XCTest-tests,
projektets Python-kontroller og både iPhone- og Watch-simulatorbuilds. To
SwiftUI-runtimeadvarsler opstod i Nightscout-tests og fandtes også i den
tidligere målrettede kørsel; de er ikke knyttet til genvejsændringen.
Dette er endnu ikke en Apple-nummereret release-kvittering. Den fysiske effekt
af den nye rettelse er **ikke** verificeret. Ingen udviklingsapp blev
installeret direkte på telefonen under undersøgelsen. Release-status
registreres særskilt øverst i dette dokument.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4303:start -->
### TestFlight 7.1.1 (4303)

- Kildecommit og tag: `57a39313f14ddcbe555ff5d7b4e3cee947824954` / `testflight-7.1.1-4303`.
- Tests: 1418/1418 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-07T07:26:36.709363+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/a43124c8-4867-4bc3-adcc-ca62ebb966e8).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4303:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4302:start -->
### TestFlight 7.1.1 (4302)

- Kildecommit og tag: `f0a3bd34653dc5c5f0e7d1e21c8064cfecc9f31a` / `testflight-7.1.1-4302`.
- Tests: 1416/1416 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-06T04:30:18.082174+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/d3a85d5b-8c65-42a0-be7b-05e5f485e700).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4302:end -->

## Kandidat efter 4302: grafens sammenlagte genindlæsning

Grafkøen springer fortsat mellemliggende visningspositioner over ved hurtig
scrolling, men viderefører nu deres krav om cache-reset og opdatering af
eksisterende data til den nyeste forespørgsel. Ved lukning af grafen ryddes
disse krav sammen med cachen. Det ændrer kun grafens indlæsning; Libre,
Watch, alarmer og behandlingernes lagring er uændrede.

To regressionstests ændrer en behandling i databasen mellem cacheindlæsning
og to køsatte grafopdateringer. De bekræfter, at den sidste visning afspejler
ændringen ved både reset og refresh. Den målrettede graf-suite bestod med
22/22 tests på iPhone-simulator. Den fulde releasekontrol og fysisk
afprøvning på iPhone er endnu ikke gennemført for denne kandidat.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4301:start -->
### TestFlight 7.1.1 (4301)

- Kildecommit og tag: `25c8064aef452a3e724d87c4a881de5a7e34488f` / `testflight-7.1.1-4301`.
- Tests: 1416/1416 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-05T14:56:55.368036+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/fb7c0e80-6fa3-4231-806e-004fee2af915).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4301:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

## Kandidat efter 4301: Watch-bolus uden for sidekarrusellen

Watch-beregneren er fjernet fra `RootView`'s carousel. Main, AGP og Big Number
viser den samme lille + i urets øverste navigationslinje og åbner den eksisterende
`WatchManualTreatmentsView` som fuldskærmsvisning. X lukker uden at registrere
noget. Et gemt sidevalg fra 4301's tidligere treatments-side (værdi 4) falder
tilbage til Main. Direkte Libre-overtagelse kan fortsat vælge Big Number som
underliggende side; beregnerens fuldskærmsvisning og indtastninger bliver
stående. Beregning, sikkerhed, Watch-kø og telefonens behandlingssti er uændrede.

Projektets lokale Python-kontroller, iPhone- og Watch-simulatorbygning samt en
usigneret iPhoneOS/arm64-build bestod. På Watch-simulatoren blev plusikonet vist på
Main, AGP og Big Number, og en gemt sideværdi 4 blev ved
genstart ændret til Main (0). Skærmbillederne ligger uden for Git under
`/private/tmp/xdrip-watch-nav-20261006-screens/`. Denne Mac har ingen styrbar
Simulator-brugerflade, så et skærmbillede af den åbne beregner og direkte
afprøvning af Crown, lukning samt Libre-overtagelse under indtastning mangler.
Intet er installeret lokalt på brugerens iPhone eller ur. Det præcise
Apple-nummererede release-checkpoint får egne XCTest-, Python- og buildresultater.

<!-- testflight-7.1.1-4300:start -->
### TestFlight 7.1.1 (4300)

- Kildecommit og tag: `5f5a1164fbca2af9c3ec771b34cef8e4be1d4782` / `testflight-7.1.1-4300`.
- Tests: 1396/1396 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-05T12:10:33.644617+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/bf44c7bd-acde-4789-b3fe-067cefd7d547).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4300:end -->

## Kandidat efter 4300: Watch-bolus og basalpåmindelse

App-ikonets eksisterende genvej til bolusberegneren er gennemgået. Den bevarer
en tidlig anmodning til scenen og Home er klar, reagerer på den publicerede
klar-tilstand og bruger ikke Homes 15-sekunders timer. Den åbner samme ark som
Home-knappen og forbruger anmodningen én gang. Der er ikke ændret i genvejens
produktionskode; den fysiske svartid på en iPhone med denne kandidat er endnu
ikke målt.

På uret samler “Bolusberegner” kulhydrat, madtype, bolus, beregning og
bekræftet registrering på én skærm. Beregningen sker kun på telefonen gennem
den eksisterende penberegner og dens profil, behandlingssnapshot,
CGM-baserede COB, sikkerhedskontrol og afrunding. Uret afstemmer ventende
behandlinger og nyere Watch-CGM før et forslag, viser fejlårsagen ved
ufuldstændigt grundlag og lader aldrig et gammelt forslag ændre den indtastede
dosis. Uden telefon kan uret stadig lægge en bekræftet manuel registrering i
sin holdbare Watch-kø; en manglende penprofil tillader kun kulhydratregistrering.
Køen fryser identiteter, tidspunkt og madtype før første levering. Telefonen
bruger den eksisterende PenDoseTreatmentLogger og journal; en gentagelse må
ikke genskabe redigerede eller slettede poster. Gamle Watch-køposter, inklusive
basal, kan fortsat læses. Ny basal registreres på telefonen.

Pen-indstillingerne har en daglig, fra start deaktiveret basalpåmindelse med
lokalt klokkeslæt. Den læser varigt gemte, ikke-slettede basaldoser og springer
en dag over, når en dosis er registreret i de forudgående 12 timer. Den
planlægger 14 dage frem som enkeltstående lokale kalendernotifikationer,
genplanlægger ved relevante ændringer og forgrundsskift, og har én mulig
udsættelse på 30 minutter. Et tryk åbner den eksisterende basalregistrering
med seneste dosis og insulinnavn som kladde; det gemmer intet uden brugerens
Gem. De planlagte notifikationer kræver ikke, at appen kører ved levering,
men horisonten fornyes først, når appen igen åbnes. Planlægning er ikke bevis
for faktisk levering eller lyd/vibration på den fysiske telefon.

Lokal kandidatkontrol efter de målrettede rettelser: 1.416/1.416 XCTest-tests
bestod, herunder de eksisterende Watch-/Libre-suiter. Projektets Python-kontroller
bestod, og både iPhone- og Watch-simulatorbuilds samt en usigneret
iPhoneOS/arm64-build bestod. De præcise release-kontroller køres igen på det
Apple-nummererede checkpoint. Simulatorappen kunne starte på iPhone og Watch,
og deres første skærme blev gemt uden for Git. Denne Mac har ingen Simulator-GUI
eller UI-teststyring, så billeder af beregner, resultat, offline-tilstand,
basalsektion og leveret notifikation kunne ikke tages. Der er ikke installeret
en ny kandidat lokalt på brugerens telefon eller ur; GO UPLOAD omfatter kun den
interne TestFlight-gruppe. Dosisforslag, Watch-levering og basalpåmindelse er
derfor endnu ikke verificeret på de fysiske enheder.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

## Kandidat efter 4299: hurtigere bolusgenvej fra app-ikonet

En fysisk iPhone viste cirka 16,5 sekunders ventetid fra tryk på app-ikonets
“Bolusberegner” til arket blev vist. Når genvejen kom før Home var klar, blev
anmodningen bevaret, men den kunne ende med først at blive forsøgt igen ved
Homes 15-sekunders opdateringstimer. Home reagerer nu på sin publicerede
klar-tilstand og forgrundsskift og præsenterer samme beregner, straks det er
muligt. Den ventende anmodning forbruges kun én gang; gentagne tryk og et
allerede åbent ark opretter ikke flere ark. Ingen dosis- eller logningsregler
er ændret.

Lokal målrettet validering før release: 630/630 XCTest-tests bestod, inklusive
regressionstest for varm/kold start, ændret klar-tilstand, gentagne tryk og
allerede åbent ark. Xcodes ekstra simulatordiagnostik timeoutede efter testene,
mens selve kørslen sluttede med `TEST SUCCEEDED` og resultatkontrollen bestod.
Det er endnu ikke målt på fysisk iPhone, hvor hurtigt den nye kode åbner arket.
Den præcise release-test og Apple-status registreres særskilt af releaseforløbet.

<!-- testflight-7.1.1-4299:start -->
### TestFlight 7.1.1 (4299)

- Kildecommit og tag: `ba81d7ca63d73d643fef8ad10abe9c7ab4e20c65` / `testflight-7.1.1-4299`.
- Tests: 1391/1391 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-05T10:39:14.516754+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/adaaadfe-5cfa-43f6-b444-b29adf7214bb).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4299:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4298:start -->
### TestFlight 7.1.1 (4298)

- Kildecommit og tag: `a7ce718f36d537d6234ff76d7009b334198c10d3` / `testflight-7.1.1-4298`.
- Tests: 1379/1379 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-05T05:38:24.320687+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/d9d0ba64-d8ca-4e1f-b9e0-55ab2498c25d).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4298:end -->

## Kandidat efter 4298: Sundhed-eksport, sletning og bolusgenvej

Den almindelige blodsukkereksport havde to dokumenterede begrænsninger:
`HealthKitManager` kunne blive stående med en tidligere falsk
`healthKitInitialized`, og efterslæbet blev hentet fra de **nyeste** 2016
målinger. Den nye sti genlæser skriveadgang, gennemgår gyldige målinger fra
den ældste ubehandlede i begrænsede batches og flytter først checkpointet
efter HealthKits bekræftede skrivning. Den eksisterende kadence, suppression,
`finalValue`, sync-id og køen for historiske rettelser er bevaret. En fælles
iPhone-forespørgsel beder om læse- og skriveadgang til blodsukker, insulin og
kulhydrater; faktisk skriveadgang kontrolleres særskilt pr. type. Den ændrer
ikke Watch-workout-tilladelsen eller den valgte behandlingskilde.

Sundhed-siden viser nu dialogforventning adskilt fra faktisk skriveadgang,
senest bekræftet skrivning, hele kendte efterslæb, ventende sletninger og
tekniske fejl uden helbredsværdier. En verificeret lokal sletning efterlader
en holdbar tombstone, indtil en eksakt app-ejet Sundhed-kopi med samme type og
sync-id er fjernet. Også tidligere dokumenterede sletninger før kildeskiftet
gennemgås; en ufuldstændig behandlingsliste bruges ikke som sletningsbevis.
App-ikonets første genvej kan åbne den eksisterende Home-bolusberegner, når
den samme lokale kildebetingelse som Home-knappen er opfyldt. En koldstart
bevarer åbningsanmodningen, indtil Home er klar; genvejen logger intet selv.

`HealthKitManager` er uændret mellem 4292 og 4298. Tidsmæssig sammenhæng med
4293 beviser derfor ikke, at 4293 fratog Sundhed-adgang. Den faktiske udløser
på brugerens telefon, HealthKit-dialogen, den installerede bundleidentitet og
Sundheds kilde skal kontrolleres fysisk. Hverken simulator eller en grøn
HealthKit-mocktest beviser en virkelig skrivning, sletning eller levering af
ikon-genvejen på telefonen. Den ældre tekst om efterladte Sundhed-kopier
beskriver den tidligere adfærd; denne kandidat gør fjernelsen automatisk,
men fysisk endnu uverificeret. Endelig test- og udgivelsesstatus tilføjes
først fra det præcise release-checkpoint.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4297:start -->
### TestFlight 7.1.1 (4297)

- Kildecommit og tag: `eee1bb5148053189cddc979b32165007560f323b` / `testflight-7.1.1-4297`.
- Tests: 1348/1348 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-04T19:40:21.978758+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/fa3c9881-9c66-4499-bdf7-1548a772ba00).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4297:end -->

## Combined candidate after 4297: ML history, model transition and pen calculator

The installed 4297 app was checked read-only on the paired iPhone. Its saved
treatment cutover is valid, records mySugr for both former sources, and disables
ongoing Health import as intended. The training path nevertheless requested
Health read access only for glucose; it omitted insulin delivery and dietary
carbohydrates. The candidate requests all three read-only when training starts,
independent of ongoing import. It traces raw HealthKit therapy rows before any
app filter, source IDs and exact match, cutover/validation/dedup exclusions,
and query failures separately from empty responses. The loader keeps selected
Health treatments before the saved cutoff and confirmed local treatments from
it, with separate source evidence across the cutoff. A test database and mocked
real query adapter exercise that path. The actual cause of zero therapy rows on
this iPhone is not yet proven; the next physical training attempt must show the
new raw counts and source match, and 60 usable days are not promised.

A prior self-checked six-model package may stay active across a clean local
logging transition only when its real files, full non-source context and former
source IDs pass the same compatibility decision used by inference and Settings.
Its original metadata remain intact. The transition model is checked
prospectively on paired +60-minute results over seven usable days after the
cutoff and disabled durably for that model/cutoff if worse than the engine.
Insufficient paired evidence remains pending; it is not a successful check.
Normal retraining and self-check thresholds are unchanged.

After a valid cutover, Apple Health settings hide the retired import switches,
pickers, status rows and English footer, while retaining Health write settings
and showing the stored date and prior source(s) in Danish. Home adds a 44-point
accessibility target opening the existing pen calculator only when local source
ownership is valid. The calculator alone can use a conservative CGM-estimated
COB bounded above by curve COB; it falls back to the original curve input when
historical glucose, treatments or profile information is insufficient. Home
COB, the forecast/ML inputs, alarms, Libre/Watch and Nightscout are unchanged.
This is a model-based estimate, not a measurement of actual carbohydrate
absorption or evidence of clinical dosing accuracy.

Local candidate validation: 1,379/1,379 XCTest tests passed after two
asynchronous HealthKit **test-fixture** races were stabilized; all project
Python controls and both iPhone/Watch simulator builds passed. An unsigned
iPhoneOS build produced an arm64 executable and compiled the Create ML path.
One current-build Home screenshot with a synthetic local-source cutoff shows
the blue calculator shortcut; the synthetic preference was removed afterward.
The other requested simulator screenshots could not be reached on this Mac:
this Xcode installation has no Simulator GUI or UI-test target, and the empty
simulator cannot produce a completed ML or pen calculation. No screenshots or
health data were added to Git. The release checkpoint must re-run validation
on the exact Apple-numbered source tree; its results and Apple status belong in
the block created by the release procedure. Simulator tests cannot prove that
historical HealthKit rows are readable on this iPhone, that an actual model
remains clinically suitable, or that a calculated bolus is safe. A fresh
on-device history run and observation of the calculator are still required
after the candidate becomes available.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4296:start -->
### TestFlight 7.1.1 (4296)

- Kildecommit og tag: `323c50d74832e6159d8f896ea790498d6fe2b2b7` / `testflight-7.1.1-4296`.
- Tests: 1346/1346 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-04T17:32:17.418781+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/c164fc2d-75c4-4c2e-850e-ee998edd7d8e).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4296:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4295:start -->
### TestFlight 7.1.1 (4295)

- Kildecommit og tag: `419ed1ba89259dd8edc725667582d2b6145a76d0` / `testflight-7.1.1-4295`.
- Tests: 1327/1327 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-04T14:17:58.015428+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/f413893b-3052-4645-88b8-7e97ea402728).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4295:end -->

## Build 4296 — penberegner og måltidsplaner

Beregnerens skærm samler kulhydrat, madtype, spisetid og en eksplicit kopierbar
insulinanbefaling. Regnestykket vises fra ét fast beregningssnapshot i ⓘ.
Log registrerer de faktisk indtastede mængder uafhængigt af nye CGM-målinger
og ændret IOB/COB; insulin uden et aktuelt kontrolleret forslag kræver særskilt
bekræftelse. Den eksisterende journal og idempotens beskytter mod dobbelt
registrering, og lagringen kontrollerer pen-trin og maksimum igen. Den
eksisterende dosisformel og dens sikkerhedsgrænser er uændrede, bortset fra
de udtrykkeligt ønskede planlagte nye kulhydrater, 🍕-deling på planer og
eksplicit valg af konkret CGM-værdi uden trend.

Planlagte måltider har nu stabile lokale koblinger og engangsnotifikationer
for spisetid, eventuel opfølgning og senere 🍕-revurdering. Bekræftelse kræver
faktisk spisetid; annullering bevarer en allerede registreret bolus. En
fejlet påmindelse ændrer ikke en verificeret behandlingsregistrering.
Automatiske beregninger ændrer aldrig de indtastede mængder. Manuel
glukose eller eksplicit valgt CGM uden trend ændrer ikke sensorhistorik,
prognosemotor, alarmer eller ML.

Det præcise 4296-checkpoint bestod 1.346/1.346 XCTest-tests, 157 Python-tests,
54 syntetiske Watch-kontroller og begge simulatorbuilds. Et separat usigneret
iPhoneOS-build bestod og frembragte et arm64-program. Den signerede IPA og alle
fem bundles blev verificeret før upload. Simulatorbilleder af tom beregner,
🍕-måltid, planlagt måltid, manuel værdi uden trend og åbent tastatur ligger
uden for Git. Simulatoren havde ikke komplette CGM- og behandlingsdata, så en
gyldig sikkerhedsadvarsel, tilstanden med manglende trend fra CGM og det aktive
ⓘ-ark kunne ikke fotograferes der. Koden er ikke verificeret på en fysisk
iPhone eller et ur; faktisk notifikationslevering og brug i hverdagen kan ikke
udledes af simulatortests. Ingen klinisk præcision eller sikker dosis er
dokumenteret.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4294:start -->
### TestFlight 7.1.1 (4294)

- Kildecommit og tag: `7d2ea25deae51c8d64b61393ca8121e36f67ff62` / `testflight-7.1.1-4294`.
- Tests: 1255/1255 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-04T06:44:07.996612+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/275ac1b4-b07d-449a-a0df-638dae6632d3).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4294:end -->

## Trin A efter 4294 — fair prognosemåling (lokalt, ikke udgivet)

Selvtjekket måler nu motor, ML og uændret glukose på præcis samme C-ankre
for hver af +30/+60/+120 minutter. Det viser antal, referenceperiode,
MAE, signeret fejl (prognose minus faktisk) og ML's forskel mod uændret
glukose. Den eksisterende regel for, om en ML-model må aktiveres, er
uændret. En afsluttet selvtjekkørsel kan deles som lokal CSV med én række
pr. anker, også når modellen afvises. Rækkerne indeholder kilde- og
indstillingskontekst, motor-/ML-/faktiske værdier, IOB/COB og summer af
behandlingerne i motorens vindue. Filen sendes kun ved brugerens egen
handling og gemmes ikke i Git.

Replay og live bruger samme event-time-filter før motoren. Syntetiske
tests dækker desuden kildevalg og dubletter med fælles oprindelses-id.
Den historiske loader vælger bevidst direkte Sundhed-behandlinger fra de
valgte kilder, mens live-målingen bruger importerede Core Data-poster med
lokal/ekstern oprindelsesprioritet. Paritet i den syntetiske motortest
beviser derfor ikke kildeparitet på brugerens faktiske telefon. Historiske
Sundhedsværdier og den aktuelle Core Data-visning kan også være forskellige,
og historisk tidspunkt for import af behandlinger er ofte ukendt.
Den oplyste forskel mellem brugerens eksterne replay og
selvtjekkets MAE er derfor **ikke forklaret** uden de enkelte replayrækker.
Der er ikke ændret dosering, alarmer, Bluetooth eller glukoselagring.

Første lokale A-validering: `scripts/local-build.sh test-all` bestod
**1.259/1.259 XCTest-tests**, nul fejl, med resultater i
`~/DeveloperBuildData/xDrip/local-runs/xdripswift/20261004T110830Z-1974/`.
Efter denne test bestod `scripts/local-build.sh release-test` med
**1.259/1.259 XCTest-tests**, projektets Python-kontroller og begge
simulatorbuilds i
`~/DeveloperBuildData/xDrip/local-runs/xdripswift/20261004T111118Z-2389/`.
En efterfølgende fail-safe-rettelse beskytter CSV ved fejlet filskrivning.
Den endelige A-kode bestod derefter **1.260/1.260 XCTest-tests**, Python-
kontroller og begge simulatorbuilds i
`~/DeveloperBuildData/xDrip/local-runs/xdripswift/20261004T112226Z-5773/`.
Fysisk iPhone/Watch er ikke kontrolleret for denne kandidat. Intet blev
uploadet i trin A.

## Trin B efter 4294 — lokal behandling som primær kilde (lokalt, ikke udgivet)

Den eksisterende Treatment-fane kan gemme bekræftede lokale insulin- og
kulhydratposter med madtype, varighed og kendt oprettelses-/ændringstid.
Planlagte måltider forbliver ubekræftede, indtil brugeren markerer dem spist;
de indgår ikke i faktisk COB, ML eller advarsler. Det eksplicitte kildeskift
afslutter først den valgte Sundhed-import, bevarer ældre mySugr-poster efter
deres hændelsestid og bruger lokal logning fra skiftet. Lokale poster skrives
til Sundhed via stabilt sync-id/version uden at miste posten ved skrivefejl.
Sundhed-kopien af en senere slettet post fjernes ikke automatisk; se
`docs/HEALTHKIT-THERAPY-IMPORT.md`.

Trin B bestod **1.287/1.287 XCTest-tests**, Python-kontroller og iPhone-/
Watch-simulatorbuilds i
`~/DeveloperBuildData/xDrip/local-runs/xdripswift/20261004T122918Z-21209/`.
Denne kvittering gælder B før tilføjelsen af doserings- og alarmkoden i C.
Ingen fysisk enhed eller klinisk effekt er verificeret. Intet blev uploadet
i trin B.

## Trin C efter 4294 — bolusforslag og “Lavt om lidt” (release-kandidat)

Den lokale penberegner viser formelens led særskilt og kræver, at brugeren
bekræfter sin forudfyldte doseringsprofil. Den læser et nyt, sammenhængende
glukose- og behandlingssnapshot ved beregning og igen før registrering. Ukendt
eller ufuldstændigt IOB/COB-grundlag giver “Kan ikke beregne”. Den separate
motorprognose kan blokere et insulin-forslag ved beregnet glukose under
3,0 mmol/L; når prognosen ikke kan beregnes, vises en tydelig advarsel om det.
Appen giver kun forslag og registrerer brugerens faktisk tagne insulin.
En ubekræftet måltidsplan tæller ikke som spist. Den nye, valgfri
“Lavt om lidt”-advarsel beregnes ved nye iPhone-målinger, uafhængigt af
Home-visningen; dens journal skelner mellem anmodet notifikation og ukendt
faktisk levering. De eksisterende Libre-/Bluetooth- og Watch-forløb er ikke
ændret i denne kandidat.

Lagring af lokale insulin-/kulhydratposter er beskyttet af en holdbar
operationsmarkør. Hvis en gemning, redigering eller sletning ikke kan
bekræftes i det permanente lager, blokeres ny doseringsregistrering, indtil
brugeren efter genstart har kontrolleret historikken. En senere Core Data-
gemning må dermed ikke lydløst gøre en tidligere fejlet ændring gældende.
Sundhed-kopier slettes ikke automatisk ved lokal sletning; se
`docs/HEALTHKIT-THERAPY-IMPORT.md`.

Den endelige lokale C-kode bestod **1.327/1.327 XCTest-tests**, projektets
Python-kontroller og både iPhone- og Watch-simulatorbuilds i
`~/DeveloperBuildData/xDrip/local-runs/xdripswift/20261004T134340Z-33896/`.
En særskilt usigneret iPhoneOS-build bestod og producerede en arm64-app;
Create ML-træningsstien, bolusberegneren og alarmkoden blev kompileret.
Den oprindelige hardwarekommando tvang iPhone-SDK på Watch-undermålet og
fejlede; gentagelsen med korrekt platformvalg bestod. Ingen fysisk iPhone
eller Watch er testet for denne kandidat. Den oplyste forskel mellem
eksternt replay og appens selvtjek er fortsat uafklaret uden replayrækker;
hverken prognosepræcision, dosisforslagenes kliniske egnethed eller faktisk
modtagelse af advarsler er verificeret på brugerens enheder.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4293:start -->
### TestFlight 7.1.1 (4293)

- Kildecommit og tag: `7d9e07351379fb42e86761d286e72fd3612831cb` / `testflight-7.1.1-4293`.
- Tests: 1246/1246 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-04T05:25:56.832657+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/1d692d7e-8edc-4fdc-9d49-0c06f8624b0e).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4293:end -->

## Build 4294 — træningsperioder og årsagsdiagnostik

På brugerens iPhone viste 4293 **330 brugbare dage** og **31.699 eksempler
ved hver af +30/+60/+120 minutter**, men afviste træningen med den generiske
`forecast.mlNotEnoughHistory`-tekst. Den konkrete gate kan ikke fastslås fra
denne tekst alene. De faste kalenderperioder i 4293 kunne efter den oplyste
Sundhed-eksport efterlade kalibreringen med for få brugbare dage; det er en
hypotese, indtil den nye status er set på iPhone.

Rettelsen i 4294 vælger C som de seneste 14 **brugbare** dage med komplette
ankre for alle tre horisonter, B som de foregående 14 brugbare dage og A som
ældre ankre. Kronologien og målbufferen på horisont plus to minutter bevares
ved periode- og walk-forward-grænser. Det seneste C-anker skal være højst
48 timer gammelt, og B+C må spænde højst 60 kalenderdage. Kravene på
60 brugbare dage samlet, A: 30 dage/300 rækker pr. horisont, B og C:
ti dage/100 rækker pr. horisont, samt walk-forward- og kalibreringsminimum
er ikke sænket. En afvisning skal nu vise fase, horisont, eventuelt fold,
datointerval og faktiske/krævede tal i stedet for én fælles fejltekst.

Alle gyldige xDrip-Sundhedsværdier på præcis samme tidspunkt sammenlignes
på tværs af de fastlåste kilder. Er spændet over 3,6 mg/dL, kasseres
tidspunktet for alle; ellers samles kopier til medianen **inden for hver
kilde**, hvorefter det eksisterende kildevalg og segmentbrud gælder.
Indstillinger skelner brugbare dage fra Sundhed og apphistorik og
viser antal sammenlagte og konfliktkasserede tidspunkter. De rensede
Sundhedsværdier sammenlignes med overlappende Core Data-`finalValue`;
antal samt median og 95-percentil af absolut forskel er diagnostik, ikke
ændringer af målinger. Årsagen til eventuelle forskelle kan ikke fastslås
uden de faktiske data. Den ændrede datadannelse har fået ny kompatibilitetsversion,
så ældre modeller og checkpoints ikke bruges. Modellerne, som består
kalibrering og selvtjek, aktiveres uden efterfølgende gen-træning.

**Lokal validering bestod 4. oktober 2026.** Hele XCTest-suiten: 1.255/1.255
bestået; projektets Python-kontroller: bestået; iPhone- og Watch-simulatorbuilds:
bestået. En særskilt usigneret iPhoneOS-build bestod og producerede en arm64-app;
Create ML-træningsfilerne blev kompileret i den. Første fulde gennemløb havde
én fejl i en ny testopstilling; den blev rettet, og hele suiten bestod ved
ny kørsel. Der er endnu ingen dokumenteret træningskørsel på den fysiske
iPhone og ingen påvist forbedring af prognosepræcision. Release-processen
gentog 1.255/1.255 tests og begge simulatorbuilds på det præcise 4294-checkpoint;
Apple har bekræftet buildet som Internal / Testing i Ole Internal.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4292:start -->
### TestFlight 7.1.1 (4292)

- Kildecommit og tag: `aa3a9ffaa2c13bfb6eb365585980bcf04673497e` / `testflight-7.1.1-4292`.
- Tests: 1230/1230 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-03T23:33:35.954262+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/f74c6b02-7c8d-4055-aba9-adb95cd6a93e).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4292:end -->

## Rettelser i 4293 — 4. oktober 2026

Home bevarer nu et tidligere komplet, valideret behandlingssnapshot under en
rutinemæssig Sundhed-genlæsning af de samme, friske kilder i højst 30 sekunder.
IOB/COB fortsætter med at ældes normalt. Delvise importsider offentliggøres
ikke som et nyt komplet datasæt; insulin og kulhydrat skal begge være afsluttet
og gemt, før de nye behandlingsværdier og kurver kan skifte samlet. Uændrede
behandlinger udløser ikke et kunstigt tomt mellemtrin. Første import,
kildeskift, fejl, tvetydighed, for gammel synkronisering, mislykket gemning og
udløbet fastholdelse bruger fortsat utilgængelig-tilstand. Den tidligere
to-sekunders undtagelse for prognosevisning er fjernet. En prognose tegnes
kun, når dens inputgeneration og reference passer til den aktuelle grafhale;
nye glukosemålinger og alarmer venter ikke på Sundhed-importen.

Personlig ML-træning kan læse op til 365 dages xDrip-glukose direkte fra
Sundhed og bolus/kulhydrater fra de allerede valgte importkilder, udelukkende
i hukommelsen. Første træning kan bede om **læseadgang til blodsukker**;
HealthKit oplyser ikke, om denne læseadgang blev givet. Tomme svar behandles
som ukendt dækning og kan kun erstattes af appens egen historik, hvor hele
behandlingsvinduet er dokumenteret. Glukose opdeles i deterministiske
replaysegmenter ved kildeskift og huller. Basal og uklassificeret insulin
bliver ikke bolusinput. Gamle modelpakker og træningscheckpoints er gjort
inkompatible med den rettede datadannelse. Indstillinger viser dansk fase,
reelt afsluttede træningstrin, brugbare dage/eksempler og selvtjekresultat.
Motorens beregning, Bluetooth, Watch, alarmer, Nightscout og gemte
glukose-/behandlingsdata er uændrede.

Lokal validering på den endelige produktkode: **1.246/1.246 XCTest-tests
bestået**, nul fejl, i `~/DeveloperBuildData/xDrip/local-runs/xdripswift/20261004T045600Z-56919/`.
Projektets Python-kontroller bestod i
`~/DeveloperBuildData/xDrip/local-runs/xdripswift/20261004T045639Z-57032/`.
Både iPhone- og Watch-simulatorbuilds bestod efter sidste produktrettelse i
`~/DeveloperBuildData/xDrip/local-runs/xdripswift/20261004T045731Z-59297/`.
De to forudgående fejlede XCTest-kørsler er bevaret: først en fejl i et nyt
testkalds argumentrækkefølge, derefter en reel kanttilstand for et forældet
Sundhed-synkroniseringstidspunkt, som nu er rettet. Den uafhængige
kodegennemgang fandt ingen resterende blokerende kildefejl.

Den parrede iPhone kunne ikke læses via CoreDevice på netværket under denne
kontrol, så hverken den visuelle effekt, den første Sundhed-tilladelsesdialog,
træning eller prognosens faktiske præcision er verificeret fysisk. De beståede
softwaretests dokumenterer ikke en personlig præcisionsforbedring. Den præcise
taggede 4293-kilde bestod igen 1.246/1.246 XCTest-tests, Python-kontroller og
begge simulatorbuilds i releaseprocessen. Den verificerede IPA blev uploadet,
og Apple bekræftede Internal / Testing for den eksisterende Ole Internal-gruppe.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

## Lokal personlig ML-prognose efter 4291 — før udgivelse

Den eksisterende prognosemotor forbliver uændret og er altid fallback.
Den lokale kandidat træner på iPhone seks Create ML-modeller: korrektion og
forventet fejl ved +30, +60 og +120 minutter. Retrospektiv genberegning bruger
samme motor og featurefunktion som visningen, ti minutters afstand mellem
træningsankre samt kronologisk adskilt træning, kalibrering og selvtjek.
De sidste 28 kalenderdage frem til seneste brugbare dag deles i 14 dage til
kalibrering og 14 dage til selvtjek; de behøver ikke alle være brugbare.
Der kræves samlet mindst 60 kalenderdage med brugbare eksempler på alle tre
horisonter. For hver horisont kræver træningsperioden mindst 30 brugbare dage
og 300 eksempler; kalibrering og selvtjek kræver hver mindst 10 brugbare dage
og 100 eksempler.
En kandidat må kun aktiveres, hvis den samlede viste kurve forbedrer MAE mod
motoren ved alle tre horisonter og ikke forværrer en gyldigt sammenlignelig
aktiv model. Den aktiveres først efter fuld modelpakke er genindlæst og
kontrolleret. Træning afbrydes, når appen forlades. Modellen bindes til
behandlingskilde og indstillinger; ugyldige eller ukomplette prognoser
falder tilbage til motoren.
Midlertidige Create ML-checkpoints beskyttes og udelades fra backup, og
afbrudte sessioner fjernes ved næste start. Kun den aktive model og én
verificeret tidligere model beholdes; ukendte mapper bevares.

Historiske behandlingers import-/registreringstid og tidligere indstillinger
kan ikke altid bevises. Selvtjekket markeres derfor retrospektivt og kan ikke
dokumentere fremtidig personlig præcision. Usikkerhedsbåndets 80 %-mål gælder
kun de kalibrerede +30/+60/+120-punkter, ikke hele kurven. Der er ikke indført
nye HealthKit-tilladelser eller ændret Bluetooth, Watch, alarmer, målinger,
Nightscout eller kildeprioritet. Ingen trænede modeller eller helbredsdata
skal i Git.

Validering på den endelige lokale kilde 3. oktober 2026:
`scripts/local-build.sh release-test` bestod med **1.227/1.227 XCTest-tests**,
nul fejl og nul skipped, alle Python-kontroller samt iPhone- og Watch-
simulatorbuilds. En separat usigneret iPhoneOS-arm64-build kompilerede
Create ML-stien og bestod. Testkvittering og xcresult findes i
`~/DeveloperBuildData/xDrip/local-runs/xdripswift/20261003T214314Z-23236/`.
Den sidste iPhoneOS-kontrol er logget i
`/tmp/xdrip-ml-final-device-build.log`. `git diff --check` og
Xcode-projektets plist-kontrol bestod. Der er ikke trænet en model på
brugerens faktiske iPhone eller målt dens fremtidige præcision; denne
softwarevalidering dokumenterer hverken forbedret patientpræcision eller
bånddækning i drift. Ingen version er ændret, og intet er uploadet eller
installeret på tidspunktet for denne kontrol. Brugeren godkendte intern TestFlight-upload 4. oktober 2026; release-validering skal fortsat bestås.

---

<!-- testflight-7.1.1-4291:start -->
### TestFlight 7.1.1 (4291)

- Kildecommit og tag: `f8e8023a26c2d047e963d486703806c7eb73e633` / `testflight-7.1.1-4291`.
- Tests: 1210/1210 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-03T19:54:54.639567+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/48d122a0-ffa3-417a-86d6-3813d15c4162).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4291:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

## Lokal rettelse efter 4290 — prognose og kurver ved genåbning

3. oktober 2026: den installerede iPhone-version blev kontrolleret trådløst og
bekræftet som 7.1.1 (4290). Den bevarede prognoselog viste et utilgængeligt
resultat og et gyldigt resultat på samme målereference 504 ms senere.
App-startposter placerer dette ved opstart; det er ikke en optagelse af alle
visningsframes ved almindeligt skift mellem apps. Rådata opbevares privat,
uden for Git.

Kodegennemgangen fandt to mekanismer: en genindlæsning fra Sundhed kunne
ugyldiggøre prognosens visning uden ændrede behandlinger, og midlertidigt
manglende kurver kunne ændre fælles akse-/IOB-/COB-skalering. Den lokale rettelse:

- Skelner mellem en genindlæsningsanmodning og faktiske ændringer af input.
  Kun en identificeret genindlæsning af tidligere komplette Sundhedsdata kan
  bevare en allerede beregnet, dateret prognose i højst to sekunder, mærket
  »Opdaterer…« uden numeriske +30/+60/+120-oversigter. Gentagne anmodninger
  forlænger ikke fristen, og tilstanden logges ikke som en gyldig beregning.
- Afviser fortsat gamle resultater ved ændrede behandlinger, indstillinger,
  kilde, sensor eller referenceværdi, fejlede/ukendte input og ventende gemning.
  Et importbarns gemning er også beskyttet frem til den endelige databasecommit.
  En ældre databasecommit kan ikke kvittere for nyere, stadig ventende ændringer.
- Bevarer kun aksegrænser og fælles kurveskalering under genindlæsning af
  livegrafen. Usikre behandlingspunkter bliver ikke beholdt som aktuelle data.
  Skift af visning, periode, indstillinger eller eksplicit nulstilling samt
  udløb af referencepunktet fra det synlige interval nulstiller geometrien.

Validering på den lokale ændring oven på `cc5e9f4f`:

- `scripts/local-build.sh release-test`: exit 0.
- **1.210/1.210 XCTest-tests bestået**, nul fejl og nul skipped, herunder 18 nye
  regressionstests for genindlæsning, inputidentitet, importgemning og geometri.
- Alle Python-kontroller bestod; iPhone- og Watch-simulatorbuilds bestod.
- Hashkontrol af 196 beskyttede kilde-/testfiler bestod uden ændringer.
  Prognosemotorens matematik, alarmer, Bluetooth, sensorejerskab og
  workout-runtime er uændrede. Importvalg og importadfærd er uændrede;
  den nye importmetadata bruges kun til prognosens præsentationskontrol.
- Uafhængig slutgennemgang fandt ingen resterende blokerende fejl.
  `git diff --check` bestod. Testmateriale og manifest for den lokale ændrede
  kode ligger i
  `~/DeveloperBuildData/xDrip/local-runs/xdripswift/20261003T193818Z-90863/`,
  inklusive `results/AllTests.xcresult`, `results/stability-summary.json` og
  `results/foreground-reentry-source-manifest.json`.

Fysisk kontrol af den rettede visning på iPhone mangler stadig. Der er ikke
udført upload, direkte enhedsinstallation eller ændring af versionsnummer,
release-status eller releaseartefakter. Dette er en lokal, uudgivet kandidat.
Det tidligere rapporterede tomme Watch-komplikationsfelt er fortsat særskilt
og indgår ikke i denne rettelse.

---

<!-- testflight-7.1.1-4290:start -->
### TestFlight 7.1.1 (4290)

- Kildecommit og tag: `76aa814116ff19464767ae8b0768b8782b9da567` / `testflight-7.1.1-4290`.
- Tests: 1192/1192 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-03T18:32:59.282963+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/a50d4538-18e6-4a56-9ba4-2eb3c7fc806a).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4290:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4289:start -->
### TestFlight 7.1.1 (4289)

- Kildecommit og tag: `e03747b6a7dd569bf5d6a035fb4cc761d714e379` / `testflight-7.1.1-4289`.
- Tests: 1182/1182 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-03T17:33:00.825514+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/acffa794-d07b-459a-928d-3aac2eaa35d6).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4289:end -->

## Godkendt udgivelse af de to lokale visningsrettelser

3. oktober 2026: brugerens “indtil videre så upload” godkender intern
TestFlight-udgivelse af rettelserne til grafens prognosebredde og Watch-appens
modtagelsesprik beskrevet nedenfor. Releaseprocessen vælger næste ledige
buildnummer hos Apple og gentager hele valideringen på det præcise release-træ.
De lokale testtal nedenfor er forudgående testmateriale; endelig Apple-status
og tests registreres i releaseafsnittet efter gennemført udgivelse.

Det tomme xDrip-felt på urskiven er fortsat et åbent, særskilt problem.
Watch-systemdiagnosen fra 20.04 blev læst via iPhone og viste både en ældre
xDrip-komplikation og vores aktuelle på samme urskive. Den dokumenterer ikke
årsagen til det tomme felt eller et nedbrud i vores komplikation. Brugeren
ønsker at udskyde denne undersøgelse. Der indgår ingen komplikationsrettelse,
ændring af Bluetooth, alarmer, sensorejerskab, workout-runtime eller
behandlings-/prognoseberegning i denne udgivelse. Ingen direkte installation
på brugerens enheder; TestFlight er installationsvejen.

## Lokal Watch-visningsrettelse efter 4289 — modtagelsesprik

3. oktober 2026: prikken ved målingens alder er en aktivitetsindikator, som
historisk lyser grønt i 0,5 sekunder ved datamodtagelse; den er ikke et
vedvarende signal om Bluetooth-rækkevidde eller friske sensorværdier.
Kodegennemgangen fandt, at kun den gamle `didReceiveMessage`-variant uden
replyHandler tændte grønt. Den fælles refresh-modtagelse satte indikatoren grå,
så moderne kvitterede pushes og svar på urets anmodninger ikke viste blinket.
Fejlvejen fandtes før 4289 og skyldes ikke de nye basal-/prognosefunktioner.

iPhonens aktivitetslog blev læst trådløst; den havde nye Watch 4289-hændelser
med højst ét sekund mellem Watch-tid og telefonens modtagelse i det seneste
udsnit. Det dokumenterer Watch→iPhone-trafik, ikke hvert iPhone→Watch-svar eller
prikkens rendering. Den lokale eksport af hele Watch-journalen var ældre og
bruges ikke som bevis for urets aktuelle modtagelser.

Rettelsen knytter det grønne 0,5-sekunders blink til den fælles, validerede
`received`-hændelse. Afviste payloads og behandlings-/målekvitteringer tænder
ikke alene grønt. Ældre forsinkede nulstillinger kan ikke slukke et nyere blink
eller en nyere ventende anmodning. Orange under afventning og grå i hvile
bevares. Dette er kun præsentation; leveringsprotokol, genopkobling,
sensorejerskab, runtime, alarmer og behandlinger ændres ikke. Der tilføjes
ingen polling eller keepalive. iPhone-grafrettelsen nedenfor bevares.

Validering af begge lokale visningsrettelser, 3. oktober 2026:

- `scripts/local-build.sh release-test` afsluttede med exit 0.
- **1.192/1.192 XCTest-tests bestod**, nul fejl/skipped, inklusive otte nye
  tests for validerede/afviste modtagelser, ældre og kvitterede leveringsveje,
  uændrede korrelerede svar, udløb og overlappende indikatoropdateringer.
- Alle Python-kontroller og både iPhone- og Watch-simulatorbuilds bestod.
- Uafhængig diff-gennemgang fandt ingen ændring af transport-/kvitteringslogik.
  `git diff --check` bestod. Den tidligere grafrettelses kodehash er bevaret.
- Testmateriale:
  `~/DeveloperBuildData/xDrip/local-runs/xdripswift/20261003T175751Z-69579/`,
  inklusive `results/AllTests.xcresult`, `results/stability-summary.json` og
  `results/combined-visual-fixes-source-manifest.json` for den lokale ændrede
  kode oven på `fa3aaf23`.

Fysisk bekræftelse af blinket afventer en særskilt autoriseret udgivelse.
Ingen upload, enhedsinstallation, versions- eller release-statusændring.

---

## Lokal visningsrettelse efter 4289 — stabil prognosebredde

3. oktober 2026: iPhone blev læst trådløst med Apples devicectl og bekræftet
på 7.1.1 (4289). Den lokale prognoselog viste fem `dataUnavailable`-poster;
fire blev efterfulgt af en gyldig prognose på samme målereference efter
219–511 ms. Den femte reference havde allerede en gyldig bevaret post, så
loggens første-gyldige-deduplikering kan ikke afgøre dens senere restitution.
Aktivitetsloggen viste ti fortløbende sensormålinger i det undersøgte interval,
med højst 61 sekunder mellem målingerne. Rådata ligger privat uden for Git.
Dette dokumenterer korte inputpauser; der er ikke optaget skærmbilleder af
hver render-frame på telefonen.

Kodefund: Home koblede hele grafens fremtidige tidsområde til tilstedeværelsen
af prognosepunkter. En midlertidigt skjult prognose trak derfor tidsaksen ind
og ud for både glukose, behandlinger og IOB/COB. Rettelsen reserverer det valgte
60/120-minutters område under genindlæsning, også når resultatet er utilgængeligt.
Fra, historik, natvisning og kompakte grafer bevarer deres eksisterende område.
Gyldighedskontrollerne er uændrede; der vises ingen gammel prognose hen over
ukendte eller ændrede behandlingsdata.

Ændringerne er begrænset til grafvisning, regressionstests og dokumentation.
Prognosemotor, logformat, HealthKit-import, alarmer, Bluetooth, Watch-runtime,
ejerskab og levering er uændrede. Buildnummer og release-status ændres ikke.
Ingen upload eller direkte installation er foretaget for denne rettelse.

Validering af denne lokale rettelse, 3. oktober 2026:

- `scripts/local-build.sh release-test` afsluttede med exit 0.
- **1.184/1.184 XCTest-tests bestod**, nul fejl/skipped, herunder to nye
  regressionstests for stabilt tidsområde ved 60/120 minutter og ved
  indlæsning → gyldig → utilgængelig → gyldig prognose.
- Alle Python-kontroller samt iPhone- og Watch-simulatorbuilds bestod.
- `git diff --check` bestod. Kodeændringen omfatter kun `GlucoseChartView.swift`,
  `RootHomeChartViews.swift` og den eksisterende `RootHomeInteractionTests.swift`.
- Kvittering og logs:
  `~/DeveloperBuildData/xDrip/local-runs/xdripswift/20261003T174636Z-66258/`.
  `results/forecast-reentry-source-manifest.json` knytter testen til den lokale
  kode oven på `fa3aaf23`; HEAD alene indeholder endnu ikke rettelsen.

Fysisk kontrol af grafen ved gentagne appskift afventer en særskilt godkendt
udgivelse. Den korte skjulning af estimatet under reel inputkontrol kan fortsat
forekomme; hele grafen skal ikke længere ændre vandret skala af den grund.

---

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

## Lokal kandidat efter 4288: prognose, basalregistrering og måling af præcision

Denne kandidat fortsætter `integration/upstream-7.1.1` fra
`bbfc66803033dd2e063954d3dd277ba0d7a6b1c7`. Rettelserne fra 4287 og 4288
bevares; 4286 er kun sammenligningsgrundlag. Appversion/buildnummer og
release-state var uændrede under implementeringen. Brugerens efterfølgende
“Upload” den 3. oktober 2026 godkender nu intern TestFlight-udgivelse af denne
kandidat. Den eksisterende releaseproces vælger nummeret fra Apple og tester
det præcise release-træ igen. Faktisk Apple-status fremgår af releaseafsnittet,
når processen er gennemført; der foretages ingen direkte enhedsinstallation.

Ændringer:

- `GlucoseForecastEngine.swift`: eksplicit nul korrektionsbidrag, fortsat
  beregning af correctionRate, uændret 15-minutters regression og særskilt
  10-minutters momentumaftrapning. Akkumuleret residual bevares derefter;
  behandlingseffekter og 60/120-minutters horisont fortsætter. Delt, versionssat
  konfiguration bruges af motor og log. Personlige indstillinger er uændrede.
- `LibreWatchDirectSession.swift`, `WatchManager.swift`, Watch
  `WatchStateModel.swift` og `RootView.swift`: særskilt basalregistrering som
  `BasalInjection`, hele positive enheder op til den eksisterende 200 U-grænse,
  tydelig bolus/basal-bekræftelse og holdbar kø/kvittering. Ukendte typer afvises
  synligt uden falsk gemt-kvittering eller overskrivning af køen. Basal påvirker
  ikke bolus, IOB, COB eller prognoseinput. Kun behandlingssektionerne ændres.
- Ny `GlucoseForecastLog.swift` og adaptertilkobling: første gyldige snapshot
  pr. reference/horisont/motorversion bevares uændret, separate fejlposter,
  seriel lokal JSONL-lagring, højst 400 UTC-dage og almindelig enhedsbackup.
- Ny `GlucoseForecastLogExportView.swift`, Home-indstillingsmodel/routing,
  engelske/danske tekster og projektfil: eksplicit streaming CSV-eksport via
  Indstillinger → Hjemskærm → Eksportér prognoselog.
- `scripts/evaluate-glucose-forecast.py` og syntetiske Python-tests: lokal
  +30/+60/+120-evaluering mod samme faktiske målinger som uændret-værdi-baseline,
  faste matchregler, reelle resterende prognosetider og særskilte manglende data.
  `local-build.sh` kører de nye Python-tests sammen med eksisterende kontroller.
- Nye/udvidede forecast-, adapter-, log- og basal-XCTest-tests. Model og
  CSV-/evalueringsformat er dokumenteret i `docs/GLUCOSE-FORECAST.md`.

Validering af den endelige kode, 3. oktober 2026:

- `scripts/local-build.sh release-test` afsluttede med exit 0.
- **1.182/1.182 XCTest-tests bestod; 0 fejl og 0 skipped.** Heri indgår
  17 logtests, 8 basaltests samt nye motor- og adaptertests.
- **157 Python-tests og 54 syntetiske selvkontroller bestod**, inklusive
  evaluatorens 18 tests. Swift-genereret CSV er også læst af det faktiske
  Python-værktøj med kendt syntetisk facit for begge prognosehorisonter.
- iPhone- og Watch-simulatorbuilds bestod med Xcode 27.0 (27A266a), uden
  enhedssignering. Den eksisterende `local-build.sh`-kommando kan ikke uploade.
- Testresultater og logs:
  `~/DeveloperBuildData/xDrip/local-runs/xdripswift/20261003T171157Z-47158/`.
  Se `results/AllTests.xcresult`, `results/stability-summary.json` og
  `results/forecast-candidate-source-manifest.json`. Resultaterne vedrører den
  lokale ændrede kode oven på den angivne HEAD; HEAD alene er ikke kandidaten.
- `git diff --check` og projektfilens plist-kontrol bestod. Historiske tags,
  `Version.xcconfig` og `release-automation/active.json` er uændrede.
  Denne lokale validering oprettede ingen release/tag; den efterfølgende
  autoriserede udgivelse får sin egen testkvittering og sit eget checkpoint.

Første fulde kørsel fandt en reel JSONL-fejl: projektets generiske
`Data.append(integer)` skrev et linjeskift plus nulbytes. Den nye log bruger nu
en eksplicit enkelt byte og har en regressionstest. Basaltestens antagelse om
nul ved tomme IOB/COB-data blev rettet til den eksisterende `.noTreatments`/
ukendt-værdi-adfærd. Simulatoren kan ikke dokumentere fysisk iOS-filbeskyttelse;
testen kontrollerer konfigurationen, og hardwarekontrollen afventer enhed.

Præcision: De eksternt oplyste replay-tal er ikke reproduceret. Der foreligger
endnu ingen fremadrettet præcisionsmåling med denne motor. Beståede softwaretests
vil alene dokumentere beregnings- og logmekanik. Loggen er Home-drevet, ikke
kontinuerlig døgnlogning; deduplikering og fejlbegrænsning betyder, at værktøjets
tilgængelighed er for bevarede records, ikke alle mulige beregningsforsøg.
Evaluatoren kan ikke identificere efterfølgende måltider/insulin ud fra de to
CSV-filer alene.

Fysisk opfølgning efter en særskilt godkendt udgivelse: basalbekræftelse og
kvittering på Watch/iPhone, kø ved midlertidig manglende kontakt, CSV-deling,
log efter genstart og normal enhedsbackup/gendannelse samt den eksisterende
prognosevisning ved appskift. Frisk prospektiv log og faktiske glukosemålinger
kræves for at vurdere præcision.

Beskyttede funktioner er bevaret: alarmregler/-levering, sensor/Bluetooth,
ejerskab/handoff/workout, Nightscout-upload/kildeprioritet, glukosemålinger,
kalibrering/statistik og HealthKit-tilladelser/import. Ingen nye timere,
baggrundsprognose, dosisberegning, databaseændring eller eksterne frameworks.

---

<!-- testflight-7.1.1-4288:start -->
### TestFlight 7.1.1 (4288)

- Kildecommit og tag: `697ffcb0f25b855fbb0ccc9fbb7a2a64f8643f65` / `testflight-7.1.1-4288`.
- Tests: 1148/1148 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-03T15:57:19.192290+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/e2f2c3db-584b-4e34-9320-9b9a551da124).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4288:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4287:start -->
### TestFlight 7.1.1 (4287)

- Kildecommit og tag: `90c29c14402511b67da872e607ea4d901cf361d1` / `testflight-7.1.1-4287`.
- Tests: 1148/1148 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-03T13:52:13.335693+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/3a93c3d3-8c2d-4839-91f3-35db2ce2e415).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4287:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

## Prognose ved appskift efter 4287

En fysisk iPhone-observation viste, at 4287 viste “Beregner estimat…” i
appvælgeren, når xDrip blev inaktiv, selv om Home havde en frisk måling.
Home-nulstillingen ved scene-skift fjernes: en færdig prognose bevares under
et kort appskift, mens ny beregning stadig kun sker i forgrunden. Den
eksisterende visningskontrol skjuler estimatet ved for gamle målinger,
sensorskift, ændret behandlingsgrundlag eller uoverensstemmelse med grafen.
Sensorforbindelse, målelagring, alarmer og Watch-kode er uændrede.
Appvælgeren viser fortsat et iOS-snapshot, ikke live data. Fysisk kontrol af
visningen efter installation af næste build mangler.

<!-- testflight-7.1.1-4286:start -->
### TestFlight 7.1.1 (4286)

- Kildecommit og tag: `143ca805e65c88fc953e84f74fd3abd75b62babf` / `testflight-7.1.1-4286`.
- Tests: 1141/1141 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-03T12:20:33.062353+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/8b3d67c3-2c71-4410-ad21-4f96bc90b2b5).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4286:end -->

## Prognosevisning efter 4286

En fysisk observation 3. oktober viste, at prognosen kortvarigt kunne forsvinde,
selv om Home viste en frisk sensormåling. iPhone-fejlfindingsloggen viste
fortsatte minutmålinger under observationen. Den næste kandidat retter Home-
visningens nulstilling ved hver grafopdatering og lader prognosen vælge den
nyeste gyldige måling efter samme filtrering som Home. En tidligere prognose
bevares kun kortvarigt ved uændrede behandlingskilder, indstillinger og
sensoridentitet; den skjules ved usikker kilde, sensorskift eller for gamle data.
Beregning, målelagring, alarmer, Bluetooth og Watch-runtime er uændrede.

Hele den lokale testsuite og begge simulatorbuilds er bestået på kandidaten.
Rettelsen er endnu ikke bekræftet på en fysisk iPhone; prognosen er stadig et
estimat og må ikke forveksles med en målt blodsukkerværdi.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4285:start -->
### TestFlight 7.1.1 (4285)

- Kildecommit og tag: `61bf73bfcccabc61b1fbfce7ea6c3f7177eead05` / `testflight-7.1.1-4285`.
- Tests: 1120/1120 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-03T10:44:17.363520+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/d0348e82-71be-4e29-95b8-380b05b69214).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4285:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4284:start -->
### TestFlight 7.1.1 (4284)

- Kildecommit og tag: `26d7876fa63f33aa91ebda283ae76cc6644f7110` / `testflight-7.1.1-4284`.
- Tests: 1115/1115 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-10-03T06:02:22.067099+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/1888b6f3-9968-4310-a7ee-8a9195b0c6b8).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4284:end -->

## Ændringer efter 4284

Watch kan nu registrere insulin (U) og kulhydrat (g) manuelt uden dosisberegning.
En registrering gemmes først lokalt på uret og leveres derefter til iPhone;
iPhone kvitterer først efter databasegemning og genlevering genkendes på et
stabilt UUID. Registreringerne er lokale på iPhone og indgår i backup, men
sendes ikke til Nightscout. Den nye Watch-side viser den registrerede mængde
og om den afventer iPhone eller er gemt der. Manglende lagring vises som fejl.

Watch markerer en for gammel direkte glukosemåling tydeligt ved tallet og
viser dens alder adskilt fra forbindelsesstatus. iPhone Home skjuler
ændringsværdien for en for gammel måling og reserverer fast plads til
IOB/COB-status, så rækken ikke rykker ved genindlæsning. Sensorens Bluetooth-
og overdragelseslogik samt alarmernes regler er uændrede. En særskilt
Watch-alarmtone er ikke tilføjet, da det anvendte watchOS-SDK ikke understøtter
den ønskede tilpassede notifikationslyd.

Den lokale kontrol af disse ændringer 3. oktober 2026 bestod 1.120/1.120
XCTest-tests, Python-kontroller og både iPhone- og Watch-simulatorbuilds.
Fysisk registrering og levering samt effekten på Home-visningen er endnu
ikke testet på brugerens enheder. I den seneste fysiske 4284-test modtog uret
89/91 sensorminutter under 91 minutters ejerskab, men én pause varede
181,175 sekunder og overskred dermed treminutterskravet. Der er ingen
Bluetooth-rettelse i de nye ændringer. Ved en lokal filfejl i Watch-køen
vises en fejl, og nye registreringer blokeres i den aktuelle app-session.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4283:start -->
### TestFlight 7.1.1 (4283)

- Kildecommit og tag: `b80db1207e35c201fd0dc70faabe494ac0028489` / `testflight-7.1.1-4283`.
- Tests: 1113/1113 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-28T13:12:44.760574+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/dd1daa27-f5f4-49a4-9eb0-f82279a94599).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4283:end -->

## Afgrænset Watch-alarmrettelse efter 4283

Et ældre, forsinket svar fra watchOS om notifikationstilladelse kunne ændre
Watch-alarmens autorisation og annullere eller genplanlægge en alarm, selv efter
et nyere svar var modtaget. Kun svaret fra den senest startede kontrol må nu
ændre alarmtilstand og planlagte notifikationer. Det gælder også, når den
almindelige tilladelseskontrol overlapper kontrollen ved sensor-overtagelse.
To regressionstests dækker svar i omvendt rækkefølge. De 1.115/1.115 XCTest-tests,
Python-kontrollerne og begge simulatorbuilds bestod 3. oktober 2026.
Bluetooth-genopkobling, timeouts, alarmregler og snooze er uændrede. Virkningen
på det fysiske ur er endnu ikke bekræftet; en kort kontrol af alarmberedskabet
erstatter ikke en 90-minutters stabilitetstest.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

## Rettelser efter 4282 og fysisk opfølgning

Watch-alarmens beredskab sammenligner nu den oprindeligt planlagte timerperiode
med den kølagte notifikation. Den bevægelige næste affyringsdato gav tidligere
en falsk advarsel om, at alarmen ikke var planlagt. Knappen til at anmode om
Watch-notifikationer vises kun, før tilladelsen er afgjort. Alarmregler,
Bluetooth-genopkobling og timeouts ændres ikke.

Home skjuler straks en gammel lokal IOB/COB-værdi, når en behandling gemmes, og
viser først et nyt tal efter databasegemning og beregning. Et normalt
15-sekunders-tick udløser én samlet Home-opdatering i forgrunden i stedet for
tre; et skift i statistikperioden kan stadig give en ekstra opdatering.

En særskilt udviklingssigneret 7.1.1 (4282.1) blev installeret direkte på
brugerens iPhone 28. september efter en verificeret privat kopi af appdata.
Den findes ikke i TestFlight, og den seneste modtagne Watch-log viser stadig
4282. Den næste normale TestFlight-build skal installeres på begge enheder,
og Watch-buildnummeret skal kontrolleres fra en frisk Watch-log før testen.
Målet er 90 minutters Watch-ejerskab uden tryk: mindst 95 % direkte modtagne
sensorminutter, ingen pause over tre minutter og ubrudt workout. Første måling
og den første opstartstid rapporteres separat.

<!-- testflight-7.1.1-4282:start -->
### TestFlight 7.1.1 (4282)

- Kildecommit og tag: `1b50457a5f728ee89f144a33a0da935e31c8ce25` / `testflight-7.1.1-4282`.
- Tests: 1109/1109 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-28T07:12:25.392089+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/551aa9f6-0524-4ceb-82d7-4e2a16353b58).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4282:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

## Afgrænsning og fysisk opfølgning for 4282

4282 ændrer kun Home-visningen af lokale IOB/COB under en kort genindlæsning.
En sidst bekræftet værdi kan blive stående i højst 60 sekunder, mærket med
beregningstidspunktet; den underliggende behandlingstilstand er fortsat
utilgængelig indtil nye data er klar. Ældre værdier og ændret datakilde giver
fortsat streger. Watch-Bluetooth, workout, alarm, målebehandling og overdragelse
er uændrede. Effekten på den faktiske åbningsanimation er endnu ikke fysisk
bekræftet. Før upload viste Xcodes enhedsliste den parrede iPhone som
`unavailable`, så ingen fysisk iPhone-smoke-test blev udført.

Næste direkte Watch-test skal derfor måle stabilitet, ikke tilskrive 4282 en
Bluetooth-forbedring. Den sidste fysiske 4279-test gav 88/90 sensorminutter,
men femminuttersalarmen var ikke klar, og alle testbetingelser var ikke
verificeret. Med 4282 installeret på både iPhone og Watch: sæt alarmen for
manglende målinger til fem minutter og fjern snooze; overtag sensoren på uret,
vent på første direkte måling, slå derefter iPhonens Bluetooth og Wi-Fi fra i
Indstillinger og noter starttidspunktet. Lad uret være urørt i 90 minutter,
genetabler derefter telefonens forbindelser og giv ejerskabet tilbage. Hent
friske Watch- og iPhone-logs. Godkendelseskriterierne er mindst 86/90 modtagne
sensorminutter, ingen pause over tre minutter og en ubrudt workout. Rapportér
første 60 og sidste 30 minutter hver for sig; skeln mellem planlagt alarm og
dokumenteret alarmlevering. Se `WATCH-RSSI-ALARM-DIAGNOSTICS.md`.

<!-- testflight-7.1.1-4281:start -->
### TestFlight 7.1.1 (4281)

- Kildecommit og tag: `047aa57602bcee24bb801fb2dd645db756e6f169` / `testflight-7.1.1-4281`.
- Tests: 1106/1106 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-28T04:48:23.155985+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/25b1127d-bd3c-4475-b8c5-b616a50776fa).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4281:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4280:start -->
### TestFlight 7.1.1 (4280)

- Kildecommit og tag: `f1a4d29a7aa3ce299031f5d2b3188bd6992bbdc4` / `testflight-7.1.1-4280`.
- Tests: 1104/1104 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-27T20:12:25.005363+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/9657eca6-acc5-426c-bd0a-16473c1a7430).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4280:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

## Alarmrettelse efter den fysiske 4279-test

Build 4280 retter kun afrundingen af Watch-notifikationers baseline.
Alle fem alarmtyper er gennemgået; otte nye tests reproducerer fejlen og
beskytter blandt andet snooze, ejerskab og telefonens valgte alarmforsinkelse.
Bluetooth, runtime, målebehandling og levering bevares.
Se [rettelse og RSSI-analyse](WATCH-ALARM-TIMESTAMP-REVIEW.md).
Trendudfyldning er kun en [plan til en senere diagnosebuild](WATCH-TREND-SHADOW-PLAN.md).


### Verifikation og fysisk afgrænsning for 4280

Afrundingsfejlen blev først reproduceret mod 4279-koden: tre af otte nye
testmetoder fejlede med i alt 11 assertions. Med rettelsen bestod alle otte.
Den endelige 4280-kilde bestod 1.104/1.104 XCTest-tests, Python-kontrollerne
og begge simulatorbuilds. Kilde-tag, alle fem signerede bundles og den
eksporterede IPA er verificeret. Rettelsen ændrer ingen Bluetooth-logik,
timeouts, alarmindstillinger eller trendbehandling.

Den parrede iPhone blev læst via lokalnettet og havde 4279 installeret.
4280-arkivets udviklingsprofiler omfatter ikke denne iPhone, så ingen ny kode
blev installeret eller startet direkte på telefonen. Enhedsregistrering og
signeringskonfiguration er uændret. Dette er en verificeret trådløs
enhedskontrol, ikke en fysisk smoke-test af 4280 eller dokumentation for
faktisk lyd/haptik fra urets alarmer. Det sidste skal fortsat observeres på uret.
Lokal kontrol: `build/testflight-7.1.1-4280/physical-iphone-preflight.json`.

IPA SHA-256: `4372ce058bb78320503f52b81d81db99b3c3e2e6cf2ce91d730e3f7351688cc5`.
Regressionens før/efter-resultater og den eksisterende 4279-tests
RSSI-beregning med kildehash findes i `build/alarm-timestamp-fix/`.
Se [alarmgennemgang og RSSI](WATCH-ALARM-TIMESTAMP-REVIEW.md) og
[plan for en senere skyggetest af trendværdier](WATCH-TREND-SHADOW-PLAN.md).


<!-- testflight-7.1.1-4279:start -->
### TestFlight 7.1.1 (4279)

- Kildecommit og tag: `5dd3ac9b23ee59bfc8ccd44a2bea73aae0c295ca` / `testflight-7.1.1-4279`.
- Tests: 1096/1096 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-27T17:27:16.077433+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/9c25d000-4250-46a7-b41b-8953386fa3d2).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4279:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

## Diagnoseforløb efter 4278

Apple Watch-sysdiagnose er verificeret fra en prøve kl. 18:45 den 27. september:
trådløs hentning via iPhone, bekræftet Watch-oprindelse og læsbar HCI-log i
PacketLogger. Prøven dokumenterer ikke årsagen til det tidligere Libre-udfald.
Diagnoseudgivelsen 4279 tilføjer kun RSSI og automatisk kontrol af
alarmberedskab; genopkobling, timeout, runtime og måleflow bevares.
Se [afgrænsning, logbegrænsninger og 90-minutters test](WATCH-RSSI-ALARM-DIAGNOSTICS.md).


### Verifikation og fysisk afgrænsning for 4279

Den præcise release-kilde bestod 1.096/1.096 XCTest-tests uden fejl eller
skipped tests, inklusive 22 nye RSSI-/alarmtests, Python-kontrollerne og begge
simulatorbuilds. Den signerede IPA er kontrolleret mod kilde-tagget og alle
fem bundles. Apple-status og kildecommit står i releaseblokken ovenfor.

Den parrede iPhone kunne læses trådløst med devicectl og havde 4278 installeret
som en udviklerapp. 4279-arkivets udviklingsprofiler omfatter ikke denne iPhone.
Der blev derfor ikke installeret eller startet ny kode på telefonen, og ingen
appdata blev ændret. Et valgfrit opslag af enhedsregistrering hos Apple blev
afvist af automatisk godkendelseskontrol på grund af manglende særskilt
tilladelse til at sende enheds-id'et; opslaget blev ikke gentaget. Profiler,
enhedsregistrering og signeringskonfiguration blev ikke ændret for at omgå det.
Den trådløse loghentning er verificeret, men er ikke en fysisk smoke-test af 4279.
Lokal kontrol: `build/testflight-7.1.1-4279/physical-iphone-preflight.json`.

Ingen fysisk stabilitetsforbedring eller faktisk alarmlevering er endnu bevist
med 4279. Den næste afgrænsede Watch-test varer 90 minutter som beskrevet i
diagnosevejledningen. En kodegennemgang bemærkede desuden en mulig eksisterende
race mellem overlappende almindelige permission-refresh-svar; den er ikke
observeret i denne test og blev ikke ændret som del af diagnosen.

<!-- testflight-7.1.1-4278:start -->
### TestFlight 7.1.1 (4278)

- Kildecommit og tag: `8f860214eb82d1ea751566eda02af654d338d157` / `testflight-7.1.1-4278`.
- Tests: 1074/1074 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-27T10:48:30.158334+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/7a7c2de9-fa7d-4b81-8f32-d69039162b02).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4278:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4277:start -->
### TestFlight 7.1.1 (4277)

- Kildecommit og tag: `1983fe38c2dcebe4468a5c8324bce4b14fc7a590` / `testflight-7.1.1-4277`.
- Tests: 1067/1067 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-26T19:37:06.774887+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/863a5e25-9fae-4224-872c-bdf535019514).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4277:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4276:start -->
### TestFlight 7.1.1 (4276)

- Kildecommit og tag: `d559492dd82bf107f9fb48d121f3594ce0d74a40` / `testflight-7.1.1-4276`.
- Tests: 1055/1055 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-26T16:56:30.768485+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/59fdbc59-c502-427e-81a6-e61ee0c40943).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4276:end -->

## Lokal Watch-genopkobling efter 4276-testen

Testen viste 56 af 62 sensor-minutter og to uplanlagte afbrydelser under
aktiv udvidet runtime. Alle 56 indsamlede målinger nåede iPhone. Den lokale
rettelse giver efter bekræftet cancellation én ekstra, tidsbegrænset
forbindelsesrunde til den tidligere frame-bekræftede sensor, før scan bruges
som fallback. Der ændres ikke runtime-type, timeoutgrænser eller databehandling.

Før release bestod 1067/1067 lokale tests samt iPhone- og
Watch-simulatorbuilds. Den efterfølgende releasekvittering står øverst i
dokumentet. Fysisk forbedring er endnu ikke påvist; næste Watch-test bør
vare 80–90 minutter med den nye version. Se
[analyse, sikkerhedsgrænser og validering](WATCH-RECONNECT-4276-REVIEW.md).


De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

## Afgrænset intern test af Watch-runtime

Næste TestFlight-build ændrer kun Watch-appens `WKBackgroundModes` fra
`self-care` til `physical-therapy` i den installerede app. Signerings- og
arkivkontrollerne forventer samme ene værdi. Der tilføjes ingen batterilog,
træningsfunktion, automatisk forlængelse, trend-backfill eller BLE-ændring.
Formålet er en personlig diagnose af, om længere udvidet runtime forbedrer
Libre-forbindelsen, når iPhone er utilgængelig. Det er endnu ikke en påvist
varig løsning.

4275 bevares komplet som sammenligningsbuild under denne release. Efter
installation testes Watch som sensorejer i cirka 70–75 minutter med iPhone
utilgængelig. Vi sammenligner minutmålinger, uplanlagte BLE-afbrydelser og
runtime-udløb før og efter 60-minuttersgrænsen. Testen afgør ikke alene
forbindelsens stabilitet ved alle fremtidige forhold.

## Selektiv release-cacheoprydning, 26. september 2026

Build 4275 blev frisk bekræftet via Apples officielle API som VALID,
INTERNAL_ONLY og IN_BETA_TESTING med Ole Internal-tilknytning kl. 09:37 UTC.
Den sikkerhedskontrollerede oprydning fjernede 88.845 gendannelige cachefiler
fra afsluttede builds 4266 og 4268–4273. Filernes rapporterede allokerede
størrelse var 12.561.162.240 byte (11,70 GiB); den målte stigning i ledig
plads på disken var 2.359.599.104 byte (2,20 GiB). APFS/File Provider kan
dele eller håndtere disse blokke anderledes end filernes summerede størrelse.

Finder holdt kortvarigt en cachemappe åben under første gennemløb, så den
løbende kontrol standsede efter 61.741 filer. Et nyt, idempotent gennemløb
bestod alle kontroller og fjernede de resterende 27.104 filer. Rapporterne
ligger i de ignorerede lokale mapper
`build/release-automation/cleanup/20260926T093551.019829Z/` og
`build/release-automation/cleanup/20260926T093801.092191Z/`.
Den afsluttende rapport bekræfter uændret Git-tilstand og uændrede bevarede
releasefiler. Hele 4275, det ufuldendte 4274-forsøg, arkiver, IPA, dSYM,
XCResult, logs, JSON, Apple-status og øvrige uklare mapper er bevaret.

Release-automationen forsøger fortsat selektiv oprydning efter en fuldført
Internal / Testing-statuscommit/push. Den kræver frisk Apple-status,
bevarede releaseartefakter, proces- og åben-filkontrol samt fælles værtslås
med buildscriptet. Hele DerivedData slettes aldrig; se MAC-BUILD.md.
File Provider-hydrering ændrede metadata-ctime uden observeret ændring af
filidentitet, størrelse eller mtime. Cacheidentiteten kontrolleres nu via
filsystem, inode, type, størrelse og
mtime, mens hardlink-antallet også kontrolleres umiddelbart før sletning.
29 isolerede oprydningstests og 28 release-tests bestod efter rettelsen.
Intet nyt Xcode-/TestFlight-build eller upload blev startet.

<!-- testflight-7.1.1-4275:start -->
### TestFlight 7.1.1 (4275)

- Kildecommit og tag: `d36cb9c84176e23a9fbfb8ed9bcf29da7fb6d9d2` / `testflight-7.1.1-4275`.
- Tests: 1055/1055 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-26T08:26:21.583113+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/36833269-7361-4950-98de-08c560688c59).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4275:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4273:start -->
### TestFlight 7.1.1 (4273)

- Kildecommit og tag: `817fa1b81e81658b8eca03a8597e34b5d8659366` / `testflight-7.1.1-4273`.
- Tests: 1055/1055 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-25T17:38:08.665227+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/916b33b2-766e-400b-92ea-416cce1915b6).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4273:end -->

## Målrettet runtime-diagnostik efter den fysiske 4273-test

Den selvstændige Watch-test den 26. september kl. 06:19–07:21 gav 52 af 62
sensor-minutnumre. Ni uplanlagte Core Bluetooth-afbrydelser genoprettedes;
alle 52 dekodede målinger blev gemt lokalt på Watch og senere varigt lagret
på iPhone. De otte registrerede målehuller havde ingen afkodnings-,
framesamlings- eller notification-fejl. Den nye grænse for et uændret native
forbindelsesforsøg blev ikke udløst. Den bevarede detaljerede analyse og
originale testfiler ligger uden for Git. Dette forløb dokumenterer derfor
fortsat ustabil sensormodtagelse efter runtime-udløb, men ikke en bestemt
kodefejl eller et tab i Watch-til-iPhone-leveringen.

Ved udløbet af den udvidede Watch-runtime eksporterede 4273 kun
`error=other/1`. Fejldomænet blev bevidst erstattet med `other` i begge
eksportveje, så det rå domæne ikke kan genskabes fra denne test. Den nye
ændring lader de eksisterende sikre domæner og et kort, syntaktisk
begrænset `com.apple.*`-runtime-domæne følge med i både lokal Watch-evidens
og iPhones aktivitetslog. Den eksporterer fortsat hverken fri fejltekst eller
sensoridentitet. Ukendte eller mistænkelige domæner forbliver `other`, og
andre hændelsestyper får ikke udvidet domænelisten. Der tilføjes ingen
Bluetooth-operationer, timere, journalposter eller ændring i genopkoblingen.
Det er diagnostik og **ikke en eftervist rettelse af de ni radioafbrydelser**.

De to berørte XCTest-suiter og det færdige XCResult bekræfter 132/132
bestået, 0 fejl og 0 skipped. Xcode ventede efter selve testene på en
separat `simctl diagnose`-indsamling med 600 sekunders timeout; ved andet
testforsøg blev netop den indsamling stoppet, hvorefter xcodebuild
afsluttede med exit 0 og skrev en gyldig XCResult-pakke. Separate
usignerede iPhone- og Watch-simulatorbuilds afsluttede med exit 0.
En ny TestFlight-build kræver fortsat den præcise release-kildes fulde
testforløb og verifikation. Den næste fysiske kontrol
skal især måle sensor-minutter og linkbrud efter runtime-udløb med telefonen
utilgængelig og urets skærm i hvile.

Arkivforsøg for 7.1.1 (4274) den 26. september bestod den præcise
release-kildes 1055/1055 XCTest-tests, begge simulatorbuilds og
checkpoint/push/tag (`031a3e40f6d0a5e5307aff50ad5e621814666298` /
`testflight-7.1.1-4274`). Arkiveringen stoppede før IPA og upload:
File Provider satte `com.apple.FinderInfo` og
`com.apple.fileprovider.fpfs#P` på den genererede Watch-komplikation, og
`codesign` afviste dens ressourceattributter. Den fejlede buildmappe,
testresultaterne og tagget bevares. Fejlen siger ikke noget om BLE-stabilitet.

Release-scriptet kan nu lade den ignorerede `build/…/build` pege på en ny,
lokal, vedvarende mappe uden for File Provider via
`XDRIP_SIGNING_OUTPUT_ROOT`. Kilde-, test-, signatur- og uploadkontroller
er uændrede. Da procesændringen er ny kildekode efter det uforanderlige
4274-tag, skal et senere build allokeres og testes fuldt igen.

Build 4275 blev arkiveret og eksporteret fra den lokale mappe, men den første
udpakning til den afsluttende `codesign --verify` skete stadig i File Provider
og fik igen `FinderInfo`. Den fejlede udpakning er bevaret; et link til en ny
lokal verifikationsmappe gjorde det muligt at gennemføre den uændrede
release-verifikation og upload. Efter 4275-tagget er release-scriptet rettet,
så fremtidige builds opretter både build- og verify-link automatisk. Dette er
kun release-automatisering; den installerede 4275-app er uændret.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

## Afgrænset genoprettelse af fastlåst Watch-forbindelse efter 4272

4272-testen den 25. september kl. 18:22–18:53 dokumenterede fire uplanlagte
Bluetooth-afbrydelser. Watch afkodede 20 af 31 forventede minutpladser frem
til den manuelle retur. Alle 20 blev lagret lokalt og senere varigt kvitteret
af telefonen. Den afsluttende pause begyndte efter sidste Watch-måling kl.
18:44:17; samme system-genforbindelse ventede fra kl. 18:44:23 til returen
kl. 18:52:51. Den fulde lokale analyse og originalfilerne er bevaret uden
for Git; telefonens præcise radioskiftetid er ikke dokumenteret.

Kode og log viser, at det eksisterende 90-sekunders eksekveringsbudget blev
sat på pause ved inaktiv app uden udvidet runtime. Der var stadig 66,6
sekunder tilbage efter over otte faktiske minutter. Dette er en begrænsning
i genoprettelsespolitikken, ikke en nulstilling af budgettet. De nye
callbackmålinger viste højst cirka 423 ms for en afsluttet callback og
forklarer ikke den lange ventetid som en tilsvarende blokering i callbacken.

Den efterfølgende ændring tilføjer en separat grænse på 180 sekunders
monoton forløbstid for samme uændrede, native `connecting`-forsøg.
Den eksisterende engangsopgave vælger den tidligste grænse: det gamle
eksekveringsbudget eller forbindelsesforsøgets alder. Alder vurderes kun,
når aktiv app eller gyldig runtime giver den eksisterende politik lov til
genoprettelse. En kølagt forbindelse/opsætningscallback får stadig forrang,
og session, sensoridentitet, generation, native tilstand og ejerskab
kontrolleres igen før kontrolleret afbrydelse. Afbrydelsesbevis og den
eksisterende afskærmning af pensionerede peripherals bevares. Rask modtagelse
og GATT-opsætning beholder deres eksekveringsbudgetter. Der oprettes ingen
ny periodisk timer, runtime-forlængelse eller alternativ sensoridentitet.

Watch-visningen adskiller nu genforbindelse fra en forbindelse, der afventer
en måling eller mangler friske målinger. Sidste direkte målings alder vises
med en tydelig tekst. En gemt Watch-måling beskriver ikke iPhones forbindelse,
når telefonen har ejerskabet. Glukoseberegning, alarmer og iPhone-grafens
layout ændres ikke som del af dette arbejde.

**Afgrænsning og fysisk test:** Ændringen håndterer en dokumenteret fastlåsning;
den beviser ikke, at årsagen til de oprindelige radioafbrydelser er løst.
Den kan ikke vække en suspenderet Watch-app ved treminuttersgrænsen. Næste
fysiske kontrol skal ske med samme nye build på begge enheder, telefonen
utilgængelig og urets skærm i hvile det meste af tiden. Mål de faktisk
afkodede sensor-minutter, genoprettelsestid, udløsningsårsag og behov for
manuel åbning særskilt. Fuldt uovervåget modtagelse er fortsat et åbent mål.
Den automatiske releaseblok registrerer testresultater og faktisk Apple-status,
når releasekontrollerne er afsluttet.

<!-- testflight-7.1.1-4272:start -->
### TestFlight 7.1.1 (4272)

- Kildecommit og tag: `923bccc178e75b02d0e3929e4825c872887d28cd` / `testflight-7.1.1-4272`.
- Tests: 1033/1033 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-25T15:39:28.381651+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/bf5babe7-fe17-4c76-a02c-cf2cc2db54b4).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4272:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4271:start -->
### TestFlight 7.1.1 (4271)

- Kildecommit og tag: `24b1657d2e3f4f01b1c481a7440fe6c36acfb210` / `testflight-7.1.1-4271`.
- Tests: 1022/1022 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-25T14:01:07.193058+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/cc25aefe-fe5a-4161-9b8a-e3bc7d2b5d1c).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4271:end -->

## Afgrænset måling af Watch-modtagelsesarbejde efter 4271

4271-testen den 25. september kl. 16:05–16:55 viste tre uplanlagte
linkafbrydelser og 44 af 49 sensor-minutter. Alle 44 dekodede målinger blev
gemt på Watch og senere varigt kvitteret af iPhone. Den sidste periode
kl. 16:37–16:54 havde 18/18 minutter. Retur til telefonen afsluttedes
kl. 16:55:06 uden et ekstra minut-hul. Telefonens Bluetooth og Wi-Fi var
tændt i begyndelsen og blev ifølge brugeren slukket omtrent en halv time
inde i testen; det præcise tidspunkt er ukendt. Resultatet er derfor ikke
en hel times kontrol uden telefonforbindelse og beviser ikke, at 4271 har
løst BLE-udfaldene. De originale testfiler og den detaljerede optælling
er bevaret lokalt uden for Git.

Den længste afsluttede `value`-callback havde cirka 1,239 sekunders work og
næsten ingen efterfølgende collector-diagnostic-flush. Work omfatter også
synkrone leveringsdiagnoser, den varige målingskø, lokale opdateringer og
transport/genforsøg. Kodegennemgangen fandt ikke en dokumenteret fejl, der
forklarer linkbruddene. Identiske, allerede gemte køer undgår allerede
gentagne filwrites, og OS-overførsler med samme ID beskyttes mod genindlevering.

Den nye kandidat tilføjer derfor en lille tidsopdeling i hukommelsen i
den eksisterende callbackopsummering: leveringsdiagnostik, kølagring,
lokal visning/komplikation/alarmer, transport/genforsøg og øvrigt arbejde.
Indlejrede trin tælles eksklusivt, så eksempelvis journalarbejde under
afsendelse ikke tælles to gange. Den dekodede frames eksisterende payload-ID
knytter opsummeringen til leveringsloggen; transporttrinnet kan desuden
genforsøge ældre payloads. Trintællerne er operationer, ikke antal disk-writes.
Varighederne er monoton forløbstid inklusive ventetid, ikke CPU-tid eller
isoleret disk-/radiotid. Arbejde uden for en aktiv callback tilskrives ikke
callbacken. Den afsluttende collector-diagnostic-flush måles fortsat separat.

Felterne er valgfrie i JSON og aktivitetslog, så ældre logs bevarer ukendt
som ukendt. Målingerne følger de eksisterende diagnose- og checkpointmuligheder;
der tilføjes ingen timer eller journalpost pr. måletrin. Varig kølagring,
lokal alarmbehandling, sensorprotokol, runtime og genopkoblingspolitik
ændres ikke. Dette er målrettet diagnostik, **ikke en eftervist BLE-rettelse**.
Næste fysiske kontrol skal vise, hvilket arbejde der fylder i callbacken,
mens telefonen er utilgængelig, og tælle de faktiske sensor-minutter særskilt.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4270:start -->
### TestFlight 7.1.1 (4270)

- Kildecommit og tag: `5ec013da0c16c24327bc322a42739985ad4d348f` / `testflight-7.1.1-4270`.
- Tests: 1015/1015 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-25T10:26:16.935056+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/da5ed95c-bacc-47df-a8c1-3e59ed7f86dc).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4270:end -->

## Mindre diagnostikarbejde under Watch-modtagelse

7.1.1-kandidaten, som Apple-allokeringen har nummereret **4271**, reducerer arbejdet i Bluetooth-callbacks uden at
ændre sensorprotokol, system-autoreconnect, runtime-politik eller beregning
af glukose. Diagnosesnapshots lagres fortsat synkront i journal og outbox.
Kun den efterfølgende transportafsendelse flyttes til en samlet opgave på
main-køen. Hvis watchOS suspenderer før afsendelsen, kan diagnoserne leveres
senere fra de gemte poster. Den direkte målings-, alarm-, unlock- og
overdragelsesvej beholder sin eksisterende afsendelse og lokale lagring.

Uændrede journaler genserialiseres ikke længere blot for at kontrollere
størrelsesgrænsen. Valideringen glemmes efter genstart og ugyldiggøres ved
ændringer, herunder kvitteringsfelter og rotationstællere. Allerede køede
journalposter genkodes ikke ved replay; deres payload og genforsøgsfrist
bevares. Journalens bytegrænse kontrolleres også efter opdatering af
rotationstællerne i den nyeste post.

En isoleret syntetisk Mac-måling med samme optimerede Swift-compiler og
64 allerede køede diagnostikposter viste cirka **47 ms før og 4,4 ms efter**
for 100 prune/replay-gentagelser. Begge varianter bevarede 64 ID'er,
25.983 journalbytes og samme kø/backoff. Målingen isolerer genbehandling af
uændrede poster; den omfatter ikke disk, WatchConnectivity eller fysisk
Watch-hardware og dokumenterer ikke forbedret BLE-stabilitet.

Syv nye regressionstests dækker udløb/genstart, størrelsesgrænser og metadata,
replay/backoff, samlet afsendelse, ny afsendelse under callbackbehandling og
lokal lagring ved suspension før transport. En syntetisk test på 64 poster
med 100 gentagelser rapporterer tid uden en ustabil tidsgrænse. De afsluttede
releasekontroller og Apple-status registreres i den automatiske releaseblok.

**Fysisk efterprøvning:** dette er en konkret reduktion af diagnosebelastning,
men ikke en eftervist løsning på de observerede BLE-linkbrud. Efter samme nye
build er installeret på begge enheder, sammenlignes én times Watch-ejerskab
med telefonens Bluetooth/Wi-Fi slukket med 4270-resultatet på 47/60 minutter.
Lad urets skærm være i hvile det meste af tiden. Efter retur eksporteres både
lokal Watch-leveringslog og telefonlog. Vurder manglende sensor-minutter,
linkafbrydelser, callbackarbejde og diagnoseflush særskilt; flyttet transport
kan sænke callbacktiden uden i sig selv at bevise bedre BLE-modtagelse.

## Standalone 4270-test, 25. september 2026 kl. 13:54–14:57

Brugerens hovedmål er stabil direkte sensormodtagelse på Watch uden telefonen.
Under denne test blev telefonens Bluetooth og Wi-Fi slået fra efter overdragelsen.
Watch-ejerskab er logget kl. 13:54:13, første dekodede måling kl. 13:55:15,
og den manuelle retur til telefonen kl. 14:56:35. Første efterfølgende
telefonmåling kl. 14:57:15 introducerer ikke et ekstra minut-hul.

Den bevarede lokale Watch-snapshot er eksporteret kl. 14:57:32 og dækker
forløbet, selv om den efterfølgende hentestatus siger, at en helt frisk
snapshot ikke kunne hentes. Optællingen er afgrænset til build 4270 og den
aktuelle Watch-proces. De 266 lokale testposter har sammenhængende sekvensnumre.

- **47/60 sensor-minutter** kl. 13:55–14:54. Hele perioden kl. 13:55–14:56
  indeholder **49/62**, altså 13 manglende minutter fordelt på ni frame-gap-poster.
- Det længste interval mellem dekodede målinger er cirka **240 sekunder**
  (kl. 14:07–14:11). Alle ni huller registrerer linkafbrydelse; ingen af dem
  registrerer samlings-, dekodnings- eller notification-fejl. De ti
  linkafbrydelser i disse hulposter er ikke en total for alle testens afbrydelser.
- Alle **49 dekodede målinger** er accepteret og bekræftet skrevet i urets
  lokale kø; alle 49 er senere lagret og varigt kvitteret af telefonen.
  Efterlevering, mens telefonen igen er tilgængelig, må ikke forveksles med
  de minutter, som uret slet ikke dekodede.
- Telefonens bevarede Watch-journal dokumenterer ni uplanlagte afbrydelser
  med efterfølgende vellykket genopkobling. Journalen har sekvenshuller omkring
  kl. 14:37–14:49; lokal frame-gap-evidens viser yderligere linkafbrydelser i
  dette tidsrum. Der kan ikke udledes et fuldstændigt disconnect-forløb alene
  fra telefonens journal.
- Runtime startede kl. 13:54:13 og stoppede kl. 14:04:14. Der blev dekodet
  40 målinger efter stoppet; første manglende minut er kl. 14:08. Tidsfølgen
  beviser ikke, at runtime-stop forårsager afbrydelserne. Sceneaktivering under
  testen betyder også, at fuldt uovervåget genopkobling ikke er eftervist.
- Længste afsluttede callback i testen kl. 14:46:18 tog cirka **893 ms**,
  heraf **545 ms** til efterfølgende diagnostikarbejde. Det er monoton
  forløbstid, ikke CPU-tid eller bevis for årsagen til linkbruddene.

**Nuværende udviklingsfokus:** reducer konkret, gentaget diagnostikarbejde i
Bluetooth-callbacks, mens synkron lokal lagring af målinger og diagnoser
bevares. En uafhængig kodegennemgang fandt ingen begrundet ændring af
system-autoreconnect, generationer eller runtime-politik: de dokumenterede
forløb genopkobler allerede uden parallelle app-initierede forbindelsesforsøg.
En performanceændring skal testes som sådan; forbedret fysisk BLE-stabilitet
skal eftervises i næste test og må ikke påstås på baggrund af simulatorchecks.
Denne prioritet erstatter leveringsfokus fra den tidligere test med telefonen
i nærheden. Historikken nedenfor bevares.

## Fysisk 4270-test, 25. september 2026 kl. 12:29–13:13

Brugeren afsluttede den planlagte time cirka 16 minutter tidligere. Det
tilgængelige forløb er tilstrækkeligt til den aftalte 30-minutters kontrol.
Telefonloggen er eksporteret kl. 13:14:15; den lokale Watch-snapshot er fra
kl. 13:14:09 og leveringsfilen fra kl. 13:14:54. Begge enheder identificerer
4270 og taggets kildecommit. Optællingen nedenfor bruger kun den aktuelle
Watch-proces/build og entydige målings-ID'er; historiske rotationstællere,
ældre builds og den blandede døgnprocent indgår ikke.

- **43/44 sensor-minutter** fra kl. 12:29 til og med 13:12; kun kl. 12:41
  mangler. Alle 43 er dekodet, accepteret og bekræftet skrevet lokalt på uret.
- Én uplanlagt BLE-afbrydelse kl. 12:41:14 (`CBErrorDomain/7`), efterfulgt af
  første gyldige frame kl. 12:42:15. Frame-gap-sporet tæller ét manglende
  sensor-minut og én linkafbrydelse, uden registrerede samlings-,
  dekodnings- eller notification-fejl i dette hul. De næste **31/31**
  sensor-minutter kl. 12:42–13:12 er til stede.
- Retur til iPhone anmodet kl. 13:12:46 og afsluttet kl. 13:12:47. Denne
  manuelle afbrydelse tælles særskilt. Første efterfølgende iPhone-måling
  er kl. 13:13:14; overdragelsen introducerer ikke et ekstra målehul.
- **43/43** entydige Watch-målinger er lagret og varigt kvitteret af iPhone.
  Leveringen er dog forsinket: 13 når telefonlagring inden for tre minutter,
  30 senere. Medianen er cirka 7 minutter, maksimum cirka **27 minutter**
  (12:45:13 til 13:12:16). Det er forskelle mellem enhedernes vægure, ikke
  en synkroniseret transportmåling. Den store efterlevering begynder før
  den manuelle retur; returen er derfor ikke dokumenteret som dens årsag.
- Der er 177 læsningsforsøg/-modtagelser for de 43 ID'er, heraf 176 via
  `transferUserInfo` og ét via `sendMessage`. Telefonen klassificerer 134
  som dubletter. Koden kontrollerer allerede igangværende OS-overførsler
  med samme ID og beholder målingen til varig kvittering; antallet beviser
  ikke i sig selv en fejl i afsendelseslåsen eller tab af målinger.

Den ekstra runtime startede kl. 12:27:52, havde oplyst udløb kl. 12:37:52
og blev invalideret kl. 12:37:53. Tiden svarer til projektets `self-care`-
session på ti minutter. Stopposten indeholder dog reason `-1`, fejlobjekt,
kode `1` og det sanitiserede domæne `other`; den præcise fejl kan derfor
ikke klassificeres ud fra koden alene. Uret dekodede **34 målinger efter
stoppet**. Dette forløb underbygger ikke, at runtime-stop alene stopper BLE.
Den længste afsluttede Bluetooth-callback i sammendraget er cirka 469 ms,
heraf 448 ms til diagnostiklagring. Det er forløbstid, ikke CPU-forbrug,
og dokumenterer hverken en CPU-kvoteoverskridelse eller årsagen til linkbruddet.

**Vurdering og næste fokus:** BLE-resultatet er bedre end 4269-kontrollens
47/60 minutter og 13 uplanlagte afbrydelser, men én kortere test af en
diagnostikændring beviser ikke en stabilitetsrettelse. Undersøg nu den
forsinkede Watch→iPhone-levering og omkostningen ved diagnostiklagring.
Brugeren har efterfølgende bekræftet, at telefonen lå forholdsvis tæt på
uret under en lur, mens uret ejede sensoren. Forløbet skal derfor undersøges
som baggrundslevering med en telefon i nærheden; fysisk nærhed alene beviser
ikke, at WatchConnectivity rapporterede live-reachability.

En opfølgende optælling af de 43 ID'er afgrænser forsinkelsen: Fra Watch-
accept til første indlevering til transport gik højst **1,204 sekunder**
(median 0,117). Fra telefonens første `transportReceived` til `phoneStored`
gik højst **2,569 sekunder** (median 2,519). Telefonens transportpost skrives
i WCSession-delegatevejen **før** `DispatchQueue.main.async` til modtagerens
behandling. Den lange ventetid ligger dermed før denne registrerede
modtagelse, ikke i den efterfølgende databasebehandling. Logs adskiller ikke
OS-transportventetid, radiosituation og ventetid før delegatelevering.

Næste kodeundersøgelse skal fokusere på WatchConnectivity-baggrundslevering,
afsendelsesprioritet og genforsøg/kvitteringer. Den eksisterende kø sender
allerede nye målinger hurtigt og beskytter mod genindlevering af samme ID,
mens OS rapporterer overførslen som igangværende; denne beskyttelse må ikke
fjernes i et forsøg på at gøre leveringen hurtigere. Den konkrete test skal
ikke gentages alene for at nå en time. Ingen appkode eller ny TestFlight-
upload er ændret som led i denne loganalyse.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4269:start -->
### TestFlight 7.1.1 (4269)

- Kildecommit og tag: `87064b28e624cf1f9fe3f48c3f8579c284e1df31` / `testflight-7.1.1-4269`.
- Tests: 1007/1007 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-24T19:31:11.013219+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/0d274227-ee1b-440a-b87e-9618f21e9a5a).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4269:end -->

## Målrettet Watch-diagnostik efter den fysiske sammenligning

25. september 2026 er næste 7.1.1-kandidat klar til release-kontroller.
Kodegennemgangen fandt, at runtime-invalideringens frie fejltekst ikke indgår
i den delbare log af hensyn til privatliv, mens den strukturerede fejlkode
slet ikke blev udfyldt. Den tidligere manglende tekst beviser derfor ikke,
at watchOS leverede en tom fejl.

Kandidaten eksporterer nu tilladt fejldomæne og kode, om et fejlobjekt var
til stede, sessionens tilstand og oplyste udløbstid samt tidspunktet for
appens modtagelse af runtime-startcallbacken. Den seneste runtime-stoppost
gemmes straks lokalt med sin oprindelige build-/proceskontekst og følger
Watch-leveringsloggen, også hvis telefonens journaloverførsel forsinkes.
Fri fejltekst og userInfo tilføjes ikke til den delbare log.

Et afgrænset sammendrag måler desuden monoton forløbstid i leverede
Bluetooth-callbacks, opdelt i callbackarbejde og efterfølgende lagring af
diagnostik. Det er ikke CPU-tid eller ventetid før watchOS leverer callbacken.
Sammendraget beholder sidste og længste afsluttede callback for collectorens
levetid; der oprettes ingen ekstra timer eller logpost pr. notification.
Lokale sammendrag følger den eksisterende checkpointfrekvens. Nye felter er
valgfrie, så ældre logs fortsat kan læses uden at gøre ukendt til nul.

De otte fokuserede suites har foreløbigt kørt **502 tests uden fejl**; den
endelige releasekvittering kræver stadig hele suiten, begge simulatorbuilds
og kontrol af det af Apple valgte buildnummer. Den automatiske releaseblok
ovenfor registrerer de faktisk afsluttede kontroller og Apple-status.

**Dette er diagnostik, ikke en eftervist BLE-stabilitetsrettelse.** Efter
installation af samme nye build på iPhone og Watch er næste fysiske kontrol
én 30-minutters Watch Direct-test med skærmen i hvile det meste af tiden.
Notér start og retur til telefonen, og eksportér både den friske lokale
Watch-leveringslog og telefonens aktivitetslog. Kontroller især runtime-fejl,
callbacktider og sensor-minutter før/efter runtime-stop. En ny lang
telefonkontrol er ikke nødvendig. BLE-genforbindelse, runtime-politik,
alarmer og glukoseberegning er ikke ændret af denne kandidat.

## Fysisk Watch-/iPhone-sammenligning, 25. september 2026

4269-loggen eksporteret kl. 11:44:56 afslutter telefonkontrollen efter
brugerens overdragelse **fra Watch tilbage til iPhone** kl. 08:47.
Kontrollen er optalt efter målingstid og entydige minutintervaller, ikke efter
telefonens modtagelsestid eller den blandede 24-timers dækningsprocent:

- Watch kl. 07:48–08:47: **47/60** forventede minutmålinger.
- iPhone kl. 08:48–09:47: **60/60** forventede minutmålinger.
- Hele iPhone-kontrollen kl. 08:48–11:44: **177/177**, ingen manglende
  minutintervaller, højst to sekunder mellem målingstid og logregistrering.
  Der er ingen loggede telefon-Bluetooth-fejl eller appstarter i intervallet.
- Watch-returen blev anmodet kl. 08:47:23 og afsluttet kl. 08:47:25
  (iPhone-modtagelse kl. 08:47:26). Sidste Watch-måling og første
  iPhone-måling ligger i på hinanden følgende minutter; overdragelsen
  introducerede ikke et ekstra målehul.

Den tilhørende lokale Watch-leveringslog viste **55/55** dekodede/accepterede
målinger lagret og kvitteret af iPhone i det fulde Watch-forløb. Ti frame-gap-
hændelser omfattede 13 manglende sensor-minutter og hver en linkafbrydelse;
ingen samlings-/dekodningsfejl var registreret i disse huller. Den senere
telefonlog indeholder fortsat de samme 13 manglende minutter.

Der var 13 uplanlagte Watch-disconnects: ti `CBErrorDomain/7` og tre `/6`.
Alle skete med `scene=inactive`, `runtime=false`, og alle fulgtes af
`recoverySucceeded`. Samme proces og central fortsatte. Ingen app-iværksat
annullering er logget før den udtrykkelige retur. Den ekstra runtime blev
invalideret kl. 07:49:55 med reason `-1`, uden eksporteret runtime-fejltekst.
Det er en tidsmæssig sammenhæng, ikke bevis for normal udløbstid,
baggrundskvote, sensorfejl eller en bestemt watchOS-fejl.

**Næste udviklingsfokus:** Watch-modtagelse og genforbindelse efter
runtime-invalidering. Telefonkontrollen skal ikke gentages uden en ny
hypotese eller kodeændring. Kodegennemgangen har endnu ikke eftervist en
konkret fejl, der forklarer disse afbrydelser; en ny runtime-kæde,
baggrundsopgave-handler eller kortere timeout er derfor ikke en dokumenteret
rettelse. Afklar først callback-eksekvering og runtime-fejlen; eventuel ekstra
diagnostik skal beskrives som diagnostik. Ingen appkode, signering eller
TestFlight-upload er ændret som led i denne loganalyse.

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4268:start -->
### TestFlight 7.1.1 (4268)

- Kildecommit og tag: `eb7d20981a4c34f9a26e7a5887975e15b76804e5` / `testflight-7.1.1-4268`.
- Tests: 1006/1006 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-24T18:48:58.775113+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/84bc1f6b-db58-4080-a82e-1bb384f27739).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4268:end -->

De følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.

<!-- testflight-7.1.1-4267:start -->
### TestFlight 7.1.1 (4267)

- Kildecommit og tag: `c11e27b135565c6fd971bdd7d4dc632986806c5a` / `testflight-7.1.1-4267`.
- Tests: 1001/1001 bestået; 0 fejlet; 0 skipped. iPhone- og Watch-simulatorbuilds bestod.
- Apple-status (2026-09-24T14:58:33.150542+00:00): [Internal / Testing](https://appstoreconnect.apple.com/apps/6795645396/testflight/ios/db8aeb8a-6980-47c5-952f-ae98c7a6a286).
- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.
- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; TestFlight-uploaden løser dem ikke.
<!-- testflight-7.1.1-4267:end -->

## Opfølgning på fysisk 4268-test af Home-grafen

24. september 2026 meldte brugeren, at Home-grafen med kulhydrat/insulin stadig
giver et kort dyk ved hver åbning af den installerede 4268. 4268 ændrede ikke
grafens akseberegning eller Watch-forbindelsens BLE-genopretning.

Den efterfølgende kodegennemgang fandt to mulige årsager til dykket:
IOB/COB-kurverne indlæses asynkront, og først når de er til stede, udvides
grafens nederste akse fra den almindelige glukosegrænse til terapiområdet.
Desuden nulstillede et almindeligt Home-/forgrundsskift den beholdte øverste
akse før den asynkrone dataopdatering. Den lokale næste kandidat reserverer
terapiområdet fra første tegning, når kurverne er slået til, og bevarer den
øverste akse under almindeligt Home-/forgrundsskift. Et eksplicit dobbelttryk
på grafen kan fortsat nulstille aksen. **1007/1007** lokale XCTest-tests og
begge simulatorbuilds bestod for denne kildeændring; fysisk 4268-observation
kan ikke bevise, at kandidatens visuelle effekt er korrekt, før den er testet
på iPhone.

Der foreligger endnu ingen ny fysisk 4268-Watch-log, som viser BLE-hullerne
med de nye frame-gap-spor. De ni manglende minutter i 4267-forløbet og den
særskilte modtagerkontekst-risiko nedenfor er fortsat åbne. En grafrettelse
må ikke beskrives som en rettelse af Watch Direct-forbindelsen.

## Fysisk 4267-stabilitetstest og næste interne kandidat

24. september 2026 blev en times Libre 2 Plus EU Direct Watch-forløb sammenholdt
med den lokale Watch-leveringslog og iPhone-log. For intervallet ca. 17:05–18:05
blev 51 entydige Watch-målinger dekodet og accepteret; alle 51 blev lagret og
kvitteret af iPhone. Ni forventede sensor-minutter manglede allerede **før** en
vellykket Watch-dekodning. Flere huller lå nær CoreBluetooth-afbrydelser
(`CBErrorDomain` 6/7), men loggen kan ikke alene skelne sensor/radio/watchOS fra
delvise BLE-frames. Watch-runtime blev også invalideret i intervallet, så
timerbaseret genopretning kunne ikke forventes at køre kontinuerligt. Der blev
ikke observeret en app-iværksat annullering under de pågældende huller.

Aktivitetsloggen var tung ved åbning med mange lange Watch-poster. Skærmbilledet
"Watch transport is not reachable" beskrev øjeblikkets iPhone/Watch-transport;
en lokal Watch-log blev senere faktisk modtaget. Home-indholdets højde kunne
ændre sig ved første datavisning og ved et kortvarigt lokalt terapi-cache-miss.
Den næste interne kandidat retter disse reproducerbare UI-forløb og tilføjer
afgrænset Watch-diagnostik for fremtidige BLE-huller. Det er ikke dokumentation
for, at de ni minutters målinger nu er genoprettet; fysisk gentest er påkrævet.

En særskilt risiko er fortsat åben: Telefonen kan klassificere midlertidigt
manglende sensor-/kalibreringskontekst som terminal `invalidPayload`, hvorefter
Watch fjerner en måling fra leveringskøen. Det forekom ikke i den undersøgte
51/51-sekvens. Rettelse kræver fokuserede tests for genforsøg, uændret
kalibreringsrevision og reelt sensorskift før ændring af modtagersemantik.

Det følgende afsnit beskriver featuregrundlaget og den fysiske afprøvning;
ældre releasehistorik følger derefter.

# Apple Sundhed-bolus og kulhydrater – TestFlight 7.1.1 (4267)

Opdateret 24. september 2026. Funktionen er uploadet fra
`feature/healthkit-bolus-carbs` som **Internal / Testing** til den eksisterende
Ole Internal-gruppe i TestFlight 7.1.1 (4267). Ingen app er automatisk
installeret eller startet på fysiske enheder. 4266-tagget og dets kilde er
uændret.

- Udgivet udgangspunkt: `testflight-7.1.1-4266`, kildecommit
  `a54cbcb492d3c1c411de5ed52cc6260350c69cb9`. Featuregrenen blev
  oprettet fra den efterfølgende videreførte commit
  `74f69be9bed5bc56b5eceefaa453526683341b23`, så release- og
  statusændringerne efter 4266 blev bevaret. Den testede appkode, nye tests og
  funktionsvejledning er gemt i commit
  `eaf4773d2204a5c0330cddd4af7bf9d9315c1d06` (tree
  `decbd3298473b5a2b18ac94cd5488e107237e0a8`). Buildnummerændringen blev
  testet særskilt, committet som release-checkpoint
  `c11e27b135565c6fd971bdd7d4dc632986806c5a` og tagget
  `testflight-7.1.1-4267`, før arkiv og IPA blev bygget fra tagget.
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
  Watch-simulatorbuilds bestod. Det autoritative release-tree-`.xcresult`,
  build-, arkiv-, eksport- og uploadlogs ligger lokalt under
  `build/testflight-7.1.1-4267/` (ignoreret af Git). Featurekontrol før
  versionsændringen ligger i `build/local/healthkit-feature-final-3/`.
  De tidligere **983/983** hører alene til 4266-baselinen.
- Åbent for intern afprøvning af 4267: rigtige HealthKit-kilder, faktisk læseadgang,
  baggrundslevering, korrektion/sletning og iPhone/Watch-friskhed skal
  efterprøves fysisk. Apple afslører ikke fuld læseadgang; et
  synkroniseringstidspunkt er ikke bevis på komplette data. Kilder uden delt
  oprindelses-ID kan ikke deduplikeres sikkert
  mod en anden import alene ud fra tid og mængde. Den særskilte
  `invalidPayload`-risiko og de historisk dokumenterede full-suite-fejl nedenfor
  er fortsat åbne. Se [førstegangsopsætning og fysisk testplan](HEALTHKIT-THERAPY-IMPORT.md).

4267 fulgte den faste tag-baserede proces. Det næste TestFlight-build kræver
en ny, versionsspecifik **GO UPLOAD**. Ingen ny API-nøgle eller ændring af
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
