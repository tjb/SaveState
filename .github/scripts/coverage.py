#!/usr/bin/env python3
"""Reports line coverage across every test bundle, and enforces a floor.

Usage: coverage.py <package dir> [--floor floor.json] [--write-floor floor.json]

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

    run = subprocess.run(
        ["swift", "test", "--enable-code-coverage", *scratch],
        cwd=package,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if run.returncode != 0:
        print(run.stdout)
        sys.exit(f"::error::The tests failed during the coverage run in {package}")
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

    # Files no test bundle links, or with no executable lines, never reach the report.
    unmeasured = sorted(
        str(path.relative_to(package)) for path in (package / "Sources").rglob("*.swift")
        if str(path.relative_to(package)) not in files
    )

    for name, lines in sorted(files.items()):
        print(f"{lines['percent']:6.1f}%  {lines['covered']:4}/{lines['count']:<4}  {name}")
    covered, count = sum(v["covered"] for v in files.values()), sum(v["count"] for v in files.values())
    total = 100 * covered / count if count else 0
    print(f"{total:6.1f}%  {covered:4}/{count:<4}  total")

    if args.write_floor:
        # Rounded down, so a small shift in line counts alone doesn't fail the floor.
        floor = {name: int(lines["percent"]) for name, lines in files.items()}
        floor.update({name: 0 for name in unmeasured})
        floor = dict(sorted(floor.items()))
        pathlib.Path(args.write_floor).write_text(json.dumps(floor, indent=2) + "\n")

    if args.floor:
        floor = json.loads(pathlib.Path(args.floor).read_text())
        failures = [
            f"{name}: {files[name]['percent']:.1f}% is below its floor of {minimum}%"
            for name, minimum in floor.items()
            if name in files and files[name]["percent"] < minimum
        ]
        # A floor of 0 records a deliberate exemption for a file the report can't see.
        failures += [
            f"{name}: listed with a floor of {minimum}% but not measured"
            for name, minimum in floor.items()
            if name not in files and minimum > 0
        ]
        failures += [f"{name}: isn't measured. Test it, or list it with a floor of 0." for name in unmeasured if name not in floor]
        failures += [f"{name}: has no floor. Add it to the floor file." for name in files if name not in floor]
        for failure in failures:
            print(f"::error::{failure}")
        if failures:
            sys.exit(1)


if __name__ == "__main__":
    main()
