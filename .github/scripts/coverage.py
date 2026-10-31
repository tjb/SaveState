#!/usr/bin/env python3
"""Reports line coverage across every test bundle, and enforces a floor.

Usage: coverage.py <package dir> [--floor coverage-floor.json] [--write-floor path]

`swift test --enable-code-coverage` builds one bundle per test target, and its
exported JSON leaves some modules out, so this merges them with llvm-cov directly.
"""
import argparse
import json
import pathlib
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("package")
    parser.add_argument("--scratch-path")
    parser.add_argument("--floor")
    parser.add_argument("--write-floor")
    args = parser.parse_args()
    package = pathlib.Path(args.package).resolve()
    scratch = ["--scratch-path", args.scratch_path] if args.scratch_path else []

    subprocess.run(["swift", "test", "--enable-code-coverage", *scratch], cwd=package, check=True, stdout=subprocess.DEVNULL)
    path = subprocess.run(
        ["swift", "test", "--show-codecov-path", *scratch], cwd=package, check=True, capture_output=True, text=True
    ).stdout.strip().splitlines()[-1]
    codecov = pathlib.Path(path).parent
    products = codecov.parent
    bundles = sorted(products.glob("*.xctest"))
    if not bundles:
        raise SystemExit(f"No test bundles under {products}")
    objects = []
    for bundle in bundles:
        objects += ["-object", str(bundle / "Contents/MacOS" / bundle.stem)]
    report = subprocess.run(
        ["xcrun", "llvm-cov", "export", "-summary-only", *objects, f"-instr-profile={codecov / 'default.profdata'}"],
        check=True,
        capture_output=True,
        text=True,
    )

    root = str(package) + "/"
    files = {}
    for entry in json.loads(report.stdout)["data"][0]["files"]:
        name = entry["filename"]
        if name.startswith(root + "Sources/"):
            files[name[len(root):]] = entry["summary"]["lines"]

    for name, lines in sorted(files.items()):
        print(f"{lines['percent']:6.1f}%  {lines['covered']:4}/{lines['count']:<4}  {name}")
    covered, count = sum(v["covered"] for v in files.values()), sum(v["count"] for v in files.values())
    total = 100 * covered / count if count else 0
    print(f"{total:6.1f}%  {covered:4}/{count:<4}  total")

    if args.write_floor:
        # Rounded down, with a small allowance so unrelated line shifts don't fail.
        floor = {name: int(lines["percent"]) for name, lines in sorted(files.items())}
        pathlib.Path(args.write_floor).write_text(json.dumps(floor, indent=2) + "\n")

    if args.floor:
        floor = json.loads(pathlib.Path(args.floor).read_text())
        failures = [
            f"{name}: {files[name]['percent']:.1f}% is below its floor of {minimum}%"
            for name, minimum in floor.items()
            if name in files and files[name]["percent"] < minimum
        ]
        failures += [f"{name}: listed in the floor but not measured" for name in floor if name not in files]
        failures += [f"{name}: has no floor. Add it to the floor file." for name in files if name not in floor]
        for failure in failures:
            print(f"::error::{failure}")
        if failures:
            sys.exit(1)


if __name__ == "__main__":
    main()
