import unittest
from server import response


class Baseline(unittest.TestCase):
    def test_index_and_api(self):
        self.assertIn("Field Notes", response("/")[2])
        self.assertEqual(response("/api/photos")[1], "application/json")
        self.assertEqual(response("/api/photos?page=0")[0], 400)
        self.assertEqual(response("/missing")[0], 404)
