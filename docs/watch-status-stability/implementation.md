**Afgrænset stabilitetsændring: Watch-status og målingsbeviser**

Ændringen samler status-/graftrafik og gør den eksisterende målingslevering efterprøvbar. Den ændrer ikke glukoseberegning, kalibrering, smoothing, alarmgrænser eller sensorens genforbindelsesstrategi. Bluetooth-modtagelse, WatchConnectivity, lagring, visning og alarmer behandles fortsat hver for sig. Mindre WatchConnectivity-trafik er ikke dokumentation for færre sensorpauser.

**Fælles opdateringsforløb**

`RootView` vælger de synlige databehov og fortæller `WatchRefreshCoordinator`, om scenen er aktiv. De to MainView-faner og BigNumberView benytter samme koordinator. Skjulte faner starter ikke egne requests. UI-timeren opdaterer kun lokal alder, farver og nedtælling; grafens højre kant flyttes lokalt højst én gang i minuttet, så gamle målinger ikke bliver stående ved en tilsyneladende aktuel kant. Lokal AGP-projektion genbruges, indtil profil eller synligt datointerval ændres.

| Regel | Implementeret værdi |
| --- | --- |
| Samling af samtidige ønsker, begge ender | 250 ms |
| Aktiv Watch-request | Højst én samlet request for status, graf og eventuel AGP |
| Watch-request/reply-timeout | 8 sekunder |
| Watch-retry efter fejl | 5, 10, 20, 40, 80, derefter højst 120 sekunder |
| Status- og grafcache | 60 sekunder; reelle dataændringer kan opdatere tidligere |
| AGP-cache | 15 minutter samt kontrol af faktisk dataændring, dag og relevant visningsinterval |
| Telefonens arbejde pr. opbygning | Tokenbeskyttet timeout på 5 sekunder |
| Telefonens push | Ét aktivt forsøg; 8 sekunders timeout; stigende ventetid op til 120 sekunder |
| Fejlet application context | Beholdes lokalt; genforsøg med stigende ventetid op til 120 sekunder |
| Kompatibilitet med ældre modpart | Højst én legacy-batch pr. 60 sekunder |

Lokale frister bruger et injicerbart monotont ur, som i produktion er `ProcessInfo.processInfo.systemUptime`. Watch-forsøg, modtaget telefonstatus og modtaget telefongraf har selvstændig tilstand. Målingens alder indgår ikke i pollingbeslutningen. Scenen skal være aktiv for at udføre planlagt polling eller retry; ved genoptagelse kontrolleres en gammel deadline igen. Ingen timer hævder at kunne vække en suspenderet app. Telefonens tilbageholdte push/context genprøves ved faktiske request-, data-, aktiverings- og reachability-hændelser.

**Protokol og kompatibilitet**

Den nye Watch sender én `sendMessage` med `replyHandler`: `requestWatchUpdate="snapshot"`, `watchRefreshProtocol=1`, et UUID i `requestID`, `streams` og `knownContentIDs`. En AGP-request medtager desuden `visibleStartDate`, `visibleEndDate` og `agpRequestID`.

Telefonens samme reply indeholder protokolversion, det samme request-ID, `contentIDs`, `unchangedStreams` og de nødvendige `status`-, `bgReadings`- og `agp`-ordbøger. Et stadig gyldigt, allerede autoritativt sessionssnapshot kan medfølge. Uændrede strømme kan udelades fra svarets indhold, når Watch oplyste den samme kendte indholdsidentitet. Det opdaterer transportens cachefrist, ikke målingens tidsstempel.

Et svar anvendes først efter kontrol af request-ID og deadline. Sene eller dobbelte callbacks kan ikke afslutte et nyt forsøg. Snapshot-valideringen afviser ældre generationer, ældre målinger og ændret indhold under samme revision. En identisk context, der ankommer før den interaktive push, kan kvitteres idempotent uden endnu en skrivning eller visningsopdatering. Moderne AGP anvendes kun fra det korrelerede svar; en gammel context kan ikke udskifte profilen.

Reelle uopfordrede opdateringer anvender `watchSnapshotPush=1` og `pushID`. Watch kvitterer efter lokal validering med samme ID, `success`, `acceptedStreams` og `rejectedOrSupersededStreams`. Målingernes lagringskvitteringer har fortsat deres særskilte protokol.

En 4259-telefon afviser den nye overload med `success=false` uden protokolversion. Det udløser én overgang til begrænset legacy-status/graf/AGP for resten af processen. Timeout og generiske transportfejl udløser ikke fallback. En ny telefon genkender de gamle eksplicitte request-typer og sender en samlet legacy-opdatering uden reply. En gyldig moderne request viser, at modparten understøtter den nye protokol. Legacy-afsendelse uden reply registreres som ubekræftet indsendelse, ikke som modtagerens lagring.

**Indhold, autoritet og friskhed**

`WatchPhoneRefreshService` samler ønsker før databaseopslag, grafberegning, serialisering og afsendelse. SHA-256-identiteten beregnes af semantisk indhold og sessionsscope. Genereringstid, valideringstid, transportgeneration, request-ID, ren sensoralder og den lokale AGP-projektion skaber ikke alene nyt indhold. Faktiske måletider, værdier, sensorstart og relevante indstillinger bevares. Nye ændringer under en opbygning beholdes til næste behandling.

