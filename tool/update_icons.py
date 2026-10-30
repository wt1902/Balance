"""Resize the original Balance icon into platform assets (requires Pillow)."""
import json
from pathlib import Path
from PIL import Image
root = Path(__file__).resolve().parents[1]
icon = Image.open(root / 'assets/app_icon.png').convert('RGB')
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
for name,size in [('Icon-192',192),('Icon-512',512),('Icon-maskable-192',192),('Icon-maskable-512',512)]:
    save(root/f'web/icons/{name}.png',size)
save(root/'web/favicon.png',32)
icon.save(root/'windows/runner/resources/app_icon.ico',sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])
manifest=root/'web/manifest.json'
data=json.loads(manifest.read_text());data.update(background_color='#f4faf6',theme_color='#356859',orientation='any')
manifest.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
