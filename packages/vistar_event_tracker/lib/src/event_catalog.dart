/// Dart-side event catalog — the compile-time companion to the backend
/// `catalog.js`. Keep the two in sync: names here should exist there so that,
/// with `EVENTTRACKER_STRICT_CATALOG=true`, ingestion never rejects a batch.
///
/// Use these constants instead of raw strings at call sites for safety:
///   tracker.track(VistarEvents.orderPlaced, properties: {'amount': 250});
class VistarEvents {
  VistarEvents._();

  // lifecycle / system
  static const appOpen = 'app_open';
  static const appBackground = 'app_background';
  static const appForeground = 'app_foreground';
  static const sessionStart = 'session_start';
  static const sessionEnd = 'session_end';

  // identity
  static const userSignedUp = 'user_signed_up';
  static const userLoggedIn = 'user_logged_in';
  static const userLoggedOut = 'user_logged_out';
  static const userIdentified = 'user_identified';

  // navigation
  static const screenViewed = 'screen_viewed';
  static const pageViewed = 'page_viewed';

  // commerce / core funnel
  static const productViewed = 'product_viewed';
  static const productSearched = 'product_searched';
  static const cartItemAdded = 'cart_item_added';
  static const cartItemRemoved = 'cart_item_removed';
  static const checkoutStarted = 'checkout_started';
  static const orderPlaced = 'order_placed';
  static const orderCancelled = 'order_cancelled';
  static const paymentSucceeded = 'payment_succeeded';
  static const paymentFailed = 'payment_failed';

  // engagement
  static const buttonTapped = 'button_tapped';
  static const linkClicked = 'link_clicked';
  static const formSubmitted = 'form_submitted';
  static const notificationOpened = 'notification_opened';
  static const fileDownloaded = 'file_downloaded';

  // errors
  static const clientError = 'client_error';
  static const apiError = 'api_error';

  /// Snake_case guard mirroring the backend's regex, for optional local checks.
  static final RegExp namePattern = RegExp(r'^[a-z0-9]+(_[a-z0-9]+)*$');
  static bool isValidName(String name) => namePattern.hasMatch(name);
}
