# Anforderungen an den Middle Keycloak

Status: Design input informed by the validated IDLab PoC

## Tracking

- Canonical tracker: `docs/component-issues/idlab-proof-of-concepts.md`
- Related docs:
  - `docs/proof-of-concepts/idlab-offline-identity-lab.md`

## Beschreibung

Der Upper Keycloak bzw. allgemeiner ein autoritatives Upstream-Identitätssystem ist das führende System für Benutzer, Gruppen und Gruppenzugehörigkeiten. Der Middle Keycloak übernimmt diese Identitäten, verarbeitet sie lokal weiter und ist der einzige Runtime-Identity-Provider für Downstream-Anwendungen. Downstream-Systeme authentifizieren Benutzer daher nicht direkt gegen das Upstream-System, sondern ausschließlich über den Middle Keycloak.

Die für Downstream-Systeme benötigten Benutzer, Gruppen und Gruppenzugehörigkeiten werden aus dem Kontext des Middle Keycloak über eine standardisierte Provisioning-Schnittstelle bereitgestellt. Die konkrete technische Kopplung zwischen Upstream-System und Middle Keycloak ist fachlich zunächst nicht festgelegt. Entscheidend ist, dass der Middle Keycloak Identitäten, Gruppen und Gruppenzugehörigkeiten aus einem autoritativen Upstream-System übernehmen und lokal konsistent vorhalten kann.

Provisioning und Authentifizierung sind getrennt zu betrachten:

- Provisioning dient der Übernahme und Bereitstellung von Benutzern, Gruppen und Gruppenzugehörigkeiten.
- Authentifizierung dient der Laufzeitanmeldung von Benutzern.
- Eine Provisioning-Schnittstelle ersetzt keine föderationsfähige Authentifizierungs-Schnittstelle.

Für diese Zielarchitektur sind die zu unterstützenden Standards fest vorzugeben:

- Die föderierte Authentifizierung zwischen Upstream-Identitätssystem und Middle Keycloak erfolgt über `OIDC`.
- Die Laufzeit-Authentifizierung zwischen Downstream-Anwendungen und dem Middle Keycloak erfolgt über `OIDC`.
- Das Provisioning vom Upstream-Identitätssystem in den Middle Keycloak erfolgt über `SCIM`.
- Das Provisioning von Benutzern, Gruppen und Gruppenzugehörigkeiten in Richtung Downstream erfolgt über `SCIM`.

Wichtige Präzisierung zur Kopplung:

- Die aktuelle PoC-Validierung auf Proxmox beweist jetzt die Topologie `Upstream SCIM Push -> zustandsbehafteter Middle Keycloak -> Downstream SCIM Push`.
- Das bedeutet: Der Middle Keycloak bzw. die Middle-Layer-Logik stellt ein echtes SCIM-Ingest-Ziel für das Upstream-System bereit und provisioniert anschließend selbst per SCIM in Richtung Downstream.
- Die Zustandsbehaftung im Middle Layer bleibt dabei erhalten, weil dort weiterhin lokale Credentials, Failover-Zustände, Overrides und Rückkonvergenzlogik gehalten werden.
- Im aktuellen Repo wird der Upstream-Keycloak noch durch einen UKC-spezifischen Adapter in dieses SCIM-Push-Modell übersetzt. Wenn ein Upstream-IdP den benötigten SCIM-Push direkt unterstützt, entfällt dieser Adapter.

Im Regelbetrieb erfolgt die Authentifizierung über den Middle Keycloak als Broker zu einem autoritativen Upstream-Identitätssystem. Zusätzlich muss der Middle Keycloak einen autarken Betrieb unterstützen. In diesem Modus authentifiziert der Middle Keycloak Benutzer direkt mit lokal hinterlegten Credentials, wenn das Upstream-System nicht verfügbar ist oder der Offline-Betrieb administrativ aktiviert wurde.

Ein lokales Offline-Kennwort darf erst nach einer erfolgreich gegen das Upstream-System verifizierten Anmeldung im Middle Keycloak hinterlegt werden. Die Verwaltung lokaler Offline-Credentials ist damit eine Funktion des Middle Keycloak; Provisioning-Prozesse dürfen keine Credentials setzen.

Für die Autorisierung in Downstream-Systemen sind zwei Aspekte zu unterscheiden:

