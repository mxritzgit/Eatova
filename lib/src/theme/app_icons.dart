import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// ICONS (UI polish 2026-11-01) — the app's ONE interface icon layer.
//
// Screens name a CONCEPT (`AppIcons.edit`), never a font glyph; this file is
// the only place that knows the font, so switching the family is a change to
// this file (plus its package when the family is one).
//
// Family: Material Icons from the SDK, no extra dependency ("option B" of the
// UI polish brief). Material Symbols Rounded (option A) was measured and
// failed the size gate once fully migrated: all 152 concepts shook the
// Rounded font to 444,760 bytes against a 250 kB limit (APK +232 kB;
// docs/design/UI-FOUNDATION-2026-11-01.md). The rule that makes option B
// read as one family:
//   * objects (pencil, bin, bell, calendar, camera) as a contour:
//     `*_outline_rounded` where it exists, else `*_outlined`;
//   * line glyphs (check, plus, chevrons, arrows, close) as `*_rounded`;
//   * an "on" state (favourite set, saved, done, listening) is the FILLED
//     glyph of the same concept, through [AppIcons.filled] / [StateIcon] —
//     never decoration.
// The theme's icon axes (fill, weight, grade, optical size) are ignored by
// this font and take effect only with a variable family such as Symbols.
//
// Rules:
//   * Every entry is a `static const`: release builds shake the icon font to
//     the glyphs referenced by constants. A computed `IconData` or a lookup
//     by name keeps the whole font (repo rule in test/repo_rules_test.dart).
//   * One concept, one glyph. A missing concept is added here, not spelled
//     out in a screen.
//   * Steps are the custom footprint [StepsIcon], not a walking person.
//   * [aiMark] (the sparkles) is only an AI ORIGIN mark right next to the
//     word "KI"/"AI" (disclosure, consent, AI estimate). Everywhere else a
//     glyph of the task (camera, note, document; the Coach's conversation).
// ---------------------------------------------------------------------------

/// Semantic icon constants. See the file header for the rules.
abstract final class AppIcons {
  /// The "on" glyph of a state concept: [favorite] set, [checkCircle] done,
  /// [bookmarkAdded] saved, [mic] listening. Concepts without a filled form
  /// return themselves. [StateIcon] and `AppIconButton(selected:)` use it.
  static IconData filled(IconData icon) => switch (icon) {
    favorite => Icons.favorite_rounded,
    checkCircle => Icons.check_circle_rounded,
    removeCircle => Icons.remove_circle_rounded,
    bookmarkAdded => Icons.bookmark_added_rounded,
    bookmarkAdd => Icons.bookmark_add_rounded,
    mic => Icons.mic_rounded,
    notifications => Icons.notifications_rounded,
    pauseCircle => Icons.pause_circle_rounded,
    flag => Icons.flag_rounded,
    eventAvailable => Icons.event_available_rounded,
    person => Icons.person_rounded,
    lock => Icons.lock_rounded,
    lightbulb => Icons.lightbulb_rounded,
    chatBubble => Icons.chat_bubble_rounded,
    _ => icon,
  };

  // --- Actions ---------------------------------------------------------------
  static const IconData add = Icons.add_rounded;
  static const IconData remove = Icons.remove_rounded;
  static const IconData edit = Icons.edit_outlined;
  static const IconData editNote = Icons.edit_note_outlined;
  static const IconData editOff = Icons.edit_off_outlined;
  static const IconData delete = Icons.delete_outline_rounded;
  static const IconData close = Icons.close_rounded;
  static const IconData check = Icons.check_rounded;
  static const IconData doneAll = Icons.done_all_rounded;
  static const IconData copy = Icons.content_copy_outlined;
  static const IconData contentPaste = Icons.content_paste_outlined;
  static const IconData folderCopy = Icons.folder_copy_outlined;
  static const IconData search = Icons.search_rounded;
  static const IconData searchOff = Icons.search_off_rounded;
  static const IconData manageSearch = Icons.manage_search_rounded;
  static const IconData imageSearch = Icons.image_search_outlined;
  static const IconData refresh = Icons.refresh_rounded;
  static const IconData replay = Icons.replay_rounded;
  static const IconData restartAlt = Icons.restart_alt_rounded;
  static const IconData restore = Icons.restore_rounded;
  static const IconData autorenew = Icons.autorenew_rounded;
  static const IconData sync = Icons.sync_rounded;
  static const IconData syncProblem = Icons.sync_problem_rounded;
  static const IconData undo = Icons.undo_rounded;
  static const IconData redo = Icons.redo_rounded;
  static const IconData iosShare = Icons.ios_share_rounded;
  static const IconData fileDownload = Icons.file_download_outlined;
  static const IconData openInNew = Icons.open_in_new_rounded;
  static const IconData link = Icons.link_rounded;
  static const IconData linkOff = Icons.link_off_rounded;
  static const IconData logout = Icons.logout_rounded;
  static const IconData tune = Icons.tune_rounded;
  static const IconData sort = Icons.sort_rounded;
  static const IconData swapHoriz = Icons.swap_horiz_rounded;
  static const IconData moreHoriz = Icons.more_horiz_rounded;
  static const IconData playlistAddCheck = Icons.playlist_add_check_rounded;
  static const IconData playlistRemove = Icons.playlist_remove_rounded;
  static const IconData translate = Icons.translate_rounded;

