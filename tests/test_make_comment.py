def make_comment(system: str, seq: str) -> str:
    return f"MoveCatcher_{system}_{seq}"


def parse_comment(comment: str):
    prefix = "MoveCatcher_"
    assert comment.startswith(prefix)
    rest = comment[len(prefix):]
    system, seq = rest.split("_", 1)
    return system, seq


def test_make_comment_roundtrip():
    samples = [
        "(0,1)",
        "(" + ",".join(str(i) for i in range(8)) + ")",
        "(10,11,12,13)",
    ]
    for seq in samples:
        for system in ['A', 'B']:
            comment = make_comment(system, seq)
            assert len(comment) <= 31
            sys, dec = parse_comment(comment)
            assert sys == system
            assert dec == seq

