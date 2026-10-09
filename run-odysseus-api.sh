cd odysseus
python3 -m venv venv
source venv/bin/activate
python -m uvicorn app:app --host 127.0.0.1 --port 7000

