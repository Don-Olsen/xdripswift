# Apple Health treatment import

This optional iPhone feature reads recorded bolus insulin and carbohydrate entries
from Apple Health into xDrip's existing treatment history. It does not deliver
insulin or change the selected insulin or carbohydrate model. After the explicit
local cutover below, xDrip also writes its own confirmed bolus and carbohydrate
entries to Health. Imported entries are never echoed back. The existing
**Write to Apple Health** glucose setting remains separate.

## First-time setup

1. On the iPhone, open **xDrip Settings → Sharing and Services → Apple Health**.
2. Turn on **Import bolus insulin** and/or **Import carbohydrates**. Both are off
   until you choose to enable them. In Apple's permission dialog, grant read access
   to **Insulin Delivery** and/or **Dietary Carbohydrates** for the types you enabled.
3. Choose **Insulin source** and **Carbohydrate source** separately. Each menu lists
   sources Apple Health actually reports for that type. Pick the app or device
   that writes your records. If the list is empty, check that the source has saved
   an entry and that Health access is configured, then use **Refresh sources**.
   A missing source or empty read is not proof that there are no treatments.
4. Check the separate import status and **Last sync** under each type. Source
   choices are retained; normal registrations do not require another prompt.

Only insulin samples explicitly marked **bolus** by HealthKit metadata can
contribute to bolus IOB. Basal, unclassified, invalid, and ambiguous-interval
samples do not. Individual dietary-carbohydrate samples contribute grams to COB;
sugar/fiber types and daily summaries are not substituted for meals. The original
recorded time is used, including for entries added later. Import time does not
make an older treatment current.

The importer observes enabled Health types and catches up with anchored queries
at startup, after Health changes, and when protected data becomes available.
It records sample identity, source, deletions, and separate progress for each
type. A local write must succeed before its query progress advances; a failed
read or write is shown as incomplete and retried later. Switching a preferred
source changes which imported records are eligible for the local estimate;
existing manual treatments are retained. An empty Health query never deletes
previously imported records.

## Switch from mySugr to local logging

Choose **mySugr** separately as both the insulin and carbohydrate source, and
enable both imports. The **Log behandlinger i xDrip** row shows the selected
source names and bundle identifiers. The switch completes only after *both*
selected mySugr reads reach their last page and their entries are durably saved.
A read or save error, a changed source or a 60-second timeout leaves the old
imports active and reports failure. An incomplete import cannot certify the
boundary.

The completed switch stores one durable cutoff with the two source identities,
disables continuing mySugr import and selects local IOB/COB ownership. Event
time determines the source even for a backdated entry: imported mySugr entries
before the cutoff remain available, while xDrip and Watch entries from the
cutoff onward are eligible. A repeat switch cannot silently move the cutoff.
Glucose source and Nightscout glucose upload do not change. A mySugr treatment
created only *after* the final import will not be imported later; enter new
treatments in xDrip after switching.
Confirmed treatments entered directly in the iPhone app remain subject to
the app's **existing** Nightscout treatment-upload setting. The new cutover
does not create a network service or explicitly trigger an upload, but it
does not promise that a locally entered treatment stays off Nightscout when
that existing upload is enabled. Imported Health treatments and Watch-local
entries retain their separate exclusion rules.

A full xDrip backup from a phone that had already switched records the source
cutoff as provenance. If that backup is restored onto a phone without an active
cutoff, xDrip marks therapy source setup as required. Local IOB/COB and forecasts
remain unavailable rather than treating missing pre-switch mySugr history as
zero. Complete the mySugr source setup and a successful new local-logging switch
to clear this marker. A settings-only restore does not create this marker, and
an existing destination cutoff is preserved. A stored cutoff that cannot be
decoded also keeps imports and local estimates unavailable; it is never treated
as a fresh pre-switch installation.

Confirmed local bolus and carbohydrate entries keep a stable UUID and a
monotonically increasing Health sync version. A failed Health write never
removes the local entry. A retry uses the same sync ID and version; an edit
keeps the ID and increments the version so HealthKit replaces the previous
sample. The Health write queue tracks the pending version so a previously acknowledged
parent-context write cannot hide a newer edit. Planned and cancelled meals are
not written as consumed food, and
Watch registrations keep their existing local-only rule. The app excludes its
own samples from the Health import ledger. Health write permission is required
on the iPhone; if it is denied, the local record remains pending for retry.
Insulin and carbohydrate inserts, edits and deletions also use a protected
write-ahead gate. A successful child-context save is not treated as completion:
the intended state must be read back from the persistent store. If that cannot
be confirmed, xDrip blocks another dose log until the app has been restarted
and the user has checked the treatment history and, if applicable, Health.
An unrelated later database save cannot silently clear this gate.
Deleting a previously synced local treatment currently does **not** delete its
Health copy; xDrip will not reimport that copy. The Health record can be removed
in Apple's Health app. Automatic Health deletion needs separate authorization
and is not part of this build.

When another active import has the same documented external or sync identifier,
its treatment takes precedence. Some source apps do not share an identifier with
their other export routes; xDrip cannot safely infer that equal time and amount
represent the same dose. Check the chosen source and existing imports before
relying on a local estimate; manual entries and genuine repeated doses are never
silently merged by approximate matching.

The imported treatments use xDrip's existing IOB/COB models and iPhone/Watch
presentation, including their freshness limits. Nightscout AID still owns both
metrics when configured; CareLink still owns IOB. An external-source outage does
not silently switch to a local estimate. Before explicit cutover, xDrip reads
these Health treatment types only. Health-imported treatments are never
automatically forwarded to Nightscout or other services.
Apple does not disclose complete HealthKit read permission to an app. A completed
permission dialog, a recent sync, or an empty result cannot guarantee that all
records are available; check the status before relying on a local estimate.

## Physical acceptance checks still required

Automated tests use synthetic samples in isolated stores. They cannot establish
real HealthKit permissions, background delivery, or Watch behavior. Before
relying on this feature, verify on the user's own iPhone and Watch:

- With each import off, confirm existing glucose export is unchanged. Then enable
  one type at a time, grant only its read permission, choose the actual source,
  and compare a recorded bolus and meal with xDrip's treatment history and
  calculated IOB/COB. Check that basal and unclassified insulin are excluded.
- Check a backdated entry, a corrected entry (deletion followed by a new sample),
  and a deletion. Confirm recorded times, no duplicate treatment on repeat sync,
  and no deletion of a manual entry or genuine repeated dose.
- Check foreground catch-up, app restart, offline-to-online catch-up, background
  Health notification delivery, and retry after the phone has been locked and
  protected data becomes available again. Check Last sync and incomplete status
  when Health access is denied, partial, or unavailable.
- Compare iPhone and Watch values after a fresh treatment and after the normal
  freshness deadline; confirm a stale or unavailable estimate is not shown as
  newly current. Check that the configured external metric source retains its
  priority and that no treatment is sent to an external service.

Record actual device results and any unresolved issue in `docs/PROJECT-STATUS.md`.
