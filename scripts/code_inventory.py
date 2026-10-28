#!/usr/bin/env python3
"""Reproducible source inventory; no generated builds, binary assets or experiment duplicates."""
import argparse
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP = {".git", ".build", "build", "DerivedData", "__pycache__", ".swiftpm"}
GROUPS = ("App", "SpatialCore", "Contracts", "OptionalModels", "Tests", "Scripts")


def category(path):
    """Classify first-party source only; frozen Experiments are deliberately excluded."""
    name = path.as_posix()
    if name.startswith("PRTS/") and (path.suffix == ".swift" or name.endswith(".metal.txt")):
        return "App"
    if name.startswith("Vendor/SpatialCore/Sources/") and path.suffix == ".swift":
        return "SpatialCore"
    if name.startswith("Vendor/PRTSCore/Sources/") and path.suffix == ".swift":
        return "Contracts" if "PRTSContracts" in path.parts else "OptionalModels"
    if name.startswith(("Vendor/PRTSCore/Tests/", "PRTSTests/", "PRTSUITests/", "Vendor/SpatialCore/Tests/")) and path.suffix == ".swift":
        return "Tests"
    if name.startswith("scripts/") and path.suffix in {".py", ".sh", ".swift"}:
        return "Tests" if path.name.startswith("test_") else "Scripts"
    return None


def inventory(root):
    records = []
    # Only these source roots: avoid walking large models, build logs and historical captures.
    for directory in ("PRTS", "PRTSTests", "PRTSUITests", "Vendor/SpatialCore/Sources",
                      "Vendor/SpatialCore/Tests", "Vendor/PRTSCore/Sources", "Vendor/PRTSCore/Tests", "scripts"):
        for current, directories, filenames in os.walk(root / directory, followlinks=False):
            # Prune before descending; filtering rglob results still traverses build caches.
            directories[:] = sorted(d for d in directories if d not in SKIP
                                    and not (Path(current) / d).is_symlink())
            for filename in sorted(filenames):
                path = Path(current) / filename
                if path.is_symlink():
                    continue
                relative = path.relative_to(root)
                group = category(relative)
                if group:
                    lines = path.read_text(encoding="utf-8").splitlines()
                    records.append((relative.as_posix(), group, len(lines), sum(bool(line.strip()) for line in lines)))
    return sorted(records)


def report(records):
    lines = [
        "# 代码清单", "",
        "各模块的文件数和行数，由 `python3 scripts/code_inventory.py --write` 生成，不要手改。", "",
        "- 行数包含注释，不等于语句数。",
        "- App 包含 Swift 和 Metal 源码；Tests 包含 Swift 和 Python 测试。",
        "- Contracts 是 App 链接的 `PRTSContracts`；OptionalModels 是没有链接进 App 的可选源码。",
        "- Total 是全部维护的源码，不等于 App 的编译量。",
        "- 不算 Experiments、模型、图片、文档、工程配置和 Package.swift。", "",
        "| 模块 | 文件数 | 物理行 | 非空行 |",
        "|---|---:|---:|---:|",
    ]
    for group in (*GROUPS, "Total"):
        selected = records if group == "Total" else [r for r in records if r[1] == group]
        lines.append(f"| {group} | {len(selected)} | {sum(r[2] for r in selected)} | {sum(r[3] for r in selected)} |")
    lines += ["", "## 文件树", "", "各目录做什么见 [代码结构](code-structure.md)。", "", "```text"]
    previous = ()
    for name, _, physical, _ in records:
        parts = Path(name).parts
        parents = parts[:-1]
        for depth, part in enumerate(parents):
            if previous[:depth + 1] != parents[:depth + 1]:
                lines.append("  " * depth + part + "/")
        lines.append("  " * len(parents) + f"{parts[-1]} ({physical} lines)")
        previous = parents
    return "\n".join(lines + ["```", ""])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Update docs/architecture/code-inventory.md")
    args = parser.parse_args()
    text = report(inventory(ROOT))
    if args.write:
        (ROOT / "docs/architecture/code-inventory.md").write_text(text, encoding="utf-8")
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
