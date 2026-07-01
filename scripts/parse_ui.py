import re, sys

filepath = sys.argv[1] if len(sys.argv) > 1 else '/tmp/ui_p1.xml'
with open(filepath, 'r') as f:
    content = f.read()

print(f"File size: {len(content)} chars")

# Simple approach: find all clickable nodes with content-desc
nodes = re.findall(r'<node[^>]*/>', content)
for n in nodes:
    desc_m = re.search(r'content-desc="([^"]*)"', n)
    bounds_m = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    click_m = re.search(r'clickable="(true|false)"', n)
    if desc_m and bounds_m:
        desc = desc_m.group(1).replace('&#10;',' | ').strip()
        x1 = int(bounds_m.group(1)); y1 = int(bounds_m.group(2))
        x2 = int(bounds_m.group(3)); y2 = int(bounds_m.group(4))
        cl = click_m.group(1) if click_m else '?'
        if desc and (x2-x1) > 20 and (y2-y1) > 20:
            cx = (x1+x2)//2; cy = (y1+y2)//2
            print(f'TAP({cx},{cy}) [{x1},{y1}][{x2},{y2}] click={cl} "{desc[:100]}"')

print("---DONE---")
