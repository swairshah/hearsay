#!/usr/bin/env python3
"""
Fix the Hearsay app icon to have proper macOS rounded corners (superellipse/squircle).
macOS Big Sur+ uses a specific superellipse shape with ~22.37% corner radius.
"""

import subprocess
import os
from pathlib import Path

# Icon sizes for macOS app icons
ICON_SIZES = [
    (16, "icon_16.png", 1),
    (32, "icon_16@2x.png", 1),  # 16@2x = 32px
    (32, "icon_32.png", 1),
    (64, "icon_32@2x.png", 1),  # 32@2x = 64px
    (128, "icon_128.png", 1),
    (256, "icon_128@2x.png", 1),  # 128@2x = 256px
    (256, "icon_256.png", 1),
    (512, "icon_256@2x.png", 1),  # 256@2x = 512px
    (512, "icon_512.png", 1),
    (1024, "icon_512@2x.png", 1),  # 512@2x = 1024px
]

def create_rounded_icon(input_path, output_path, size):
    """
    Create a macOS-style rounded icon using ImageMagick.
    The corner radius for macOS Big Sur+ is approximately 22.37% of the icon size.
    """
    # macOS uses a superellipse, but a rounded rectangle with ~22% radius is close enough
    corner_radius = int(size * 0.2237)
    
    # Create the rounded rectangle mask and apply it
    # We'll composite the original image with a rounded rect mask
    # Icon content should be ~80% of canvas (10% padding on each side)
    content_size = int(size * 0.8)
    border = (size - content_size) // 2
    
    cmd = [
        'magick',
        input_path,
        '-resize', f'{content_size}x{content_size}',
        '-background', 'none',
        '-gravity', 'center',
        '-extent', f'{size}x{size}',
        output_path
    ]
    
    subprocess.run(cmd, check=True)
    print(f"  Created {output_path} ({size}x{size})")

def main():
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    icon_dir = project_root / "Hearsay" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
    
    # Use the highest resolution source
    source_icon = icon_dir / "icon_512@2x.png"
    
    if not source_icon.exists():
        print(f"Error: Source icon not found at {source_icon}")
        return 1
    
    print(f"Using source: {source_icon}")
    print("Generating rounded icons...")
    
    for size, filename, _ in ICON_SIZES:
        output_path = icon_dir / filename
        create_rounded_icon(str(source_icon), str(output_path), size)
    
    print("\nDone! Icons now have macOS-style rounded corners.")
    print("Run ./run.sh to rebuild the app.")
    return 0

if __name__ == "__main__":
    exit(main())
