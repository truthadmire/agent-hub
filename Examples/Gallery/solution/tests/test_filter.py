import json
import unittest
from server import response


class FilteredIndex(unittest.TestCase):
    def test_filter_then_paginate(self):
        status, _, body = response("/api/photos?category=Coast&page=2")
        result = json.loads(body)
        self.assertEqual(status, 200)
        self.assertEqual((result["page"], result["pages"], result["total"]), (2, 2, 3))
        self.assertEqual([p["title"] for p in result["items"]], ["Last Ferry"])

    def test_empty_and_invalid(self):
        for target in ["/api/photos?category=Missing", "/api/photos?page=99"]:
            self.assertEqual(json.loads(response(target)[2])["items"], [])
        for page in ["0", "-1", "banana"]:
            self.assertEqual(response("/api/photos?page=" + page)[0], 400)

    def test_html(self):
        self.assertIn("No photographs found.", response("/?category=Portraits")[2])
        page = response("/?category=Coast")[2]
        self.assertIn("Apply filter", page)
        self.assertIn("category=Coast&amp;page=2", page)
        self.assertIn("Tide Pool", page)
