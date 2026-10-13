import 'package:flutter/widgets.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

final fakeLoadedHtmlStrings = <String>[];
final fakeLoadedRequestUrls = <String>[];
final fakeExecutedJavaScripts = <String>[];
int fakeClearCookieCalls = 0;
int fakeReloadCalls = 0;
int fakeWebViewControllerCreationCount = 0;
final _fakeWebViewControllers = <_FakePlatformWebViewController>[];

Future<NavigationDecision?> submitFakeNavigationRequest({
  required int controllerIndex,
  required String url,
  required bool isMainFrame,
}) {
  return _fakeWebViewControllers[controllerIndex].requestNavigation(
    NavigationRequest(url: url, isMainFrame: isMainFrame),
  );
}

void submitFakeUrlChange({
  required int controllerIndex,
  required String url,
}) {
  _fakeWebViewControllers[controllerIndex].changeUrl(url);
}

void submitFakeJavaScriptMessage({
  required int controllerIndex,
  required String channel,
  required String message,
}) {
  _fakeWebViewControllers[controllerIndex].postJavaScriptMessage(
    channel,
    message,
  );
}

void setFakePageTitle({
  required int controllerIndex,
  required String? title,
}) {
  _fakeWebViewControllers[controllerIndex]._title = title;
}

void setFakeTitleRetrievalFailure({
  required int controllerIndex,
  required bool fails,
}) {
  _fakeWebViewControllers[controllerIndex]._titleRetrievalFails = fails;
}

void submitFakeWebResourceError(
    {required int controllerIndex, required WebResourceError error}) {
  _fakeWebViewControllers[controllerIndex]
      ._navigationDelegate
      ?._onWebResourceError
      ?.call(error);
}

void submitFakePageFinished({
  required int controllerIndex,
  required String url,
}) {
  _fakeWebViewControllers[controllerIndex].finish(url);
}

void installFakeWebViewPlatform() {
  fakeLoadedHtmlStrings.clear();
  fakeLoadedRequestUrls.clear();
  fakeExecutedJavaScripts.clear();
  fakeClearCookieCalls = 0;
  fakeReloadCalls = 0;
  fakeWebViewControllerCreationCount = 0;
  _fakeWebViewControllers.clear();
  WebViewPlatform.instance = _FakeWebViewPlatform();
}

class _FakeWebViewPlatform extends WebViewPlatform
    with MockPlatformInterfaceMixin {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    fakeWebViewControllerCreationCount += 1;
    final controller = _FakePlatformWebViewController(params);
    _fakeWebViewControllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    return _FakePlatformNavigationDelegate(params);
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) {
    return _FakePlatformWebViewWidget(params);
  }

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) {
    return _FakePlatformWebViewCookieManager(params);
  }
}

class _FakePlatformWebViewController extends PlatformWebViewController
    with MockPlatformInterfaceMixin {
  _FakePlatformWebViewController(super.params) : super.implementation();

  _FakePlatformNavigationDelegate? _navigationDelegate;
  String? _currentUrl;
  String? _title;
  bool _titleRetrievalFails = false;
  final Map<String, void Function(JavaScriptMessage)> _javaScriptChannels = {};

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {
    _javaScriptChannels[javaScriptChannelParams.name] =
        javaScriptChannelParams.onMessageReceived;
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    if (handler is _FakePlatformNavigationDelegate) {
      _navigationDelegate = handler;
    }
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    final url = params.uri.toString();
    final decision = await _navigationDelegate?.request(
      NavigationRequest(url: url, isMainFrame: true),
    );
    if (decision == NavigationDecision.prevent) return;
    _currentUrl = url;
    fakeLoadedRequestUrls.add(url);
    _navigationDelegate?.finish(_currentUrl!);
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    fakeLoadedHtmlStrings.add(html);
    _currentUrl = baseUrl ?? 'about:blank';
    _navigationDelegate?.finish(_currentUrl!);
  }

  @override
  Future<String?> currentUrl() async => _currentUrl;

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<bool> canGoForward() async => false;

  @override
  Future<void> goBack() async {}

  @override
  Future<void> goForward() async {}

  @override
  Future<void> reload() async {
    fakeReloadCalls++;
  }

  @override
  Future<void> clearCache() async {}

  @override
  Future<void> clearLocalStorage() async {}

  @override
  Future<void> runJavaScript(String javaScript) async {
    fakeExecutedJavaScripts.add(javaScript);
  }

  @override
  Future<String?> getTitle() async {
    if (_titleRetrievalFails) throw StateError('Fake title retrieval failure');
    return _title;
  }

  Future<NavigationDecision?> requestNavigation(
    NavigationRequest request,
  ) async {
    return _navigationDelegate?.request(request);
  }

  void changeUrl(String url) {
    _currentUrl = url;
    _navigationDelegate?.changeUrl(url);
  }

  void postJavaScriptMessage(String channel, String message) {
    _javaScriptChannels[channel]?.call(JavaScriptMessage(message: message));
  }

  void finish(String url) {
    _currentUrl = url;
    _navigationDelegate?.finish(url);
  }
}

class _FakePlatformNavigationDelegate extends PlatformNavigationDelegate
    with MockPlatformInterfaceMixin {
  _FakePlatformNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? _onNavigationRequest;
  PageEventCallback? _onPageStarted;
  PageEventCallback? _onPageFinished;
  UrlChangeCallback? _onUrlChange;
  WebResourceErrorCallback? _onWebResourceError;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {
    _onNavigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async {
    _onPageStarted = callback;
  }

  @override
  Future<void> setOnWebResourceError(
      WebResourceErrorCallback onWebResourceError) async {
    _onWebResourceError = onWebResourceError;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    _onPageFinished = onPageFinished;
  }

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {
    _onUrlChange = onUrlChange;
  }

  Future<NavigationDecision?> request(NavigationRequest request) async {
    final decision = await _onNavigationRequest?.call(request);
    if (request.isMainFrame && decision != NavigationDecision.prevent) {
      _onPageStarted?.call(request.url);
    }
    return decision;
  }

  void finish(String url) {
    _onPageFinished?.call(url);
  }

  void changeUrl(String url) {
    _onUrlChange?.call(UrlChange(url: url));
  }
}

class _FakePlatformWebViewWidget extends PlatformWebViewWidget
    with MockPlatformInterfaceMixin {
  _FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.expand();
  }
}

class _FakePlatformWebViewCookieManager extends PlatformWebViewCookieManager
    with MockPlatformInterfaceMixin {
  _FakePlatformWebViewCookieManager(super.params) : super.implementation();

  @override
  Future<bool> clearCookies() async {
    fakeClearCookieCalls += 1;
    return true;
  }

  @override
  Future<void> setCookie(WebViewCookie cookie) async {}

  @override
  Future<List<WebViewCookie>> getCookies(Uri url) async => [];
}
