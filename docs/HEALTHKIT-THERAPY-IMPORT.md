# Apple Health treatment import

This optional iPhone feature reads recorded bolus insulin and carbohydrate entries
from Apple Health into xDrip's existing treatment history. It does not deliver
insulin, recommend a dose, or change the selected insulin or carbohydrate model.
The existing **Write to Apple Health** glucose setting remains separate.

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

When another active import has the same documented external or sync identifier,
its treatment takes precedence. Some source apps do not share an identifier with
their other export routes; xDrip cannot safely infer that equal time and amount
represent the same dose. Check the chosen source and existing imports before
relying on a local estimate; manual entries and genuine repeated doses are never
silently merged by approximate matching.

The imported treatments use xDrip's existing IOB/COB models and iPhone/Watch
presentation, including their freshness limits. Nightscout AID still owns both
metrics when configured; CareLink still owns IOB. An external-source outage does
not silently switch to a local estimate. xDrip reads these Health treatment
types only: it does not write insulin or carbohydrate records back to Health or
automatically forward Health-imported treatments to Nightscout or other services.
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
