"""A small synthetic photography catalogue. Public API accepts category and page."""
PHOTOS = [
    {"id": 1, "title": "Stone Steps", "category": "Architecture"},
    {"id": 2, "title": "Tide Pool", "category": "Coast"},
    {"id": 3, "title": "Sea Wall", "category": "Coast"},
    {"id": 4, "title": "Last Ferry", "category": "Coast"},
    {"id": 5, "title": "Blue Window", "category": "Architecture"},
]


def catalogue(category="", page=1):
    return {"items": PHOTOS, "total": len(PHOTOS), "page": 1, "pages": 1}
