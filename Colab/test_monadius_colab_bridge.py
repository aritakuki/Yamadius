from pathlib import Path
import tempfile
import unittest

from Colab.monadius_colab_bridge import (
    PAGE,
    chunked_multipart_part,
    discard_stale_effect_events,
    read_audio_event_update,
)


class AudioEventUpdateTests(unittest.TestCase):
    def write_events(self, content: bytes) -> Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "audio-events"
        path.write_bytes(content)
        return path

    def test_reconnect_snapshot_restores_only_latest_bgm(self) -> None:
        path = self.write_events(
            b"bgm\tBGM/bgm0.wav\t1.0\t100\n"
            b"play\tSE/shot.wav\t0.1\t200\n"
            b"stop-bgm\t\t1.0\t300\n"
            b"bgm\tBGM/bgm1.wav\t0.8\t400\n"
        )

        offset, events, changed = read_audio_event_update(
            path, -1, include_timestamps=True
        )

        self.assertTrue(changed)
        self.assertEqual(offset, path.stat().st_size)
        self.assertEqual(events, [["bgm", "BGM/bgm1.wav", 0.8, 400]])

    def test_incremental_stream_update_keeps_emission_timestamps(self) -> None:
        first = b"bgm\tBGM/bgm0.wav\t1.0\t100\n"
        path = self.write_events(
            first
            + b"play\tSE/shot.wav\t0.1\t200\n"
            + b"stop\tSE/laser.wav\t0.3\t250\n"
        )

        offset, events, changed = read_audio_event_update(
            path, len(first), include_timestamps=True
        )

        self.assertTrue(changed)
        self.assertEqual(offset, path.stat().st_size)
        self.assertEqual(
            events,
            [
                ["play", "SE/shot.wav", 0.1, 200],
                ["stop", "SE/laser.wav", 0.3, 250],
            ],
        )

    def test_incomplete_line_is_not_consumed(self) -> None:
        complete = b"play\tSE/shot.wav\t0.1\t200\n"
        path = self.write_events(complete + b"play\tSE/laser.wav")

        offset, events, changed = read_audio_event_update(
            path, 0, include_timestamps=True
        )

        self.assertTrue(changed)
        self.assertEqual(offset, len(complete))
        self.assertEqual(events, [["play", "SE/shot.wav", 0.1, 200]])

    def test_legacy_update_omits_timestamps(self) -> None:
        path = self.write_events(b"play\tSE/shot.wav\t0.1\t200\n")

        _offset, events, _changed = read_audio_event_update(
            path, 0, include_timestamps=False
        )

        self.assertEqual(events, [["play", "SE/shot.wav", 0.1]])

    def test_stale_effect_is_dropped_but_music_and_recent_effect_remain(self) -> None:
        events = [
            ["play", "SE/old.wav", 0.1, 1_000],
            ["play", "SE/recent.wav", 0.2, 1_500],
            ["bgm", "BGM/bgm0.wav", 1.0, 1_000],
            ["stop", "SE/old.wav", 0.1, 1_000],
        ]

        filtered = discard_stale_effect_events(events, now_milliseconds=2_001)

        self.assertEqual(filtered, events[1:])


class MultipartStreamTests(unittest.TestCase):
    def test_audio_part_is_valid_chunked_multipart_data(self) -> None:
        payload = b'{"offset":12,"events":[]}'
        chunk = chunked_multipart_part(
            b"monadiusframe",
            "application/json; charset=utf-8",
            payload,
            (("X-Monadius-Message", "audio"),),
        )
        size_text, encoded_part = chunk.split(b"\r\n", 1)
        part = encoded_part[:-2]

        self.assertEqual(int(size_text, 16), len(part))
        self.assertIn(b"Content-Type: application/json; charset=utf-8\r\n", part)
        self.assertIn(b"X-Monadius-Message: audio\r\n", part)
        self.assertTrue(part.endswith(payload + b"\r\n"))

    def test_page_receives_audio_from_frame_stream_without_long_poll(self) -> None:
        self.assertNotIn("fetch('/audio-events", PAGE)
        self.assertNotIn("pollAudioEvents()", PAGE)
        self.assertIn("X-Monadius-Message", PAGE)
        self.assertIn("maxEffectEventAgeMilliseconds", PAGE)


if __name__ == "__main__":
    unittest.main()
