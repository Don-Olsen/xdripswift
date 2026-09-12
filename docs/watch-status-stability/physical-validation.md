# Fysisk kontrol af status og målingslevering

Denne plan skal udføres på fysisk iPhone og Apple Watch med den præcise nye TestFlight-build/SHA registreret på begge enheder. Xcode-tests dokumenterer ikke den målte forbedring. Builden er klar til fysisk validering, når udgivelseskontrollerne er bestået; den er ikke derved dokumenteret til ubetinget selvstændig døgnbrug.

## Forberedelse

Bevar sensor, glukoseberegning, kalibrering, smoothing, integrationsvalg, alarmgrænser og behandlingsindstillinger. Ingen falske målinger i historikken. Brug et uafhængigt, kendt alarmgrundlag under testen; udviklingsappen må ikke være det eneste. Fremkald ikke højt/lavt blodsukker og ændr ikke behandling for at teste alarmer.

Registrér dato/tidszone, build/SHA på begge enheder, OS/hardware, sensorens pseudonyme session, ejer, komplikation/urskive, batteri og opladning, strømbesparelse, telefonens Bluetooth og netforhold, WatchConnectivity activation/reachability samt synlige alarmtilladelser. Registrér alert/sound-status og Focus/lydløs-tilstand, hvor tilgængeligt; én `authorized`-værdi er utilstrækkelig. Notér snooze/Snooze All og den faktiske alarmansvarlige enhed. Synkroniser ikke manuelt ure under et vindue; skriv kendt klokkeforskel/usikkerhed ned.

Start en lokal Watch-supporteksport før og efter hvert vindue, og hent den efter genoprettet transport. Notér eksport-ID, faktisk første/sidste hændelse, rotation, skrive-/eksportfejl og om Watch-filen faktisk kom med. En telefonrapport uden Watch-fil er ufuldstændig, også selv om telefonloggen ser rolig ud. Eksportér først efter det uforstyrrede vindue, så åbning af appen ikke ændrer baggrundstesten.

## Tre adskilte vinduer

Brug **60 minutter i hvert scenario**, separat start/slut registreret på samme tidsgrundlag. Gentag samme scenario og betingelser ved en egentlig før/efter-sammenligning. 4259-kontrollens 61:57,973 var et blandet vindue med telefon-Bluetooth slukket og mange brugeraktiveringer; den må ikke betegnes som en ren A-, B- eller C-baseline. Sammenlign tællinger over lige lange afgrænsede vinduer eller angiv forsøg/minut og præcis eksponering.

| Scenario | Reproducerbare trin | Bevar og notér |
|---|---|---|
| A: telefon nær | Telefon tæt ved, telefon-Bluetooth tændt, telefonappen i baggrunden. Overdrag sensoren til Watch, bekræft ejerskab og første aktuelle Watch-værdi. Brug uret normalt i 60 minutter. | Notér hver appåbning, faneændring, manuel refresh og eventuel skærmfejl. Hold afstand/batteriforhold ens mellem sammenligninger. |
| B: faktisk baggrund | Efter bekræftet Watch-ejerskab trykkes eksplicit tilbage til urskiven. Start et sammenhængende 60-minutters vindue uden debugger og uden løbende appåbninger. Telefonen er tæt på med Bluetooth tændt. Åbn først appen og eksportér efter sluttid. | Notér præcist Crown/app-exit og første genåbning. Dette overstiger self-care-vinduet og er noget andet end sænket håndled med appen frontmost. `inactive`, `background` og faktisk suspension skal rapporteres særskilt; manglende kodeeksekvering alene beviser ikke suspension. |
| C: transport utilgængelig | Med sensoren ejet af Watch: 15 minutter normal telefontransport, 30 minutter kontrolleret utilgængelig telefontransport, derefter 15 minutter genetableret transport. Urets Bluetooth til sensoren skal forblive tændt. Dokumentér den valgte metode og observeret reachability/fejl. | Ændr kun telefonens transportforhold, aldrig Watch-Bluetooth for at simulere offline. Telefon-Bluetooth alene dokumenterer ikke Wi-Fi-tilgængelighed. Hvis transport stadig virker, er offline-delen ikke bestået som testbetingelse. Kontrollér efterlevering efter genetablering; forlæng opfølgningen separat, hvis køen endnu ikke er kvitteret. |

