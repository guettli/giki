/// The server a fresh device should sign in to by default.
library;

/// The origin of [page], or '' when the app was not loaded from a web server.
///
/// The server serves the app itself, so on a fresh device the page's own
/// origin is almost always the server to sign in to. It is only a default for
/// the text field: nothing is stored until the user acts.
String servingOrigin(Uri page) {
  if (page.scheme != 'http' && page.scheme != 'https') {
    return '';
  }
  return page.origin;
}
