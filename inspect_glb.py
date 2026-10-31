# inspect_glb.py
import sys, json, struct
from pathlib import Path

def read_glb(path):
    with open(path, "rb") as f:
        magic, version, length = struct.unpack("<III", f.read(12))
        assert magic == 0x46546C67, "Not a GLB"
        chunks = {}
        while f.tell() < length:
            clen, ctype = struct.unpack("<II", f.read(8))
            data = f.read(clen)
            if ctype == 0x4E4F534A:  # JSON
                chunks["json"] = json.loads(data.decode("utf-8"))
            elif ctype == 0x004E4942:  # BIN
                chunks["bin"] = data
        return chunks

def main(path):
    g = read_glb(path)["json"]

    print("=" * 60)
    print(f"GLB: {path}")
    print("=" * 60)

    print(f"\nScenes: {len(g.get('scenes', []))}")
    print(f"Nodes:  {len(g.get('nodes', []))}")
    print(f"Meshes: {len(g.get('meshes', []))}")
    print(f"Skins:  {len(g.get('skins', []))}")
    print(f"Animations: {len(g.get('animations', []))}")
    print(f"Materials: {len(g.get('materials', []))}")

    print("\n--- NODES ---")
    for i, n in enumerate(g.get("nodes", [])):
        name = n.get("name", f"node_{i}")
        kids = n.get("children", [])
        mesh = n.get("mesh")
        skin = n.get("skin")
        print(f"  [{i}] {name!r:40s} children={kids} mesh={mesh} skin={skin}")

    print("\n--- SKINS ---")
    for i, s in enumerate(g.get("skins", [])):
        joints = s.get("joints", [])
        jnames = [g["nodes"][j].get("name", f"n{j}") for j in joints]
        print(f"  [{i}] skeleton={s.get('skeleton')} joints={len(joints)}")
        for jn in jnames:
            print(f"        bone: {jn}")

    print("\n--- ANIMATIONS ---")
    for i, a in enumerate(g.get("animations", [])):
        name = a.get("name", f"anim_{i}")
        channels = a.get("channels", [])
        targets = set()
        for ch in channels:
            t = ch.get("target", {})
            n = t.get("node")
            if n is not None:
                targets.add(g["nodes"][n].get("name", f"n{n}"))
        print(f"  [{i}] {name!r} channels={len(channels)} targets={len(targets)}")
        for tn in sorted(targets):
            print(f"        -> {tn}")

    print("\n--- MORPH TARGETS ---")
    for i, m in enumerate(g.get("meshes", [])):
        for pi, prim in enumerate(m.get("primitives", [])):
            targets = prim.get("targets")
            if targets:
                print(f"  mesh[{i}] {m.get('name')!r} prim[{pi}] has {len(targets)} morph targets")

if __name__ == "__main__":
    main(sys.argv[1])