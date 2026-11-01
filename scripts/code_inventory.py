#!/usr/bin/env python3
"""Reproducible source inventory; no generated builds, binary assets or experiment duplicates."""

import argparse
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP = {
    ".git",
    ".build",
    "build",
    "DerivedData",
    "__pycache__",
    ".swiftpm",
    "PRTSLocalVLM.xcframework",
}
GROUPS = ("App", "SpatialCore", "LocalVLM", "Contracts", "OptionalModels", "Tests", "Scripts")


def category(path):
    """Classify first-party source only; frozen Experiments are deliberately excluded."""
    name = path.as_posix()
    if name.startswith("PRTS/") and (path.suffix == ".swift" or name.endswith(".metal.txt")):
        return "App"
    if name.startswith("Packages/SpatialCore/Sources/") and path.suffix == ".swift":
        return "SpatialCore"
    if name.startswith("Packages/LocalVLM/") and path.suffix in {".swift", ".cpp", ".h", ".sh"}:
        return "LocalVLM"
    if name.startswith("Vendor/PRTSCore/Sources/") and path.suffix == ".swift":
        return "Contracts" if "PRTSContracts" in path.parts else "OptionalModels"
    if (
        name.startswith(
            ("Vendor/PRTSCore/Tests/", "PRTSTests/", "PRTSUITests/", "Packages/SpatialCore/Tests/")
        )
        and path.suffix == ".swift"
    ):
        return "Tests"
    if name.startswith("scripts/") and path.suffix in {".py", ".sh", ".swift"}:
        return "Tests" if path.name.startswith("test_") else "Scripts"
    return None


def inventory(root):
    records = []
    # Only these source roots: avoid walking large models, build logs and historical captures.
    for directory in (
        "PRTS",
        "PRTSTests",
        "PRTSUITests",
        "Packages/SpatialCore/Sources",
        "Packages/SpatialCore/Tests",
        "Packages/LocalVLM",
        "Vendor/PRTSCore/Sources",
        "Vendor/PRTSCore/Tests",
        "scripts",
    ):
        for current, directories, filenames in os.walk(root / directory, followlinks=False):
            # Prune before descending; filtering rglob results still traverses build caches.
            directories[:] = sorted(
                d for d in directories if d not in SKIP and not (Path(current) / d).is_symlink()
            )
            for filename in sorted(filenames):
                path = Path(current) / filename
                if path.is_symlink():
                    continue
                relative = path.relative_to(root)
                group = category(relative)
                if group:
                    lines = path.read_text(encoding="utf-8").splitlines()
                    records.append(
                        (
                            relative.as_posix(),
                            group,
                            len(lines),
                            sum(bool(line.strip()) for line in lines),
                        )
                    )
    return sorted(records)


def report(records):
    lines = [
        "# 代码清单",
        "",
        "本报告按需生成，不作为仓库文档维护。运行 `python3 scripts/code_inventory.py` 查看，或加 `--write` 保存到本地 `build/code-inventory.md`。",
        "",
        "## 怎样理解统计范围",
        "",
        "物理行数包含空行和注释，非空行数只排除空行，两者都不等于可执行语句数。",
        "",
        "App 统计 Swift 和 Metal 源码，LocalVLM 包含本地模型封装与准备脚本，Tests 包含 Swift 与 Python 测试。Contracts 指 App 使用的 `PRTSContracts`，OptionalModels 指未链接进 App 的可选模型源码。Total 是本表统计范围的合计，不能当作 App 的实际编译量。",
        "",
        "脚本只扫描 App、测试、SpatialCore、PRTSCore 和 scripts 中指定的源码目录。包含自有 LocalVLM 封装，不统计 Experiments、模型权重、图片、文档和工程配置。",
        "",
        "## 模块规模",
        "",
        "| 模块 | 文件数 | 物理行 | 非空行 |",
        "|---|---:|---:|---:|",
    ]
    for group in (*GROUPS, "Total"):
        selected = records if group == "Total" else [r for r in records if r[1] == group]
        lines.append(
            f"| {group} | {len(selected)} | {sum(r[2] for r in selected)} | {sum(r[3] for r in selected)} |"
        )
    lines += [
        "",
        "## 源码文件树",
        "",
        "括号内为物理行数，目录职责见仓库中的 `docs/architecture.md`。",
        "",
        "```text",
    ]
    previous = ()
    for name, _, physical, _ in records:
        parts = Path(name).parts
        parents = parts[:-1]
        for depth, part in enumerate(parents):
            if previous[: depth + 1] != parents[: depth + 1]:
                lines.append("  " * depth + part + "/")
        lines.append("  " * len(parents) + f"{parts[-1]} ({physical} lines)")
        previous = parents
    return "\n".join(lines + ["```", ""])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--write", action="store_true", help="Save a local report to build/code-inventory.md"
    )
    args = parser.parse_args()
    text = report(inventory(ROOT))
    if args.write:
        output = ROOT / "build/code-inventory.md"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(text, encoding="utf-8")
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
