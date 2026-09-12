# Eftervist kontrolgrundlag: build 4259

Kontrolleret direkte mod råfiler 12. september 2026. En tidligere vurderings konklusion er ikke brugt som erstatning for optælling eller læsning af referencekoden.

## Materiale og reference

- Referencegren: `fix/watch-disconnect-retention-4259`; SHA `e11a6f4d3674b0ef58f1ac5159fcf0aac7ca8c21`. Den nye arbejdsgren `fix/watch-status-delivery-stability` blev oprettet fra denne SHA. Den yderste arbejdsmappe er ikke appens udgivelsesrepository. Den nye patch bygger ikke på `master` og medfører ingen upstream-sync.
- Tilgængeligt råarkiv: `1-Komprimeret-arkiv.zip` i den aktuelle samtales vedhæftningsmappe `742EE33E-BB02-4ABA-A899-183838CA40C1`, 385.959 bytes, SHA-256 `60365b846ce5f126591e6e1197d0741c259dc6bca42f6bfa4ddb3ec97dc6f3e8`.
- De fire udtrukne filer i den yderste arbejdsmappe `review/watch-report-742EE33E/` er byteidentiske med arkivets `TroubleshootingLog.txt`, `appinfo.txt`, `xdriptrace.0.log` og `xdriptrace.2.log`. `__MACOSX`-metadata er ikke analysegrundlag.
- `review/watch-report-742EE33E/vurdering.md` findes. Filen med det præcise navn `xdrip_4259_kontrol_2026-09-12.md` og et råarkiv med det præcise navn `Komprimeret arkiv(4).zip` blev ikke fundet i arbejdsområdet eller den aktuelle samtales vedhæftningsmappe. Vi har ikke antaget navneidentitet; det tilgængelige arkivs indhold er eftervist som nedenfor.
- Eksporttid: 12. september 2026 kl. 12:39:59 CEST. `TroubleshootingLog.txt:7` angiver iPhone build 4259 og reference-SHA. De 221 beholdte Watch-poster angiver samme build/SHA, men har egne oprindelsestider og Watch-identitet. `trace.2` slutter 01:19 og bruges ikke til det senere kontrolvindue.

## Optælling inden for faktisk Watch-ejerskab

Alle tider er 12. september 2026 CEST. Afgrænsningen er det halvåbne interval **[11:36:02.571, 12:38:00.544)**: fra `releasingToWatch → watch` til `watch → releasingToPhone` i `xdriptrace.0.log:14996` og `:18003`. Varighed **3.717,973 sekunder = 61 minutter 57,973 sekunder**. Protokollens senere `releasingToPhone → iphone` kl. 12:38:00.560 er et andet tidspunkt.

| Mål | Eftervist resultat | Optællingsregel |
|---|---:|---|
| Statusafsendelser | 1.130 | Rækker med `sending foreground watch update` i vinduet |
| Statusfejlcallbacks | 654 | Rækker med `error sending watch update`; 652 utilgængelig modpart og 2 svarfejl |
| Sessionsfejlcallbacks | 474 | Rækker med `Could not send Libre Watch session:`; alle utilgængelig modpart |
| Unikke lagrede Watch-payload-ID'er | 50 | 13 `liveAccepted` og 37 `historicalInserted` |
| Ekstra dubletresultater | 6 | Allerede lagrede ID'er; ikke seks ekstra målinger |
| Uventede disconnects / efterfølgende recoveries | 7 / 7 | Oprindelig Watch-tid og unik journalsekvens; forventet brugerretur udeladt |
| Største målingsinterval | 359 sekunder | 11:55:48 → 12:01:47 mellem registrerede Watch-målinger |
| Største disconnect → gyldig frame | 300 sekunder | 11:56:47 → 12:01:47 |

Dette er loggede forsøg og callbacks, ikke radiopakker. Sessionsfejl kan ikke omregnes til sessionsforsøg, når den tilsvarende komplette forsøgstæller mangler. De tidligere 1.244 statusforsøg/708 fejl vedrører det bredere interval fra 11:32 til trace-slut 12:39:57 og er ikke den valgte ejerskabsbaseline.

| Disconnect | didConnect | Gyldig frame / recovery | Disconnect → frame |
|---|---|---|---:|
| 11:50:46 | 11:51:46 | 11:51:48 | 62 s |
| 11:52:46 | 11:53:47 | 11:53:49 | 63 s |
| 11:54:46 | 11:55:46 | 11:55:48 | 62 s |
| 11:56:47 | 12:01:45 | 12:01:47 | 300 s |
| 12:18:46 | 12:19:45 | 12:19:46 | 60 s |
| 12:25:46 | 12:27:45 | 12:27:46 | 120 s |
| 12:29:47 | 12:30:46 | 12:30:48 | 61 s |

Reference til deduplikerede disconnect-rækker i `xdriptrace.0.log`: 15219, 15234, 15249, 15266, 16320, 16470, 17883. Modtagne/gensendte journalposter skal ikke tælles flere gange. Alle syv brud har logget `isReconnecting=true`, `scene=inactive`, `runtime=false`, `CBErrorDomain`, kode 7. Det dokumenterer ikke en af Apples navngivne budgetfejl, og `inactive` beviser hverken en bestemt håndledsbevægelse eller faktisk suspension.

