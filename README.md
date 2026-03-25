# winopt

Windows 11 / kirbyOS Gaming- und CS2-Tuning fuer ein System mit:

- CPU: AMD Ryzen 7 5800X
- GPU: AMD Radeon RX 7900 XTX
- Mainboard: MSI MAG B550 TOMAHAWK
- RAM: 32 GB DDR4

Der Fokus dieses Projekts liegt auf niedrigerer Input-Latenz, besseren Frametimes und einer sauberen, rueckgaengig machbaren Windows-Optimierung fuer Counter-Strike 2.

## Enthalten

- [`win11_gaming_tune.ps1`](./win11_gaming_tune.ps1)
  Ein PowerShell-Skript mit Backup/Restore, Service-Reduzierung, Registry-Tweaks und einem `-Cs2Mode` fuer kompetitives Spielen.

## Schnellstart

PowerShell als Administrator oeffnen und im Projektordner ausfuehren:

```powershell
PowerShell.exe -ExecutionPolicy Bypass -File .\win11_gaming_tune.ps1 -Mode Optimize -Profile Aggressive -Cs2Mode -DisableXboxServices -DisableRemoteDiscoveryServices -DisableSearchIndexing
```

Optional, wenn du die Funktionen wirklich nicht brauchst:

```powershell
PowerShell.exe -ExecutionPolicy Bypass -File .\win11_gaming_tune.ps1 -Mode Optimize -Profile Aggressive -Cs2Mode -DisableXboxServices -DisableRemoteDiscoveryServices -DisableSearchIndexing -DisableBluetoothServices -DisablePrintServices -DisableVbs
```

Rueckgaengig machen:

```powershell
PowerShell.exe -ExecutionPolicy Bypass -File .\win11_gaming_tune.ps1 -Mode Restore
```

## Was das Skript macht

- legt ein Backup der geaenderten Registry-Werte, Services, geplanten Tasks, Power-Settings und BCD-Werte an
- schaltet Game DVR/Capture ab und aktiviert sinnvolle Gaming-Grundeinstellungen
- deaktiviert Mausbeschleunigung
- setzt einen Performance-Powerplan
- reduziert unnoetige Windows-Dienste in `Safe` oder `Aggressive`
- aktiviert im `-Cs2Mode` zusaetzlich:
  - USB Selective Suspend aus
  - PCIe Link State Power Management aus
  - CPU Energy Preference auf maximale Performance
  - CPU Min/Max auf 100
  - Core Parking aus
  - aggressiverer CPU-Boost fuer kompetitives Gaming

## Empfohlene Hardware- und BIOS-Settings

Fuer dein Setup mit `MSI MAG B550 TOMAHAWK + Ryzen 7 5800X + RX 7900 XTX` sind diese Punkte meist wichtiger als noch mehr Service-Cuts:

1. BIOS aktuell halten.
2. `A-XMP` aktivieren.
3. Wenn stabil, RAM moeglichst auf `DDR4-3600` mit `FCLK 1800` im 1:1-Modus fahren.
4. Wenn dein RAM nur `DDR4-3200` stabil schafft, `FCLK 1600` nutzen.
5. `Above 4G Decoding` und `Re-Size BAR Support` aktivieren.
   Das ist die Grundlage fuer AMD Smart Access Memory.
6. `UEFI` statt `CSM/Legacy` verwenden.
7. `PBO` und `Curve Optimizer` nur dann anfassen, wenn du sauber auf Stabilitaet testest.

Hinweis: Die exakten BIOS-Menues koennen sich je nach BIOS-Version leicht unterscheiden.

## Empfohlene AMD Adrenalin Settings fuer CS2

Fuer `cs2.exe` ist eine einfache, latenzorientierte Konfiguration meistens besser als ein "alles an"-Profil:

- `AMD Anti-Lag`: ON
- `AMD Chill`: OFF
- `AMD Boost`: OFF
- `AFMF / Frame Generation`: OFF
- `HYPR-RX`: OFF
- `V-Sync`: OFF
- `Radeon Enhanced Sync`: nur testen, nicht blind erzwingen

Ziel: moeglichst wenig zusaetzliche Frame-Pipeline, keine stromsparenden Eingriffe, keine "Smart"-Features, die in einem kompetitiven Shooter eher stoeren koennen.

## Windows- und CS2-Hinweise

- Overlays nur nutzen, wenn du sie wirklich brauchst.
  Discord-Overlay, Xbox Game Bar, Browser, RGB-Suiten und Mainboard-Tools koennen Frametime-Spikes verursachen.
- Fuer AMD ist `Anti-Lag` in der Regel sinnvoller als irgendwelche zufaelligen Registry-Packs.
- Wenn du Borderless spielst, teste in Windows 11 die `Optimizations for windowed games`.
- Wenn du die niedrigste moegliche Input-Latenz willst, ist ein sauberer BIOS-/RAM-Setup oft wichtiger als noch 20 weitere deaktivierte Services.

## Tools und Referenzen

Externe Tools, die als Ergaenzung interessant sein koennen:

- [Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat)
  Solides Debloat-/Privacy-Tool fuer Windows 11. Nicht blind mit anderen Debloat-Skripten stapeln.
- [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil)
  Umfangreiches Windows-Tuning- und Setup-Tool mit vielen Schaltern fuer Features, Dienste und Apps.
- [Windows Tweaking & Debloating Apps - YouTube Playlist](https://www.youtube.com/playlist?list=PLwdwMLbf_qda6u3pAJ7x0p-0AO4UpnKAi)
  Sammlung rund um Windows-Tweaks, Debloat-Tools und Optimierungsansaetze.

## Empfehlung zum Einsatz

Nicht alles gleichzeitig anwenden. Sinnvolle Reihenfolge:

1. BIOS und RAM sauber konfigurieren.
2. AMD Chipset Driver und Adrenalin aktuell halten.
3. Dieses Skript mit `-Cs2Mode` ausfuehren.
4. Erst danach zusaetzliche Debloat-Tools einzeln pruefen.

So siehst du klarer, welche Aenderung wirklich geholfen hat.

## Sicherheit

- Das Skript ist auf Rueckgaengigkeit ausgelegt, aber Windows-Tuning bleibt immer auf eigenes Risiko.
- `-DisableVbs` kann Performance bringen, reduziert aber Sicherheitsfunktionen.
- Extrem aggressive Service-Cuts bringen oft weniger FPS als erwartet und koennen spaeter Features kaputt machen.