- Benutzer, Gruppen und Gruppenzugehörigkeiten müssen im Downstream-System provisioniert sein, damit sie dort als Identitäten und Berechtigungsobjekte existieren.
- Die für die Laufzeit-Autorisierung verwendeten Gruppen- oder Rolleninformationen müssen stabil aus dem Middle Keycloak kommen, zum Beispiel über Claims in Tokens.

Der Middle Keycloak ist damit die maßgebliche Quelle für die zur Laufzeit verwendeten Autorisierungsinformationen gegenüber Downstream-Systemen.

Die fachlichen Verantwortlichkeiten sind dabei wie folgt zu verstehen:

- Das Upstream-Identitätssystem ist autoritativ für Benutzer, Gruppen und Gruppenzugehörigkeiten.
- Der Middle Keycloak ist autoritativ für lokale Offline-Credentials sowie für die zur Laufzeit gegenüber Downstream-Systemen ausgegebenen Autorisierungsinformationen.
- Das Downstream-System ist ein konsumierendes Zielsystem für provisionierte Identitäten und Laufzeit-Claims, aber nicht das führende System für Stammdaten.

Der Offline-Betrieb ist in zwei Ausbaustufen zu betrachten:

- In der ersten Stufe dient der Offline-Fallback ausschließlich der lokalen Authentifizierung auf Basis zuvor replizierter Daten. Dieser Modus ist read-only.
- In der zweiten Stufe kann der Offline-Betrieb um lokale Pflegeprozesse für Benutzer, Gruppen und Rollen erweitert werden.

Ein bestehender Online-only-Betrieb muss in den Offline-Fallback erweitert werden können. Die Offline-Fähigkeit muss also als zuschaltbare Funktion für bestehende Middle-Keycloak-Installationen aktivierbar sein und darf keine Neuimplementierung des Gesamtsystems voraussetzen.

Der Eintritt in den Offline-Modus muss flexibel unterstützt werden:

- vollständig automatisch
- vollständig manuell
- oder automatisch beim Ausfall des Upstream-Systems, jedoch ohne automatischen Rückwechsel in den Online-Betrieb

Insbesondere bei lokalem Schreibbetrieb im Offline-Modus darf der Rückwechsel in den Online-Betrieb nicht automatisch erfolgen, wenn dadurch lokale Änderungen unkontrolliert verworfen würden.

Für das Konsistenzmodell des Offline-Betriebs gilt:

- Im read-only Offline-Fallback bleiben zuletzt erfolgreich replizierte Benutzer, Gruppen und Gruppenzugehörigkeiten verfügbar.
- Während eines Offline-Ausfalls werden Änderungen aus dem Upstream-System nicht übernommen.
- Nach Wiederkopplung an das Upstream-System muss der Middle Keycloak wieder auf den autoritativen Upstream-Stand konvergieren.

Für das Konsistenzmodell im Online-Betrieb gilt ebenfalls eine wichtige Präzisierung:

- Die Zielarchitektur fordert eine deterministische Konvergenz von Middle Keycloak und Downstream auf den zuletzt erfolgreich ingestierten autoritativen Upstream-Stand.
- Sie fordert keine transaktionale Sofortkonsistenz, bei der Upstream, Middle und Downstream zu jedem Zeitpunkt vollständig identisch sein müssen.
- Kurzzeitige Abweichungen während Propagation, Wiederanlauf, Failover oder lokalem Offline-Schreibbetrieb sind fachlich zulässig, solange die Rückkonvergenz auf den autoritativen Upstream-Stand sichergestellt ist.

## Features für Middle Keycloak, die an Hersteller kommuniziert werden müssen

### Grundbefähigung Downstream-Integration (P0)

`Middle Keycloak:`

