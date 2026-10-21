/// Runs in every WebKit frame: native platform views do not route their key
/// events through Flutter's focus tree. Never infer DOM editing from shell focus.
const browserKeyboardShortcutsScript = r'''
(() => {
  if (window.__wingmanNavigationKeys) return;
  window.__wingmanNavigationKeys = true;
  const isEditor = node => node && node.nodeType === 1 && (
    node.isContentEditable ||
    /^(INPUT|TEXTAREA|SELECT|IFRAME|OBJECT|EMBED)$/.test(node.tagName) ||
    node.matches('[role="textbox"], [role="searchbox"], [role="combobox"], ' +
      '.monaco-editor, .cm-editor, .CodeMirror, [data-wingman-keyboard="editor"]')
  );
  const editing = event => {
    if (document.designMode.toLowerCase() === 'on') return true;
    if (event.composedPath().some(isEditor)) return true;
    let active = document.activeElement;
    while (active) {
      if (isEditor(active)) return true;
      active = active.shadowRoot && active.shadowRoot.activeElement;
    }
    return false;
  };
  // Bubble after app handlers so preventDefault/stopPropagation keeps custom
  // editor shortcuts. Closed shadow editors can mark their host as an editor.
  window.addEventListener('keydown', event => {
    if (!event.isTrusted || event.defaultPrevented || event.isComposing ||
        !event.metaKey || event.ctrlKey || event.altKey || event.shiftKey ||
        (event.key !== 'ArrowRight' && event.key !== 'ArrowLeft') ||
        editing(event)) return;
    const channel = window.WingmanNavigation;
    if (!channel || typeof channel.postMessage !== 'function') return;
    event.preventDefault();
    if (!event.repeat) {
      channel.postMessage(event.key === 'ArrowRight' ? 'nextApp' : 'openMenu');
    }
  });
})();
''';
