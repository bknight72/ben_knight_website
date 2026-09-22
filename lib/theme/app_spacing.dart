/// Shared spacing scale used for padding and gaps across section widgets.
///
/// Every named value below maps 1:1 to a literal that was previously
/// hardcoded inline; changing a value here updates every call site at once.
/// Values that only ever occurred once and don't fit the shared scale are
/// deliberately left as local literals (see individual widget files) rather
/// than added here, to keep this scale from growing unbounded.
class AppSpacing {
  AppSpacing._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 28;
  static const double xxxl = 32;
  static const double huge = 64;
  static const double hero = 96;
}
