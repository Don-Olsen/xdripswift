# Plan: validering af Libre 2 Plus-trendværdier i skyggetilstand

Status: plan for en senere diagnosebuild. Ingen trendkode aktiveres i
alarmrettelsen efter 4279, og denne plan giver ikke anledning til en ny upload.

## Kilde og hypotese

Projektets iPhone-parser i `Libre2BLEUtilities.parseBLEData` placerer syv
pakkesamples ved forskydningerne `[0, 2, 4, 6, 7, 12, 15]`. Watch-dekoderen
`Libre2WatchDirectAlgorithms` bruger i dag primært den aktuelle og den
foregående sample. DiaBLE anvender samme syv trendforskydninger og separate
historiske samples; det understøtter hypotesen, men beviser ikke identiske
værdier på denne Libre 2 Plus-sensor.
[Kilde: DiaBLE, parseBLEData](https://raw.githubusercontent.com/gui-dos/DiaBLE/main/DiaBLE/Libre2.swift).

Syv forskydninger er ikke en komplet minutserie. Offset nul er den aktuelle
måling, ikke backfill. Et hul kan kun udfyldes, når en faktisk senere sample
refererer til det manglende sensorminutnummer. Der interpoleres ikke, og
historiske kvarterværdier blandes ikke ind i dette første forsøg.

## Afgrænset implementering i et senere build

1. Efter en gyldig pakke er dekodet, og den direkte måling er behandlet/gemt,
   beregnes kandidaterne for de syv samples uden ekstra BLE-kald eller timer.
   Brug samme kontrol af rå glukose, temperatur, temperaturkorrektion og
   kalibreringsparametre som den direkte dekoder. Ukendte eller ugyldige
   samples afvises; sensorens minutnumre bruges til identitet, ikke telefonens
   modtagelsestid.
2. Knyt hver kandidat til sensorsession, sensorvariant, sensorminut,
   kildepakkens minut, offset og kalibreringsrevision. Hold en afgrænset lokal
   sammenligningsbuffer med allerede modtagne direkte samples. Skift af sensor,
   session eller uforenelig kalibrering skal nulstille sammenligningsgrundlaget.
3. Sammenlign rå samplefelter og værdier beregnet med samme parametre på samme
   sensorminut. Sammenlign ikke med en senere udglattet iPhone-kurve. Registrér
   matches, manglende reference, ugyldige samples og afvigelser særskilt pr.
   offset og sensorvariant. En afvigelse skal forklares; den skjules ikke ved
   at udvide en tolerance. Brug på forhånd definerede numeriske tolerancer kun
   til den dokumenterede flydende beregning, ikke til rå data eller minutidentitet.
4. Log kun afgrænset diagnostik. Skyggekandidater må ikke indsættes i
   måledatabase, visningshistorik, outbox, HealthKit, Nightscout eller alarmvej.
   De må ikke opdatere sidste direkte måling, missing-reading-deadline eller
   Bluetooth-budgetter. Der lagres altså diagnostik, men ingen nye glukoseposter.
5. Rapportér hver for sig: direkte modtagne sensorminutter, forventede minutter,
   manglende minutter, unikke mulige udfyldninger og validerede overlapsammenligninger.
   Huller uden direkte reference kan tælles som kandidater; deres værdi kan ikke
   kaldes verificeret alene fordi der mangler en reference.

## Tests og beslutning før aktivering

Syntetiske pakkefiksturer skal dække bitfelter, temperaturfortegn, hver offset,
ugyldige samples, dubletter, session-/kalibreringsskift, tidlige sensorminutter,
minutgrænser og modtagelse i forkert rækkefølge. Kontroller eksplicit, at
skyggetilstanden hverken skriver kliniske målinger, nulstiller deadlines eller
udløser alarmer.

Et senere fysisk diagnoseforløb skal have overlap med direkte målinger ved
alle seks historiske offsets på Libre 2 Plus. Rapportér antal sammenligninger
og alle afvigelser. Før lagring overhovedet aktiveres, skal eventuelle afvigelser
være forklaret og beslutningen dokumenteret i en særskilt ændring og test.
En kort test eller en fremmed parser er ikke i sig selv validering.

Ved en eventuel efterfølgende aktivering skal historiske poster beholde deres
oprindelige sensorminut og tidspunkt, mærkes som efterleverede og deduplikeres.
En direkte måling må ikke overskrives. Historiske værdier må aldrig udløse
alarmer for fortiden eller nulstille beredskabet for manglende nye målinger.
Forbedret historik tælles separat fra stabil live-modtagelse.