Telefonens `AGPCalculationGate` tillader desuden kun én faktisk statistikberegning ad gangen. Den eksisterende OperationQueue-beregning kan ikke afbrydes blot ved en transporttimeout. Porten frigives derfor først ved beregningens rigtige callback; nye requests kan få deres status/graf og et genprøvbart AGP-resultat uden at starte flere beregninger eller opbygge en ny ventekø.

`snapshotValidatedAt` angiver genkontrol af et ellers uændret snapshot. Den erstatter ikke `generatedAt` eller målingernes tidsstempler. `WatchPhoneSnapshotStore` bevarer eksisterende målingsgrænser; urets direkte værdi og historik er fortsat autoritative, når uret ejer sensoren. Telefonens graf kan da valideres og caches uden at erstatte direkte Watch-data. Appens og komplikationens eksisterende kliniske friskhedsmarkeringer er ikke udvidet.

`updateApplicationContext` bevares. Delvise opdateringer flettes på hovedkøen med den eksisterende context, herunder indholds-ID'er, så status ikke fjerner sessions-, kalibrerings- eller alarmfelter. En mislykket status/context-opdatering beholdes til en senere mulighed.

`LibreWatchHandoffSnapshotCache` genbruger kun et semantisk gyldigt snapshot. Reelle ændringer af ejer, sensor, unlock-tæller, kalibrering, alarmkonfiguration eller delegation får fortsat en monoton autoritativ revision. Watch gemmer det fulde typede accepterede snapshot og accepterer samme revision som dublet alene ved identisk indhold. Almindelig polling opretter ikke en ny overdragelse. Målinger, modtagerkvitteringer og reelle kontrolændringer benytter deres eksisterende særskilte veje og afventer ikke grafens backoff.

**Lokalt målingsbevis**

Et stabilt payload-ID dannes én gang efter dekodning og følges gennem accept/afvisning, bekræftet atomisk outbox-skrivning, afsendelsesforsøg, telefonmodtagelse, faktisk telefonlagring og kvittering på Watch. En dekodningshændelse er ikke en lagringskvittering. Build/SHA, installations- og procesidentitet tilhører den enhed, hvor hændelsen opstod.

Watch-modtagelsestid, telefonregistrering og eventuel kendt sensortid holdes adskilt. Sensorens minut-tæller er ikke et opfundet kalenderstempel. Eksporten angiver, at enhedernes urforskel er ukendt. Den separate journal er begrænset til 24 timer, 4.096 hændelser og 3 MiB; tællere checkpointes ved arbejdslejligheder højst én gang i minuttet. Rå sensorbytes, dekrypteringsmateriale og glukoseværdier kopieres ikke til denne journal. Journalfejl går ikke tilbage i den kliniske outbox.

Manuel supporteksport kan anmode om Watch-journalen som en separat WC-filoverførsel. Eksporten skelner mellem anmodning, modtaget fil og faktisk dækningsperiode og oplyser rotation, skrivefejl og manglende materiale. En gammel Watch-fil præsenteres med sin egen eksporttid. Rotation af journalhændelser er ikke lig med tab af glukosemålinger.

**Verifikation og resterende usikkerhed**

Ved dokumentets oprettelse er de nye testmetoder **klargjort, men endnu ikke udført på Xcode** i `WatchRefreshCoordinatorTests`, `WatchPhoneRefreshServiceTests`, `WatchSnapshotSemanticsTests` og `WatchDeliveryEvidenceTests`. De nye suites indgår i begge Codemagic-workflows sammen med relevante eksisterende tests. Det faktiske antal udførte tests skal læses fra den konkrete Xcode-kørsels resultatmanifest; antallet af metoder i kildekoden er ikke et testresultat.

Testene benytter produktionskoordinatorer, wire-format, receiver-validering, atomisk outbox og isolerede testlagre. Sammenkoblede telefon-/Watch-tests dækker samling før databasearbejde, uændret indhold, ændringer under igangværende arbejde, pushes under request-backoff, context før push samt afvisning af ugyldige dubletter. Andre tests dækker timeout uden callback, sene svar, genoptagelse, legacy, lokale skrivefejl, genstart, tabt kvittering og ufuldstændig journaleksport. Syntetiske data bruges alene i tests.

Faktiske Xcode-resultater og senere build-/SHA-status skal hentes fra den konkrete CI-kørsel, testmanifest og release-manifest. En kodegennemgang på Windows er ikke en bestået Xcode-test. Release-manifestet kontrollerer vores eget arkiv, indlejret Watch-app, bundle-ID'er, SHA og signering før eksport/upload; uploadsucces og Apples efterbehandling er forskellige trin.

Færre fejl eller mindre trafik er endnu ikke målt på fysisk hardware. Alarmlyd, visning, tilbagelevering, længere reel baggrundstid og offline-efterlevering kræver [den fysiske testplan](physical-validation.md). En times prøve kan ikke dokumentere døgnstabilitet. [Apple-afklaringen](apple-background-assessment.md) beskriver den dokumenterede platformadgang og det separate, usendte supportudkast. Statusændringen giver hverken ny baggrundsrettighed eller ubegrænset eksekveringstid.
