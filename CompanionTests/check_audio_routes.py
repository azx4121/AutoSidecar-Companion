"""用已套用修正的來源執行離線 AVAudioEngine 音訊路由測試。"""
import argparse
from pathlib import Path
import subprocess
import tempfile


def check(source):
    audio = (source / "iPadOSClient/WiredDisplayClient/Sources/ClientAudio.swift").read_text()
    buffers = audio[audio.index("final class SpeakerBuffers"):audio.index("/// iPad audio")]
    start = audio.index("    private nonisolated static func makeSpeakerSource(")
    factory = audio[start:audio.index("    /// Asks for microphone permission", start)]
    fixture = Path(__file__).with_name("audio-route-tests.swift").read_text()
    with tempfile.TemporaryDirectory() as temp:
        staging = Path(temp)
        test = staging / "AudioRoutes.swift"
        test.write_text("import AVFoundation\nimport os\n" + buffers + fixture +
                        "\nextension AudioRoutes {\n" + factory + "}\n")
        session = source / "Shared/Session"
        files = [session / (name + ".swift") for name in ("Wire", "Messages", "KeyMap", "AudioJitterBuffer")]
        binary = staging / "audio-routes"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", *files, test, "-o", binary], check=True)
        subprocess.run([binary], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="可攜版整合後的原始碼根目錄")
    check(parser.parse_args().source)