  // --- Navigation and disclosure -------------------------------------------
  static const IconData chevronLeft = Icons.chevron_left_rounded;
  static const IconData chevronRight = Icons.chevron_right_rounded;
  static const IconData expandMore = Icons.expand_more_rounded;
  static const IconData expandLess = Icons.expand_less_rounded;
  static const IconData arrowBack = Icons.arrow_back_rounded;
  static const IconData arrowForward = Icons.arrow_forward_rounded;
  static const IconData arrowUpward = Icons.arrow_upward_rounded;
  static const IconData arrowDownward = Icons.arrow_downward_rounded;
  static const IconData arrowOutward = Icons.arrow_outward_rounded;
  static const IconData northEast = Icons.north_east_rounded;

  // --- Status and feedback ---------------------------------------------------
  static const IconData info = Icons.info_outline_rounded;
  static const IconData error = Icons.error_outline_rounded;
  static const IconData warning = Icons.warning_amber_rounded;
  static const IconData priorityHigh = Icons.priority_high_rounded;
  static const IconData lightbulb = Icons.lightbulb_outline_rounded;

  /// Done as a STATE: [filled] when done, the contour otherwise.
  static const IconData checkCircle = Icons.check_circle_outline_rounded;
  static const IconData removeCircle = Icons.remove_circle_outline_rounded;
  static const IconData cloudOff = Icons.cloud_off_outlined;
  static const IconData cloudDone = Icons.cloud_done_outlined;
  static const IconData cloudSync = Icons.cloud_sync_outlined;
  static const IconData cloudUpload = Icons.cloud_upload_outlined;
  static const IconData hourglassEmpty = Icons.hourglass_empty_rounded;
  static const IconData hourglassTop = Icons.hourglass_top_rounded;
  static const IconData schedule = Icons.schedule_rounded;
  static const IconData timer = Icons.timer_outlined;
  static const IconData history = Icons.history_rounded;
  static const IconData historyToggleOff = Icons.history_toggle_off_rounded;
  static const IconData lock = Icons.lock_outline_rounded;
  static const IconData lockReset = Icons.lock_reset_rounded;
  static const IconData lockClock = Icons.lock_clock_outlined;
  static const IconData key = Icons.key_outlined;
  static const IconData shield = Icons.shield_outlined;
  static const IconData healthAndSafety = Icons.health_and_safety_outlined;
  static const IconData visibility = Icons.visibility_outlined;
  static const IconData visibilityOff = Icons.visibility_off_outlined;
  static const IconData science = Icons.science_outlined;
  static const IconData factCheck = Icons.fact_check_outlined;
  static const IconData thumbDownAlt = Icons.thumb_down_alt_outlined;

  /// The AI ORIGIN mark, only right next to the word "KI"/"AI".
  static const IconData aiMark = Icons.auto_awesome_outlined;

  // --- States with a filled form ([filled]) ----------------------------------
  /// Favourite: [filled] when set.
  static const IconData favorite = Icons.favorite_outline_rounded;

  /// Saved: [filled].
  static const IconData bookmarkAdded = Icons.bookmark_added_outlined;
  static const IconData bookmarkAdd = Icons.bookmark_add_outlined;

  // --- Media -----------------------------------------------------------------
  static const IconData playArrow = Icons.play_arrow_rounded;
  static const IconData pause = Icons.pause_rounded;
  static const IconData pauseCircle = Icons.pause_circle_outline_rounded;
  static const IconData stop = Icons.stop_rounded;
  static const IconData skipNext = Icons.skip_next_rounded;
  static const IconData mic = Icons.mic_none_rounded;

