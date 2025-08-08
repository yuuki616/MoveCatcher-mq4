MAX_COMMENT_LENGTH = 31


def make_comment(system: str, seq: str) -> str:
    comment = f"MoveCatcher_{system}_{seq}"
    if len(comment) > MAX_COMMENT_LENGTH:
        comment = comment[:MAX_COMMENT_LENGTH]
    return comment


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
            assert len(comment) <= MAX_COMMENT_LENGTH
            sys, dec = parse_comment(comment)
            assert sys == system
            assert dec == seq


def test_make_comment_truncates_long_seq():
    seq = "(" + ",".join(str(i) for i in range(20)) + ")"
    comment = make_comment('A', seq)
    assert len(comment) == MAX_COMMENT_LENGTH
    sys, dec = parse_comment(comment)
    assert sys == 'A'
    assert comment == f"MoveCatcher_{sys}_{dec}"

