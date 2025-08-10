import pathlib
import re


def test_slippage_pips_used_for_all_orders():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcherLite.mq4"
    code = mc_path.read_text(encoding="utf-8")

    # 新しい入力パラメータが存在する
    assert "input double SlippagePips" in code

    # RetryOrder が成行と指値の両方で呼ばれている
    assert "RetryOrder(false, positionTicket[SYSTEM_A]," in code
    assert "RetryOrder(false, ticketBuyLim, OP_BUYLIMIT" in code

    # OrderSend が SlippagePips / Pip を使用している
    m = re.search(r"OrderSend\([^;]*\);", code)
    assert m is not None
    assert "SlippagePips / Pip" in m.group(0)