## Transport, måletid og dækning

Telefonens Bluetooth-manager viser `poweredOff` 11:38:57.473 og `poweredOn` 12:16:03.806 (`xdriptrace.0.log:15156`, `:15167`). Et tidligere kort skift er også logget: off 11:37:20.715 og on 11:38:36.914. Dette er telefonens Bluetooth-tilstand, ikke urets sensor-Bluetooth, og det fastslår ikke telefonens Wi-Fi-tilgængelighed.

Den registrerede Watch-måling kl. 11:38:46 fremgår på telefonen kl. 12:16:11 (`TroubleshootingLog.txt:275`), en observeret forskel på 37:25. Transportbegrænsningen er forventelig ved en utilgængelig telefon og skal holdes adskilt fra sensorens fire tidligere disconnects. De første fire sensorbrud ligger før den store loggede status-/fejlaktivitet fra 12:16; første statusfejl derefter er `xdriptrace.0.log:15433`, 12:16:20.337. Statuskommunikationen er ikke bevist årsag til alle brud.

I referencekoden kaldes `parseDirectReading(... receivedAt: now)` ved fuld frame på Watch. Tiderne omtalt som måletider ovenfor er derfor de registrerede Watch-værdier, ikke et eftervist selvstændigt sensorur. Enhedsforskelle i vægure gør transportforsinkelser omtrentlige; ingen synkroniseringsmåling findes i råmaterialet.

De 221 eksporterede Watch-poster har sekvens 5906–6126 uden huller. De er de poster, telefonen har modtaget og beholdt. Det beviser ikke, at urets lokale kø er tom, at eksporten omfatter alle lokale stadier, eller at ingen endnu ikke leveret hændelse eksisterer. Journalrotation er ikke lig mistede målinger. Ny diagnostik skal vise dette eksplicit.

Alarmberedskabet er heller ikke en bestået fysisk alarmtest: 215 poster har `authorized=true`, heraf 211 med Watch-alarmansvar. Alarmrevision 46 har `snoozeAllUntil=13 September at 01:29:40` gennem sidste dokumenterede post kl. 12:15:42; revision 47 har feltet `unknown` fra første dokumenterede post kl. 12:18:46. `unknown` er ikke i sig selv en bekræftet fysisk ophævelse af snooze. Loggen beviser ikke hørbar lyd eller korrekt notifikationsvisning. Næste alarmkontrol skal have kendte tilladelser og snooze-status.

## Kodeproblemet er eftervist i den byggede SHA

Kildekontrollen med `git show e11a6f4d:<sti>` viser UI-timer hvert andet sekund i `WatchStateModel`, flere view-kald til `requestWatchStateUpdate`, og `MainView`'s femsekunderskontrol mod `updatedDate`, som også ændres ved direkte sensorværdier. Status og graf sendes som separate ønsker. Telefonens almindelige status-handler kalder både `processWatchUpdate` og `sendLibreWatchSession`; `libreWatchSessionPayload` kalder `nextHandoffRevision()` ved hver opbygning. Det underbygger den afgrænsede rettelse af koordinering, indholdsidentitet og reply-vejen. Det underbygger ikke en bred BLE-omskrivning.

**4259 har allerede atomisk fillagring.** `LibreWatchOutboxFileStore` bruger `Data.write(... options: .atomic)` og undlader gentagen serialisering af identiske, succesfuldt lagrede snapshots. Outboxen har eksisterende grænser på 512 elementer, 512 KiB og seks timer. Denne patch beskrives ikke som indførelsen af den atomiske outbox.

Den gamle arbejdsgren `fix/watch-reading-durability-4260` indeholder en særskilt, ikke-udgivet lokal Swift-diff: fire filer, 370 tilføjelser og 27 sletninger. Den vedrører accept/outbox/display-cache-grænsen, en bekræftet-lagringsmarkør, reparation fra cache ved genstart og lagringsfejlvisning. Filerne er `WatchStateModel.swift`, `LibreDirectView.swift`, `LibreWatchDirectSession.swift` og `LibreWatchValuePipelineTests.swift`. De otte nye tests dækker commit før lokal visning, crash mellem outbox og cache, legacy/fejlet cache med stabilt ID, allerede kvitteret cache, skrivefejl med RAM og retry, genstartsreparation samt sessions-/kalibrerings-/aldersgrænser. Denne diff bevares i sin oprindelige arbejdsmappe og indgår ikke i status-/diagnostikpatchen. Et grennavn med 4260 er ikke et udgivet buildnummer.

## Reproducerbar kontrol

Optællingen læser kun de originale fire udtrukne filer. Trace-tidsstempler parses før filtrering; status, sessioner og lagringsresultater tælles separat. Watch-hændelser sammenholdes med deres oprindelige `watchTime`, omregnet fra UTC til CEST, og deduplikeres med sekvens. Payload-ID'er bruges kun til unikhed/dubletkontrol. Arkivindhold blev sammenlignet byte for byte med udtrækket, og SHA-256 blev beregnet fra råarkivet. Ingen glukoseværdier, rå sensorbytes, nøgler, profiler eller serveradresser er medtaget her. Dette er baseline-verifikation, ikke en ny fysisk test af den ændrede build.
