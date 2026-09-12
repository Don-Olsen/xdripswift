# Fysisk test af Watch-recovery

## Før testen

Brug samme Libre 2 Plus EU-sensor, Watch, iPhone, alarmgrænser, snooze-status og behandlingsindstillinger i begge forløb. Brug ingen debugger. Registrér appversion/build/SHA, iOS/watchOS-versioner, hardware, batteriniveau og opladning, Low Power Mode, telefonens Bluetooth, afstand/reachability og eventuelle brugerinteraktioner. Watch skal eje sensoren under de sammenlignede vinduer; tidspunktet for overdragelse registreres.

Bevar eksisterende telefon-zip og lokal Watch-evidens før testen som separate, uændrede filer med SHA-256. Notér filernes reelle første/sidste Watch-tid, build/SHA, eksporttid, proces-/central-ID'er, sequence-dækning og rotation. Manglende eller allerede roteret materiale registreres som manglende og må ikke rekonstrueres som observerede hændelser.

Brug et sikkert, uafhængigt måle- og alarmgrundlag under udviklingstesten, som ikke konkurrerer om den samme sensor-Bluetooth-forbindelse. Udviklingsappen må ikke være eneste alarmgrundlag. Ændr ikke behandling, og fremkald ikke høje/lave værdier.

## A. Kontrol med appen fremme

1. Start et præcist dokumenteret 10-minutters kontrolvindue med Watch-appen frontmost under den eksisterende self-care-session og telefonappen i baggrunden. Ti minutter er den dokumenterede øvre frontmost-varighed for denne sessionstype; forlæng ikke testen med genåbninger. Lad telefonens transportforhold være stabile og registrer enhver faktisk ændring i Bluetooth/reachability.
2. Brug uret normalt, men åbn ikke en debugger, skift ikke sensor-ejer og ændr ikke indstillinger. Hvis watchOS afslutter frontmost-sessionen tidligere eller ændrer scene/runtime-tilstand, stopper kontrolvinduet dér og den faktiske varighed registreres.
3. Stop vinduet før eksport. Eksportér derefter den lokale Watch-fil med den eksisterende funktion og telefonens samlede log. Filindsamlingen hører ikke til selve testvinduet.

## B. Sammenhængende baggrund på urskiven

1. Genskab samme dokumenterede startbetingelser. Start et nyt 60-minutters vindue og gå eksplicit tilbage til urskiven.
2. Lad uret blive på urskiven i alle 60 minutter uden debugger, løbende åbning af appen eller andre handlinger, som gør den frontmost. Notér uundgåelige brugerinteraktioner og systemhændelser eksternt uden at åbne appen.
3. Først efter slutpunktet åbnes appen én gang for at anmode om og hente den lokale Watch-evidens. Registrér anmodningstid, telefontransport, modtagelsestid og resultat. Gem filen uændret med SHA-256 samt telefonloggen og eventuelle faktiske `.ips`-, watchdog-, jetsam- eller sysdiagnosefiler.

Rå tællere sammenlignes kun for lige lange og faktisk dækkede vinduer: kontrolvinduet sammenlignes med et lige langt udsnit af baggrundsforløbet, mens hele 60-minuttersforløbet rapporteres særskilt. Hvis journalen ikke dækker hele vinduet, rapporteres den kortere dækningsperiode; resultater skaleres ikke til opdigtede hændelser.

## Hvad der måles

For hvert vindue rapporteres separat:

- sidste/næste lokale frame-modtagelse, største måleinterval og tid uden aktuelle Watch-data;
- rå disconnect-callbacks, deduplikerede accepterede disconnects og faste recovery-episode-ID'er;
- proces-ID, central-ID, proceslokalt forbindelsesobservations-ID, separat GATT-`generation`, recovery-`attemptID`, scene/runtime og eventuel `willRestoreState`;
- GATT-fasen ved bruddet og parrene `discoverServices`, `discoverCharacteristics`, notification og unlock med både kald, callback, fejl og afvisningsgrund;
- callbackkilden for reconnect: Apples moderne værdi eller appens observation af `CBPeripheral.state`;
- rækkefølgen mellem callback, tilstandsovergang/GATT-kald og efterfølgende lokal journalisering samt eventuelle navngivne systembudgetadvarsler;
- stabilt payload-ID gennem Watch-lagring, sendeforsøg, telefonmodtagelse, faktisk `phoneStored`-resultat og Watch-kvittering samt forsinkelsen mellem leddene.

`duplicate` ved telefonlagring er ikke en tabt måling. Telefonens `receiptTime` måler transport og erstatter ikke Watch-eventets egen tid eller sensorens egen måletid. Manglende og forsinkede målinger rapporteres som forskellige kategorier.

## Observationen der afgør rettelsen

Ved et disconnect i forløb B skal journalen vise, at callbacken behandles uden timerafhængighed, at en ny `didConnect` får et nyt proceslokalt forbindelsesobservations-ID og en frisk GATT-generation, og at ingen gammel service/characteristic-callback accepteres. Ved procesrestoration må proces-/centralgrænsen ikke fejlagtigt læses som bevis for en ny fysisk radioforbindelse. Efter restoration af en faktisk forbundet og entydigt identificeret peripheral må gyldige restored objekter bruges; efter et reelt disconnect skal kæden begynde med ny discovery og derefter nå `services → characteristics → notifications → unlock → valid frame` uden at Watch-appen åbnes først.

Hvis en sådan naturlig recovery forekommer og gennemføres før appåbning, er det fysisk evidens for den rettede vej. Hvis der ikke forekommer et disconnect/restoration i de 60 minutter, viser testen kun fravær af en observeret regression; den validerer ikke recovery-rettelsen og skal følges af et længere baggrundsforløb. Der loves ingen maksimal genforbindelsestid.

Hvis pausen gentager sig, klassificeres den ud fra sidste dokumenterede led: disconnect uden ny forbindelse, `didConnect` uden GATT-kald, GATT-kald uden callback, afvist gammel generation, notification/unlock uden gyldig frame eller gyldig lokal frame uden telefonlagring/kvittering. Appåbningens tidspunkt markeres særskilt, så en bedring efter åbning ikke bruges som bevis for proces-, platform-, radio- eller sensorårsag.

## Tilbagelevering og alarmer

Efter hvert målevindue kontrolleres tilbagelevering til iPhone som et særskilt forløb: ejerændring, Watch-stop, telefonens genoptagelse og bekræftet lagring. Test derefter appens eksisterende lokale testalarm og manglende-måling-alarm med på forhånd kendte notification-/lyd-/haptic-tilladelser og kendt snooze/Snooze All-status. Brug den indbyggede sikre testvej; indsæt ingen falske glukosemålinger og ændr ikke alarmgrænser for at fremkalde et fysiologisk udfald.

En bestået 60-minutters prøve er første fysiske kontrol. Døgnstabilitet, offline/recovery over længere tid og faktisk alarmberedskab kræver efterfølgende særskilte forløb.
