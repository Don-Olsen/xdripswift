# Direct Watch Libre runtime and acceptance test

The user-started Watch takeover starts one HealthKit workout session with
`HKWorkoutActivityType.other` and indoor location while the Watch owns the
confirmed Libre sensor. It does not request location, start a workout builder
collection, or call `finishWorkout()`. At return, sensor/session change, or
known Watch battery level of 15% or lower, the app ends the session and calls
`discardWorkout()`. If workout authorization is absent or startup fails,
the existing physical-therapy extended runtime is the only fallback. The two
sessions must never overlap. A competing workout blocks automatic workout
restart; other unexpected endings may retry only when the xDrip Watch app
becomes active again.

If HealthKit never reports a running workout, a 30-second system-uptime
budget asks that session to end. The physical-therapy fallback can start
only after HealthKit confirms the workout ended. A paused workout is reported
as unavailable and asked to resume; it cannot count as active runtime.

The Watch application delegate calls HealthKit recovery immediately from
Apple's active-workout recovery callback after a process restart. The
collector then checks persisted
session and sensor identities before reattaching the delegate and reconciling
the existing direct BLE connection. The 4277 known-sensor reconnect and
Watch-to-iPhone delivery paths remain unchanged.

The watchOS 26 API contract was checked against Apple's current documentation:
[`HKWorkoutSession`](https://developer.apple.com/documentation/healthkit/hkworkoutsession),
[`HKHealthStore.requestAuthorization`](https://developer.apple.com/documentation/healthkit/hkhealthstore/requestauthorization%28toshare%3Aread%3Acompletion%3A%29),
[`recoverActiveWorkoutSession`](https://developer.apple.com/documentation/healthkit/hkhealthstore/recoveractiveworkoutsession%28completion%3A%29),
[`handleActiveWorkoutRecovery`](https://developer.apple.com/documentation/watchkit/wkapplicationdelegate/handleactiveworkoutrecovery%28%29),
[`WKBackgroundModes`](https://developer.apple.com/documentation/watchkit/enabling-background-sessions),
and [Watch battery reporting](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/batterylevel).
The code also compiles with Xcode's current Watch SDK.

Watch diagnostics include the HealthKit workout authorization result at takeover,
`runtimeKind` (the requested type followed by the running type), workout
transitions and end reason,
battery fraction at takeover, every 15 minutes and at return, and
`healthTicks10m`. The health timer normally fires every 30 seconds while
execution is available. Missing or low tick counts show that the app did not
receive continuous runtime. Only the pending native connection's age uses
`ContinuousClock`; all other BLE execution budgets still pause during sleep.

**HealthKit limit:** This implementation avoids saving a workout record, but
cannot guarantee zero writes to Health. Apple's
[`Running workout sessions` documentation](https://developer.apple.com/documentation/healthkit/running-workout-sessions)
says the Watch automatically saves active-energy samples while a workout
session runs and generates frequent heart-rate samples.
[`discardWorkout()`](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder/discardworkout%28%29)
does not delete samples already added to HealthKit. The app adds no samples
to its workout builder.

## Physical acceptance test

After an installed build is available, start Watch ownership while the Watch
app is active. Turn off iPhone Bluetooth and Wi-Fi. Leave the Watch owning the
sensor for 2 hours 15 minutes without touching the Watch app, then restore
iPhone Bluetooth and Wi-Fi and return ownership to the phone. Export the Watch
delivery evidence and iPhone activity log, and note takeover/return times.

Report separately for each of the first two 60-minute windows:

| Metric | Calculation |
| --- | --- |
| Sensor minutes | Distinct valid minute timestamps received / expected minutes |
| Unplanned BLE breaks | Count disconnects, grouped by error domain and code |
| Longest gap | Maximum elapsed time between valid technical frames |
| Runtime | Workout state and any type changes throughout the window |
| Health ticks | Sum of reported `healthTicks10m` over the six ten-minute windows |
| Battery | Fraction at takeover and return; change during each hour |

Compare the first hour with 4277's 58/60 sensor minutes (97%). Accept only if
each hour is at least 95%, no technical-frame gap exceeds 3 minutes, and the
workout remains running for the entire 2 hours 15 minutes. A fallback to
physical therapy, absent diagnostics, or an incomplete test is not a pass.
