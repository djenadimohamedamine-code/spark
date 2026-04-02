import urllib.request
import json
import time

REPO = "djenadimohamedamine-code/spark"
GITHUB_API = f"https://api.github.com/repos/{REPO}/actions/runs"

def check_android_build():
    try:
        req = urllib.request.Request(GITHUB_API, headers={"Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
        
        runs = data.get("workflow_runs", [])
        for run in runs:
            if run["name"] == "Mimo-Spark-Android-Build-APK":
                status = run["status"]
                conclusion = run["conclusion"]
                print(f"Build Name: {run['name']}")
                print(f"Status: {status}")
                print(f"Conclusion: {conclusion}")
                print(f"Created at: {run['created_at']}")
                print(f"URL: {run['html_url']}")
                return
        print("Android build not found in recent runs.")
    except Exception as e:
        print(f"Error checking build: {e}")

if __name__ == "__main__":
    check_android_build()
