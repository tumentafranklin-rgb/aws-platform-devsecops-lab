from datetime import datetime, timezone

from fastapi import FastAPI

app = FastAPI(
    title="DevSecOps Lab API",
    description="AWS Platform Automation and DevSecOps demonstration",
    version="1.0.0",
)


@app.get("/")
def home():
    return {
        "application": "DevSecOps Lab API",
        "status": "running",
        "message": "Welcome to the AWS DevSecOps Lab!",
    }


@app.get("/health")
def health():
    return {
        "status": "healthy",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/info")
def info():
    return {
        "project": "AWS Platform Automation and DevSecOps Lab",
        "environment": "development",
        "version": "1.0.0",
    }