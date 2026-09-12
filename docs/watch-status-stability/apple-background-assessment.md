# Apple-baggrund: afklaring og usendt henvendelse

Kontrolleret 12. september 2026 mod Apples aktuelle dokumentation og reference-SHA `e11a6f4d3674b0ef58f1ac5159fcf0aac7ca8c21`. Dokumentationen blev læst på Apples sider; JavaScript-siderne blev efter indlæsning læst i browseren, fordi søgeværktøjets Markdown-hentning ikke kunne gengive indholdet. Dette er en arkitekturvurdering, ikke dokumentation for fysisk døgnstabilitet.

## Understøttede muligheder og grænser

- **Offentlig Bluetooth-baggrundsadgang:** Den aktuelle vejledning beskriver `UIBackgroundModes = bluetooth-central`, GATT-notifikationer og forbindelser, som systemet kan holde, mens appen er suspenderet. Den dokumenterer fem samlede scanning-/timely-alert-muligheder i et rullende døgn; muligheder frigives efter 24 timer, og brugerstart af appen genopfrisker budgettet. De konkrete advarsler er `leGattNearBackgroundNotificationLimit` og `leGattExceededBackgroundNotificationLimit`. Det giver ingen dokumentation for ubegrænset minutvis CGM-modtagelse. [Using background tasks](https://developer.apple.com/documentation/watchkit/using-background-tasks).
- **Almindelige delegates:** Apple viser `didUpdateValueFor` til hændelser i både forgrund og baggrund samt kort eksekvering ved disconnect til at anmode om reconnect. Den offentlige model giver korte, budgetterede muligheder; gentagne brud kan også begrænse reconnect-afstand. Ingen af disse forhold kan udledes af antallet af WatchConnectivity-fejl. [WWDC22: Get timely alerts from Bluetooth devices on watchOS](https://developer.apple.com/videos/play/wwdc2022/10135/).
- **Self-care:** Apples aktuelle tabel angiver frontmost-eksekvering i højst ti minutter. Skærmen må være slukket, men sessionen slutter ved udløb eller når brugeren eksplicit forlader appen. Den er ikke en almindelig baggrunds- eller døgnservice. En sessionstype skal vælges ud fra det faktiske formål. Denne patch indfører ingen workouts, lyd, mindfulness, physiotherapy, runtime-kæder eller ændrede runtime-rettigheder. [Using extended runtime sessions](https://developer.apple.com/documentation/WatchKit/using-extended-runtime-sessions).
- **App refresh:** Apple beskriver omtrent fire opgaver i timen ved en aktiv komplikation, delt budget og udskudte opgaver efter budgetforbrug. Det er ikke minutlig planlægning eller garanteret vækning; WidgetKit er heller ikke en erstatning for sensorindsamling. [WKApplicationRefreshBackgroundTask](https://developer.apple.com/documentation/watchkit/wkapplicationrefreshbackgroundtask).
- **WatchConnectivity:** `sendMessage` kræver aktiveret session, returnerer før asynkron levering og kan fejle, hvis modparten bliver utilgængelig efter kontrollen. Et aktivt Watch kan vække iPhone; det omvendte kald vækker ikke Watch. Replies kommer på baggrundstråd. Appens korrelation, timeout og retry skal derfor styres særskilt. [sendMessage](https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)).
- **Seneste kontekst og offline:** `updateApplicationContext` erstatter ventende kontekst. Derfor skal alle aktuelle status-, sessions-, kalibrerings- og alarmfelter flettes før opdateringen. Baggrundsoverførsel er transport, ikke appens lagringskvittering. Apples sample bruger fysisk iPhone/Watch og lokal fillog, som manuelt kan overføres. [Transferring data with Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity).

## Livscyklus i referencekoden

`xDrip Watch App/xDripWatchApp.swift` opretter `WatchStateModel` og `LibreWatchDirectCollector` i appens initializer og kalder `prepare(with:)`. Der er ingen `WKApplicationDelegate`/`WKExtensionDelegate`, SwiftUI `backgroundTask`, app-refresh-planlægning eller eksplicit task-completion-handler i denne reference.

`LibreWatchDirectCollector.prepare` opretter CoreBluetooth på hovedkøen med restoration-ID. `didUpdateValueFor` kontrollerer aktuel characteristic, peripheral, generation og ejerskab og udfører frame-samling, dekodning, accept og eksisterende outbox-arbejde synkront. Delvise frames giver ikke en ny baggrundstimer. `notificationErrorAction` skelner allerede de to navngivne budgetfejl fra øvrige Bluetooth-fejl; `reportCoreBluetoothCallback` bevarer domæne, kode og klassifikation. Den moderne disconnect-delegate registrerer `isReconnecting`, og generationsværn forhindrer dobbelt behandling af moderne/ældre callbacks. Disse veje ændres ikke af statusforbedringen.

`WatchStateModel`'s WC-delegates videresender behandlingen asynkront til hovedkøen. Delegate-return er derfor ikke bevis for afsluttet lokal behandling. Der er imidlertid ingen eksisterende eksplicit task-handler, som i koden kan påvises at kalde completion for tidligt, og råmaterialet viser ingen identificeret task-watchdog-termination. **Der indføres derfor ingen ny lifecycle-handler i denne patch alene for at få mere køretid.** Dette er en afgrænsning, ikke en bestået fysisk baggrundstest.

Hvis en konkret modtaget systemopgave senere kræver håndtering, skal den omfatte egne igangværende lokale operationer, ikke blot `hasContentPending`. SwiftUI markerer opgaven færdig, når handleren returnerer; en WK-handler skal selv afslutte efter delegate-behandling. Begge skal reagere på afbrydelse/udløb inden for det korte systemvindue. En separat lille rettelse skal teste normal afslutning, flere overlappende callbacks, cancellation og fejl. [Using background tasks](https://developer.apple.com/documentation/watchkit/using-background-tasks).

Apples aktuelle WC-sample kræver afslutning af de modtagne baggrundsopgaver og forklarer, at en uafsluttet opgave kan opbruge budgettet. Samplets transporttilstand er ikke bevis for afslutning af ekstra app-arbejde på andre køer. [Transferring data with Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity).

Eksisterende tests omfatter blandt andet `testInactiveAndBackgroundRemainDistinctWithoutClaimingTimerExecution`, `testEighteenMinuteTwentyNineSecondSuspensionPreservesRemainingExecutionBudget`, `testBackgroundNotificationQuotaErrorsNeverCountAsInvalidFramesOrStartRecovery` og `testBackgroundBLENotificationRetriesPersistedReadingsWithoutTimerPermission`. De er kodekontroller, ikke en simulering af watchOS' faktiske suspension eller Bluetooth-budget. Ny Xcode-kørsel rapporteres i udgivelsesresultatet.

## Historisk særrettighed og signering

En Apple-ingeniør beskrev i august 2019 `com.apple.developer.bluetooth-central-background` som en meget selektiv rettighed for watchOS-apps, der kommunikerer med CGM-enheder. Det er historisk dokumentation, ikke en aktuel godkendelse, adgangsprocedure eller garanti for dette team. [Apple Developer Forums, 109947](https://developer.apple.com/forums/thread/109947).

Forumtråden fra 2026 handler blandt andet om gamle health-monitoring-henvisninger og HealthKit. Den identificerer ikke en nuværende CGM-rettighed for dette projekt. DTS understreger begrænsede ressourcer, at kontinuerlig almindelig baggrundseksekvering ikke er en understøttet generel brug, og at workouts til ikke-workout-formål kan afvises. [Apple Developer Forums, 816544](https://developer.apple.com/forums/thread/816544).

Managed capabilities kræver Apple-godkendelse, og en organisations Account Holder skal sende anmodningen. At generelle Capability Requests findes i portalen betyder ikke, at den historiske CGM-rettighed findes som selvbetjening. [Capability requests](https://developer.apple.com/help/account/capabilities/capability-requests). Godkendelser kan være begrænset til bestemte distributionsformer; App ID, profil og signeret binær skal stemme overens. [Provisioning with managed capabilities](https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities).

Ved kildekontrollen indeholder `xDrip-Watch-App-Info.plist` almindelig `bluetooth-central` og `self-care`. Watch-appens kilde-entitlements indeholder app group, ikke den historiske CGM-nøgle. Der fandtes ingen lokal IPA, `.xcarchive` eller `.mobileprovision` i arbejdsområdet, som dokumenterer build 4259's faktisk signerede rettigheder. **Signerede rettigheder og teamets eventuelle særgodkendelse er derfor ukendte ved denne vurdering.** Dette udfyldes med en begrænset liste over relevante entitlement-navne/resultater fra vores eget nye Release-arkiv, når det foreligger. Profiler, certifikater og private nøgler skal ikke publiceres.

## Udkast til Apple Developer Support / DTS — ikke sendt

Subject: Supported watchOS architecture and possible managed capability for direct CGM reception and local alerts

Hello Apple Developer Support / DTS,

We maintain a modified open-source xDrip4iOS application with an iPhone companion and an Apple Watch app. The Watch can receive Libre 2 Plus EU continuous glucose monitor data directly over CoreBluetooth and provide local alerts using existing user-configured thresholds and snooze settings. This work introduces no new dosing logic. We want to implement the supported architecture and describe its limits accurately.

Our observed test used watchOS 26.6 (23U67), iOS 26.6.2 and TestFlight build 4259. Our distribution setup uses team GFZ896KN66 and iPhone bundle com.GFZ896KN66.xdripswift; exact Watch bundle, signed-entitlement summary and tested build/SHA can be supplied from our own archive after verification. We distinguish a frontmost self-care session from an app explicitly dismissed to the watch face, and we are not seeking to simulate workouts, play silent audio, chain runtime sessions or bypass system budgets.

Your current background-task documentation describes budgeted Bluetooth timely alerts. In forum thread 109947, an Apple engineer described a selectively granted CGM Bluetooth background entitlement in 2019. We do not assume that historical statement describes current availability or entitles our team to use it.

1. On the current watchOS release, which supported architecture applies to frequent direct CGM reception and local glucose/missing-data alerts while the Watch app is actually in the background or suspended, beyond the frontmost self-care window?
2. Is there a current managed capability for this use case? If so, what are its exact scope and eligibility criteria, and could a modified open-source CGM application such as ours be considered? What information or approvals would you require?
3. Which App ID configuration, entitlement assignment, provisioning/signing and TestFlight distribution requirements apply? Does any approval cover development only or also internal TestFlight/App Store distribution?
4. How should we distinguish normal background-budget enforcement from an OS defect? Which diagnostic records and minimal reproduction would be most useful, and should such a case go to Feedback Assistant?

We can provide sanitized callback sequences, actual error domains/codes including any named background-budget warnings, lifecycle/runtime state, measured local processing durations and a minimal physical-device reproduction. We will not infer a quota limit from CBErrorDomain code 7 alone. Please clarify whether any managed capability changes the documented budget and what restrictions remain; we do not assume unrestricted continuous runtime.

Thank you.

## Hvis der er mistanke om en OS-fejl

Forbered en lille app med samme offentlige Bluetooth-mode, restoration-ID, kendt peripheral/GATT-abonnement og lokal, begrænset tidslinje. Registrér start på urskiven, lifecycle, notification/disconnect/didConnect/GATT/unlock/gyldig-frame, fejldomæne og kode, `isReconnecting`, runtime og termineringsrapport. Undlad appens graf, serverintegrationer og unødvendig WC-trafik i reproduktionen. Brug fysisk Watch/iPhone uden debugger; medtag OS/build, hardware, batteri, opladning, strømbesparelse, testtrin og præcist tidsvindue. Indsaml relevant systemdiagnostik ved fejltidspunktet og redigér persondata før ekstern deling. Et udkast/diagnostik sendes først efter brugerens godkendelse. Statusrettelsen afhænger ikke af Apples svartid.