- MUSS Identitäten, Gruppen und Gruppenzugehörigkeiten aus einem autoritativen Upstream-Identitätssystem übernehmen und lokal verarbeiten können.
- MUSS Identitäten, Gruppen und Gruppenzugehörigkeiten in Richtung Downstream über eine standardisierte Provisioning-Schnittstelle bereitstellen können.
- MUSS für diese Provisioning-Schnittstelle `SCIM` unterstützen.
- MUSS eine standardisierte SCIM-Provisioning-Schnittstelle als Ingest-Ziel für ein autoritatives Upstream-Identitätssystem bereitstellen können.
- MUSS dadurch die Topologie `Upstream SCIM Push -> Middle Keycloak -> Downstream SCIM Push` unterstützen können.
- MUSS im Online-Betrieb Middle- und Downstream-Zustand deterministisch auf den zuletzt erfolgreich ingestierten autoritativen Upstream-Stand konvergieren können.
- MUSS dafür keine transaktionale Sofortkonsistenz zwischen Upstream, Middle und Downstream garantieren, sofern eine definierte und nachvollziehbare Rückkonvergenz sichergestellt ist.
- MUSS als alleiniger Runtime-Identity-Provider für Downstream-Systeme fungieren.
- MUSS Authentifizierung im Regelbetrieb an ein autoritatives Upstream-Identitätssystem weiterleiten können.
- MUSS gegenüber Upstream-Identitätssystemen für die föderierte Authentifizierung `OIDC` unterstützen.
- MUSS gegenüber Downstream-Anwendungen für Laufzeit-Authentifizierung und Token-Ausstellung `OIDC` unterstützen.
- MUSS für das Provisioning von Benutzern, Gruppen und Gruppenzugehörigkeiten in Richtung Downstream `SCIM` unterstützen.
- MUSS Gruppen- und Rolleninformationen so bereitstellen können, dass diese einerseits im Downstream-System provisioniert und andererseits zur Laufzeit für Autorisierung nutzbar gemacht werden können.
- MUSS hochverfügbar betrieben werden können.
- MUSS revisionssicher auditierbar sein.
- MUSS in Logging, Monitoring und Alarmierung des Hersteller-Betriebsmodells integrierbar sein.

### Grundbefähigung Offline Fallback (P1)

- MUSS bei Nichtverfügbarkeit des Upstream-Identitätssystems eine lokale Authentifizierung über den Middle Keycloak ermöglichen.
- MUSS Benutzer nach erfolgreicher Upstream-verifizierter Anmeldung zur Hinterlegung eines lokalen Offline-Kennworts befähigen.
- MUSS sicherstellen, dass Provisioning-Prozesse und administrative Replikationsschnittstellen keine lokalen Offline-Credentials setzen oder verändern.
- MUSS erkennen können, dass das Upstream-Identitätssystem nicht verfügbar ist.
- MUSS für den Wechsel zwischen Online- und Offline-Betrieb eine definierte und administrierbare Umschaltlogik bereitstellen.
- MUSS den Offline-Betrieb vollständig manuell aktivieren lassen können.
- MUSS den Offline-Betrieb vollständig automatisch aktivieren können.
- MUSS den Offline-Betrieb auch in einem Modus unterstützen, in dem der Eintritt automatisch erfolgt, der Rückwechsel in den Online-Betrieb jedoch ausschließlich manuell erfolgt.
- MUSS im Offline-Fallback der ersten Ausbaustufe einen read-only-Betrieb für Benutzer, Gruppen und Rollen unterstützen.
- MUSS im read-only Offline-Fallback die zuletzt erfolgreich replizierten Benutzer, Gruppen und Gruppenzugehörigkeiten verfügbar halten.
- MUSS nach Wiederverfügbarkeit des Upstream-Identitätssystems wieder auf den autoritativen Upstream-Stand konvergieren können.
- MUSS als bestehender Online-only-Betrieb um die Offline-Fallback-Funktion erweiterbar sein, ohne eine Neuaufsetzung des Gesamtsystems oder einen Austausch der führenden Identitätsquelle zu erzwingen.

### Offline Fallback mit Pflegeprozessen (P1)

- MUSS im Offline-Betrieb die lokale Pflege von Benutzern, Gruppen und Rollen unterstützen können, sofern dieser Betriebsmodus aktiviert ist.
- MUSS für diesen Betriebsmodus klar zwischen Upstream-autoritativem Betrieb und lokal gepflegtem Offline-Betrieb unterscheiden.
- MUSS nach Wiederkopplung an das Upstream-System lokale Änderungen kontrolliert verwerfen oder überschreiben können.
- MUSS den Rückwechsel in den Online-Betrieb administrativ steuerbar machen, damit lokale Offline-Änderungen nicht unkontrolliert verworfen werden.
- MUSS den Offline-Betrieb mit Pflegeprozessen als zweite Ausbaustufe auf die Grundbefähigung Offline Fallback aufsetzen können.
