BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def make_comment(system: str, seq: str) -> str:
    cleaned = seq.replace("(", "").replace(")", "").replace(" ", "")
    parts = cleaned.split(",") if cleaned else []
    encoded = "".join(BASE64[int(p)] for p in parts if p)
    return f"MoveCatcher_{system}_{encoded}"


def parse_comment(comment: str):
    prefix = "MoveCatcher_"
    assert comment.startswith(prefix)
    rest = comment[len(prefix):]
    system, enc = rest.split("_", 1)
    numbers = [str(BASE64.index(ch)) for ch in enc]
    seq = "(" + ",".join(numbers) + ")"
    return system, seq


def test_make_comment_roundtrip():
    samples = [
        "(0,1)",
        "(" + ",".join(str(i) for i in range(10)) + ")",
        "(" + ",".join(str(i % 64) for i in range(17)) + ")",
    ]
    for seq in samples:
        for system in ['A', 'B']:
            comment = make_comment(system, seq)
            assert len(comment) <= 31
            sys, dec = parse_comment(comment)
            assert sys == system
            assert dec == seq

