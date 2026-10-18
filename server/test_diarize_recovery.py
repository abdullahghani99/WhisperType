import unittest
import diarize as d
class Timeline:
    def duration(self):return 5.0
class Diar:
    def __init__(self,n=2):self.n=n
    def labels(self):return list(range(self.n))
    def label_timeline(self,label):return Timeline()
class Out:
    def __init__(self,v):self.speaker_embeddings=v;self.speaker_diarization=Diar(len(v))
class RecoveryTests(unittest.TestCase):
    def test_trigger_requires_short_degenerate_multispeaker_result(self):
        self.assertTrue(d.needs_short_recovery(Out([[1,0],[0,0]]),147))
        self.assertFalse(d.needs_short_recovery(Out([[1,0],[0,0]]),301))
        self.assertFalse(d.needs_short_recovery(Out([[1,0],[0,1]]),147))
        self.assertFalse(d.needs_short_recovery(Out([[1,0]]),147))
    def test_zero_and_nonfinite_vectors_are_invalid(self):
        for v in [[],[0,0],[float('nan'),1],[float('inf'),1]]:self.assertFalse(d.usable_embedding(v))
    def test_retry_must_have_valid_distinct_voices(self):
        self.assertTrue(d.recovery_is_distinct(Out([[1,0],[0,1]])))
        for v in [[[1,0],[0,0]],[[1,0],[1,.01]],[[1,0]],[[1,0]]*5]:self.assertFalse(d.recovery_is_distinct(Out(v)))
if __name__=='__main__':unittest.main()
