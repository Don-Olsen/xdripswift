## Selektiv release-cacheoprydning, 26. september 2026

Build 4275 blev frisk bekræftet via Apples officielle API som VALID,
INTERNAL_ONLY og IN_BETA_TESTING med Ole Internal-tilknytning kl. 08:36 UTC.
Den autoriserede oprydningskommando afviste derefter sletning, fordi Xcode
og SWBBuildService stadig kørte. **Ingen projekt-/releasefiler blev slettet;
frigivet plads er 0 byte.** En skrivebeskyttet optælling fandt cirka 11,7 GiB
kendte cachefiler i de afsluttede builds 4266, 4268–4273. Hele 4275 og det
ufuldendte 4274-forsøg samt øvrige uklare/historiske mapper er bevaret.
Detaljer, præcise stier og valideringslog ligger i den ignorerede lokale mappe
`build/release-automation/cleanup/20260926-safety-review/`.

Release-automationen forsøger nu selektiv oprydning efter en fuldført
Internal / Testing-statuscommit/push. Den kræver frisk Apple-status,
bevarede arkiver/IPA/testresultater, proces- og åben-filkontrol samt fælles
værtslås med buildscriptet. Hele DerivedData slettes aldrig: logs, JSON,
dSYM, produkter, testmateriale og ukendte filer bevares. Git og bevarede
releasefiler kontrolleres før/efter; hver slettet cachefil registreres.
Se den fulde regel og genoptagelseskommando i MAC-BUILD.md.

26 isolerede oprydnings-/låse-/proceskontroller, 28 release-tests,
12 processing-tests og 40 Apple-klienttests samt de eksisterende
self-tests bestod. Intet Xcode-/TestFlight-build eller upload blev startet.
Dette ændrer kun lokal release-automatisering, ikke den installerede 4275-app.
Oprydningen afventer lukning af Xcode; kør derefter `cleanup --apply`,
ikke en ny `release`, for at gentage alle kontroller og frigive cachepladsen.

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
