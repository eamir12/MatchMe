/// This configuration is used to customize the webview that is used to
/// authenticate the user.
///
/// See more details here:
/// https://learn.microsoft.com/en-us/entra/msal/objc/customize-webviews
///
/// This configuration is only supported on iOS/MacOS platforms.
/// For iOS, it is only used when broker is webView.
final class CustomWebViewConfig {
  /// Title of the webview.
  /// For macOS, this is the title of the authentication window.
  final String? title;

  /// Title of the cancel button. default value is "Cancel".
  /// Available only for iOS.
  final String cancelButtonTitle;

  /// Show navigation controls. default value is "false".
  /// Available only for iOS.
  final bool showNavigationControls;

  const CustomWebViewConfig({
    this.title,
    this.cancelButtonTitle = 'Cancel',
    this.showNavigationControls = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'cancelButtonTitle': cancelButtonTitle,
      'showNavigationControls': showNavigationControls,
    };
  }
}
