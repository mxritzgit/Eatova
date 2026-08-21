import 'dart:math' as math;

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

/// Luft zwischen oberer Safe-Area (Statusleiste, Notch, Dynamic Island) und
/// der Oberkante eines Sheets.
const double kSheetTopGap = 12;

/// Untergrenze fuer [sheetMaxHeight]: bei extremen Werten (kleiner Bildschirm,
/// hohe Tastatur, Querformat) schrumpft ein Sheet nicht unter diese Hoehe —
/// lieber ragt es in Grenzfaellen an den Rand, als dass der Kopf mit seinen
/// Aktionen in einem Streifen von wenigen Pixeln verschwindet.
const double kSheetMinHeight = 320;

/// Die hoechste Hoehe, die ein Bottom-Sheet auf diesem Bildschirm haben darf,
/// ohne unter die obere Safe-Area zu rutschen.
///
/// `size.height - viewPadding.top - viewInsets.bottom - kSheetTopGap`, nie
/// kleiner als [kSheetMinHeight].
///
/// Warum nicht ein fester Anteil (`size.height * 0.92`)? Ein Sheet liegt
/// oberhalb der Tastatur (`Padding(bottom: viewInsets.bottom)`), und der
/// Anteil kannte die Tastatur nicht: Sheet-Hoehe plus Tastatur ueberstiegen
/// die Bildschirmhoehe, die Route klemmte das Sheet auf `Bildschirm minus
/// Tastatur` — und damit bis an den oberen Rand, unter Statusleiste und
/// Dynamic Island. Der Kopf mit Kamera/Galerie/Barcode war auf dem iPhone
/// nicht mehr zu sehen. Ohne Tastatur waren 8 % auf Geraeten mit 59 pt
/// Safe-Area ohnehin knapp. Mit dieser Formel schrumpft bei offener
/// Tastatur der Scrollbereich, nicht der sichtbare Kopf.
///
/// Reine Funktion ueber den Daten — fuer Sheets im Baum steht
/// [sheetMaxHeightOf] bereit, das die obere Safe-Area korrekt beschafft.
double sheetMaxHeight(MediaQueryData mediaQuery) {
  final available = mediaQuery.size.height -
      mediaQuery.viewPadding.top -
      mediaQuery.viewInsets.bottom -
      kSheetTopGap;
  return math.max(kSheetMinHeight, available);
}

/// [sheetMaxHeight] fuer den Build-Kontext eines Sheets.
///
/// Im Builder von `showModalBottomSheet` ist `viewPadding.top` bereits 0:
/// die Route legt `MediaQuery.removePadding(removeTop: true)` um ihr Kind
/// (damit ein `SafeArea` IM Sheet oben keine Luecke reisst), und
/// `removePadding` zieht dabei auch `viewPadding.top` auf 0. Die Formel
/// liefe dort ins Leere. Die Safe-Area des Geraets kennt aber weiterhin der
/// [FlutterView]; von dort kommt sie, wenn die MediaQuery sie nicht mehr
/// traegt. `useSafeArea: true` an der Route waere keine Loesung — das setzt
/// den Wert genauso auf 0 und nimmt dem Sheet zusaetzlich die 12 pt Luft.
double sheetMaxHeightOf(BuildContext context) {
  final mediaQuery = MediaQuery.of(context);
  final viewTop = MediaQueryData.fromView(View.of(context)).viewPadding.top;
  if (viewTop <= mediaQuery.viewPadding.top) return sheetMaxHeight(mediaQuery);
  return sheetMaxHeight(
    mediaQuery.copyWith(
      viewPadding: mediaQuery.viewPadding.copyWith(top: viewTop),
    ),
  );
}

/// Oeffnet [sheet] als Eatova-Bottom-Sheet: scrollgesteuert, auf [AppTokens.bg],
/// mit Ziehgriff, [rSheet]-Kappe, Tastatur-Ausgleich und Safe-Area-Deckel
/// ([sheetMaxHeight]).
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
      child: ConstrainedBox(
        // Der Deckel gilt fuer das ganze Sheet; `showDragHandle` setzt den
        // Griff als `kMinInteractiveDimension` hohes Polster UEBER den
        // Builder-Inhalt (Stack + Padding in BottomSheet.build), also geht
        // er hier ab. Ohne Deckel fuellt ein langer Inhalt (SheetScaffold
        // bei grosser Schrift, offene Tastatur im Feld) den Rest des
        // Bildschirms bis unter die Statusleiste.
        constraints: BoxConstraints(
          maxHeight: sheetMaxHeightOf(sheetContext) - kMinInteractiveDimension,
        ),
        child: sheet,
      ),
    ),
  );
}