Apples self-care er en frontmost-session på højst ti minutter, og eksplicit app-exit afslutter den; derfor er B et særskilt forsøg. [Using extended runtime sessions](https://developer.apple.com/documentation/WatchKit/using-extended-runtime-sessions). Apples WatchConnectivity-sample anbefaler fysisk udstyr og understreger, at debuggeren ændrer suspension. [Transferring data with Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity).

## Fælles måleskema

For hvert scenario angives start/slut, ejerskabsinterval, faktisk journal-dækning og antal lokale/telefoniske hændelser. Rapportér følgende separat:

1. Status/graf og sessionssnapshots: forsøg, samlede ønsker, undladte dubletter, timeout, konkrete WC-fejlklasser, reply/push/kontekst og faktisk udfald. De er forsøg/callbacks, ikke optalte radiopakker. Hold målings-, kvitterings- og diagnostiktrafik adskilt.
2. Sensor-BLE: unikke uventede disconnects, `isReconnecting`, tid til didConnect, videre til GATT/unlock og gyldig frame; største disconnect-til-frame. Brugerbestilt tilbagelevering tælles separat.
3. Målinger: største interval mellem faktisk registrerede Watch-målinger og tid uden aktuelle Watch-data efter de eksisterende friskhedsgrænser. Lokale UI-ticks må ikke gøre værdier friske. En teknisk frame kan være gyldig, selv om payloaden afvises.
4. Levering pr. stabilt målings-ID: modtaget/dekodet, accepteret/afvist med årsag, bekræftet lokal outbox-skrivning, afsendelse, telefonmodtagelse, faktisk lagringsresultat og Watch-kvittering. Sensorens egen tid medtages kun, hvis den er kendt. Forskelle mellem enheders vægure er usikre; lokal forsøgsvarighed bruger monotont ur.
5. **Forsinket**: payloaden kommer senere og får bekræftet lagring. **Manglende efter dokumenteret lokal accept**: ID mangler efter afsluttet opfølgning, men dækningsperioden er kendt. **Ukendt**: ingen fuld lokal journal eller endnu åben kø. Tomme minutpositioner og journalrotation må ikke omtales som optagne, tabte glukosemålinger.

## Overdragelse og alarmer

Efter hvert scenario: anmod eksplicit om tilbagelevering, notér disconnect-bekræftelse, telefon-ejerskab og første friske telefonmåling som tre forskellige tidspunkter. Kontrollér, at der ikke er samtidige sensor-ejere.

Brug appens eksisterende lokale testalarm på hver relevant enhed med kendte tilladelser og kendt snooze-status. Kontrollér faktisk lyd/haptik/visning og registreret alarmansvar. Kontrollér også eksisterende manglende-måling-alarm i et separat, dokumenteret kontrolforløb uden at fremkalde fysiologiske ændringer; brug det uafhængige alarmgrundlag og den aftalte testfunktion/procedure. C fjerner kun telefontransport og bør ikke i sig selv udløse Watch-manglende-måling-alarm, når uret fortsat modtager sensoren. Historisk efterlevering må ikke affyre aktuelle glukosealarmer. En konstateret regression i alarmansvar, snooze eller alarmfunktion stopper videre anvendelse/udgivelse og undersøges særskilt.

## Opfølgning og konklusion

En times kontrol er første trin. Efter de tre første kontroller planlægges et sammenhængende længere B-forløb på 4–6 timer og et gentaget C-forløb med længere offlineperiode inden for den eksisterende outbox-alder/kapacitet. Først derefter aftales en døgnkontrol med uafhængigt alarmgrundlag. Ingen automatisk planlagt job eller løfte om døgnstabilitet følger af denne plan.

Et godt resultat er mindre unødvendig status-/sessionstrafik og en målingskæde, der kan forklares, uden regression i datalagring, visning, ejerskab eller alarmer. Hvis trafikken falder, men målepauserne fortsætter, skal det stå direkte i resultatet. En senere BLE-rettelse vælges kun ud fra den dokumenterede del af `disconnect → didConnect → GATT/unlock → gyldig frame`, ikke ud fra WC-fejltallet alene.
