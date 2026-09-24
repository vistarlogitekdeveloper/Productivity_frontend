/// Runtime feature switches for the DPL module.
///
/// Flags live here (not on a server response) because the gates they
/// drive are UI shape decisions, not policy. Flipping one off should
/// be a one-line edit + redeploy, used as a fast rollback lever if a
/// new flow misbehaves in the field.
///
/// Default values reflect the *current* production posture, not the
/// legacy posture. A flag set to `true` means the new behaviour is
/// already in the user's hands.
class DplFeatureFlags {
  /// Trip-driven dispatch (migration 048).
  ///
  /// When `true`:
  ///   * The dispatcher landing screen shows the "Open Trips" section
  ///     at the top.
  ///   * The legacy per-plant manual machine-picker form inside
  ///     `PlantCard` is hidden — dispatchers cut slips by ticking
  ///     plans on a manager-submitted trip.
  ///
  /// When `false`:
  ///   * Open Trips section disappears (Phase 2 widget renders empty).
  ///   * Legacy machine-picker form is restored as the only slip
  ///     creation path.
  ///
  /// Backend supports both shapes simultaneously (`POST /dispatch/slips`
  /// auto-detects via `trip_id` presence), so flipping this is safe.
  static const bool enableDispatchTrips = true;

  /// Cap a trip plan's qty at the labelled stock (migration 147).
  ///
  /// Currently **OFF**, at the plant's request: labels are not yet flowing for
  /// every part, so the cap had the effect of blocking trip planning outright.
  /// With nothing printed the allowance is zero, the qty field rejects every
  /// keystroke, and Submit can never enable — there is no way to plan at all.
  ///
  /// When `true`:
  ///   * The qty input is hard-capped at `printed − already loaded onto a trip`.
  ///   * Submit is refused if the draft exceeds that across all trips.
  ///   * `POST /dispatch/trips` refuses with `LABEL_STOCK_EXCEEDED` — the
  ///     backend has its own switch, `DPL_ENFORCE_LABEL_STOCK_ON_PLAN`, and
  ///     BOTH must be on for the rule to bite.
  ///
  /// When `false` (today):
  ///   * Planning is unrestricted. The labelled-stock figure is still fetched
  ///     and still SHOWN beside the qty, because knowing a part has no labels
  ///     is useful even when it is not a blocker — it just no longer stops
  ///     anyone.
  ///
  /// Turning this off does NOT weaken the dispatch guarantee. Nothing
  /// unlabelled can still ship: `createSlipFromTrip` refuses to cut a slip
  /// until every planned piece has been physically scanned onto the trip
  /// (`LABELS_NOT_SCANNED`), and that gate is untouched by this flag. This one
  /// only governs how early the system complains.
  static const bool enforceLabelStockOnPlan = false;
}
