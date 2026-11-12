# E0 NEGATIVE PROBE (throwaway, do not merge): a deliberately failing assertion.
import unittest


class E0ProbeBroken(unittest.TestCase):
    def test_deliberate_failure(self):
        self.assertEqual(1, 2, "E0 negative probe: deliberate failure")


if __name__ == "__main__":
    unittest.main()
