import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ai_assistant/ai_assistant_controller.dart';
import '../app_core.dart';
import '../app_navigator.dart';

class SiriOrb extends StatefulWidget {
  const SiriOrb({super.key});

  @override
  State<SiriOrb> createState() => _SiriOrbState();
}

class _SiriOrbState extends State<SiriOrb>
    with SingleTickerProviderStateMixin {
  final AiAssistantController _controller = AiAssistantController.instance;
  late final AnimationController _pulse;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _openAssistant() async {
    if (!mounted || _opening) return;
    setState(() => _opening = true);
    
    // التأكد من تفعيل المساعد الذكي برمجيًا عند النقر لتفادي أي قفل في الحالة
    if (!AppCore.aiAssistantEnabled) {
      await AppCore.setAiAssistantEnabled(true);
    }

    try {
      // SiriOrb is inserted by MaterialApp.builder beside the Navigator,
      // so its own BuildContext is NOT a descendant of Navigator. Use the
      // root Navigator overlay context to ensure the sheet route can be pushed.
      final navigatorContext = emisNavigatorKey.currentState?.overlay?.context;
      if (navigatorContext == null) {
        throw StateError('تعذر الوصول إلى نافذة التطبيق الرئيسية.');
      }
      await showModalBottomSheet<void>(
        context: navigatorContext,
        useRootNavigator: true,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black54,
        builder: (sheetContext) => const _AssistantSheet(),
      );
    } catch (error) {
      debugPrint('EMIS assistant sheet open failed: $error');
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('تعذر فتح المساعد: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
      try {
        await _controller.stopListening();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppCore.aiAssistantEnabledNotifier,
      builder: (context, isAiEnabled, _) {
        // إذا كان المساعد معطلاً بالكامل من الإعدادات، لا نعرض الأيقونة العائمة
        if (!isAiEnabled || _opening) {
          return const SizedBox.shrink();
        }

        return Positioned(
          bottom: 12,
          left: 0,
          right: 0,
          child: SafeArea(
            top: false,
            child: Center(
              child: StreamBuilder<void>(
                stream: _controller.changes,
                builder: (context, _) {
                  final listening =
                      _controller.state == AiAssistantState.listening;
                  return Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _opening ? null : _openAssistant,
                      child: SizedBox(
                        width: 76,
                        height: 76,
                        child: Center(
                          child: AnimatedBuilder(
                            animation: _pulse,
                            builder: (context, _) {
                              final scale = 1 +
                                  _pulse.value * (listening ? .16 : .055);
                              return Transform.scale(
                                scale: scale,
                                child: Container(
                                  width: 62,
                                  height: 62,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: AppCore.isWindows ? null : const SweepGradient(
                                      colors: [
                                        Color(0xFF00D5FF),
                                        Color(0xFF8B5CF6),
                                        Color(0xFFFF4FCB),
                                        Color(0xFF00D5FF),
                                      ],
                                    ),
                                    color: AppCore.isWindows ? AppCore.windowsGradientFallback(const SweepGradient(
                                      colors: [
                                        Color(0xFF00D5FF),
                                        Color(0xFF8B5CF6),
                                        Color(0xFFFF4FCB),
                                        Color(0xFF00D5FF),
                                      ],
                                    )) : null,
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF8B5CF6)
                                            .withOpacity(.42),
                                        blurRadius: 20,
                                        spreadRadius: 2,
                                      ),
                                    ],
                                  ),
                                  padding: const EdgeInsets.all(4),
                                  child: Container(
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Color(0xFF111827),
                                    ),
                                    child: Icon(
                                      listening
                                          ? Icons.graphic_eq_rounded
                                          : Icons.auto_awesome_rounded,
                                      color: Colors.white,
                                      size: 27,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AssistantSheet extends StatefulWidget {
  const _AssistantSheet();

  @override
  State<_AssistantSheet> createState() => _AssistantSheetState();
}

class _AssistantSheetState extends State<_AssistantSheet> {
  final AiAssistantController _controller = AiAssistantController.instance;
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_controller.startListening().catchError((e) {
          debugPrint('Voice start error inside sheet: $e');
        }));
      }
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _toggleMicrophone() async {
    if (_controller.state == AiAssistantState.listening) {
      await _controller.finishListening();
    } else {
      _focusNode.unfocus();
      await _controller.startListening(
        preserveTranscript: _controller.transcript.trim().isNotEmpty,
      );
    }
  }

  Future<void> _send() async {
    if (_controller.state == AiAssistantState.processing) return;

    // The send arrow is the single execution action for both voice and text.
    // Stop capture first so Android can deliver its final recognition result.
    if (_controller.state == AiAssistantState.listening) {
      await _controller.finishListening();
    }

    final typed = _textController.text.trim();
    final spoken = _controller.transcript.trim();
    final value = [spoken, typed]
        .where((part) => part.isNotEmpty)
        .join(' ')
        .trim();

    if (value.isEmpty) {
      _focusNode.unfocus();
      return;
    }

    _textController.clear();
    _focusNode.unfocus();
    await _controller.processText(value);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxHeight = math.min(media.size.height * .62, 520.0);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            decoration: BoxDecoration(
              color: const Color(0xF0181B2B),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0x886F72FF)),
              boxShadow: const [
                BoxShadow(color: Color(0x55000000), blurRadius: 24),
              ],
            ),
            child: StreamBuilder<void>(
              stream: _controller.changes,
              builder: (context, _) {
                final state = _controller.state;
                final listening = state == AiAssistantState.listening;
                final status = listening
                    ? 'أستمع إليك الآن...'
                    : state == AiAssistantState.processing
                        ? 'أحلل الأمر...'
                        : _controller.reply;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'مساعد EMIS',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'مسح المحادثة',
                          visualDensity: VisualDensity.compact,
                          onPressed: _controller.clearConversation,
                          icon: const Icon(Icons.delete_sweep_outlined,
                              color: Colors.white70, size: 21),
                        ),
                        IconButton(
                          tooltip: 'إغلاق', 
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close,
                              color: Colors.white70, size: 21),
                        ),
                      ],
                    ),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 105),
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.055),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              status,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                height: 1.4,
                              ),
                            ),
                            if (_controller.transcript.isNotEmpty ||
                                _controller.lastProcessedText.isNotEmpty) ...[
                              const SizedBox(height: 5),
                              Text(
                                _controller.transcript.isNotEmpty
                                    ? 'سمعت: ${_controller.transcript}'
                                    : 'آخر أمر: ${_controller.lastProcessedText}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _textController,
                            focusNode: _focusNode,
                            minLines: 1,
                            maxLines: 3,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: 'اكتب أمراً للمساعد...',
                              hintStyle: const TextStyle(
                                color: Colors.white54,
                                fontSize: 13,
                              ),
                              filled: true,
                              fillColor: Colors.white10,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 11),
                              suffixIcon: IconButton(
                                tooltip: 'مسح النص',
                                visualDensity: VisualDensity.compact,
                                onPressed: _textController.clear,
                                icon: const Icon(Icons.backspace_outlined,
                                    color: Colors.white60, size: 18),
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton.filled(
                          tooltip: 'إرسال الأمر',
                          onPressed: state == AiAssistantState.processing ? null : _send,
                          style: IconButton.styleFrom(
                            backgroundColor: const Color(0xFF6257D9),
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.send_rounded, size: 20),
                        ),
                        const SizedBox(width: 3),
                        IconButton.filled(
                          tooltip: listening ? 'إيقاف الاستماع' : 'ابدأ الاستماع',
                          onPressed: _toggleMicrophone,
                          style: IconButton.styleFrom(
                            backgroundColor: listening
                                ? const Color(0xFFB93855)
                                : const Color(0xFF168C78),
                            foregroundColor: Colors.white,
                          ),
                          icon: Icon(
                            listening ? Icons.mic_off_rounded : Icons.mic_rounded,
                            size: 21,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'الميكروفون لالتقاط الكلام وإيقافه فقط. اضغط أيقونة ✨ لتنفيذ الأمر بعد اكتمال كلامك.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 10),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
