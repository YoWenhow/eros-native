#!/usr/bin/env python3
"""Audit a local, pinned F08a db.text.json; no network, imports, or remote code execution."""
import argparse
import hashlib
import json
from pathlib import Path

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key")
        result[key] = value
    return result

def audit(path, manifest):
    if path.stat().st_size != manifest["byteCount"]:
        raise ValueError("byte count mismatch")
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != manifest["hash"]:
        raise ValueError("SHA-256 mismatch")
    doc = json.loads(raw, object_pairs_hook=unique_object)
    if doc["repo"] != manifest["repository"] or doc["version"] != manifest["schemaVersion"] or doc["head"]["sha"] != manifest["sourceCommit"]:
        raise ValueError("source identity/schema mismatch")
    counts = {}
    for group in doc["data"]:
        ns = group["namespace"]
        if ns in counts or group["count"] != len(group["data"]):
            raise ValueError("namespace/count mismatch")
        counts[ns] = len(group["data"])
        for key, entry in group["data"].items():
            if not isinstance(key, str) or not key or any(not isinstance(entry.get(field), str) for field in ("name", "intro", "links")):
                raise ValueError("entry schema mismatch")
    if counts != manifest["namespaceCounts"] or sum(counts.values()) != manifest["entryCount"]:
        raise ValueError("manifest counts mismatch")
    return {"status": "PASS", "version": manifest["version"], "schemaVersion": doc["version"], "byteCount": len(raw), "sha256": manifest["hash"], "namespaceCount": len(counts), "entryCount": sum(counts.values())}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).resolve().parents[2] / "docs/ios27-native/phase-2/evidence/f08a-source-manifest.json")
    args = parser.parse_args()
    print(json.dumps(audit(args.input, json.loads(args.manifest.read_text())), indent=2))
