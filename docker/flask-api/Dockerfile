FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Create log directory — will be overridden by the shared ECS volume at runtime
RUN mkdir -p /var/log/app

EXPOSE 5000

CMD ["python", "app.py"]
