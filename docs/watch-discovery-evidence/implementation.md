# Afgrænset rettelse af discovery, kvittering og diagnostik

Grundlag: `a8e2bc8e1f3ac481340d26684660f5bb25b01446` (7.0.0, build 4261), uden upstream-opdatering. Arbejdsgren: `fix/watch-discovery-evidence`.

## Tre adskilte fejl

1. **Journalgenstart:** iPhone-targetets generiske `Data.append` kan fortolke den utypede newline som en Int. Det giver LF efterfulgt af syv NUL-bytes, så efterfølgende JSON-rækker ikke kunne genindlæses. Nye delimitere skal være eksplicitte UInt8. Indlæsning må kun reparere det kendte gamle format og må bevare oprindelige hændelsestider, payload-ID'er, build og proces. Historiske fejltællere slettes ikke. Dette vedrører den lokale diagnostikjournal, ikke glukosedatabasen eller den atomiske outbox.
2. **Status-/grafkvittering:** Watch sender `libreWatchDirectSuccess`, mens telefonen forventer `success`. De faktiske WCSession-adaptere bruger nu én fælles kontrakt, som understøtter begge feltnavne under protokol 1, kræver korreleret UUID og accepterede strømme og afviser modstridende svar. Ny Watch sender begge felter, så en 4261-telefon også kan læse svaret. Timeout, samtidighed og begrænset kompatibilitet håndteres fortsat af den eksisterende service. Målingers lagringskvitteringer er en separat protokol.
3. **Fund under retirement:** et verificeret sensorfund kunne forsvinde, mens den gamle peripheral endnu ventede på bekræftet disconnect. En enkelt kandidat bevares til sikker frigivelse. Den genvalideres mod faktisk observeret navn, session/sensor, central, generation, ejerskab og native tilstand, før den eksisterende connect-vej kaldes. Ingen parallel forbindelse eller ekstra unlock tillades. Kandidaten findes kun i hukommelsen; procesgenstart giver ingen påstået genfundet observation.

## Afgrænsning

Ingen ny notification-recovery-politik, callback-forsøgstæller, baggrundstimer, scanningstakt eller capability. CoreBluetooth auto-reconnect, GATT-generationsværn, friskhedsgrænser, én sensor-ejer, kalibrering, smoothing, alarmgrænser og snooze bevares. De tre fejl er eftervist i kode; de er ikke eftervist som årsagen til alle observerede målepauser.

Journalens første beskadigede råfil bevares lokalt før reparation, med en størrelsesgrænse. Den er ikke endnu en løbende journal og indgår ikke automatisk i den delbare eksport. Eksporten angiver reparerede rækker og bevaret råfils størrelse. Allerede roterede eller tidligere bortskrevne hændelser kan ikke rekonstrueres.

En gemt discovery-kandidat udløber efter 120 sekunder på det monotone ur, kontrolleret ved næste faktiske callback. Det er en konservativ gyldighedsgrænse for den gamle observation, ikke en reconnect-frist eller en timer, der kan vække watchOS. Efter udløb kræves et nyt gyldigt fund via den eksisterende scanning. Suspension kan derfor gøre kandidaten for gammel; der loves ingen fremdrift efter fristens udløb.

## Verifikation og udgivelse

Regressioner ligger i de eksisterende `WatchDeliveryEvidenceTests`, `WatchRefreshCoordinatorTests` og `LibreWatchValuePipelineTests`. Begge Codemagic-workflows inkluderer disse suites. Den eksisterende resultatkontrol sammenholder alle testmetoder i de valgte kildefiler med den faktiske xcresult; en oversprunget eller manglende test er ikke bestået.

Kør `xdrip-verify` og derefter højst én `xdrip-testflight`-udgivelse fra uændret testet SHA. Release-workflowet henter næste buildnummer fra Apple og kontrollerer Release-arkiv, indlejret Watch-app, signering, bundle-ID'er og indbygget SHA. Faktiske SHA'er, testantal, CI-ID'er, artefakter og Apple-status registreres i den særskilte udgivelsesrapport efter udførelse. Denne fil er ikke i sig selv bevis for en bestået test eller upload.

## Fysisk kontrol

Bevar eksisterende eksport og hent den lokale Watch-evidens før ny test, hvis den stadig findes. Brug samme sensor, udstyr og indstillinger, og registrér build/SHA, OS, batteri, opladning, strømbesparelse, ejer og telefontransport.

1. Kort kontrol med Watch-appen fremme og telefonen tæt på med Bluetooth tændt.
2. Separat 60-minutters vindue eksplicit på urskiven, uden debugger eller løbende appåbning. Telefonappen er i baggrunden, Bluetooth forbliver tændt. Notér start/slut og uundgåelige brugerinteraktioner.
3. Først efter slutpunktet: åbn for indsamling, anmod om lokal Watch-fil, bekræft dens modtagelse, kildebuild/proces, dækning og rotation, og eksportér telefonloggen. Registrér indsamlingens tid særskilt.

Sammenlign kun lige lange dækkede vinduer. Adskil lokale frame-intervaller, disconnect→gyldig frame, GATT-fase, proces/restoration og forsinkelse til bekræftet telefonlagring. Nye status-/grafkvitteringer skal give `pushAcknowledged`; reelle transportfejl bevares. Journalhændelser skal fortsat være læsbare efter genstart uden nye fejl fra newline-formatet.

Den specifikke BLE-observation er: gyldigt discovery mens gammel peripheral afsluttes → kandidat gemmes → gammel forbindelse bekræftet afbrudt → præcis ét connect → frisk GATT-opsætning → gyldig lokal frame, uden ny discovery eller appåbning som forudsætning. Hvis rækkefølgen ikke forekommer fysisk, er den vej endnu kun deterministisk testet.

Test kontrolleret telefon-offline/recovery og fysisk rækkeviddetab i separate vinduer. Kontrollér tilbagelevering og eksisterende test-/manglende-måling-alarm særskilt med kendte tilladelser og snooze. Brug et sikkert uafhængigt måle-/alarmgrundlag, der ikke konkurrerer om samme sensorforbindelse. Ingen falske målinger eller ændret behandling. En times test dokumenterer ikke døgnstabilitet eller en maksimal recoverytid; følg op med en længere baggrunds- og offlineprøve.
