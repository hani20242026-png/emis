import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_core.dart';

enum NavigableFieldType {
  text,
  dropdown,
}

class _FieldRegistration {
  final String id;
  final NavigableFieldType type;
  final FocusNode focusNode;
  final GlobalKey key;
  bool Function()? isAvailable;
  Future<void> Function()? waitBeforeActivate;

  _FieldRegistration({
    required this.id,
    required this.type,
    required this.focusNode,
    required this.key,
    this.isAvailable,
    this.waitBeforeActivate,
  });
}

/// النظام المركزي للتنقل بين الحقول النصية والقوائم المنسدلة عبر أزرار الكيبورد
class CentralKeyboardNavigator {
  final Map<String, _FieldRegistration> _registry = {};
  final List<String> Function() _sequenceBuilder;
  final void Function(String fieldId)? onFieldFocused;

  /// دالة تحدد ما إذا كان الحقل يحتوي على قيمة افتراضية من الإعدادات ليتم تجاوزه تلقائياً
  final bool Function(String fieldId)? shouldSkipField;

  Timer? _dropdownRouteWatcher;
  String? _activeDropdownFieldId;
  DateTime? _lastAdvanceTime;
  String? _lastAdvancedFromField;
  bool _disposed = false;

  CentralKeyboardNavigator({
    required List<String> Function() sequenceBuilder,
    this.onFieldFocused,
    this.shouldSkipField,
  }) : _sequenceBuilder = sequenceBuilder;

  bool get isEnabled => AppCore.centralKeyboardNavigationEnabled;

