# Alarmrettelse efter 4279

## Afgrænsning

Denne ændring retter sammenligningen af en Watch-notifikations tidsstempel ved
kontrol af en planlagt alarm og ved præsentation i forgrunden. Bluetooth,
forbindelsesforsøg, tidsgrænser, workout, RSSI-kald og målelevering ændres ikke.
Den ændrer ingen af brugerens alarmgrænser, snoozes eller tilladelser.

Notifikationen gemmer sin baseline som sekunder siden 1970. Konvertering til
Foundations Date-repræsentation og tilbage kan ændre den interne brøkdel med
cirka 0,12 mikrosekund. Eksakt Date-lighed kan derfor afvise en notifikation,
selv om den bærer præcis den baseline, appen sendte. Den fælles baselinekontrol
sammenligner i stedet de endelige, finite tal i det eksisterende 1970-format.
Der indføres ingen vilkårlig tolerance i sekunder eller millisekunder.
Gamle og nye notifikationer bruger samme format; persistens kræver ingen migration.
Se [Apples beskrivelse af timeIntervalSince1970](https://developer.apple.com/documentation/foundation/date/timeintervalsince1970).

Den konstaterede fejlvej gælder alarmen for manglende målinger, både inden og
efter første direkte måling. Lav, akut lav, høj og akut høj bruger allerede
målingens UUID til at identificere den relevante notifikation. Disse fire veje
bevarer deres identitetskontrol og får hver en regressionstest med
brøksekunder, serialisering, genindlæst alarmtilstand, automatisk throttle,
manuelt snooze, ændret måling/session og manglende tilladelse/ejerskab.

Der testes desuden:

- At den oprindelige afrundingsfejl reproduceres i begge retninger.
- At den rigtige baseline accepteres ved pending-kontrol og præsentation.
- At en anden baseline, også en mikrosekund senere, stadig afvises.
- At manglende/ikke-finite værdier og forældede målinger ikke godkendes.
- At telefonens valgte alarmforsinkelse bevares (syntetiske 5, 11 og 30 minutter).
- At slukket regel og snooze stadig giver advarsel ved overtagelse.

## RSSI fra den eksisterende 4279-test

Kun de 61 vellykkede RSSI-svar fra en etableret forbindelse indgår; discovery
og forespørgsler uden en signalmåling blandes ikke ind i fordelingen.
For normal drift før udfaldsvinduet bruges de 57 svar før kl. 21:09 CEST.
Det er en eksplicit tidsafgrænsning, ikke et filter på signalstyrken.

| Udsnit | Antal | Median | 10-percentil, nearest rank |
|---|---:|---:|---:|
| Etablerede forbindelser før kl. 21:09 | 57 | −82 dBm | −91 dBm |
| Alle etablerede forbindelser, inklusive udfaldsvinduet | 61 | −84 dBm | −91 dBm |

De svageste 10 % afrundes til seks af de 57 observationer:
−94, −93, −93, −92, −91 og −91 dBm. Ved udfaldet måltes −102 og −100 dBm,
altså 18–20 dB under normaludsnittets median og 6–8 dB under dets svageste
observation. Dette er en relativ sammenligning; modtagerens følsomhedsgrænse
kendes ikke, så en egentlig radiomargin kan ikke beregnes. RSSI alene beviser
ikke årsagen. Den eksisterende test indeholder stadig ikke komplet
collector-journal eller HCI-log fra selve udfaldet.

Præcise data, afgrænsning og kildehashes bevares lokalt uden for Git under
`build/alarm-timestamp-fix/`. Ingen ny fysisk test er udført for RSSI-analysen.

## Verifikation og åbne forhold

De otte nye tests er kørt mod den uændrede alarmkode: tre testmetoder
fejlede med i alt 11 assertions. Med rettelsen bestod alle otte uden fejl.
BeforeFix.xcresult og AfterFix.xcresult bevares lokalt sammen med logs.
Release-processen kører hele
XCTest-suiten, Python-kontroller og begge simulatorbuilds mod det præcise
staged release-træ efter Apples valg af buildnummer. De faktiske resultater
og Apple-status registreres særskilt i PROJECT-STATUS.md.

Simulator-tests dokumenterer logikken, ikke at en fysisk alarm kan høres eller
mærkes. Før næste fysiske test indstiller brugeren én gang missing-reading-
alarmen til fem minutter uden snooze. Appen kontrollerer de reelle overførte
indstillinger; fem minutter hardkodes ikke. Eventuel aflevering rapporteres
som observeret eller ukendt, aldrig alene ud fra planlægning.

Den tidligere nævnte mulige race mellem almindelige permission-refresh-svar
undersøges ikke som del af denne afgrænsede rettelse. Der er ikke påvist en
ny Bluetooth-årsag eller ændret reconnection-adfærd.

Trendudfyldning er alene planlagt i [skyggetilstandsplanen](WATCH-TREND-SHADOW-PLAN.md).
