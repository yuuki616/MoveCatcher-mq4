import pathlib


def test_handle_oco_distance_band_removed():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    content = mc_path.read_text(encoding="utf-8")
    idx = content.find("void HandleOCODetectionFor")
    assert idx != -1, "HandleOCODetectionForが見つからない"
    end_idx = content.find("\nvoid ", idx + 1)
    if end_idx == -1:
        end_idx = len(content)
    fragment = content[idx:end_idx]
    assert "UseDistanceBand" not in fragment, "HandleOCODetectionForに距離帯判定が残っている"
    assert "outside band" not in fragment, "距離帯スキップのログが残っている"
