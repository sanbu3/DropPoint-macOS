"""Run after render-shelf-artwork.cjs; Pillow is a development-only dependency."""
from PIL import Image
from pathlib import Path
import hashlib
import json

manifest = {}
for name, duration in [('Cat_in_Box', 2.97), ('Empty Box', 4.037)]:
    files = sorted(Path('.build/artwork-frames', name).glob('*.png'))
    if not files:
        raise SystemExit('Render frames first: ' + name)
    frames = [Image.open(file).convert('RGBA') for file in files]
    target = Path('Resources', name + ' Timeline.png')
    frames[0].save(target, save_all=True, append_images=frames[1:],
                   duration=duration * 1000 / len(frames), loop=0, disposal=0, blend=0, optimize=True)
    encoded = Image.open(target)
    manifest[name] = {
        'sourceSHA256': hashlib.sha256(Path('Resources', name + '.svg').read_bytes()).hexdigest(),
        'duration': duration, 'sampledFrames': len(frames), 'encodedFrames': encoded.n_frames,
        'resolution': frames[0].size, 'bytes': target.stat().st_size,
    }
Path('Resources/ArtworkTimelines.json').write_text(json.dumps(manifest, indent=2) + '\n')
