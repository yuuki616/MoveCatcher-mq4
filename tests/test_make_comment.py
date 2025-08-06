import string


def make_comment(system: str, seq: str) -> str:
    comment = f"MoveCatcher_{system}_{seq}"
    if len(comment) <= 31:
        return comment

    compact_seq = ''.join(ch for ch in seq if ch not in '() ')
    comment = f"MoveCatcher_{system}_{compact_seq}"
    if len(comment) <= 31:
        return comment

    h = 0
    for ch in seq:
        h = (h * 131 + ord(ch)) & 0x7FFFFFFF
    hash_str = format(h, 'x')
    comment = f"MoveCatcher_{system}_{hash_str}"
    if len(comment) > 31:
        allowed = 31 - len(f"MoveCatcher_{system}_")
        hash_str = hash_str[:allowed]
        comment = f"MoveCatcher_{system}_{hash_str}"
    return comment


def test_make_comment_length():
    samples = [
        "(0,1)",
        "(0,1,2,3,4,5,6,7,8,9)",
        "(" + ",".join(str(i) for i in range(30)) + ")",
        "(" + ",".join(str(i) for i in range(100)) + ")",
    ]
    for seq in samples:
        for system in ['A', 'B']:
            comment = make_comment(system, seq)
            assert len(comment) <= 31
            assert comment.startswith(f"MoveCatcher_{system}_")


def test_hash_string_lowercase():
    seq = "(" + ",".join(str(i) for i in range(100)) + ")"
    for system in ['A', 'B']:
        comment = make_comment(system, seq)
        hash_part = comment.split("_")[-1]
        assert hash_part == hash_part.lower()
