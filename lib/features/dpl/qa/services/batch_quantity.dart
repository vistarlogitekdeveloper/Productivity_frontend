/// How many labels one press issues.
///
/// Pulled out of the print screen's State so it can be tested. These are the
/// numbers a button promises and a printer obeys; getting them wrong either
/// prints labels for parts that do not exist or sends the server a request it
/// will refuse with a message no operator can act on.
class BatchQuantity {
  const BatchQuantity._();

  /// The most the server will issue in one request.
  ///
  /// Enforced twice on the backend — `issueStickersSchema`'s `max(500)`, which
  /// answers 400 VALIDATION_ERROR, and `partStickerService`'s own `n > 500`
  /// check, which answers BATCH_TOO_LARGE. Joi fires first, so exceeding this
  /// surfaces as a raw validation message about a field the operator never
  /// sees. Keep this in step with both.
  static const int maxPerBatch = 500;

  /// The largest quantity a single press may ask for: whatever is still
  /// allowed for the plan item, but never more than one batch.
  ///
  /// Returns 1 when nothing is left. The caller disables the button in that
  /// case; returning 0 would make the label read "print 0 labels".
  static int ceiling(int remainingQty) {
    if (remainingQty <= 0) return 1;
    return remainingQty < maxPerBatch ? remainingQty : maxPerBatch;
  }

  /// What the operator typed, resolved to what will actually be sent.
  ///
  /// [batch] is whether this organization holds `labels.print_batch`. Without
  /// it the answer is always 1 and the screen shows no field at all.
  ///
  /// Garbage in — an empty field mid-edit, a pasted minus sign — resolves to 1
  /// rather than to an error, because the button has to mean something at
  /// every keystroke.
  static int resolve({
    required String typed,
    required int remainingQty,
    required bool batch,
  }) {
    if (!batch) return 1;
    final parsed = int.tryParse(typed.trim()) ?? 1;
    if (parsed < 1) return 1;
    final cap = ceiling(remainingQty);
    return parsed > cap ? cap : parsed;
  }

  /// Quick quantities, so common pack sizes are one tap rather than typed.
  ///
  /// [ceilingQty] is what [ceiling] returned. Presets at or above it collapse
  /// into a single "all of it" button: offering 50 when 12 remain is offering
  /// a refusal, and strictly-less-than also keeps a duplicate out of the list
  /// when a common size equals the ceiling exactly.
  static List<int> presets(int ceilingQty) {
    const common = [5, 10, 16, 25, 50];
    final out = common.where((p) => p < ceilingQty).toList();
    if (ceilingQty > 0) out.add(ceilingQty);
    return out;
  }
}
