/// Device-local appearance preferences; these never enter finance sync payloads.
enum ColorPreset {
  forest('forest', 'Лес', 0xff356859),
  indigo('indigo', 'Индиго', 0xff4f46a5),
  ocean('ocean', 'Океан', 0xff006b9a),
  rose('rose', 'Роза', 0xff984563),
  oled('oled', 'OLED — чёрный', 0xff51bda0);

  const ColorPreset(this.id, this.label, this.seedArgb);
  final String id, label;
  final int seedArgb;

  static ColorPreset fromId(String? id) =>
      values.firstWhere((preset) => preset.id == id, orElse: () => forest);
}
