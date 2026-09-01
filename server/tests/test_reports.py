from fastapi.testclient import TestClient
from app.main import app
import json

client = TestClient(app)

def test_pdf_report_not_found():
    response = client.get("/reports/99999/pdf")
    assert response.status_code == 404
