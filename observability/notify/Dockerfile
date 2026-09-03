FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
ENV PORT=8080
CMD ["functions-framework", "--target=notify", "--host=0.0.0.0", "--port=8080"]
