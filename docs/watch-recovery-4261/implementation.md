# Watch-recovery efter build 4260

## Grundlag og evidens

Arbejdet starter fra `fix/watch-status-delivery-stability` på `a3c9c8c805bdb9ddc4a13c786a1d682ee9ba7966`, version 7.0.0 (4260), og fortsætter på `fix/watch-recovery-callback-4261`. Status-/grafkoordinatoren, glukoseberegningen, den atomiske målings-outbox, kvitteringer, kalibrering og alarmernes eksisterende ansvar er bevaret.

Det omtalte `Komprimeret arkiv(5).zip`, `xdrip_4260_dobbeltkontrol_2026-09-12.md`, sekvens 6297–6356 og den lokale 4260-`WatchDeliveryEvidence.json` findes ikke i arbejdsområdet. Den eneste fundne zip er rå-eftervist som build 4259/SHA `e11a6f4d3674b0ef58f1ac5159fcf0aac7ca8c21` og er ikke brugt som 4260-bevis. 4260-tidslinjen nedenfor er derfor oplyste kontrolpunkter, ikke en ny rålogverifikation:

- Watch-ejerskab: 16:32:41.553–17:48:13.864 CEST.
- Sidste og næste registrerede Watch-modtagelse: 17:14:49.413549 og 17:32:50.088992, et hul på 1.080,675443 sekunder.
- Oplyste `willRestoreState`-hændelser omkring 17:14:49 og 17:32:14, et behandlet legacy-disconnect omkring 17:15:50 og afsluttende `didConnect → services → characteristics → notifications → unlock → valid frame` omkring 17:32:47–17:32:50.

Hullet er et hul mellem de tilgængelige modtagelsestider. Det beviser ikke et crash, sensorstop, tab af alle lokale frames, baggrundskvote eller at 4260 generelt er dårligere end 4259.

## Efterviste kodefejl og rettelse

Kodegennemgangen og de deterministiske regressionssekvenser viser konkrete fejl i 4260-koden. De viser endnu ikke, hvilken af dem der forårsagede det fysiske 18-minutters forløb.

1. Legacy-`didDisconnect` udsatte hele tilstandsovergangen 0,1 sekund på hovedkøen. Suspension før work item'et eller en ny `didConnect` først kunne efterlade den gamle setup-fase og GATT-epoke. Legacy-callbacken behandles nu i det leverede CoreBluetooth-callback uden timerafhængighed. Dobbelt-callbacks afvises fortsat. Et moderne callback med timestamp før den nye `didConnect` afvises som gammelt, når CoreBluetooth stadig viser den nye peripheral som forbundet. Hvis den allerede står som afbrudt eller forbindende, behandles recovery, fordi modtagelsestidspunktet for `didConnect` kan ligge efter et hurtigt reelt brud, når hovedkøen har været belastet.
2. En ny `didConnect` kunne ankomme, mens tilstandsmaskinen stadig stod i den gamle forbindelses `services`/`characteristics`/`notifications`/`unlock`/`receiving`-fase. Den eksplicitte `acceptDidConnect`-overgang pensionerer nu den gamle GATT-epoke og starter en frisk connection/setup-epoke. `beginSetup` udfører selve faseskiftet og roterer kun igen ved en udtrykkelig serviceinvalidering; det afgør ikke selv, om der kom en ny forbindelse. Et almindeligt connect-retry nulstiller ikke længere disconnect-deduplikeringen, før CoreBluetooth faktisk leverer `didConnect`.
3. Restoration accepterede tidligere én unavngiven peripheral og udfyldte selv det forventede navn. Den forventede NFC-identitet kunne dermed fremstå som observeret identitetsbevis. Restoration kræver nu præcis ét faktisk observeret navnematch; uafklaret, forkert eller tvetydig identitet afvises og går tilbage til den eksisterende sikre scanvej uden at ændre den gemte sensorsession.
4. Et gendannet GATT-objekttræ kunne overleve en restoration, hvor peripheral ikke længere var forbundet. Restored services/characteristics genbruges nu kun for en peripheral, som CoreBluetooth faktisk gendanner som `.connected`. Efter disconnect, ny forbindelsesgeneration eller serviceinvalidering kasseres gamle objektreferencer, og opsætningen starter igen ved relevant service discovery. `didModifyServices` reagerer kun, når den ugyldiggjorte service er det aktuelle objekt; andre og gamle callbacks afvises.
5. `didDiscoverServices` har ikke et request-ID. Hvis en ny `didConnect` afbryder en uafsluttet `services`-fase på samme `CBPeripheral`-objekt, kan det første senere callback derfor ikke knyttes sikkert til den gamle eller nye discovery. Kun i denne tvetydige sekvens afvises det første callback, hvorefter appen udsteder præcis én ny `discoverServices`; den næste callback behandles af den nye GATT-generation. Almindelige serviceopslag forbliver enkeltstående.

