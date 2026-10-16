#!/usr/bin/env bash
# AuloPS2 - fork ARMSX2 (GPL-3.0), rebrand, paksa landscape, ganti ikon, build APK.
# Jalankan di GitHub Codespaces:  bash setup_aulops2.sh [path_icon.png]
set -euo pipefail

APP_NAME="AuloPS2"
APP_ID="com.aulops2.app"
UPSTREAM="https://github.com/ARMSX2/ARMSX2.git"
ROOT="$(pwd)"
SRC="$ROOT/AuloPS2-src"
ICON="${1:-$ROOT/aulops2_icon.png}"

[ -f "$ICON" ] || { echo "Icon nggak ketemu: $ICON"; echo "Upload gambarnya ke folder ini dengan nama aulops2_icon.png"; exit 1; }

echo "==> [1/6] Install dependency"
sudo apt-get update -y
sudo apt-get install -y ninja-build cmake python3 python3-pil pkg-config zip unzip curl git openjdk-17-jdk

echo "==> [2/6] Android SDK"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  curl -fsSL -o /tmp/cmdtools.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
  unzip -q -o /tmp/cmdtools.zip -d /tmp/cmdtools
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mv /tmp/cmdtools/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest"
fi
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager "platform-tools" >/dev/null

echo "==> [3/6] Clone ARMSX2 (lama, ada submodule)"
if [ ! -d "$SRC/.git" ]; then
  git clone --recurse-submodules --shallow-submodules --depth 1 "$UPSTREAM" "$SRC"
fi
cd "$SRC"

echo "==> [4/6] Rebrand: nama, applicationId, landscape, ikon"
APP_NAME="$APP_NAME" APP_ID="$APP_ID" ICON="$ICON" python3 - <<'PY'
import os, re, sys
from pathlib import Path
from PIL import Image, ImageDraw

NAME = os.environ["APP_NAME"]
APP_ID = os.environ["APP_ID"]
ICON = os.environ["ICON"]
SKIP = {"node_modules", ".git", "build", ".gradle"}

def find(pattern):
    return [p for p in Path(".").rglob(pattern) if not (set(p.parts) & SKIP)]

# modul app = build.gradle(.kts) yang punya applicationId
gradles = [p for p in find("build.gradle*") if "applicationId" in p.read_text(errors="ignore")]
if not gradles:
    sys.exit("Gagal: build.gradle dengan applicationId nggak ketemu")
g = gradles[0]
mod = g.parent
print("Modul app:", mod)

# applicationId (namespace/package kode TIDAK diubah, biar JNI native aman)
t = g.read_text()
t2, n = re.subn(r'(applicationId\s*=?\s*)"[^"]+"', lambda m: m.group(1) + '"' + APP_ID + '"', t)
g.write_text(t2)
print("applicationId diganti di", n, "tempat")
if n == 0:
    print("PERINGATAN: pola applicationId nggak cocok, ganti manual di", g)

res = mod / "src/main/res"
res.mkdir(parents=True, exist_ok=True)
mf = mod / "src/main/AndroidManifest.xml"
m = mf.read_text()

# landscape untuk semua activity
m = re.sub(r'\s+android:screenOrientation="[^"]*"', '', m)
m = re.sub(r'<activity(?![\w-])', '<activity android:screenOrientation="sensorLandscape"', m)

# ikon + label di tag <application>
def fix_app(match):
    tag = match.group(0)
    tag = re.sub(r'\s+android:(icon|roundIcon)="[^"]*"', '', tag)
    tag = re.sub(r'\s+android:label="[^@"][^"]*"', ' android:label="@string/app_name"', tag)
    return tag.replace('<application', '<application android:icon="@mipmap/aulo_launcher" android:roundIcon="@mipmap/aulo_launcher_round"', 1)
m = re.sub(r'<application[^>]*>', fix_app, m, count=1)
mf.write_text(m)

# nama app (semua bahasa)
for sx in res.glob("values*/strings.xml"):
    s = sx.read_text()
    s2 = re.sub(r'(<string\s+name="(?:app_name|app_label)"[^>]*>)[^<]*(</string>)',
                lambda mm: mm.group(1) + NAME + mm.group(2), s)
    if s2 != s:
        sx.write_text(s2)
