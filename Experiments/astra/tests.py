import unittest
from metrics import qualified, episodes, future_false, contiguous, resample
import numpy as np

def frame(t, hit=True):
    c=[dict(center=[0,0,-.5],support=6,distance=.5)] if hit else []
    return dict(epoch=1,frameID=round(t*60)+1,timestamp=t,missingDepth=False,tracking=True,raw=dict(clusters=c,allLaneClusters=c))

class MetricsTests(unittest.TestCase):
    def test_gap_never_completes_three_hits(self):
        rr=[frame(0),frame(.1),frame(.3),frame(.4),frame(.5)]
        self.assertEqual(qualified(rr,1)[0],[False,False,False,False,True])
    def test_unknown_not_interpolated(self):
        rr=[frame(0),frame(.1),frame(.2)];rr[1]['missingDepth']=True
        self.assertFalse(any(qualified(rr,1)[0]))
    def test_spatial_cluster_must_match(self):
        rr=[frame(0),frame(.1),frame(.2)];rr[1]['raw']['clusters'][0]['center']=[1,0,0]
        self.assertFalse(any(qualified(rr,1)[0]))
    def test_false_proxy_and_censoring(self):
        rr=[frame(i*.1,i==0) for i in range(21)]
        self.assertTrue(future_false(rr,0,1.5))
        self.assertIsNone(future_false(rr,15,1.5))
        rr[7]['missingDepth']=True;self.assertIsNone(future_false(rr,0,1.5))
    def test_persistent_support_not_false(self):
        rr=[frame(i*.1,i<5) for i in range(21)]
        self.assertFalse(future_false(rr,0,1.5))
    def test_resampling_preserves_endpoints(self):
        p=resample([[0,0,0],[0,0,1],[1,0,1]])
        np.testing.assert_allclose(p[0],[0,0,0]);np.testing.assert_allclose(p[-1],[1,0,1])
        self.assertLessEqual(np.linalg.norm(np.diff(p,axis=0),axis=1).max(),.050001)

if __name__=='__main__':unittest.main()
