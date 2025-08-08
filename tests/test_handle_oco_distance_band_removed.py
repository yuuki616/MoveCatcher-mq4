import pathlib


def test_handle_oco_distance_band_violation_logging():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    content = mc_path.read_text(encoding="utf-8")
    idx = content.find("void HandleOCODetectionFor")
    assert idx != -1, "HandleOCODetectionForが見つからない"
    end_idx = content.find("\nvoid ", idx + 1)
    if end_idx == -1:
        end_idx = len(content)
    fragment = content[idx:end_idx]
    assert "DistanceBandViolation" in fragment, "距離帯判定エラーのハンドリングが必要"
