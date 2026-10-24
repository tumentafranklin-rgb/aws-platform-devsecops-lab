pipeline {
    agent { label 'ubuntu-docker' }

    options {
        buildDiscarder(logRotator(numToKeepStr: '5'))
        disableConcurrentBuilds()
        timeout(time: 15, unit: 'MINUTES')
    }

    stages {
        stage('Checkout') {
            steps {
                git branch: 'main',
                    url: 'https://github.com/tumentafranklin-rgb/aws-platform-devsecops-lab.git'
            }
        }

        stage('Verify Tools') {
            steps {
                sh '''
                    whoami
                    java -version
                    docker info --format '{{.ServerVersion}}'
                    trivy --version
                '''
            }
        }

        stage('Build Image') {
            steps {
                sh 'docker build -t lightfeather-lab:${BUILD_NUMBER} ./app'
            }
        }

        stage('Health Test') {
            steps {
                sh '''
                    docker run --rm lightfeather-lab:${BUILD_NUMBER} python -c '
import json
import subprocess
import time
from urllib.request import urlopen

subprocess.Popen(["uvicorn", "main:app", "--host", "127.0.0.1", "--port", "8000"])
time.sleep(5)
response = urlopen("http://127.0.0.1:8000/health", timeout=5)
data = json.load(response)
assert response.status == 200 and data["status"] == "healthy", data
print("PASS: /health returned HTTP 200 and healthy")
'
                '''
            }
        }

        stage('Security Scan') {
            steps {
                sh '''
                    trivy image \
                      --scanners vuln \
                      --severity HIGH,CRITICAL \
                      --ignore-unfixed \
                      --exit-code 1 \
                      --timeout 10m \
                      lightfeather-lab:${BUILD_NUMBER}
                '''
            }
        }
    }
}
}