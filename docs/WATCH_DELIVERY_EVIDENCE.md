# Lokal dokumentation af Watch-målingers levering

Denne instrumentation ændrer ikke glukoseberegning, alarmpolitik, målingskøens kvitteringsregler eller sensorens BLE-genforbindelse. Den eksisterende atomiske `LibreWatchOutboxFileStore` er allerede del af referencebuild 4259. Den separate revisionslog dokumenterer udfaldet af disse eksisterende produktionsveje.

## Manuel eksport

I telefonens **Activity Log** findes **Hent lokal Watch-log** og **Del leveringslog**. Anmod først om Watch-loggen efter det afsluttede testvindue; en åbning af Watch-appen under testen ændrer især baggrundstestens betingelser.

En anmodning har ét korrelations-ID og otte sekunders timeout. Der er ingen automatisk fallback eller gentagelsesløkke. Et positivt svar betyder, at Watch har overdraget en fil til WatchConnectivity; det betyder ikke, at telefonen har modtaget filen. Vent på status for modtaget lokal log inden den endelige eksport. Watch må højst have to af disse supportfiler under overførsel samtidig. En fuldt utilgængelig Watch kan ikke eksporteres fra telefonen; dens lokale journal forbliver på uret til en senere manuel anmodning.

Modtageren læser og gemmer supportfilen atomisk, før `didReceive(file:)` returnerer og systemet kan fjerne sin midlertidige fil. JSON-eksporten indeholder telefonens lokale journal og seneste faktisk modtagne Watch-journal. Manglende eller ældre Watch-materiale beskrives i eksporten. Den almindelige supportmail får samme `WatchDeliveryEvidence.json` som vedhæftet fil.

## Betydningen af hændelserne

| Hændelse | Dokumenterer |
| --- | --- |
| `decoded` | Et gyldigt dekrypteret frame er fortolket på Watch; et payload-ID er tildelt. |
| `accepted` / `rejected` | Watch-pipelinens eksisterende adgangskontrol og resultat; afvisninger har årsag. |
| `localWriteConfirmed` | Den eksisterende atomiske outbox-lagring er afsluttet, og payloadet er bevaret i køen. |
| `localWriteFailed` | Outbox-lagringen eller køens optagelse blev ikke bekræftet. En lokalt vist værdi er ikke dermed dokumenteret som varigt køet. |
| `sendAttempt` | Et konkret `sendMessage`- eller `transferUserInfo`-kald, ikke en optalt radiopakke. |
| `transportReceived` | Telefonen har fået en endnu ikke valideret målingskonvolut. |
| `phoneReceived` | Telefonen har dekodet målingspayloadet; det er endnu ikke bevis for lagring. |
| `phoneStored` / `phoneRejected` | Udfaldet efter den eksisterende kvittering for faktisk databaselagring eller en konkret afvisning. |
| `acknowledgement` | Watch har modtaget svar eller separat kvittering med success/durable/outcome. Forsinkede dubletkvitteringer kan også fremgå, uden at nogen klinisk tilstand ændres. |

ID'et tildeles én gang pr. dekodet frame og følger det samme payload gennem kø, genforsøg, telefon og kvittering. Et gentaget sensorframe kan få et nyt observations-ID og blive afvist som ikke-stigende sensorminut; det er ikke en ekstra accepteret måling.

`watchReceivedAt` er den eksisterende tidsangivelse fra Watch-modtagelsen. Sensorens forløbne minutter gemmes særskilt. Der udledes intet absolut sensortidsstempel: `sensorTime` mangler, når det ikke kendes. `at` kommer fra hændelsens egen enhed, med den enheds build/SHA og pseudonyme installation/proces/session. `uptime` kan sammenlignes inden for samme proces. Urforskellen mellem iPhone og Watch er ukendt; forskelle mellem deres vægure er ikke præcise transportmålinger.

## Grænser og tællere

Journalen er uafhængig af den kliniske outbox og har højst 24 timers logisk retention, 4.096 hændelser og 3 MiB hændelsesdata pr. enhed. Den appender én kompakt linje pr. leveringshændelse. Ved kapacitetsgrænsen frigøres omtrent en fjerdedel samlet; der serialiseres ikke fuld journal ved hvert fragment eller UI-tick. Et delvist mislykket append repareres før næste append. Journalfejl sendes aldrig tilbage i outboxen.

Eksporten angiver første/sidste beholdte hændelse, rotation, ulæselige linjer og skrivefejl. **Journalrotation er ikke tab af glukosemålinger.** Tid før installationen af denne instrumentation rekonstrueres ikke. De sidste registrerede alarmoplysninger viser autorisation, særskilte alert/sound-indstillinger, ansvar og snooze; de beviser ikke, at lyd eller haptik faktisk blev oplevet.

Tællere adskiller `status`, `graph`, `agp`, `session`, `reading`, `receipt` og `diagnostic`, samt handling og fejldomæne/kode. De er kumulative fra `counterWindowStartedAt`; brug en start- og sluteksport for at sammenligne lige lange vinduer. De gemmes højst én gang pr. minut ved eksisterende eksekvering og ved eksport. En brat procesafslutning kan derfor mangle op til det sidste minuts tællerændringer. Der oprettes ingen timer, der forsøger at vække watchOS.

Færre WatchConnectivity-forsøg eller fejl dokumenterer ikke i sig selv færre sensorpauser. BLE-brud, teknisk frame-liveness, lokal accept, lagring, transport, visning og alarmberedskab vurderes særskilt.
