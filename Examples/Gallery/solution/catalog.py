"""A small synthetic photography catalogue. Public API accepts category and page."""
PHOTOS = [
    {"id": 1, "title": "Stone Steps", "category": "Architecture"},
    {"id": 2, "title": "Tide Pool", "category": "Coast"},
    {"id": 3, "title": "Sea Wall", "category": "Coast"},
    {"id": 4, "title": "Last Ferry", "category": "Coast"},
    {"id": 5, "title": "Blue Window", "category": "Architecture"},
]


def catalogue(category="", page=1):
    selected = [p for p in PHOTOS if not category or p["category"] == category]
    start = (page - 1) * 2
    return {"items": selected[start:start + 2], "total": len(selected),
            "page": page, "pages": (len(selected) + 1) // 2}
