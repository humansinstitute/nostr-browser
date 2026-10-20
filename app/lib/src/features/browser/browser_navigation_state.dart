import 'dart:collection';

/// Tracks overlapping main-frame navigations without letting an older callback
/// clear the visible state for a newer refresh or navigation.
class BrowserNavigationState {
  final Queue<_PendingNavigation> _pending = Queue<_PendingNavigation>();
  int _nextId = 0;
  int? _activeId;

  bool get isLoading => _activeId != null;

  int beginRequested(String url) {
    final navigation = _PendingNavigation(
      id: ++_nextId,
      url: url,
      awaitingStart: true,
    );
    _pending.add(navigation);
    _activeId = navigation.id;
    _trim();
    return navigation.id;
  }

  void pageStarted(String url) {
    for (final navigation in _pending) {
      if (navigation.awaitingStart && navigation.url == url) {
        navigation.awaitingStart = false;
        if (_activeId == null || navigation.id > _activeId!) {
          _activeId = navigation.id;
        }
        return;
      }
    }
    final navigation = _PendingNavigation(id: ++_nextId, url: url);
    _pending.add(navigation);
    _activeId = navigation.id;
    _trim();
  }

  bool pageFinished(String url) => _complete(url: url);

  bool pageFailed(String? url) => _complete(url: url);

  bool requestFailed(int id) {
    _PendingNavigation? navigation;
    for (final item in _pending) {
      if (item.id == id) {
        navigation = item;
        break;
      }
    }
    if (navigation == null) return false;
    _pending.remove(navigation);
    if (_activeId != id) return false;
    _activeId = null;
    return true;
  }

  bool _complete({required String? url}) {
    _PendingNavigation? completed;
    if (url == null && _activeId != null) {
      for (final navigation in _pending) {
        if (navigation.id == _activeId) {
          completed = navigation;
          break;
        }
      }
    }
    for (final navigation in _pending) {
      if (completed == null && (url == null || navigation.url == url)) {
        completed = navigation;
        break;
      }
    }
    if (completed == null) return false;
    _pending.remove(completed);
    if (_activeId != completed.id) return false;
    _activeId = null;
    return true;
  }

  void _trim() {
    while (_pending.length > 16) {
      final removed = _pending.removeFirst();
      if (_activeId == removed.id) _activeId = null;
    }
  }
}

class _PendingNavigation {
  _PendingNavigation({
    required this.id,
    required this.url,
    this.awaitingStart = false,
  });

  final int id;
  final String url;
  bool awaitingStart;
}
