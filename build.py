import os
import time
import subprocess
import urllib.request
import json
import sys

# Configuration
REPO = "djenadimohamedamine-code/spark"
GITHUB_API = f"https://api.github.com/repos/{REPO}/actions/runs"

def run_command(cmd):
    print(f"Exec: {cmd}")
    process = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    stdout, stderr = process.communicate()
    if stdout: print(stdout)
    if stderr: print(stderr)
    return process.returncode

def watch_build():
    print(f"\n--- SURVEILLANCE DU BUILD ({REPO}) ---")
    start_time = time.time()
    
    # Attendre que le build apparaisse (parfois un petit délai après le push)
    time.sleep(5)
    
    while (time.time() - start_time) < 1800: # Max 30 min
        try:
            req = urllib.request.Request(GITHUB_API, headers={"Accept": "application/vnd.github+json"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read())
            
            runs = data.get("workflow_runs", [])
            if not runs:
                print("Aucun run trouvé...")
                time.sleep(10)
                continue
                
            latest_run = runs[0]
            status = latest_run["status"]
            conclusion = latest_run["conclusion"]
            name = latest_run["name"]
            created_at = latest_run["created_at"]
            
            print(f"[{time.strftime('%H:%M:%S')}] {name}: {status} (Conclusion: {conclusion})")
            
            if status == "completed":
                if conclusion == "success":
                    print("\n✅ BUILD REUSSI ! L'APK est prête.")
                else:
                    print(f"\n❌ BUILD ECHOUE. (Conclusion: {conclusion})")
                return
                
            time.sleep(15)
            
        except Exception as e:
            print(f"Erreur surveillance: {e}")
            time.sleep(10)

if __name__ == "__main__":
    print("--- PREPARATION DU PUSH ---")
    run_command("git add .")
    # Tenter un commit (au cas où il reste des changements)
    run_command('git commit -m "Mimo Spark: Auto-Trigger Build"')
    
    print("\n--- PUSH VERS GITHUB ---")
    ret = run_command("git push")
    
    if ret == 0:
        print("\nPush réussi. Lancement de la surveillance...")
        watch_build()
    else:
        print("\nErreur lors du push. (Peut-être pas de nouveaux changements?)")
        # On lance quand même la surveillance pour voir l'état du dernier run
        watch_build()
