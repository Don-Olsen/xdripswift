# Afgrænset kodevurdering til loggen 12. september 2026

Kontrolleret lokalt: `fix/watch-reading-durability-4260`, HEAD `e11a6f4d3674b0ef58f1ac5159fcf0aac7ca8c21`. Fire Swift-filer har allerede lokale ændringer. Loggens `appinfo.txt` angiver installeret build 4259; de lokale ændringer indgår derfor ikke i denne fysiske test. Ingen produktionskode, tests eller udgivelse er ændret som del af vurderingen.

**Første anbefalede adfærdsrettelse efter afstemning af den nye log:** fælles refresh-styring på Watch og sammenlægning af telefonens status/graf, med eksporterbar trigger- og leveringsdiagnostik. De 1.244 statusafsendelser er observeret; den konkrete sandsynlige kilde er en 2-sekunders timer i to MainView-instansers refresh-forløb, særskilte status-/grafrequests og samtidige reachability-opdateringer. Se kildekæden i opfølgningen nedenfor: `WatchStateModel` 79 og 557–570, `MainView` 122–127, `RootView` 26/30 og `WatchManager` 1231–1240/1280–1284. Årsagsfordelingen er en kodeunderstøttet hypotese, fordi triggeren ikke logges. Der er **ingen bevist årsagssammenhæng til BLE-afbrydelserne**.

Lagringsrettelsen og telefonens fejlagtige klassifikation af midlertidig kontekst er fortsat relevante kodefund, men loggen har ikke reproduceret tab af en konkret optaget måling. De bør ikke præsenteres som testens påviste fejlårsag eller blandes med det første afgrænsede trafikforsøg.

## 1. Den lokale kørettelse lukker et reelt, men ikke logbevist, vindue

I udgivet HEAD kaldes lokal visning og alarmer før målingen lægges i leveringskøen (`WatchStateModel.swift`, HEAD linje 740–751). Procesafbrydelse mellem disse trin kan efterlade en vist måling uden den tilsvarende køpost. Den lokale ændring kalder først `LibreWatchReadingSubmission.receive` og forsøger atomisk fillagring, før lokal visning/alarm offentliggøres (arbejdsfil linje 743–765; `LibreWatchDirectSession.swift` 2335–2357).

Ændringen bevarer målingens ID og tid, lokalt alarmforløb og genforsøg efter skrivefejl. Tilføjede tests omfatter faktisk outbox-fil, stop mellem kø- og displaycache, legacy-cache, skrivefejl og idempotent gendannelse (`LibreWatchValuePipelineTests.swift` 5871–6061). Ved vedvarende diskfejl findes flere målinger fortsat kun i RAM; displaycachen kan kun gendanne den seneste. Rettelsen er derfor ikke dokumentation for, at enhver mulig lagringsfejl kan overleves.

## 2. Et gendannelseshjørne skal med i færdiggørelsen

Den nye `restore` udvælger den viste måling før `persist(&pending)` (`LibreWatchDirectSession.swift` 2382–2403). Men `persist` kan ved en tidligere læsefejl indlæse den eksisterende fil og indflette nyere køposter (`prepareForDelivery`, 2723–2727). Hvis displaycachen indeholder A og den nu læsbare køfil indeholder nyere B, returnerer den nye kode stadig A sammen med køen, der nu indeholder B. Det afviger fra rettelsens tilsigtede gendannelse af nyeste måling efter et stop mellem kø og cache.

Tilføj en regression med første fillæsning mislykket, ældre cache og efterfølgende vellykket køindlæsning. Udvælg visningskandidaten efter den eventuelle sammenfletning. Dette er et statisk kodefund, ikke en hændelse påvist i den nye log.

## 3. Telefonens midlertidige kontekstfejl kan stadig give varigt tab

`WatchManager.refreshLibreWatchCalibrationSnapshot` nulstiller både RAM og gemt kalibrering, hvis sensor/transmitter eller kalibrering ikke kan hentes (622–647). `submitReading` samler derefter manglende afhængighed og ugyldig måling i samme `invalidPayload`-afvisning (913–920). `invalidPayload` er terminal (`LibreWatchConnectivityDeliveryPolicy` 1011–1034), og Watch fjerner posten (`WatchStateModel` 1573–1575). En midlertidig lokal opstarts-/tilgængelighedsfejl kan dermed blive til en permanent afvisning. Sletning af en ellers uændret kalibrering kan også udløse et unødvendigt nyt revisionsnummer ved næste genoprettelse (WatchManager 669–688), så forsinket historik afvises ved revisionskontrollen.

Den lokale rettelse ændrer ikke `WatchManager`. En afgrænset efterfølgende rettelse bør skelne mellem midlertidigt utilgængelig modtager (`collectorUnavailable`, allerede ikke-terminal), faktisk sessions-/sensorskift og ugyldigt payload. Bevar et tidligere snapshot under uafklaret tilgængelighed, men brug det ikke til klinisk import, før den aktuelle sensors identitet og kalibrering er verificeret. Tilføj tests for genforsøg, uændret revision ved midlertidig fejl, og fortsat afvisning ved rigtigt sensorskift/ændret kalibrering.

Denne fejlvej er en kodepåvist risiko. Den nye tests kendte telefonkvitteringer viser `liveAccepted`, `historicalInserted` og `duplicate`; den må ikke beskrives som testens dokumenterede årsag uden en faktisk afvisning i loggen.