  // --- People, account and communication ------------------------------------
  static const IconData person = Icons.person_outline_rounded;
  static const IconData manageAccounts = Icons.manage_accounts_outlined;
  static const IconData mail = Icons.mail_outline_rounded;
  static const IconData markEmailRead = Icons.mark_email_read_outlined;
  static const IconData markEmailUnread = Icons.mark_email_unread_outlined;
  static const IconData alternateEmail = Icons.alternate_email_rounded;
  static const IconData chatBubble = Icons.chat_bubble_outline_rounded;
  static const IconData forum = Icons.forum_outlined;
  static const IconData notifications = Icons.notifications_none_rounded;
  static const IconData notificationsActive =
      Icons.notifications_active_outlined;
  static const IconData notificationsOff = Icons.notifications_off_outlined;
  static const IconData settings = Icons.settings_outlined;
  static const IconData workspacePremium = Icons.workspace_premium_outlined;
  static const IconData phoneAndroid = Icons.phone_android_outlined;
  static const IconData keyboard = Icons.keyboard_outlined;
  static const IconData keyboardAlt = Icons.keyboard_alt_outlined;
  static const IconData female = Icons.female_rounded;
  static const IconData male = Icons.male_rounded;
  static const IconData cake = Icons.cake_outlined;
  static const IconData height = Icons.height_rounded;
  static const IconData accessibilityNew = Icons.accessibility_new_rounded;

  // --- Food, recipes and planning -------------------------------------------
  static const IconData restaurant = Icons.restaurant_rounded;
  static const IconData restaurantMenu = Icons.restaurant_menu_rounded;
  static const IconData setMeal = Icons.set_meal_outlined;
  static const IconData soupKitchen = Icons.soup_kitchen_outlined;
  static const IconData menuBook = Icons.menu_book_outlined;
  static const IconData noFood = Icons.no_food_outlined;
  static const IconData eco = Icons.eco_outlined;
  static const IconData spa = Icons.spa_outlined;
  static const IconData shoppingBasket = Icons.shopping_basket_outlined;
  static const IconData storefront = Icons.storefront_outlined;
  static const IconData warehouse = Icons.warehouse_outlined;
  static const IconData flame = Icons.local_fire_department_outlined;
  static const IconData calculate = Icons.calculate_outlined;
  static const IconData balance = Icons.balance_rounded;
  static const IconData calendar = Icons.calendar_month_outlined;
  static const IconData eventAvailable = Icons.event_available_outlined;
  static const IconData eventNote = Icons.event_note_outlined;
  static const IconData notes = Icons.notes_rounded;
  static const IconData description = Icons.description_outlined;
  static const IconData formatListNumbered =
      Icons.format_list_numbered_rounded;
  static const IconData tableRows = Icons.table_rows_outlined;
  static const IconData gridOn = Icons.grid_on_outlined;
  static const IconData flag = Icons.flag_outlined;

  // --- Body, training and progress ------------------------------------------
  static const IconData monitorWeight = Icons.monitor_weight_outlined;
  static const IconData straighten = Icons.straighten_outlined;
  static const IconData fitnessCenter = Icons.fitness_center_rounded;
  static const IconData trophy = Icons.emoji_events_outlined;
  static const IconData speed = Icons.speed_rounded;
  /// Trends and the weekly check. Not Material's `insights`: its sparkles
  /// read as the AI mark, which stays next to the word "KI" only.
  static const IconData insights = Icons.query_stats_rounded;
  static const IconData queryStats = Icons.query_stats_rounded;
  static const IconData showChart = Icons.show_chart_rounded;
  static const IconData donutSmall = Icons.donut_small_outlined;
  static const IconData trendingUp = Icons.trending_up_rounded;
  static const IconData trendingDown = Icons.trending_down_rounded;
  static const IconData trendingFlat = Icons.trending_flat_rounded;
  static const IconData contrast = Icons.contrast_rounded;

  // --- Camera, images and capture -------------------------------------------
  static const IconData photoCamera = Icons.photo_camera_outlined;
  static const IconData addAPhoto = Icons.add_a_photo_outlined;
  static const IconData noPhotography = Icons.no_photography_outlined;
  static const IconData photoLibrary = Icons.photo_library_outlined;
  static const IconData image = Icons.image_outlined;
  static const IconData hideImage = Icons.hide_image_outlined;
  static const IconData imageNotSupported = Icons.image_not_supported_outlined;
  static const IconData flashOn = Icons.flash_on_rounded;
  static const IconData flashOff = Icons.flash_off_rounded;
}

/// The six icon sizes. Any other literal size is off the scale.
///
/// | size       | where                                                  |
/// |------------|--------------------------------------------------------|
/// | [meta]     | meta lines, [StatusPill], small chips                  |
/// | [small]    | next to 13–14 px text, badge `sm`, chips               |
/// | [button]   | inside labelled buttons (primary, soft, text)          |
/// | [standard] | icon buttons, menu rows, chevrons, badge `md`          |
/// | [tile]     | badge `lg`, the tab roots' design glyphs               |
/// | [large]    | large icon buttons, empty states                       |
abstract final class AppIconSize {
  static const double meta = 14;
  static const double small = 16;
  static const double button = 18;
  static const double standard = 20;
  static const double tile = 22;
  static const double large = 24;
}
