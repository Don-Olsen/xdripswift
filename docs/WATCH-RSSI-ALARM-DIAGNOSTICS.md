# Watch-diagnostik efter 4278

Målet er mindst 90 minutters direkte Libre-ejerskab på Watch uden brugertryk. Denne udgivelse undersøger udfald; den er ikke en påvist rettelse af Bluetooth-stabiliteten.

## Systemlog verificeret før kodeændringen

Den 27. september 2026 udløste et kort knaptryk Watch-sysdiagnose kl. 18:45:43 CEST. Det fælles Watch/iPhone-arkiv blev hentet trådløst via iPhone med Xcodes devicectl. Indre SystemVersion og sysdiagnose-log bekræfter watchOS 26.6/build 23U67, Keychord og Gizmo initiated. Apples PacketLogger fra Additional Tools for Xcode 27 åbnede og afkodede begge oprindelige Watch-PKLG-filer.

Prøven indeholder 27.878 poster fra cirka 18:17:29 til 18:47:01. GUI og rå klokkeværdier stemmer med CEST-forløbet; værktøjets ISO-teksteksport viser yderligere to timer. Forskellen skal håndteres eksplicit ved korrelation. Originalerne ændres aldrig.

HCI-forbindelses-/afbrydelseshændelser og årsagsfelter kan læses. Prøven dokumenterer ikke Libre-peeridentitet, modtagne Libre-annonceringer eller RSSI. Standard-LE-annoncehændelser mangler i prøven, og producenthændelser er delvis uafkodede. Fravær i loggen beviser ikke, at en radiohændelse ikke fandt sted. Prøven dækker ikke det tidligere 14:39-udfald og forklarer ikke dets årsag.

Originaler, hashes og verification.json bevares lokalt i Git-ignoreret `build/watch-systemlog-20260927-184543/`. Private rålogs må aldrig tilføjes til Git.

## Afgrænset ændring fra 4278

- Bevar discovery-RSSI for hver observation af den bekræftede sensor, med observationstid og kilde. Genbrug af en discovery-kandidat skaber ingen ny RSSI-observation.
- Kald `readRSSI` højst én gang pr. minut, efter at netop målingen er behandlet og varigt lagret. Ingen ny periodisk timer; højst én udestående forespørgsel. Knyt forespørgsel og svar til den oprindelige session og forbindelse. Et gammelt svar må ikke fremstå som en ny måling.
- RSSI-fejl påvirker hverken genopkobling, frister, glukose eller levering. Ekstra Bluetooth-kald, logskrivninger og diagnoseoverførsler er kendte forskelle fra 4278.
- Kontroller automatisk alarmberedskabet: aktuelle indstillinger og ansvar, aktiveret regel for manglende målinger, ingen effektiv snooze, nødvendige tilladelser og verificeret ventende alarm.
- Klar tilstand giver ét kort bank pr. overtagelse uden krav om tryk. Mangler noget, vises en advarsel i Watch-appen, også på visningen med stort glukosetal. Indstillingen for antal minutter ændres ikke.
- Accepteret planlægning er ikke bevis for en ventende alarm. En ventende alarm er ikke bevis for senere levering eller mærkbar vibration. Journalfør beredskab med disse skel.

Genopkobling, timeoutgrænser, workout/physical-therapy-runtime, overdragelse, glukosebehandling og levering skal bevare 4278-adfærden. Ingen trend-backfill, automatisk tilbagelevering, forlængelsesnotifikationer eller nye capabilities indgår.


For hver gennemført forbindelsesaflæsning tilføjes en forespørgsels- og en svarpost;
discoveries har egne poster. En separat ContinuousClock måler kun RSSI-aflæsningens
interval og alder, også gennem søvn. De eksisterende recovery-budgetter ændres ikke.
Hvis Core Bluetooth aldrig svarer, bevares den ene udestående forespørgsel og
flere forbindelses-RSSI-kald blokeres i denne collectors levetid. Det forhindrer,
at et sent svar knyttes til et nyt kald; glukosemodtagelsen fortsætter uændret.

## Fysisk test efter installation

1. Indstil manglende-måling-alarmen til fem minutter på iPhone én gang. Kontroller Bluetooth-profilens gyldighed; den udløber efter fire dage.
2. Overtag sensoren på Watch. Registrer overtagelse og første direkte måling separat. Kontroller det automatiske alarmberedskab; ingen ekstra appbekræftelse kræves.
3. Slå iPhones Bluetooth og Wi-Fi fra i Indstillinger. Start den 90 minutter lange test nu. Ingen debugger må være tilsluttet.
4. Tryk ikke på uret. Kommer alarmen, tag straks en sysdiagnose før tilbagelevering/genstart: sideknap og Digital Crown samtidig i to sekunder, slip straks. Registrer tidspunktet som indgreb; tiden efter tæller ikke som uforstyrret test.
5. Genetabler telefonforbindelsen efter testen, overdrag tilbage, og læg Watch på opladeren tæt ved telefonen. Apples vejledning tillader op til 15 minutter til overførsel. Hent nyt co-sysdiagnose-arkiv og journal, og kontroller oprindelse/tidspunkt.

## Rapport og beståelse

Rapporter opstart separat; modtagne/forventede sensorminutter efter sensorens minutnumre for første time og sidste halve time; længste pause; tidslinje for hvert udfald; uplanlagte linkbrud adskilt fra appstyrede afbrydelser; runtime, batteriforbrug og alarmstatus (planlagt, observeret leveret eller ukendt). Brug RSSI, radioårsager, annonceringer og forbindelsesparametre kun, når de faktisk er tilgængelige og kan knyttes til sensoren.

Sammenlign med 4273–4278 med forbehold for kode-, test- og instrumenteringsforskelle. Adskil dokumenterede fund, sandsynlige forklaringer og manglende beviser. Vælg en rettelse ud fra fundene. Den afsluttende test kræver 90 sammenhængende minutter uden indgreb, mindst 95 procent sensorminutter, ingen pause over tre minutter og workout kørende hele vejen.

## Verifikation før udgivelse

Den præcise release-kilde skal bestå hele XCTest-suiten, Python-releasekontrollerne og begge simulatorbuilds via AGENTS.md. Kontroller fysisk iPhone-adgang og sikker testmulighed før upload. Faktiske resultater, begrænsninger og Apple-buildnummer registreres i releasekvitteringen og PROJECT-STATUS.md. Fysisk stabilitetsforbedring er først dokumenteret efter Watch-testen.
