import pathlib


def test_recover_after_sl_slippage_toggle():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    code = mc_path.read_text(encoding="utf-8")
    assert "int    slippage = 0;" in code
    assert "if(UseProtectedLimit)" in code
    assert code.count("slippage = (int)MathRound(reSlippagePips * Pip() / Point);") == 1
    assert "slippage = 0;         // no slippage" in code
    assert "flagInfo = StringFormat(\"UseProtectedLimit=true slippage=%d\", slippage);" in code
    assert "flagInfo = \"UseProtectedLimit=false slippage=0\";" in code
