import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A PIN editor that never passively reveals the newest obscured character.
/// Real editing values and Flutter's secure-input semantics remain unchanged.
class ImmediatePinField extends StatefulWidget {
  const ImmediatePinField({
    required this.controller,
    required this.decoration,
    this.obscureText = true,
    this.enabled = true,
    this.inputFormatters,
    this.onSubmitted,
    super.key,
  });

  final TextEditingController controller;
  final InputDecoration decoration;
  final bool obscureText;
  final bool enabled;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onSubmitted;

  @override
  State<ImmediatePinField> createState() => _ImmediatePinFieldState();
}

class _ImmediatePinFieldState extends State<ImmediatePinField>
    implements TextSelectionGestureDetectorBuilderDelegate {
  @override
  final editableTextKey = GlobalKey<EditableTextState>();
  @override
  bool get forcePressEnabled =>
      Theme.of(context).platform == TargetPlatform.iOS;
  @override
  bool get selectionEnabled => widget.enabled;
  late final _gestures = TextSelectionGestureDetectorBuilder(delegate: this);
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.titleMedium!;
    return AnimatedBuilder(
      animation: Listenable.merge([_focus, widget.controller]),
      builder: (context, _) => IgnorePointer(
        ignoring: !widget.enabled,
        child: _gestures.buildGestureDetector(
          behavior: HitTestBehavior.translucent,
          child: InputDecorator(
            decoration: widget.decoration.copyWith(enabled: widget.enabled),
            isFocused: _focus.hasFocus,
            isEmpty: widget.controller.text.isEmpty,
            child: Semantics(
              label: widget.decoration.labelText,
              child: _ImmediatelyObscuredEditableText(
                key: editableTextKey,
                controller: widget.controller,
                focusNode: _focus,
                style: style,
                cursorColor: theme.colorScheme.primary,
                backgroundCursorColor: theme.colorScheme.onSurface,
                selectionColor:
                    theme.colorScheme.primary.withValues(alpha: 0.3),
                obscureText: widget.obscureText,
                readOnly: !widget.enabled,
                keyboardType: TextInputType.number,
                enableSuggestions: false,
                autocorrect: false,
                inputFormatters: widget.inputFormatters,
                onSubmitted: widget.onSubmitted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ImmediatelyObscuredEditableText extends EditableText {
  _ImmediatelyObscuredEditableText({
    super.key,
    required super.controller,
    required super.focusNode,
    required super.style,
    required super.cursorColor,
    required super.backgroundCursorColor,
    required super.selectionColor,
    required super.obscureText,
    required super.readOnly,
    required super.keyboardType,
    required super.enableSuggestions,
    required super.autocorrect,
    super.inputFormatters,
    super.onSubmitted,
  }) : super(
            rendererIgnoresPointer: true,
            selectionControls: materialTextSelectionHandleControls,
            contextMenuBuilder: (context, state) =>
                AdaptiveTextSelectionToolbar.editableText(
                    editableTextState: state));

  @override
  EditableTextState createState() => _ImmediatelyObscuredEditableTextState();
}

class _ImmediatelyObscuredEditableTextState extends EditableTextState {
  // Flutter explicitly supports overriding buildTextSpan. Keep obscureText true
  // for secure input/semantics, but bypass its platform latest-character reveal.
  @override
  TextSpan buildTextSpan() => widget.obscureText
      ? TextSpan(
          style: widget.style,
          text: widget.obscuringCharacter * widget.controller.text.length,
        )
      : super.buildTextSpan();
}
