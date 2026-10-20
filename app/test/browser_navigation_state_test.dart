import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/features/browser/browser_navigation_state.dart';

void main() {
  test('refresh is loading immediately and clears on finish', () {
    final state = BrowserNavigationState();

    state.beginRequested('https://example.com');
    expect(state.isLoading, isTrue);
    state.pageStarted('https://example.com');
    expect(state.pageFinished('https://example.com'), isTrue);
    expect(state.isLoading, isFalse);
  });

  test('main-frame failure clears the current navigation', () {
    final state = BrowserNavigationState();

    state.pageStarted('https://example.com/failure');
    expect(state.pageFailed('https://example.com/failure'), isTrue);
    expect(state.isLoading, isFalse);
  });

  test('request can finish or fail before a page-start callback', () {
    final state = BrowserNavigationState();

    state.beginRequested('https://example.com/fast');
    expect(state.pageFinished('https://example.com/fast'), isTrue);
    expect(state.isLoading, isFalse);

    state.beginRequested('https://example.com/failure');
    expect(state.pageFailed(null), isTrue);
    expect(state.isLoading, isFalse);
  });

  test('stale callbacks cannot clear a newer repeated refresh', () {
    final state = BrowserNavigationState();

    state.beginRequested('https://example.com');
    state.beginRequested('https://example.com');
    state.pageStarted('https://example.com');
    state.pageStarted('https://example.com');

    expect(state.pageFinished('https://example.com'), isFalse);
    expect(state.isLoading, isTrue);
    expect(state.pageFailed('https://example.com'), isTrue);
    expect(state.isLoading, isFalse);
  });

  test('stale redirect finish does not clear the current page', () {
    final state = BrowserNavigationState();

    state.pageStarted('https://example.com/old');
    state.pageStarted('https://example.com/new');
    expect(state.pageFinished('https://example.com/old'), isFalse);
    expect(state.isLoading, isTrue);
    expect(state.pageFinished('https://example.com/new'), isTrue);
    expect(state.isLoading, isFalse);
  });
}
