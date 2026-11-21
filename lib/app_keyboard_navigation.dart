import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Central keyboard-navigation policy for EMIS.
/// New screens should use AppTextField and AppDropdownButtonFormField.
class AppKeyboardNavigation extends StatelessWidget {
  const AppKeyboardNavigation({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.enter): NextFocusIntent(),
            SingleActivator(LogicalKeyboardKey.numpadEnter): NextFocusIntent(),
          },
          child: child,
        ),
      );
}

/// A shared dropdown that can be opened when it receives keyboard focus.
/// It intentionally uses a bottom sheet for reliable keyboard and touch access
/// on Android, where DropdownButtonFormField has no public open() API.
class AppDropdownButtonFormField<T> extends StatefulWidget {
  const AppDropdownButtonFormField({
    super.key,
    required this.items,
    this.value,
    this.onChanged,
    this.decoration = const InputDecoration(),
    this.isExpanded = false,
    this.dropdownColor,
    this.iconEnabledColor,
    this.style,
    this.selectedItemBuilder,
    this.validator,
    this.onTap,
    this.isDense = false,
    this.enabled = true,
    this.autovalidateMode,
    this.onSaved,
    this.focusNode,
    this.menuMaxHeight,
    this.hint,
    this.disabledHint,
  });

  final List<DropdownMenuItem<T>> items;
  final T? value;
  final ValueChanged<T?>? onChanged;
  final InputDecoration decoration;
  final bool isExpanded;
  final Color? dropdownColor;
  final Color? iconEnabledColor;
  final TextStyle? style;
  final DropdownButtonBuilder? selectedItemBuilder;
  final FormFieldValidator<T>? validator;
  final VoidCallback? onTap;
  final bool isDense;
  final bool enabled;
  final AutovalidateMode? autovalidateMode;
  final FormFieldSetter<T>? onSaved;
  final FocusNode? focusNode;
  final double? menuMaxHeight;
  final Widget? hint;
  final Widget? disabledHint;

  @override
  State<AppDropdownButtonFormField<T>> createState() => _AppDropdownButtonFormFieldState<T>();
}

class _AppDropdownButtonFormFieldState<T> extends State<AppDropdownButtonFormField<T>> {
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode(debugLabel: 'EMIS dropdown');
  bool _ownsFocusNode = false;
  bool _opening = false;
  // Prevent focus restoration after the modal closes from reopening this same
  // dropdown before the scheduled focus traversal reaches the next field.
  bool _suppressFocusReopen = false;
  T? _current;
  final GlobalKey<FormFieldState<T>> _fieldKey = GlobalKey<FormFieldState<T>>();