Der er ikke indført ekstra scanningstimer, gentagne unlocks, kunstig runtime eller en ny background-task-handler. De tilgængelige 4260-kontrolpunkter dokumenterer ingen konkret leveret systemopgave, som appen afsluttede for tidligt.

## Diagnostik til den afgørende fysiske test

Diagnostikken registrerer nu et pseudonymt proces-ID, centralinstans-ID, et særskilt proceslokalt forbindelsesobservations-ID, GATT-epokens `generation`, GATT-fase og afvisningsgrund. ID'et oprettes, når den aktuelle peripheral leverer `didConnect`, eller når CoreBluetooth faktisk gendanner den som `.connected`, og bevares gennem services, characteristics, notification, unlock og frames i samme proces. Et processtop kan derfor dele den samme underliggende radioforbindelse i to observations-ID'er; proces- og central-ID gør denne usikkerhed synlig. Serviceinvalidering kan rotere GATT-epoken uden at opfinde en ny forbindelsesobservation. Recovery-episodens `attemptID` forbliver separat. Rå callbacks fra en retired, fremmed eller tidsstempel-afvist peripheral får ikke den aktuelle forbindelses ID. Legacy-`isReconnecting` mærkes som `peripheralStateObservation`; Apples moderne callback mærkes særskilt som `modernCallback`. Kendte ældre værdier som `CBPeripheralState(rawValue: 2)` normaliseres til `connected` i den korte rapport i stedet for `unknown`.

GATT-handlinger og callbacks er separate hændelser. Callbackens indgangstilstand indfanges før fremdrift, mens den eksisterende journal-/outbox-registrering køres efter callbackens nødvendige tilstandsovergang eller GATT-kald. Hændelser fra samme callback samles i én journal- og outbox-fillagring. Den fælles staging/replay-overgang bevarer stabile ID'er og reparerer et processtop eller en skrivefejl mellem journalen og outboxen uden dubletter. Det gør det muligt at skelne et aldrig afsendt kald, en manglende callback, en afvist gammel callback og et faktisk disconnect uden at gøre GATT-fremdrift afhængig af journal-I/O. Der logges ingen rå sensorbytes, nøgler, tokens, serveradresser eller glukoseværdier i de nye delbare felter.

## Afgrænsning mod platformen

Apples offentlige watchOS-model giver budgetterede Bluetooth-hændelser og korte eksekveringsmuligheder; den lover ikke ubegrænset minutvis CGM-modtagelse. `willRestoreState` beviser restoration, ikke årsagen til procesgenstart, og `CBErrorDomain/7` er ikke i sig selv en navngiven baggrundskvoteadvarsel. Den historiske 2019-oplysning om `com.apple.developer.bluetooth-central-background` beviser hverken aktuel adgang eller godkendelse for dette team. Den opdaterede Apple-vurdering og DTS-henvendelsen ligger i `docs/watch-status-stability/apple-background-assessment.md`; henvendelsen er ikke sendt.

## Regressioner og leverancestatus

Nye regressionscases dækker synkron legacy-behandling og deduplikering, frisk generation gennem gentagne setup-forløb, det afgrænsede service-callback-hegn, connected kontra disconnected restoration, gammel GATT-graf, præcist identitetsmatch, serviceinvalidering efter objektidentitet, stabile proces-/central-/forbindelsesfelter, journal→outbox-replay efter skrivefejl og normalisering af ældre peripheral-state-format. De kører de delte produktionsmodeller, som Watch-collectorens callbacks anvender. Watch-builden giver compile-integration af de konkrete delegate-metoder og CoreBluetooth-signaturer; den simulerer ikke CoreBluetooth-runtime eller watchOS-suspension.

Test-first commits er `acdaa9b425b38aa31ca7b3e43e984a940e0c70da` og `ac835ab171b7ea223f74c9b31ad9372968a29703`. Faktisk slut-SHA, Xcode-kommandoer, udførte testtal, arkivkontrol, buildnummer, upload og Apples status registreres i den ydre udgivelsesrapport, så den testede app-SHA ikke ændres bagefter for at udfylde dynamiske resultater.

En grøn CI-kørsel dokumenterer kode- og compile-kontrol; release-workflowet skal desuden dokumentere arkiv, indlejret Watch-app, bundle-ID'er, signering og indbygget SHA. Kun den fysiske test kan afgøre, om rettelsen ændrer det observerede baggrundsrecovery-forløb. Builden kan derefter betegnes som klar til fysisk validering, ikke som dokumenteret døgnstabil.
