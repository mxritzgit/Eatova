import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

// ---------------------------------------------------------------------------
// SHEETS — Geruest, Eingabefeld und der Oeffner.
//
// Geometrie 1:1 aus der Design-Vorlage; Farben aus [AppTokens].
// ---------------------------------------------------------------------------

/// Das Innenleben eines Bottom-Sheets: Titel, erklaerender Satz, Felder und
/// genau eine Aktion am Fuss.
class SheetScaffold extends StatelessWidget {
  const SheetScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    required this.actionLabel,
    this.destructive = false,
    this.onAction,
    this.actionEnabled = true,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final String actionLabel;
  final bool destructive;

  /// Standard ist Schliessen — ein Sheet ohne eigene Aktion bestaetigt nur.
  final VoidCallback? onAction;

  /// Scharfschaltung der Aktion (Loesch-Sheet erst, wenn LOESCHEN getippt
  /// wurde). Gesperrt heisst: gedaempft und taub, nicht unsichtbar.
  final bool actionEnabled;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final fill = destructive ? t.danger : t.forest;
    // Scrollbar, nicht nur schrumpfend: die Vorlage baut eine reine
    // `Column(mainAxisSize: min)`. Ein Sheet waechst mit der Systemschrift,
    // hat aber nur die Hoehe, die ihm der Bildschirm laesst — bei
    // textScaler 2.0 lief dieses Geruest um gemessene 101 px ueber. Mit
    // `shrinkWrap` bleibt das Sheet bei normaler Schrift genauso hoch wie
    // vorher (es waechst nur bis zu seinem Inhalt) und wird erst scrollbar,
    // wenn der Inhalt sonst nicht mehr passt.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: AppType.display(
              24,
              color: destructive ? t.danger : t.ink,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: AppType.ui(12.5, color: t.ink2, height: 1.45)),
          const SizedBox(height: 18),
          ...children,
          const SizedBox(height: 20),
          Opacity(
            opacity: actionEnabled ? 1 : 0.4,
            child: Material(
              color: fill,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                onTap: actionEnabled
                    ? (onAction ?? () => Navigator.of(context).maybePop())
                    : null,
                borderRadius: BorderRadius.circular(16),
                child: ConstrainedBox(
                  // Abweichung von der Vorlage (SizedBox(height: 52)): bei
                  // textScaler 2.0 waere die Beschriftung hoeher als der Knopf.
                  constraints: const BoxConstraints(minHeight: 52),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            actionLabel,
                            textAlign: TextAlign.center,
                            style: AppType.ui(
                              14.5,
                              weight: FontWeight.w700,
                              // `bg` ist in beiden Modi der Gegenpol zu den
                              // beiden Fuellfarben und traegt deshalb auch auf
                              // `danger` (hell im Dunkelmodus) den Kontrast.
                              color: destructive ? t.bg : t.onForest,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Beschriftetes Eingabefeld im Sheet-Stil.
class SheetField extends StatelessWidget {
  const SheetField({
    super.key,
    required this.label,
    required this.hint,
    this.obscure = false,
    this.controller,
    this.enabled = true,
    this.keyboardType,
    this.onChanged,
    this.errorText,
    this.suffix,
  });

  final String label;
  final String hint;
  final bool obscure;

  /// Die Vorlage kommt ohne Controller aus (statische Demo); echte Sheets
  /// brauchen ihn.
  final TextEditingController? controller;

  final bool enabled;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;

  /// Eine Zeile in [AppTokens.danger] unter dem Feld; faerbt zugleich den Rand.
  final String? errorText;

  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hasError = errorText != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label.toUpperCase(), style: AppType.eyebrow(t.ink2, size: 9.5)),
          const SizedBox(height: 7),
          Opacity(
            opacity: enabled ? 1 : 0.55,
            child: Container(
              decoration: BoxDecoration(
                color: t.surf,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: hasError ? t.danger : t.line),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: controller,
                      enabled: enabled,
                      obscureText: obscure,
                      keyboardType: keyboardType,
                      onChanged: onChanged,
                      cursorColor: t.accent,
                      style: AppType.ui(14, color: t.ink),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 15),
                        hintText: hint,
                        hintStyle: AppType.ui(14, color: t.ink2),
                      ),
                    ),
                  ),
                  if (suffix != null) suffix!,
                ],
              ),
            ),
          ),
          if (hasError) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              errorText!,
              style: AppType.ui(11.5, weight: FontWeight.w500, color: t.danger),
            ),
          ],
        ],
      ),
    );
  }
}

/// Oeffnet [sheet] als Eatova-Bottom-Sheet: scrollgesteuert, auf [AppTokens.bg],
/// mit Ziehgriff, [rSheet]-Kappe und Tastatur-Ausgleich.
Future<T?> showEatovaSheet<T>(BuildContext context, Widget sheet) {
  final t = context.t;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: t.bg,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
    ),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: sheet,
    ),
  );
}