  @override
  void initState() {
    super.initState();
    _current = widget.value;
    _ownsFocusNode = widget.focusNode == null;
    _activeFocusNode.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(covariant AppDropdownButtonFormField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _current = widget.value;
    if (oldWidget.focusNode != widget.focusNode) {
      if (oldWidget.focusNode != null) oldWidget.focusNode!.removeListener(_focusChanged);
      else _focusNode.removeListener(_focusChanged);
      _activeFocusNode.addListener(_focusChanged);
    }
  }

  FocusNode get _activeFocusNode => widget.focusNode ?? _focusNode;

  void _focusChanged() {
    if (_activeFocusNode.hasFocus && !_suppressFocusReopen) {
      _openOptions();
    }
  }

  Future<void> _openOptions() async {
    if (!mounted || _opening || !widget.enabled || widget.onChanged == null) return;
    _opening = true;
    widget.onTap?.call();
    _activeFocusNode.requestFocus();
    final selectedIndex = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: widget.dropdownColor ?? Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final maxHeight = widget.menuMaxHeight ?? MediaQuery.sizeOf(sheetContext).height * .65;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (var i = 0; i < widget.items.length; i++)
                  if (widget.items[i].enabled)
                    ListTile(
                      selected: widget.items[i].value == _current,
                      title: widget.items[i].child,
                      onTap: () {
                        // Set this before pop: closing the route restores focus
                        // and can otherwise trigger _focusChanged immediately.
                        _suppressFocusReopen = true;
                        Navigator.of(sheetContext).pop(i);
                      },
                    ),
              ],
            ),
          ),
        );
      },
    );
    _opening = false;
    if (!mounted || selectedIndex == null || selectedIndex < 0 || selectedIndex >= widget.items.length) return;
    final nextValue = widget.items[selectedIndex].value;
    setState(() {
      _current = nextValue;
    });
    // FormField owns its validation/error state; didChange updates it safely.
    _fieldKey.currentState?.didChange(nextValue);
    widget.onChanged?.call(nextValue);
    // Let the owning screen rebuild before moving focus. Suppression remains
    // active during route focus restoration, so this field cannot reopen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).nextFocus();
      // The next field has now had a chance to receive focus and open itself.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _suppressFocusReopen = false;
      });
    });
  }

  @override
  void dispose() {
    _activeFocusNode.removeListener(_focusChanged);
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FormField<T>(
      key: _fieldKey,
      initialValue: widget.value,
      validator: widget.validator,
      onSaved: widget.onSaved,
      autovalidateMode: widget.autovalidateMode,
      builder: (fieldState) {
        final current = fieldState.value;
        final selectedIndex = widget.items.indexWhere((e) => e.value == current);
        Widget? display;
        if (selectedIndex >= 0) {
          if (widget.selectedItemBuilder != null) {
            final built = widget.selectedItemBuilder!(context);
            if (selectedIndex < built.length) display = built[selectedIndex];
          }
          display ??= widget.items[selectedIndex].child;
        }
        display ??= widget.hint;
        if (!widget.enabled && display == null) display = widget.disabledHint;
        return Focus(
          focusNode: _activeFocusNode,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent && (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter || event.logicalKey == LogicalKeyboardKey.space)) {
              _openOptions();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: InkWell(
            onTap: widget.enabled ? () { _activeFocusNode.requestFocus(); _openOptions(); } : null,
            child: InputDecorator(
              decoration: widget.decoration.copyWith(errorText: fieldState.errorText),
              isEmpty: display == null,
              isFocused: _activeFocusNode.hasFocus,
              child: Row(
                children: [
                  Expanded(child: Align(alignment: AlignmentDirectional.centerStart, child: display ?? const SizedBox.shrink())),
                  Icon(Icons.arrow_drop_down, color: widget.enabled ? (widget.iconEnabledColor ?? Theme.of(context).iconTheme.color) : Theme.of(context).disabledColor),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shared text input for new screens. Enter/Next advances using Flutter's
/// focus traversal; if the next control is a shared dropdown, it opens itself.
class AppTextField extends StatelessWidget {
  const AppTextField({super.key, this.controller, this.focusNode, this.decoration,
    this.keyboardType, this.textDirection, this.textAlign = TextAlign.start,
    this.style, this.onChanged, this.onSubmitted, this.enabled, this.readOnly = false,
    this.autofocus = false, this.maxLines = 1, this.inputFormatters,
    this.autocorrect = true, this.enableSuggestions = true});
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final TextInputType? keyboardType;
  final TextDirection? textDirection;
  final TextAlign textAlign;
  final TextStyle? style;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool? enabled;
  final bool readOnly, autofocus, autocorrect, enableSuggestions;
  final int? maxLines;
  final List<TextInputFormatter>? inputFormatters;
  @override
  Widget build(BuildContext context) => TextField(
    controller: controller, focusNode: focusNode, decoration: decoration,
    keyboardType: keyboardType, textInputAction: TextInputAction.next,
    textDirection: textDirection, textAlign: textAlign, style: style,
    onChanged: onChanged,
    onSubmitted: onSubmitted ?? (_) => FocusScope.of(context).nextFocus(),
    enabled: enabled, readOnly: readOnly, autofocus: autofocus, maxLines: maxLines,
    inputFormatters: inputFormatters, autocorrect: autocorrect,
    enableSuggestions: enableSuggestions,
  );
}

/// Form-aware companion for new screens that need validation and saving.
class AppTextFormField extends StatelessWidget {
  const AppTextFormField({
    super.key,
    this.controller,
    this.initialValue,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.keyboardType,
    this.textDirection,
    this.textAlign = TextAlign.start,
    this.style,
    this.onChanged,
    this.onFieldSubmitted,
    this.validator,
    this.onSaved,
    this.autovalidateMode,
    this.enabled,
    this.readOnly = false,
    this.autofocus = false,
    this.maxLines = 1,
    this.maxLength,
    this.inputFormatters,
    this.obscureText = false,
    this.textCapitalization = TextCapitalization.none,
  });

  final TextEditingController? controller;
  final String? initialValue;
  final FocusNode? focusNode;
  final InputDecoration decoration;
  final TextInputType? keyboardType;
  final TextDirection? textDirection;
  final TextAlign textAlign;
  final TextStyle? style;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;
  final FormFieldValidator<String>? validator;
  final FormFieldSetter<String>? onSaved;
  final AutovalidateMode? autovalidateMode;
  final bool? enabled;
  final bool readOnly, autofocus, obscureText;
  final int? maxLines, maxLength;
  final List<TextInputFormatter>? inputFormatters;
  final TextCapitalization textCapitalization;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        initialValue: initialValue,
        focusNode: focusNode,
        decoration: decoration,
        keyboardType: keyboardType,
        textInputAction: TextInputAction.next,
        textDirection: textDirection,
        textAlign: textAlign,
        style: style,
        onChanged: onChanged,
        onFieldSubmitted: onFieldSubmitted ?? (_) => FocusScope.of(context).nextFocus(),
        validator: validator,
        onSaved: onSaved,
        autovalidateMode: autovalidateMode,
        enabled: enabled,
        readOnly: readOnly,
        autofocus: autofocus,
        maxLines: maxLines,
        maxLength: maxLength,
        inputFormatters: inputFormatters,
        obscureText: obscureText,
        textCapitalization: textCapitalization,
      );
}