## 4. Næste log skal kunne forbinde accept, kø og kvittering

Den lokale rettelse logger payload-ID med `Logger.info` (`WatchStateModel` 758 og 1429), men de nye linjer er ikke en del af den gemte og overførte diagnosticJournal-sti (986–1015). De eksisterende eksporterede Watch-hændelser har måletid, men ingen payload-ID for accepterede målinger (`LibreWatchDirectCollector` 1468–1480). Tilføj afgrænset, eksporterbar diagnostik for samme stabile målings-ID ved lokal accept, kølagring og kvittering/afvisning, hvis næste test skal dokumentere enhver målings vej til telefonen. Gem ingen rå sensorbytes.

## Anbefalet afgrænsning

Prioritér refresh-/statusrettelsen beskrevet øverst og i opfølgningen nedenfor. Bevar den eksisterende lokale lagringsrettelse til særskilt færdiggørelse og verificering, inklusive gendannelseshjørnet. Behandl telefonens kontekstklassifikation som en efterfølgende del af leveringsrobustheden. Lad BLE-genforbindelsens adfærd være uændret, indtil loggen påviser en konkret fejl i appens beslutning; runtime-udløb og periodiske systemgenforbindelser er ikke alene bevis for en appfejl.

Ingen Swift/Xcode-test er kørt her: `swift` og `xcodebuild` er ikke tilgængelige i denne Windows-shell. De lokale testændringer skal først verificeres på Mac/Codemagic for den præcise commit, med både telefon- og Watch-build. Dette dokument er statisk review, ikke en godkendt udgivelse.

## Opfølgning: konkret kandidat til de 1.244 statusafsendelser

Efter samlet afstemning viser den nye log ikke et konkret tilfælde af optaget, derefter tabt måling. Det ændrer prioriteringen: begrænsning af den observerede overtrafik er et mere direkte næste adfærdsforsøg end at beskrive den forebyggende lagringsrettelse som løsningen på netop denne test.

Kildekæden i HEAD er konkret:

1. WatchStateModel har en timer hvert **2. sekund** (79).
2. `MainView` modtager timeren og beder om en opdatering, når `updatedDate` er over **5 sekunder** gammel (122–127). Der er ingen lokal kontrol af valgt tab, sceneaktivitet, igangværende forespørgsel eller minimumsafstand mellem forsøg.
3. `RootView` indeholder **to** `MainView`-instanser, normal og AGP (26 og 30). Hvis begge er monteret og modtager timeren, kan begge bede om de samme data. Loggen beviser ikke deres faktiske monterings-/timerstatus på hvert tidspunkt.
4. Hver `requestWatchStateUpdate` sender særskilt `status` og `bgReadings` (WatchStateModel 557–570), hvis WatchConnectivity i dét øjeblik melder reachable. Hvert svar udløser sin egen telefonafsendelse (WatchManager 1231–1240). Statusforespørgslen sender desuden Libre-sessionskontekst.
5. Telefonens reachability-callback sender også status+graf samt Libre-sessionskontekst (1280–1284), uden sammenlægning med de samtidige forespørgsler.
6. Alle disse kald får ny `generatedAt` og generation, uanset om det egentlige indhold er ændret (241–254, 294, 304), og sender straks, hvis reachable fortsat er true (452–468). Der er ingen fælles send-gate eller dæmpning efter fejlsvar.

Dette er en konkret mulighed for serier på 4–5 tætte statusafsendelser og gentagelser, når reachable flapper eller forespørgsler ikke giver et brugbart svar. Logeksemplet 12:30:17.256–12:30:17.803 har 11 sends på 547 ms (`xdriptrace.0.log` 16982–17002), med en blanding af statusfejl og Libre-sessionsfejl. Det er foreneligt med kodekæden, men eksporten logger hverken caller/trigger eller payloadtype; man kan ikke tilskrive samtlige 1.244 kald til netop timeren eller de to tabs.

En selvopretholdende alarm-settings/status-echo-løkke er **ikke påvist**. Uændret alarmkonfiguration returnerer den tidligere revision (`AlertManager` 1166); Watch kalder kun readiness callback, når revisionen ændres (`NotificationController` 128–140); telefonens alarmændringsobserver sender sessionskontekst (WatchManager 377–384), ikke direkte den loggede status/graf-afsendelse. Modtagelse af et identisk alarmforslag udfører stadig lokalt gemmearbejde, men er ikke i sig selv bevis for de 1.244 sends.

Afgrænset næste rettelse: saml status-/grafforespørgsler i modellen med én fælles igangværende forespørgsel og forsøgstid, begræns automatiske forespørgsler til den aktive brugerflade, og saml samtidige status-/grafsends fra telefonen. Seneste applikationskontekst bevares, og reelle ændringer, manuelt refresh, genforbindelse, ejerskifte og alarmkvitteringer skal fortsat komme frem. Log trigger, payloadtype og sammenlagte/udsatte sends. Verificér specifikt begge tabs, manglende svar, gentagne reachability-callbacks og ny måling under et ventende refresh. Det er en målrettet trafikrettelse; den er ikke dokumenteret som en løsning på CoreBluetooth-afbrydelserne.
