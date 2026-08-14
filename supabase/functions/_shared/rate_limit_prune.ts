// Opportunistische Tabellen-Hygiene fuer public.edge_rate_limits.
//
// Aufgerufen wird das ausnahmslos fire-and-forget (`void pruneRateLimits(...)`),
// damit der Nutzer-Request nicht auf die Aufraeumarbeit wartet. GENAU DESHALB
// muss jeder Fehler hier drin bleiben: ein rejectender fetch (DNS, TCP, Abort —
// nicht zu verwechseln mit einem HTTP-Fehlerstatus, den fetch NICHT wirft)
// waere sonst eine unhandled rejection und beendet den Isolate. Bei
// analyze-meal trifft das mitten in das 45-Sekunden-Fenster des Modellaufrufs:
// der Provider-Call ist bezahlt, der Rate-Limit-Slot verbraucht, und einen
// Refund-Pfad gibt es dort nicht. Der User-Request darf von der Aufraeumarbeit
// nie blockiert oder abgerissen werden.
//
// Die Funktion stand wortgleich in analyze-meal und search-key (beide ohne
// diese Haertung) und ein drittes Mal, gehaertet, in coach-chat/handler.ts —
// dort mit vertauschter Parameterreihenfolge, weshalb die Zugangsdaten hier
// als Objekt uebergeben werden. Alle drei Functions nutzen jetzt diese Fassung.

/** Zugangsdaten des Service-Role-Aufrufs. Bewusst ein Objekt statt zweier
 *  String-Parameter: vertauscht faellt der Unterschied nirgends auf — der
 *  Aufruf ginge dann mit dem Key als Basis-URL raus. */
export type PruneRateLimitsOptions = {
  supabaseUrl: string;
  serviceKey: string;
};

/**
 * Ruft die RPC `prune_edge_rate_limits` auf und schluckt jeden Fehler.
 *
 * Resolved IMMER — auch bei Netzwerkfehler oder Fehlerstatus. Aufrufer duerfen
 * sich darauf verlassen, dass `void pruneRateLimits(...)` folgenlos bleibt.
 */
export async function pruneRateLimits(options: PruneRateLimitsOptions): Promise<void> {
  try {
    const response = await fetch(`${options.supabaseUrl}/rest/v1/rpc/prune_edge_rate_limits`, {
      method: "POST",
      headers: {
        apikey: options.serviceKey,
        authorization: `Bearer ${options.serviceKey}`,
        "content-type": "application/json",
      },
      body: "{}",
    });
    // fetch wirft bei 4xx/5xx nicht. Ohne diese Zeile bliebe eine dauerhaft
    // fehlschlagende RPC (entzogenes grant, verschluckte Migration) voellig
    // unsichtbar: die Tabelle waechst und niemand erfaehrt davon. Nur Status
    // loggen — der Body kann nichts enthalten, was hier gebraucht wird.
    if (!response.ok) {
      console.error(`prune_edge_rate_limits failed: HTTP ${response.status}`);
    }
  } catch (e) {
    console.error(`prune_edge_rate_limits failed: ${e instanceof Error ? e.message : String(e)}`);
  }
}