  /// تسجيل أو جلب بيانات الحقل (FocusNode + GlobalKey)
  _FieldRegistration _ensureRegistered(
    String id,
    NavigableFieldType type, {
    bool Function()? isAvailable,
    Future<void> Function()? waitBeforeActivate,
  }) {
    final existing = _registry[id];
    if (existing != null) {
      if (isAvailable != null) existing.isAvailable = isAvailable;
      if (waitBeforeActivate != null) {
        existing.waitBeforeActivate = waitBeforeActivate;
      }
      return existing;
    }

    late final FocusNode node;
    node = FocusNode(
      debugLabel: 'central_nav_$id',
      onKeyEvent: (FocusNode focusNode, KeyEvent event) {
        if (!isEnabled) return KeyEventResult.ignored;
        if (event is KeyDownEvent) {
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter) {
            handleFieldSubmitted(id);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
    );

    final reg = _FieldRegistration(
      id: id,
      type: type,
      focusNode: node,
      key: GlobalKey(debugLabel: 'central_key_$id'),
      isAvailable: isAvailable,
      waitBeforeActivate: waitBeforeActivate,
    );
    _registry[id] = reg;
    return reg;
  }

  FocusNode focusNodeForText(
    String id, {
    bool Function()? isAvailable,
  }) {
    return _ensureRegistered(
      id,
      NavigableFieldType.text,
      isAvailable: isAvailable,
    ).focusNode;
  }

  GlobalKey keyForField(
    String id,
    NavigableFieldType type, {
    bool Function()? isAvailable,
    Future<void> Function()? waitBeforeActivate,
  }) {
    return _ensureRegistered(
      id,
      type,
      isAvailable: isAvailable,
      waitBeforeActivate: waitBeforeActivate,
    ).key;
  }

  /// فلتر لمنع إدخال سطر جديد عند الضغط على Enter/التالي في الحقول متعددة الأسطر وتحويله إلى انتقال
  TextInputFormatter buildEnterInterceptorFormatter(String fieldId) {
    return TextInputFormatter.withFunction((oldValue, newValue) {
      if (!isEnabled) return newValue;
      if (!oldValue.text.contains('\n') && newValue.text.contains('\n')) {
        final cleaned = newValue.text.replaceAll('\n', '');
        scheduleMicrotask(() => handleFieldSubmitted(fieldId));
        return TextEditingValue(
          text: cleaned,
          selection: TextSelection.collapsed(offset: cleaned.length),
        );
      }
      return newValue;
    });
  }

  /// يُستدعى عند النقر على Enter أو Next أو التالي أو علامة الصح في الكيبورد
  void handleFieldSubmitted(String fieldId) {
    if (_disposed || !isEnabled) return;

    final now = DateTime.now();
    if (_lastAdvancedFromField == fieldId &&
        _lastAdvanceTime != null &&
        now.difference(_lastAdvanceTime!).inMilliseconds < 220) {
      return;
    }
    _lastAdvancedFromField = fieldId;
    _lastAdvanceTime = now;

    unawaited(moveToNextField(fieldId));
  }

  bool _isFieldMountedAndReady(String id) {
    final reg = _registry[id];
    if (reg == null) return false;
    if (reg.isAvailable != null && !reg.isAvailable!()) return false;
    final ctx = reg.key.currentContext;
    if (ctx == null || !ctx.mounted) return false;
    return true;
  }

  /// True only when the field is currently part of the rendered form.
  bool isFieldMountedAndReady(String fieldId) =>
      !_disposed && _isFieldMountedAndReady(fieldId);

  /// Scroll the form so a voice-activated field is visible to the user.
  Future<void> scrollToField(String fieldId) async {
    if (_disposed || !_isFieldMountedAndReady(fieldId)) return;
    final reg = _registry[fieldId];
    if (reg != null) await _scrollIntoView(reg.key);
  }

  /// الانتقال إلى الحقل التالي في التسلسل مع تجاوز كافة الحقول التي تمتلك قيمة افتراضية
  Future<void> moveToNextField(String currentFieldId) async {
    if (_disposed || !isEnabled) return;

    final sequence = _sequenceBuilder();
    if (sequence.isEmpty) return;

    final currentIndex = sequence.indexOf(currentFieldId);
    if (currentIndex < 0) return;

    for (int i = currentIndex + 1; i < sequence.length; i++) {
      final candidateId = sequence[i];
      final reg = _registry[candidateId];
      if (reg == null) continue;

      // إذا كان الحقل يحتوي على قيمة افتراضية من الإعدادات يتم تجاوزه مباشرة للحقل الذي بعده
      if (shouldSkipField != null && shouldSkipField!(candidateId)) {
        continue;
      }

      if (reg.waitBeforeActivate != null) {
        await reg.waitBeforeActivate!();
        if (_disposed || !isEnabled) return;
      }

      // إعادة فحص التخطي بعد الانتظار في حال تغيرت حالة الحقل
      if (shouldSkipField != null && shouldSkipField!(candidateId)) {
        continue;
      }

      if (!_isFieldMountedAndReady(candidateId)) continue;

      if (reg.type == NavigableFieldType.text) {
        await _activateTextField(reg);
        return;
      } else if (reg.type == NavigableFieldType.dropdown) {
        final opened = await _activateAndOpenDropdown(reg);
        if (opened) {
          return;
        }
        // إذا كانت القائمة المنسدلة فارغة أو غير قابلة للفتح، يتم تخطيها تلقائياً للحقل التالي
      }
    }

    // عند الوصول إلى آخر حقل في النموذج (أو إذا كانت كل الحقول المتبقية ذات قيم افتراضية) يتم إغلاق الكيبورد
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _scrollIntoView(GlobalKey key) async {
    final ctx = key.currentContext;
    if (ctx == null || !ctx.mounted) return;
    try {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: 0.22,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
    } catch (_) {}
  }

  Future<void> _activateTextField(_FieldRegistration reg) async {
    if (_disposed) return;
    await _scrollIntoView(reg.key);
    if (_disposed) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      if (reg.focusNode.canRequestFocus) {
        reg.focusNode.requestFocus();
        onFieldFocused?.call(reg.id);
      }
    });
  }

  Future<bool> _activateAndOpenDropdown(_FieldRegistration reg) async {
    if (_disposed) return false;

    // إغلاق الكيبورد النصي قبل فتح القائمة المنسدلة
    FocusManager.instance.primaryFocus?.unfocus();
    await _scrollIntoView(reg.key);
    if (_disposed) return false;

    onFieldFocused?.call(reg.id);

    // انتظار استقرار التمرير وإغلاق الكيبورد
    await Future<void>.delayed(const Duration(milliseconds: 160));
    if (_disposed || !isEnabled) return false;

    final ctx = reg.key.currentContext;
    if (ctx == null || !ctx.mounted) return false;

    final tapCallback = _findDropdownTapCallback(ctx);
    if (tapCallback == null) {
      return false;
    }

    final pageRoute = ModalRoute.of(ctx);
    if (pageRoute == null) return false;
    tapCallback();

    final routeOpened = await _waitForDropdownPopupOpen(pageRoute);
    if (!routeOpened) {
      return false;
    }

    _watchDropdownCloseAndAdvance(reg.id, pageRoute);
    return true;
  }

  /// مراقبة القائمة المنسدلة عند فتحها يدوياً أيضاً في حال رغبة المستخدم
  void notifyManualDropdownTap(String fieldId, BuildContext? fieldContext) {
    if (_disposed || !isEnabled) return;
    if (_activeDropdownFieldId == fieldId) return;
    final ctx = fieldContext ?? _registry[fieldId]?.key.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final pageRoute = ModalRoute.of(ctx);
    if (pageRoute == null) return;

    unawaited(_waitForDropdownPopupOpen(pageRoute).then((opened) {
      if (opened && !_disposed && isEnabled) {
        _watchDropdownCloseAndAdvance(fieldId, pageRoute);
      }
    }));
  }

  Future<bool> _waitForDropdownPopupOpen(ModalRoute<dynamic>? pageRoute) async {
    if (pageRoute == null) return false;
    for (int i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 35));
      if (_disposed) return false;
      if (!pageRoute.isCurrent) {
        return true;
      }
    }
    return false;
  }

  void _watchDropdownCloseAndAdvance(
    String fieldId,
    ModalRoute<dynamic> pageRoute,
  ) {
    _dropdownRouteWatcher?.cancel();
    _activeDropdownFieldId = fieldId;

    _dropdownRouteWatcher = Timer.periodic(
      const Duration(milliseconds: 55),
      (timer) {
        if (_disposed || !isEnabled) {
          timer.cancel();
          _activeDropdownFieldId = null;
          return;
        }
        // عندما يعود pageRoute.isCurrent إلى true فهذا يعني أن القائمة المنسدلة أُغلقت للتو
        if (pageRoute.isCurrent) {
          timer.cancel();
          final completedFieldId = _activeDropdownFieldId;
          _activeDropdownFieldId = null;
          if (completedFieldId != null) {
            Future<void>.delayed(const Duration(milliseconds: 180), () {
              if (!_disposed && isEnabled) {
                // Dropdown overlays can leave keyboard focus on an unrelated
                // text field. Clear it before moving to the next form item.
                FocusManager.instance.primaryFocus?.unfocus();
                moveToNextField(completedFieldId);
              }
            });
          }
        }
      },
    );
  }

  /// البحث داخل شجرة عناصر القائمة المنسدلة عن زر الفتح الفعلي وتجاهل أيقونة المايكروفون تماماً
  VoidCallback? _findDropdownTapCallback(BuildContext rootContext) {
    Element? dropdownButtonElement;

    void findDropdownElement(Element element) {
      if (dropdownButtonElement != null) return;
      final widgetType = element.widget.runtimeType.toString();
      if (widgetType.startsWith('DropdownButton<')) {
        dropdownButtonElement = element;
        return;
      }
      element.visitChildElements(findDropdownElement);
    }

    (rootContext as Element).visitChildElements(findDropdownElement);
    if (dropdownButtonElement == null) return null;

    VoidCallback? onTap;
    void findGestureDetector(Element element) {
      if (onTap != null) return;
      final widget = element.widget;
      if (widget is GestureDetector && widget.onTap != null) {
        onTap = widget.onTap;
        return;
      }
      element.visitChildElements(findGestureDetector);
    }

    dropdownButtonElement!.visitChildElements(findGestureDetector);
    return onTap;
  }

  void dispose() {
    _disposed = true;
    _dropdownRouteWatcher?.cancel();
    _dropdownRouteWatcher = null;
    for (final reg in _registry.values) {
      reg.focusNode.dispose();
    }
    _registry.clear();
  }
}
