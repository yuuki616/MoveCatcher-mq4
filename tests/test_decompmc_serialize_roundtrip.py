class MockDecompMC:
    def __init__(self, seq, stock, streak):
        self.seq = seq
        self.stock = stock
        self.streak = streak

    def serialize(self):
        seq_str = ",".join(str(x) for x in self.seq)
        return f"{self.stock}|{self.streak}|{seq_str}"

    @classmethod
    def deserialize(cls, data):
        parts = data.split('|')
        assert len(parts) == 3
        stock = int(parts[0])
        streak = int(parts[1])
        seq_parts = parts[2].split(',')
        assert len(seq_parts) >= 2
        seq = [int(x) for x in seq_parts]
        return cls(seq, stock, streak)


def test_serialize_deserialize_roundtrip():
    original = MockDecompMC([0, 1, 2, 3], 5, 7)
    data = original.serialize()
    restored = MockDecompMC.deserialize(data)
    assert restored.seq == original.seq
    assert restored.stock == original.stock
    assert restored.streak == original.streak