if not any('name="app_name"' in p.read_text(errors="ignore") for p in res.glob("values*/*.xml")):
    (res / "values").mkdir(exist_ok=True)
    (res / "values/aulo_strings.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources><string name="app_name">%s</string></resources>\n' % NAME)

# ikon: buang latar putih, bikin PNG semua densitas + adaptive icon
img = Image.open(ICON).convert("RGBA")
w, h = img.size
for pt in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
    ImageDraw.floodfill(img, pt, (0, 0, 0, 0), thresh=60)
bbox = img.getbbox()
if bbox:
    img = img.crop(bbox)
BG = (11, 11, 20, 255)

def compose(size, scale, bg=None, circle=False):
    c = Image.new("RGBA", (size, size), bg if bg else (0, 0, 0, 0))
    f = img.copy()
    s = int(size * scale)
    f.thumbnail((s, s), Image.LANCZOS)
    c.alpha_composite(f, ((size - f.width) // 2, (size - f.height) // 2))
    if circle:
        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).ellipse((0, 0, size - 1, size - 1), fill=255)
        c.putalpha(mask)
    return c

for d, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
    out = res / ("mipmap-" + d)
    out.mkdir(parents=True, exist_ok=True)
    compose(px, 0.82, BG).save(out / "aulo_launcher.png")
    compose(px, 0.72, BG, circle=True).save(out / "aulo_launcher_round.png")

fg = res / "drawable-nodpi"
fg.mkdir(parents=True, exist_ok=True)
compose(432, 0.60).save(fg / "aulo_icon_fg.png")
(res / "values").mkdir(exist_ok=True)
(res / "values/aulo_colors.xml").write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n<resources><color name="aulo_icon_bg">#0B0B14</color></resources>\n')
ad = res / "mipmap-anydpi-v26"
ad.mkdir(parents=True, exist_ok=True)
xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
       '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
       '    <background android:drawable="@color/aulo_icon_bg"/>\n'
       '    <foreground android:drawable="@drawable/aulo_icon_fg"/>\n'
       '</adaptive-icon>\n')
(ad / "aulo_launcher.xml").write_text(xml)
(ad / "aulo_launcher_round.xml").write_text(xml)
print("Rebrand selesai")
PY

echo "==> [5/6] Build APK (build pertama bisa 30-60+ menit)"
MODULE_GRADLE="$(grep -rl --include=build.gradle --include=build.gradle.kts 'applicationId' . | grep -v node_modules | head -1)"
d="$(realpath "$(dirname "$MODULE_GRADLE")")"
MOD="$(basename "$d")"
while [ "$d" != "/" ] && ! ls "$d"/settings.gradle* >/dev/null 2>&1; do d="$(dirname "$d")"; done
GRADLE_ROOT="$d"
if [ -f "$GRADLE_ROOT/gradlew" ]; then GW="$GRADLE_ROOT/gradlew"; else GW="$SRC/gradlew"; fi
chmod +x "$GW"
echo "Gradle root: $GRADLE_ROOT | modul: $MOD"
df -h . | tail -1

STAMP="$(mktemp)"
cd "$GRADLE_ROOT"
JV="-Dorg.gradle.jvmargs=-Xmx4g"
"$GW" ":$MOD:assembleRelease" "$JV" --stacktrace || {
  echo "Release gagal, coba debug build..."
  "$GW" ":$MOD:assembleDebug" "$JV" --stacktrace
}

echo "==> [6/6] Sign APK"
APK="$(find "$GRADLE_ROOT" -path '*outputs/apk*' -name '*.apk' -newer "$STAMP" | grep -i release | head -1 || true)"
[ -z "$APK" ] && APK="$(find "$GRADLE_ROOT" -path '*outputs/apk*' -name '*.apk' -newer "$STAMP" | head -1)"
[ -n "$APK" ] || { echo "APK nggak ketemu"; exit 1; }
echo "APK mentah: $APK"

BT="$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1)"
KS="$HOME/aulops2.keystore"
if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -alias aulops2 -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass aulops2pass -keypass aulops2pass -dname "CN=AuloPS2"
fi
"$BT/zipalign" -f -P 16 4 "$APK" /tmp/aulo-aligned.apk 2>/dev/null || "$BT/zipalign" -f -p 4 "$APK" /tmp/aulo-aligned.apk
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:aulops2pass --key-pass pass:aulops2pass \
  --out "$ROOT/AuloPS2.apk" /tmp/aulo-aligned.apk

echo ""
echo "SELESAI -> $ROOT/AuloPS2.apk (klik kanan di Explorer > Download)"
echo "Simpan $KS, dipakai lagi biar APK update bisa nimpa versi lama."
