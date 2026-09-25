import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/local_storage_repository.dart';

/// The floor language for DPL messages (Maxion phase 4).
///
/// `null` is English. 'mr' (मराठी) or 'hi' (हिन्दी) makes every DPL request
/// carry `X-App-Language`, and the server then adds `message_local` to any
/// refusal a floor operator can meet (scans, pallets, trips, returns,
/// counts). The English message is always kept alongside, so a supervisor
/// reading over a shoulder sees the same thing the operator does.
class DplLanguageController extends Notifier<String?> {
  static const Map<String?, String> choices = {
    null: 'English',
    'mr': 'मराठी',
    'hi': 'हिन्दी',
  };

  @override
  String? build() {
    final saved = ref.read(localStorageRepositoryProvider).getDplLanguage();
    return choices.containsKey(saved) ? saved : null;
  }

  Future<void> set(String? code) async {
    final next = choices.containsKey(code) ? code : null;
    state = next;
    await ref.read(localStorageRepositoryProvider).saveDplLanguage(next);
  }
}

final dplLanguageProvider =
    NotifierProvider<DplLanguageController, String?>(DplLanguageController.new);
