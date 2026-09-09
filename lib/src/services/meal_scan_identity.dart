import 'package:supabase_flutter/supabase_flutter.dart';

import 'recipe_image_store.dart';

/// Fences photo selection and preview before their first upload. Mounted alone
/// is insufficient between an auth event and the next widget-tree rebuild.
class MealScanIdentity {
  MealScanIdentity({String? Function()? currentUserId})
    : _readUserId = currentUserId ?? _supabaseUserId,
      _images = RecipeImageStore.instance {
    _userId = _readUserId();
    _scope = _images.scopeToken;
  }

  final String? Function() _readUserId;
  final RecipeImageStore _images;
  late final String? _userId;
  late final Object _scope;

  bool get isCurrent =>
      identical(RecipeImageStore.instance, _images) &&
      identical(_images.scopeToken, _scope) &&
      _readUserId() == _userId;

  static String? _supabaseUserId() {
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } on AssertionError {
      // Widget previews use fake analyzers without initializing Supabase.
      // A real upload still requires the analyzer's authenticated session.
      return null;
    }
  }
}
