"""Exercise the native model text boundary without llama.cpp, weights or Apple frameworks."""

import random
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMPILER = shutil.which("clang++") or shutil.which("g++")
HARNESS = r"""
#include "prts_vlm_text_stream.h"
#include <iostream>
#include <vector>

static std::string hex(const std::string &text) {
    static const char *digits = "0123456789abcdef";
    std::string result;
    for (unsigned char byte : text) {
        result += digits[byte >> 4];
        result += digits[byte & 15];
    }
    return result;
}

int main(int argc, char **argv) {
    std::vector<std::string> pieces;
    auto receive = [](void *user, const char *text, size_t count) {
        static_cast<std::vector<std::string> *>(user)->emplace_back(text, count);
    };
    const bool callback = std::string(argv[1]) == "callback";
    prts_vlm_text_stream stream(callback ? receive : nullptr, &pieces);
    bool stopped = false;
    for (int i = 2; i < argc && !stopped; i++) {
        const std::string encoded = argv[i];
        std::string piece;
        for (size_t offset = 0; offset < encoded.size(); offset += 2)
            piece += static_cast<char>(std::stoul(encoded.substr(offset, 2), nullptr, 16));
        stopped = stream.append(piece.data(), piece.size());
    }
    stream.finish();
    std::string spoken;
    for (const auto &piece : pieces)
        spoken += piece;
    std::cout << hex(stream.text()) << '\n' << hex(spoken) << '\n' << stopped << '\n';
    for (const auto &piece : pieces)
        std::cout << hex(piece) << ',';
    std::cout << '\n';
}
"""


@unittest.skipUnless(COMPILER, "Native text stream tests require clang++ or g++")
class LocalVLMTextStreamTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="prts-text-stream-")
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = Path(cls.temporary.name)
        source = directory / "stream.cpp"
        source.write_text(HARNESS, encoding="utf-8")
        cls.executable = directory / ("stream.exe" if Path(COMPILER).suffix == ".exe" else "stream")
        compiled = subprocess.run(
            [
                COMPILER,
                "-std=c++17",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-I",
                str(ROOT / "Packages/LocalVLM/csrc"),
                str(source),
                "-o",
                str(cls.executable),
            ],
            capture_output=True,
            timeout=30,
        )
        if compiled.returncode:
            raise RuntimeError(compiled.stderr.decode("utf-8", errors="replace"))

    def assert_stream(self, pieces, expected, *, stopped=False, callback=True):
        result = subprocess.run(
            [
                str(self.executable),
                "callback" if callback else "silent",
                *(piece.hex() for piece in pieces),
            ],
            check=True,
            capture_output=True,
            timeout=5,
        )
        lines = result.stdout.decode("ascii").splitlines()
        self.assertEqual(bytes.fromhex(lines[0]).decode("utf-8"), expected)
        self.assertEqual(bytes.fromhex(lines[1]).decode("utf-8"), expected if callback else "")
        self.assertEqual(lines[2], "1" if stopped else "0")
        # Every callback must contain complete UTF-8, even when model tokens split characters.
        for piece in lines[3].split(","):
            bytes.fromhex(piece).decode("utf-8")

    def test_literal_comparisons_and_markup_survive_byte_splits(self):
        text = "温度<5℃。\n<div>营业时间</div>\na<b"
        self.assert_stream([bytes([byte]) for byte in text.encode("utf-8")], text)

    def test_known_marker_stops_before_callbacks_at_every_byte_split(self):
        text = "温度<5℃。请冷藏。</think>\n牌子\n虚构的下一轮".encode("utf-8")
        for split in range(len(text) + 1):
            with self.subTest(split=split):
                self.assert_stream([text[:split], text[split:]], "温度<5℃。请冷藏。", stopped=True)

    def test_known_marker_can_arrive_one_byte_at_a_time(self):
        text = "出口</think>虚构的下一轮".encode("utf-8")
        self.assert_stream([bytes([byte]) for byte in text], "出口", stopped=True)

    def test_successful_end_preserves_unfinished_marker_prefixes(self):
        for length in range(1, len("</think>")):
            text = "原文" + "</think>"[:length]
            with self.subTest(prefix=length):
                self.assert_stream([bytes([byte]) for byte in text.encode("utf-8")], text)

    def test_lookalike_tags_remain_literal_text(self):
        text = "<div>字样</div>和</thinking>不终止正文"
        self.assert_stream([bytes([byte]) for byte in text.encode("utf-8")], text)

    def test_marker_stops_inside_one_long_model_piece(self):
        text = "正文</think>" + "虚构的下一轮" * 20
        self.assert_stream([text.encode("utf-8")], "正文", stopped=True)

    def test_returned_answer_uses_the_same_boundary_without_a_callback(self):
        self.assert_stream([b"a<5</think>tail"], "a<5", stopped=True, callback=False)

    def test_randomized_unicode_and_control_marker_boundaries(self):
        generator = random.Random(20261113)
        alphabet = [
            "温度",
            "𠀀",
            "🙂",
            "℃",
            "<",
            ">",
            "</thi",
            "</thinking>",
            "<div>",
            "</div>",
            "\n",
            "。",
            "a",
            "5",
            "",
            "\u0301",
        ]
        for sample in range(1000):
            text = "".join(generator.choice(alphabet) for _ in range(generator.randrange(1, 35)))
            if sample % 2 == 0:
                offset = generator.randrange(len(text) + 1)
                text = text[:offset] + "</think>tail" + text[offset:]
            data = text.encode("utf-8")
            pieces = []
            while data:
                count = generator.randrange(1, 13)
                pieces.append(data[:count])
                data = data[count:]
            pieces.insert(generator.randrange(len(pieces) + 1), b"")
            with self.subTest(sample=sample):
                self.assert_stream(pieces, text.split("</think>", 1)[0], stopped="</think>" in text)


if __name__ == "__main__":
    unittest.main()
