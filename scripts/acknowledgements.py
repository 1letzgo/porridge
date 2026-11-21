#!/usr/bin/env python3
"""Builds the Acknowledgements lists the apps show in Settings: every third-party package and model with
version, license and the full license text.

    scripts/acknowledgements.py [<SwiftPM checkouts>]

Writes Porridge/Resources/Acknowledgements.json (iOS + Mac). The Swift license texts come from the SwiftPM checkouts
(default /tmp/PorridgeMac-dd/SourcePackages/checkouts), the rest is fetched once from the projects.
Run it again after a dependency update and adjust the versions below (Package.resolved).

Format: {"licenses": {key: text}, "sections": [{"title", "entries": [{"name", "version", "license", "url", "text"}]}]};
identical texts are stored once.
"""
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKOUTS = sys.argv[1] if len(sys.argv) > 1 else "/tmp/PorridgeMac-dd/SourcePackages/checkouts"

_cache = {}


def fetch(url):
    if url not in _cache:
        _cache[url] = subprocess.run(["curl", "-sfL", url], check=True, capture_output=True, text=True).stdout
    return _cache[url]


def local(path):
    with open(os.path.join(CHECKOUTS, path), encoding="utf-8") as f:
        return f.read()


def gh(repo, path="LICENSE", ref="HEAD"):
    return fetch(f"https://raw.githubusercontent.com/{repo}/{ref}/{path}")


APACHE = lambda: fetch("https://www.apache.org/licenses/LICENSE-2.0.txt")
CC_BY_4 = lambda: fetch("https://creativecommons.org/licenses/by/4.0/legalcode.txt")


def speaker_notice():
    """FluidInference's attribution for the Core ML speaker models, without the citation block of the README."""
    return fetch("https://huggingface.co/FluidInference/speaker-diarization-coreml/raw/main/NOTICE.md")


def pyannote_mit():
    """The MIT notice of pyannote/segmentation-3.0 (gated on Hugging Face; FluidInference reproduces it)."""
    notice = speaker_notice()
    return re.search(r"```\s*\n(MIT License.*?)```", notice, re.S).group(1)


