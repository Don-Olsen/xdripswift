# Watch-genopkobling efter testen af 4276

## Grundlag

Build 4276 (`testflight-7.1.1-4276`, kildecommit
`d559492dd82bf107f9fb48d121f3594ce0d74a40`) ændrede runtime-typen til
`physical-therapy`. Testen den 26. september 2026 omfattede Watch-modtagelse
fra 19:08:24 til 20:09:33 og efterfølgende overdragelse til iPhone.
De originale aktivitets- og Watch-evidensfiler bevares uden for Git.

Der blev dekodet og gemt 56 af 62 forventede sensor-minutnumre. Alle 56
nåede senere iPhones varige lager. De seks manglende minutter var to
grupper på tre minutter under uplanlagte BLE-afbrydelser. Begge afbrydelser
opstod, mens den udvidede runtime stadig kørte; denne test beviser derfor
ikke, at længere runtime alene løser problemet.

| Forløb, Watch-tid | Første afbrydelse | Anden afbrydelse |
| --- | --- | --- |
| System-genopkobling begyndte | 19:24:43 | 19:30:16 |
| Appen afbrød det ventende forsøg | 19:26:14 | 19:31:46 |
| Ny scanning fandt sensoren | 19:28:24 | 19:33:23 |
| Første gyldige frame igen | 19:28:25 | 19:33:24 |

De ekstra cancel-callbacks er appens kontrollerede genopkobling, ikke nye
uplanlagte radioafbrydelser. Begge oprindelige afbrydelser havde
`CBErrorDomain/6` og native `connecting`/system-genopkobling. Årsagen på
selve radioforbindelsen er ikke fastslået.

Runtime udløb 20:07:24. Kun cirka 2½ minut blev observeret efter udløbet;
de to efterfølgende minutmålinger siger ikke noget sikkert om en længere
tur uden udvidet runtime. Overdragelsen blev gennemført 20:09:57, og
iPhone modtog sin første direkte måling 20:10:24.

## Afgrænset ændring

Når et systemforsøg udløber, har collector hidtil kasseret den allerede
bekræftede peripheral og straks scannet igen. I denne test gik der
yderligere 130 og 97 sekunder, før scanning fandt den. Nu kan collector
efter bekræftet native disconnection starte én ny, tidsbegrænset
forbindelsesrunde til den kendte peripheral uden at vente på discovery.

Muligheden kræver en tidligere gyldig, dekrypteret Libre-frame fra samme
sensor, session, central og native objekt. Den forbruges før connect og
fornyes først af en ny gyldig frame. DidConnect eller et mislykket connect
fornyer den ikke. Den nye runde anvender de eksisterende 60/90 sekunders
forbindelsesbudgetter; ved fortsat fejl går den tilbage til den eksisterende
filtrerede scanning. Den rå 180-sekunders grænse for et uændret ventende
forbindelsesforsøg og cancellation-kontrollen på fem sekunder er uændrede.

Følgende sikkerhedsgrænser gælder fortsat:

- Ingen direkte retry uden bekræftet native `.disconnected`; retirement
  efter timeout giver fortsat kun adgang til den eksisterende scan-rute.
- Ingen retry ved telefon-ejerskab/overdragelse, udskiftet sensor/session/
  central/generation, et andet native objekt, slukket Bluetooth eller
  manglende eksekveringsmulighed.
- Den eksisterende disconnect-gate afviser en dublet af den gamle
  cancellation-callback indtil næste accepterede didConnect.
- Alle GATT-objekter og frame-fragmenter nulstilles; den kendte sensor
  gennemfører normal discovery/subscription/unlock igen.
- Første tilslutning, GATT-fejl, ugyldige frames og almindelig datastilstand
  uden system-genopkobling får ikke en ekstra retry-runde.

Det første nye connect kan genkendes i den eksisterende diagnostik som
`action=connect; reason=confirmedPeripheralAfterCancellation`.
Der tilføjes ingen ekstra minutvis logning, nye timere, automatisk
runtime-forlængelse, workout, batterilog eller historisk udfyldning.

Apple beskriver genopkobling til kendte peripherals før fornyet discovery
som en understøttet strategi, men den garanterer ikke succes. En sensor
kan kræve ny discovery; derfor er fallback og tidsgrænsen nødvendige.
Se [Apples Core Bluetooth-guide om genopkobling](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/BestPracticesForInteractingWithARemotePeripheralDevice/BestPracticesForInteractingWithARemotePeripheralDevice.html).

## Validering og fysisk test

Tolv regressionstests dækker de to observerede 90-sekunders forløb,
engangsforbrug, manglende frame/identitet, ejer- og sensorskift, native
cancellation/retirement, dubletter, Bluetooth/eksekvering og uændrede
budgetter. De anvender produktionskoden for timing og retry. De simulerer
ikke radiomodtagelse og kan ikke bevise hurtigere fysisk genopkobling.

Lokal validering den 26. september 2026:

- `scripts/local-build.sh test-all`: exit 0, XCResult `Passed`, 1067/1067
  bestået, ingen fejl eller skipped. Xcode ventede efter testene på sin egen
  `simctl diagnose --timeout=600`; netop denne verificerede underproces blev
  afsluttet med SIGTERM, hvorefter xcodebuild selv skrev en gyldig resultatpakke
  og afsluttede med exit 0. Den ekstra simulator-diagnoseindsamling er ufuldstændig.
- `scripts/local-build.sh build`: exit 0; både iPhone- og Watch-simulatorbuild
  viste `BUILD SUCCEEDED`.
- Testresultatet findes i
  `~/DeveloperBuildData/xDrip/local-runs/xdripswift-upstream-7.1.1/20260926T184656Z/results/AllTests.xcresult`.
  Buildlogs findes under samme `local-runs`-rod i `20260926T185110Z/logs/`.
- `xDrip-Watch-App-Info.plist`, versionsfilen, `active.json` og de allerede
  lokale lageroptimeringsændringer er uændrede. Der er ikke startet arkivering,
  signering eller TestFlight-upload. Rettelsen er endnu kun lokal.


Efter en særskilt godkendt upload testes i 80–90 minutter med Watch som
sensorejer og telefonen utilgængelig. Notér overtagelse, tilbagelevering og
eventuelle manuelle indgreb. Sammenlign dekodede minutnumre, uplanlagte
afbrydelser, tid fra brud til gyldig frame, direkte retry kontra scan og
varig iPhone-levering; opdel før og efter runtime-udløb.

Målet er kortere afbrydelser uden flere manglende målinger eller problemer
med overdragelsen. Hvis den kendte peripheral ikke længere kan forbindes,
kan den ekstra runde tværtimod forsinke scan-ruten. Derfor skal forbedring
måles, og ændringen revurderes, hvis det sker. Årsagen til de oprindelige
radioafbrydelser og stabil modtagelse i 1½–2 timer er fortsat åbne spørgsmål.
