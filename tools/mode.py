#!/usr/bin/env python3
"""Setzt den Beschleuniger eines Modells in oMLX (~/.omlx/model_settings.json).

  mode.py Ornith-1.5-35B-A3B-oQ3e-mtp plain    # ohne Spekulation
  mode.py Ornith-1.5-35B-A3B-oQ3e-mtp mtp      # Lightning MTP (eingebauter MTP-Kopf)
  mode.py Ornith-1.5-35B-A3B-oQ3e-mtp dflash Ornith-1.5-35B-A3B-DFlash

oMLX liest die Datei beim Start, also danach ./serve.sh neu starten.
"""

import json
import sys
from pathlib import Path

SETTINGS = Path.home() / ".omlx" / "model_settings.json"
MODELS = Path.home() / ".kilokal" / "models"


def main() -> None:
    if len(sys.argv) < 3 or sys.argv[2] not in ("plain", "mtp", "dflash"):
        sys.exit(__doc__)
    model, mode = sys.argv[1], sys.argv[2]
    data = json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {"version": 1, "models": {}}
    s = data.setdefault("models", {}).setdefault(model, {})
    s["mtp_enabled"] = mode == "mtp"
    s["dflash_enabled"] = mode == "dflash"
    if mode == "dflash":
        if len(sys.argv) < 4:
            sys.exit("dflash braucht den Ordner des Draft-Modells")
        s["dflash_draft_model"] = str(MODELS / sys.argv[3])
        s["dflash_verify_mode"] = "adaptive"
    SETTINGS.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    print(f"{model}: {mode}")


if __name__ == "__main__":
    main()