def resolved_versions():
    path = os.path.join(ROOT, "Porridge.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    with open(path) as f:
        pins = json.load(f)["pins"]
    return {p["identity"]: p["state"].get("version") or p["state"]["revision"][:7] for p in pins}


def apple():
    v = resolved_versions()
    libs = [
        ("EventSource", v["eventsource"], "MIT", "https://github.com/mattt/EventSource", lambda: local("EventSource/LICENSE.md")),
        ("FluidAudio", v["fluidaudio"], "Apache 2.0", "https://github.com/FluidInference/FluidAudio", lambda: local("FluidAudio/LICENSE")),
        ("NeMo Text Processing (in FluidAudio)", "0.3.0", "Apache 2.0", "https://github.com/FluidInference/text-processing-rs",
         lambda: local("FluidAudio/ThirdPartyLicenses/NemoTextProcessing-LICENSE.md") + "\n\n" + APACHE()),
        ("fastcluster (in FluidAudio)", "", "BSD 2-Clause", "https://danifold.net/fastcluster.html",
         lambda: local("FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md")),
        ("VBx (in FluidAudio)", "", "Apache 2.0", "https://github.com/BUTSpeechFIT/VBx", lambda: local("FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md")),
        ("MLX Swift", v["mlx-swift"], "MIT", "https://github.com/ml-explore/mlx-swift", lambda: local("mlx-swift/LICENSE")),
        ("MLX Swift LM", v["mlx-swift-lm"], "MIT", "https://github.com/ml-explore/mlx-swift-lm", lambda: local("mlx-swift-lm/LICENSE")),
        ("MLX (in MLX Swift)", mlx_version(), "MIT", "https://github.com/ml-explore/mlx", lambda: local("mlx-swift/Source/Cmlx/mlx/LICENSE")),
        ("MLX C (in MLX Swift)", mlx_c_version(), "MIT", "https://github.com/ml-explore/mlx-c", lambda: local("mlx-swift/Source/Cmlx/mlx-c/LICENSE")),
        ("Metal C++ (in MLX Swift)", "macOS 15 / iOS 18", "Apache 2.0", "https://developer.apple.com/metal/cpp/",
         lambda: local("mlx-swift/Source/Cmlx/metal-cpp/LICENSE.txt")),
        ("{fmt} (in MLX Swift)", "12.1.0", "MIT", "https://github.com/fmtlib/fmt", lambda: local("mlx-swift/Source/Cmlx/fmt/LICENSE")),
        ("JSON for Modern C++ (in MLX Swift)", "3.11.3", "MIT", "https://github.com/nlohmann/json", lambda: local("mlx-swift/Source/Cmlx/json/LICENSE.MIT")),
        ("Swift ASN.1", v["swift-asn1"], "Apache 2.0", "https://github.com/apple/swift-asn1",
         lambda: local("swift-asn1/LICENSE.txt") + "\n\n" + local("swift-asn1/NOTICE.txt")),
        ("Swift Collections", v["swift-collections"], "Apache 2.0", "https://github.com/apple/swift-collections", lambda: local("swift-collections/LICENSE.txt")),
        ("Swift Crypto", v["swift-crypto"], "Apache 2.0", "https://github.com/apple/swift-crypto",
         lambda: local("swift-crypto/LICENSE.txt") + "\n\n" + local("swift-crypto/NOTICE.txt")),
        ("Swift Hugging Face", v["swift-huggingface"], "Apache 2.0", "https://github.com/huggingface/swift-huggingface", lambda: local("swift-huggingface/LICENSE")),
        ("Swift Jinja", v["swift-jinja"], "Apache 2.0", "https://github.com/huggingface/swift-jinja", lambda: local("swift-jinja/LICENSE")),
        ("Swift Numerics", v["swift-numerics"], "Apache 2.0", "https://github.com/apple/swift-numerics", lambda: local("swift-numerics/LICENSE.txt")),
        ("Swift Syntax", v["swift-syntax"], "Apache 2.0", "https://github.com/swiftlang/swift-syntax", lambda: local("swift-syntax/LICENSE.txt")),
        ("Swift Transformers", v["swift-transformers"], "Apache 2.0", "https://github.com/huggingface/swift-transformers", lambda: local("swift-transformers/LICENSE")),
        ("yyjson", v["yyjson"], "MIT", "https://github.com/ibireme/yyjson", lambda: local("yyjson/LICENSE")),
        ("plaude-archiver (Plaud Bluetooth protocol)", "", "MIT", "https://github.com/roopen219/plaude-archiver", lambda: gh("roopen219/plaude-archiver")),
    ]
    models = [
        ("Parakeet TDT v3 (Core ML)", "0.6B", "CC BY 4.0", "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml",
         lambda: "NVIDIA Parakeet TDT 0.6B v3 (https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), converted to Core ML by "
                 "Fluid Inference.\n\n" + CC_BY_4()),
        ("Speaker Diarization Community-1 (Core ML)", "", "CC BY 4.0", "https://huggingface.co/FluidInference/speaker-diarization-coreml",
         lambda: speaker_notice() + "\n\n" + CC_BY_4()),
        ("Qwen3 4B Instruct 2507 (MLX, 4-bit)", "4B", "Apache 2.0", "https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit", APACHE),
        ("Qwen3.5 4B (MLX, 4-bit)", "4B", "Apache 2.0", "https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit", APACHE),
        ("Qwen3 1.7B (MLX, 4-bit)", "1.7B", "Apache 2.0", "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit", APACHE),
        ("Nemotron 3.5 Bolt-E4B (MLX, 4-bit)", "E4B", "OpenMDW 1.1", "https://huggingface.co/lmstudio-community/NVIDIA-Nemotron-3.5-Bolt-E4B-MLX-4bit",
         lambda: gh("OpenMDW/OpenMDW", "1.1/LICENSE.OpenMDW-1.1", "main")),
    ]
    return [("Libraries", libs), ("Models", models)]


def mlx_version():
    h = local("mlx-swift/Source/Cmlx/mlx/mlx/version.h")
    part = lambda n: re.search(rf"MLX_VERSION_{n} (\d+)", h).group(1)
    return f"{part('MAJOR')}.{part('MINOR')}.{part('PATCH')}"


def mlx_c_version():
    return re.search(r"set\(MLX_C_VERSION ([\d.]+)\)", local("mlx-swift/Source/Cmlx/mlx-c/CMakeLists.txt")).group(1)


def build(sections):
    licenses, keys, out = {}, {}, []
    for title, entries in sections:
        items = []
        for name, version, license, url, text in entries:
            body = text().strip() + "\n"
            digest = hashlib.sha1(body.encode()).hexdigest()
            if digest not in keys:
                keys[digest] = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
                licenses[keys[digest]] = body
            items.append({"name": name, "version": version, "license": license, "url": url, "text": keys[digest]})
        out.append({"title": title, "entries": sorted(items, key=lambda e: e["name"].lower())})
    return {"licenses": licenses, "sections": out}


def write(path, data):
    path = os.path.join(ROOT, path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(path, sum(len(s["entries"]) for s in data["sections"]), "entries,", len(data["licenses"]), "texts")


write("Porridge/Resources/Acknowledgements.json", build(apple()))
