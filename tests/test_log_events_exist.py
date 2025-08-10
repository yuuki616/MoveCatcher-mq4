import pathlib

def test_log_events_tp_reverse_sl_reentry():
    path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcherLite.mq4"
    content = path.read_text(encoding="utf-8")
    assert 'LogEvent("TP_REVERSE"' in content
    assert 'LogEvent("SL_REENTRY"' in content
