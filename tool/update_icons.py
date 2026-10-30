"""Resize the Balance icon into platform assets (requires Pillow).

Run through branding/render.sh, which first renders assets/app_icon.png and
branding/icon_foreground.png from their SVG sources.
"""
import json
from pathlib import Path
from PIL import Image
root = Path(__file__).resolve().parents[1]
icon = Image.open(root / 'assets/app_icon.png').convert('RGB')
foreground = Image.open(root / 'branding/icon_foreground.png').convert('RGBA')
def save(path, size):
    icon.resize((size,size), Image.Resampling.LANCZOS).save(path)
for target in ['ios','macos']:
    folder = root / target / 'Runner/Assets.xcassets/AppIcon.appiconset'
    for asset in json.loads((folder/'Contents.json').read_text())['images']:
        if 'filename' in asset:
            size = round(float(asset['size'].split('x')[0]) * float(asset['scale'].rstrip('x')))
            save(folder/asset['filename'],size)
for density,size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
    save(root/f'android/app/src/main/res/mipmap-{density}/ic_launcher.png',size)
    # Adaptive icon foreground is a 108dp layer: 2.25x the 48dp legacy icon.
    foreground.resize((size*9//4,)*2, Image.Resampling.LANCZOS).save(
        root/f'android/app/src/main/res/mipmap-{density}/ic_launcher_foreground.png')
res = root/'android/app/src/main/res'
(res/'mipmap-anydpi-v26').mkdir(exist_ok=True)
(res/'mipmap-anydpi-v26/ic_launcher.xml').write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
    '    <background android:drawable="@color/ic_launcher_background"/>\n'
    '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
    '</adaptive-icon>\n')
(res/'values/ic_launcher_background.xml').write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
    '    <color name="ic_launcher_background">#2B6556</color>\n</resources>\n')
for name,size in [('Icon-192',192),('Icon-512',512),('Icon-maskable-192',192),('Icon-maskable-512',512)]:
    save(root/f'web/icons/{name}.png',size)
save(root/'web/favicon.png',32)
icon.save(root/'windows/runner/resources/app_icon.ico',sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])
manifest=root/'web/manifest.json'
data=json.loads(manifest.read_text());data.update(background_color='#f4faf6',theme_color='#356859',orientation='any')
manifest.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
