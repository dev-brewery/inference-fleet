FROM python:3.12-slim
WORKDIR /app
COPY driver.py /app/driver.py
CMD ["python", "driver.py"]
