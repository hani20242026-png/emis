class AiContextMemory {
  final List<String> _turns = [];
  static const int _maxTurns = 12;

  List<String> get turns => List.unmodifiable(_turns);

  void add(String text) {
    final value = text.trim();
    if (value.isEmpty) return;
    _turns.add(value);
    if (_turns.length > _maxTurns) _turns.removeAt(0);
  }

  String get summary => _turns.join('\n');

  void clear() => _turns.clear();
}
