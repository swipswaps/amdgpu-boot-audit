# PATH: backend/Dockerfile
#
# WHAT: Container image for the boot-audit REST API.
#       Runs app.py on port 5002. The DB is never copied into the image —
#       it is mounted read-only via docker-compose volume at runtime.
#
# WHY:  Keeping the DB outside the image means:
#       1. The image is stateless and rebuildable without data loss.
#       2. boot-audit-db.sh continues writing to the DB on the host;
#          the container sees live updates on every request.
#
# MENTAL MODEL BEFORE: DB is a local file only accessible to bash scripts.
# MENTAL MODEL AFTER:  DB is mounted into the container at /data/boot_audit.db
#       and served as JSON on port 5002.
#
# FAILURE MODE: if the DB volume is not mounted, /health returns
#       {"status":"error","reason":"unable to open database file"}.
#       The frontend shows the offline banner — no silent failure.
#
# VERIFIES WITH: docker compose up --build; curl http://localhost:5002/health
#       returns {"status":"ok","row_count":N}.
#
# Source (Tier 4): swipswaps/receipts-ocr backend/Dockerfile — FROM python:3.12-slim pattern.
#   https://github.com/swipswaps/receipts-ocr/blob/main/backend/Dockerfile
# Source (Tier 2): Docker docs — EXPOSE declares the port the container listens on.
#   https://docs.docker.com/reference/dockerfile/#expose
# Source (Tier 2): Python packaging — pip install --no-cache-dir reduces image size.
#   https://pip.pypa.io/en/stable/topics/caching/

FROM python:3.12-slim

# WHAT: set working directory inside the container.
# WHY:  all subsequent COPY and CMD paths are relative to this directory.
# Source (Tier 2): Docker docs — WORKDIR sets the working directory.
#   https://docs.docker.com/reference/dockerfile/#workdir
WORKDIR /app

# WHAT: install Python dependencies before copying app code.
# WHY:  Docker layer caching — requirements layer is rebuilt only when
#       requirements.txt changes, not on every code change.
# Source (Tier 2): Docker best practices — "Order layers from least to most frequently changing."
#   https://docs.docker.com/develop/develop-images/dockerfile_best-practices/
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# WHAT: copy the application code.
# WHY:  only app.py is needed — no DB files, no secrets.
COPY app.py .

# WHAT: declare the port the container listens on.
# WHY:  docker-compose maps host port 5002 to this container port 5002.
#       EXPOSE is documentation + allows docker inspect to show the port.
# Source (Tier 2): Docker docs — EXPOSE. https://docs.docker.com/reference/dockerfile/#expose
EXPOSE 5002

# WHAT: run the Flask app via gunicorn for production threading.
# WHY:  the frontend may poll /health and /boots simultaneously while
#       /diff is also processing. gunicorn with 2 workers handles this.
#       Matches receipts-ocr pattern: "gunicorn with 4 threads allows
#       /logs during OCR processing."
# FAILURE MODE: if gunicorn is not installed, container exits immediately.
#       pre-delivery check: docker logs boot-audit-api | grep ERROR
# Source (Tier 4): swipswaps/receipts-ocr backend/Dockerfile — gunicorn CMD pattern.
#   https://github.com/swipswaps/receipts-ocr/blob/main/backend/Dockerfile
# Source (Tier 2): gunicorn docs — "--workers N sets the number of worker processes."
#   https://docs.gunicorn.org/en/stable/settings.html#workers
CMD ["gunicorn", "--bind", "0.0.0.0:5002", "--workers", "2",
     "--timeout", "30", "--log-level", "info", "app:app"]
